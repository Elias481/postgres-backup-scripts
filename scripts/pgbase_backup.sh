#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# pgbase_backup.sh
# Usage: pgbase_backup.sh <backup-base> <instance>
# - backup-base: base path for backups, e.g. /var/lib/postgresql/backup (required)
# - instance: instance name, e.g. main (required)
#
# Behavior:
# - generates UTC timestamp (YYYYMMDDTHHMMSSZ)
# - runs pg_basebackup into $BACKUP_BASE/<instance>/<timestamp>
# - parses a single manifest file (no recursive grep) to extract Start-LSN
#   (uses jq if available, otherwise a targeted grep on the manifest file)
# - converts Start-LSN to WAL filename using psql + pg_walfile_name()
# - moves matching backup-info files (<walname>.backup and .sha256) from
#   $BACKUP_BASE/<instance>/info into the backup directory
# - fallback: scan info dir for any *.backup containing the LABEL string

PG_BASEBACKUP=${PG_BASEBACKUP:-pg_basebackup}
PSQL_CMD=${PSQL_CMD:-psql}

usage() {
  cat <<EOF
Usage: $0 <backup-base> <instance>

Examples:
  $0 /var/lib/postgresql/backup main

Notes:
- The script generates a UTC timestamp automatically (format: YYYYMMDDTHHMMSSZ).
- Run as the postgres user (systemd unit or cron) so pg_basebackup can access the DB.
EOF
  exit 2
}

if [ "$#" -ne 2 ]; then
  usage
fi

BACKUP_BASE="$1"
INSTANCE="$2"
if [ -z "$BACKUP_BASE" ] || [ -z "$INSTANCE" ]; then
  echo "backup-base and instance must not be empty" >&2
  usage
fi

# UTC timestamp
TS=$(date -u +"%Y%m%dT%H%M%SZ")
BACKUP_DIR="$BACKUP_BASE/$INSTANCE/$TS"
INFO_DIR="$BACKUP_BASE/$INSTANCE/info"

created_dir=0

cleanup_on_error() {
  if [ "$created_dir" -eq 1 ] && [ -d "$BACKUP_DIR" ]; then
    rm -rf -- "$BACKUP_DIR" || true
  fi
}

trap 'rc=$?; echo "Error running pg_basebackup for $INSTANCE (exit $rc)" >&2; cleanup_on_error; exit 2' ERR INT TERM

mkdir -p "$BACKUP_DIR"
created_dir=1

echo "Starting pg_basebackup for instance='$INSTANCE' -> $BACKUP_DIR"

LABEL="pg_basebackup $INSTANCE $TS"

"$PG_BASEBACKUP" -D "$BACKUP_DIR" -F tar -X none -Z zstd:workers=0 -c fast -l "$LABEL" --manifest-checksums=sha256 -w

# success: disable trap cleanup and continue
trap - ERR INT TERM
echo "pg_basebackup completed successfully: $BACKUP_DIR"

# Find a single manifest file inside the backup dir (targeted locations, no recursion)
MANIFEST_FILE=""
MANIFEST_CANDIDATES=(
  "$BACKUP_DIR/backup_manifest.json"
  "$BACKUP_DIR/manifest/backup_manifest.json"
  "$BACKUP_DIR/backup_manifest/manifest.json"
  "$BACKUP_DIR/manifest.json"
)
for f in "${MANIFEST_CANDIDATES[@]}"; do
  if [ -f "$f" ]; then
    MANIFEST_FILE="$f"
    break
  fi
done

# top-level fallback: any file in backup dir matching *manifest*.json (non-recursive)
if [ -z "$MANIFEST_FILE" ]; then
  for f in "$BACKUP_DIR"/*manifest*.json; do
    if [ -f "$f" ]; then
      MANIFEST_FILE="$f"
      break
    fi
  done
fi

if [ -z "$MANIFEST_FILE" ]; then
  echo "Warning: manifest file not found in $BACKUP_DIR; cannot determine Start-LSN. Leaving backup-info in $INFO_DIR" >&2
  exit 0
fi

# Extract Start-LSN from manifest (jq preferred)
if command -v jq >/dev/null 2>&1; then
  START_LSN=$(jq -r '."WAL-Ranges"[0]."Start-LSN" // empty' "$MANIFEST_FILE" 2>/dev/null || true)
else
  START_LSN=$(grep -m1 -oP '"Start-LSN"\s*:\s*"\K[0-9A-Fa-f/]+' "$MANIFEST_FILE" 2>/dev/null || true)
fi

if [ -z "$START_LSN" ]; then
  echo "Warning: Start-LSN not found in manifest $MANIFEST_FILE; leaving backup-info in $INFO_DIR" >&2
  exit 0
fi

if ! command -v "$PSQL_CMD" >/dev/null 2>&1; then
  echo "psql not available to compute WAL filename; leaving backup-info in $INFO_DIR" >&2
  exit 0
fi

# Function to try moving info by wal-name
try_move_info() {
  local name="$1"
  [ -z "$name" ] && return 1
  local cand="$INFO_DIR/${name}.backup"
  if [ -f "$cand" ]; then
    mv -- "$cand" "$BACKUP_DIR/" || { echo "Failed to move $cand" >&2; return 1; }
    if [ -f "$INFO_DIR/${name}.sha256" ]; then
      mv -- "$INFO_DIR/${name}.sha256" "$BACKUP_DIR/" || true
    fi
    echo "Moved backup-info $cand -> $BACKUP_DIR/"
    return 0
  fi
  return 1
}

# Compute WAL name for START_LSN using pg_walfile_name
WAL_NAME=$("$PSQL_CMD" -t -A -c "SELECT pg_walfile_name('$START_LSN'::pg_lsn);" 2>/dev/null || true)
if try_move_info "$WAL_NAME"; then
  exit 0
fi

# Fallback: look for any *.backup in info that contains the LABEL
found_any=0
if [ -d "$INFO_DIR" ]; then
  for f in "$INFO_DIR"/*.backup; do
    [ -e "$f" ] || continue
    if grep -qF "$LABEL" "$f" 2>/dev/null; then
      mv -- "$f" "$BACKUP_DIR/" || echo "Failed to move $f" >&2
      if [ -f "${f%.backup}.sha256" ]; then
        mv -- "${f%.backup}.sha256" "$BACKUP_DIR/" || true
      fi
      echo "Moved backup-info $f -> $BACKUP_DIR/"
      found_any=1
    fi
  done
fi

if [ "$found_any" -eq 1 ]; then
  exit 0
fi

echo "No matching backup-info file found in $INFO_DIR for Start-LSN $START_LSN (WAL name: $WAL_NAME) or by LABEL $LABEL" >&2
exit 0
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# pgbase_backup.sh
# Usage: pgbase_backup.sh <instance-name>
# The script generates a UTC timestamp and runs pg_basebackup into
# $BACKUP_BASE/<instance>/<timestamp>
# After a successful backup it parses the manifest file (not greedy search),
# extracts Start-LSN (or End-LSN fallback), asks the server for the WAL filename
# (pg_walfile_name) and moves matching backup-info (*.backup and *.sha256) from
# $BACKUP_BASE/<instance>/info into the backup directory.

PG_BASEBACKUP=${PG_BASEBACKUP:-pg_basebackup}
PSQL_CMD=${PSQL_CMD:-psql}

usage() {
  cat <<EOF
Usage: $0 <backup-base> <instance>

Examples:
  $0 /var/lib/postgresql/backup main

Notes:
- The script generates a UTC timestamp automatically (format: YYYYMMDDTHHMMSSZ).
- Run as the postgres user (systemd unit or cron) so pg_basebackup can access the DB.
EOF
  exit 2
}

if [ "$#" -ne 2 ]; then
  usage
fi

BACKUP_BASE="$1"
INSTANCE="$2"
if [ -z "$BACKUP_BASE" ] || [ -z "$INSTANCE" ]; then
  echo "backup-base and instance must not be empty" >&2
  usage
fi

# UTC timestamp, sortable and parseable: 20260407T173100Z
TS=$(date -u +"%Y%m%dT%H%M%SZ")
BACKUP_DIR="$BACKUP_BASE/$INSTANCE/$TS"
INFO_DIR="$BACKUP_BASE/$INSTANCE/info"

created_dir=0

cleanup_on_error() {
  if [ "$created_dir" -eq 1 ] && [ -d "$BACKUP_DIR" ]; then
    rm -rf -- "$BACKUP_DIR" || true
  fi
}

trap 'rc=$?; echo "Error running pg_basebackup for $INSTANCE (exit $rc)" >&2; cleanup_on_error; exit 2' ERR INT TERM

mkdir -p "$BACKUP_DIR"
created_dir=1

echo "Starting pg_basebackup for instance='$INSTANCE' -> $BACKUP_DIR"

LABEL="pg_basebackup $INSTANCE $TS"

"$PG_BASEBACKUP" -D "$BACKUP_DIR" -F tar -X none -Z zstd:workers=0 -c fast -l "$LABEL" --manifest-checksums=sha256 -w

# success: disable trap cleanup and continue
trap - ERR INT TERM
echo "pg_basebackup completed successfully: $BACKUP_DIR"

## Manifest parsing: look for known manifest files (no greedy recursive grep)
MANIFEST_FILE=""
MANIFEST_CANDIDATES=(
  "$BACKUP_DIR/backup_manifest.json"
  "$BACKUP_DIR/manifest/backup_manifest.json"
  "$BACKUP_DIR/backup_manifest/manifest.json"
  "$BACKUP_DIR/manifest.json"
)
for f in "${MANIFEST_CANDIDATES[@]}"; do
  if [ -f "$f" ]; then
    MANIFEST_FILE="$f"
    break
  fi
done

# top-level fallback: any file in backup dir matching *manifest*.json (non-recursive)
if [ -z "$MANIFEST_FILE" ]; then
  for f in "$BACKUP_DIR"/*manifest*.json; do
    if [ -f "$f" ]; then
      MANIFEST_FILE="$f"
      break
    fi
  done
fi

if [ -z "$MANIFEST_FILE" ]; then
  echo "Warning: manifest file not found in $BACKUP_DIR; cannot determine Start-LSN. Leaving backup-info in $INFO_DIR" >&2
  exit 0
fi

START_LSN=""
if command -v jq >/dev/null 2>&1; then
  # JSON-safe extraction of Start-LSN
  START_LSN=$(jq -r '."WAL-Ranges"[0]."Start-LSN" // empty' "$MANIFEST_FILE" 2>/dev/null || true)
else
  # targeted grep on manifest file only
  START_LSN=$(grep -m1 -oP '"Start-LSN"\s*:\s*"\K[0-9A-Fa-f/]+' "$MANIFEST_FILE" 2>/dev/null || true)
fi

if [ -z "$START_LSN" ]; then
  echo "Warning: Start-LSN not found in manifest $MANIFEST_FILE; leaving backup-info in $INFO_DIR" >&2
  exit 0
fi

if ! command -v "$PSQL_CMD" >/dev/null 2>&1; then
  echo "psql not available to compute WAL filename; leaving backup-info in $INFO_DIR" >&2
  exit 0
fi

# Function to try moving info by wal-name
try_move_info() {
  local name="$1"
  [ -z "$name" ] && return 1
  local cand="$INFO_DIR/${name}.backup"
  if [ -f "$cand" ]; then
    mv -- "$cand" "$BACKUP_DIR/" || { echo "Failed to move $cand" >&2; return 1; }
    if [ -f "$INFO_DIR/${name}.sha256" ]; then
      mv -- "$INFO_DIR/${name}.sha256" "$BACKUP_DIR/" || true
    fi
    echo "Moved backup-info $cand -> $BACKUP_DIR/"
    return 0
  fi
  return 1
}

# Compute WAL name for START_LSN using pg_walfile_name
WAL_NAME=$("$PSQL_CMD" -t -A -c "SELECT pg_walfile_name('$START_LSN'::pg_lsn);" 2>/dev/null || true)
if try_move_info "$WAL_NAME"; then
  exit 0
fi

# Fallback: find backup-info files in $INFO_DIR that contain the LABEL (pg_basebackup <instance> <TS>)
# the LABEL is generated earlier as: LABEL="pg_basebackup $INSTANCE $TS"
found_any=0
if [ -d "$INFO_DIR" ]; then
  for f in "$INFO_DIR"/*.backup; do
    [ -e "$f" ] || continue
    if grep -qF "$LABEL" "$f" 2>/dev/null; then
      mv -- "$f" "$BACKUP_DIR/" || echo "Failed to move $f" >&2
      if [ -f "${f%.backup}.sha256" ]; then
        mv -- "${f%.backup}.sha256" "$BACKUP_DIR/" || true
      fi
      echo "Moved backup-info $f -> $BACKUP_DIR/"
      found_any=1
    fi
  done
fi

if [ "$found_any" -eq 1 ]; then
  exit 0
fi

echo "No matching backup-info file found in $INFO_DIR for Start-LSN $START_LSN (WAL name: $WAL_NAME) or by LABEL $LABEL" >&2
exit 0
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# pgbase_backup.sh
# Usage: pgbase_backup.sh <instance-name> [timestamp]
# - instance-name: e.g. "main"
# - timestamp (optional): if omitted, current UTC timestamp in format YYYYMMDDTHHMMSSZ is used
#
# This script creates a directory under $BACKUP_BASE/<instance>/<timestamp> and runs:
# pg_basebackup -D <that-dir> -F tar -X none -Z zstd:workers=0 -c fast -l "pg_basebackup <instance> <timestamp>" --manifest-checksums=sha256 -w
#
# Intended to be run from cron or a systemd timer as the postgres user (or ensure pg_basebackup is usable).

BACKUP_BASE=${BACKUP_BASE:-/var/lib/postgresql/backup}
PG_BASEBACKUP=${PG_BASEBACKUP:-pg_basebackup}


usage() {
  cat <<EOF
Usage: $0 <instance-name>

Examples:
  $0 main

usage() {
  cat <<EOF
Usage: $0 <instance-name>

Examples:
  $0 main

Notes:
- The script generates a UTC timestamp automatically (format: YYYYMMDDTHHMMSSZ).
- Run as the postgres user (systemd unit or cron) so pg_basebackup can access the DB.
EOF
  exit 2
}
created_dir=1

echo "Starting pg_basebackup for instance='$INSTANCE' -> $BACKUP_DIR"

# Build the label for pg_basebackup (human readable)
LABEL="pg_basebackup $INSTANCE $TS"

# Run pg_basebackup with the requested options.
# Note: the command may need to be executed as the 'postgres' user depending on your setup.
"$PG_BASEBACKUP" -D "$BACKUP_DIR" -F tar -X none -Z zstd:workers=0 -c fast -l "$LABEL" --manifest-checksums=sha256 -w

# success: disable trap cleanup and print success
trap - ERR INT TERM
echo "pg_basebackup completed successfully: $BACKUP_DIR"

# After successful basebackup, try to locate and move the related backup-info file
# We look for a Start-LSN inside files produced by the backup (manifest/backup_label) and
# ask the server to map that LSN to a WAL filename using pg_walfile_name().

INFO_DIR="$BACKUP_BASE/$INSTANCE/info"

START_LSN=""
# Try JSON-like manifest first
START_LSN=$(grep -R -m1 -oP '"Start-LSN"\s*:\s*"\K[0-9A-Fa-f/]+' "$BACKUP_DIR" 2>/dev/null || true)
if [ -z "$START_LSN" ]; then
  # Fallback: look for textual backup_label style
  START_LSN=$(grep -R -m1 -oP 'START WAL LOCATION:\s*\K[0-9A-Fa-f/]+' "$BACKUP_DIR" 2>/dev/null || true)
fi

if [ -z "$START_LSN" ]; then
  echo "Warning: could not find Start-LSN in backup artifacts under $BACKUP_DIR" >&2
  exit 0
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "psql not available to compute WAL filename; leaving backup-info in $INFO_DIR" >&2
  exit 0
fi

# Use the server to compute the WAL filename for the Start-LSN
WAL_NAME=""
# Compute WAL name for START_LSN using pg_walfile_name
WAL_NAME=$(psql -t -A -c "SELECT pg_walfile_name('$START_LSN'::pg_lsn);" 2>/dev/null || true)

try_move_info() {
  local name="$1"
  local cand="$INFO_DIR/${name}.backup"
  if [ -n "$name" ] && [ -f "$cand" ]; then
    mv -- "$cand" "$BACKUP_DIR/" || echo "Failed to move $cand" >&2
    if [ -f "$INFO_DIR/${name}.sha256" ]; then
      mv -- "$INFO_DIR/${name}.sha256" "$BACKUP_DIR/" || true
    fi
    echo "Moved backup-info $cand -> $BACKUP_DIR/"
    return 0
  fi
  return 1
}

if try_move_info "$WAL_NAME"; then
  exit 0
fi

# If not found, try End-LSN from manifest
END_LSN=$(grep -R -m1 -oP '"End-LSN"\s*:\s*"\K[0-9A-Fa-f/]+' "$BACKUP_DIR" 2>/dev/null || true)
if [ -n "$END_LSN" ]; then
  END_WAL_NAME=$(psql -t -A -c "SELECT pg_walfile_name('$END_LSN'::pg_lsn);" 2>/dev/null || true)
  if try_move_info "$END_WAL_NAME"; then
    exit 0
  fi
fi

echo "No matching backup-info file found in $INFO_DIR for Start-LSN $START_LSN (WAL name: $WAL_NAME) or End-LSN $END_LSN" >&2
exit 0
