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

Notes:
- The script generates a UTC timestamp automatically (format: YYYYMMDDTHHMMSSZ).
- Run as the postgres user (systemd unit or cron) so pg_basebackup can access the DB.
EOF
  exit 2
}

if [ "$#" -ne 1 ]; then
  usage
fi

INSTANCE="$1"
if [ -z "$INSTANCE" ]; then
  echo "Instance name must not be empty" >&2
  usage
fi

# UTC timestamp, sortable and parseable: 20260407T173100Z
TS=$(date -u +"%Y%m%dT%H%M%SZ")

BACKUP_DIR="$BACKUP_BASE/$INSTANCE/$TS"

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
