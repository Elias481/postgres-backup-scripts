#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# pgbase_backup.sh
# Usage: pgbase_backup.sh <backup-base> <instance>
#
# Behavior (minimal and deterministic):
# - requires two args: <backup-base> and <instance>
# - generates UTC timestamp (YYYYMMDDTHHMMSSZ)
# - runs system 'pg_basebackup' directly into $BACKUP_BASE/<instance>/<timestamp>
# - reads exactly $BACKUP_DIR/backup_manifest and extracts Start-LSN only
#   (uses jq if present, otherwise a targeted grep on that single file)
# - uses psql to compute WAL filename via pg_walfile_name(Start-LSN)
# - if matching <$walname>.backup exists in $BACKUP_BASE/<instance>/info, move
#   <$walname>.backup and <$walname>.sha256 into the backup directory
# - fallback: if WAL-name move fails, scan $INFO_DIR/*.backup for the LABEL string
#   (LABEL = "pg_basebackup <instance> <timestamp") and move any matches

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

# timestamp
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

# call system pg_basebackup directly
pg_basebackup -D "$BACKUP_DIR" -F tar -X none -Z zstd:workers=0 -c fast -l "$LABEL" --manifest-checksums=sha256 -w

# success: disable trap cleanup and continue
trap - ERR INT TERM
echo "pg_basebackup completed successfully: $BACKUP_DIR"

MANIFEST_FILE="$BACKUP_DIR/backup_manifest"
if [ ! -f "$MANIFEST_FILE" ]; then
  echo "Warning: manifest ($MANIFEST_FILE) not found; leaving backup-info in $INFO_DIR" >&2
  exit 0
fi

# Extract Start-LSN from the single manifest file
if command -v jq >/dev/null 2>&1; then
  START_LSN=$(jq -r '."WAL-Ranges"[0]."Start-LSN" // empty' "$MANIFEST_FILE" 2>/dev/null || true)
else
  START_LSN=$(grep -m1 -oP '"Start-LSN"\s*:\s*"\K[0-9A-Fa-f/]+' "$MANIFEST_FILE" 2>/dev/null || true)
fi

if [ -z "$START_LSN" ]; then
  echo "Warning: Start-LSN not found in $MANIFEST_FILE; leaving backup-info in $INFO_DIR" >&2
  exit 0
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "psql not available; leaving backup-info in $INFO_DIR" >&2
  exit 0
fi

# compute WAL filename from Start-LSN
WAL_NAME=$(psql -t -A -c "SELECT pg_walfile_name('$START_LSN'::pg_lsn);" 2>/dev/null || true)

try_move_info() {
  local name="$1"
  [ -z "$name" ] && return 1
  local cand="$INFO_DIR/${name}.backup"
  if [ -f "$cand" ]; then
    mv -- "$cand" "$BACKUP_DIR/" || { echo "Failed to move $cand" >&2; return 1; }
    # Move the canonical checksum file produced by archive_wal.sh: <basename>.backup.sha256
    if [ -f "$INFO_DIR/${name}.backup.sha256" ]; then
      mv -- "$INFO_DIR/${name}.backup.sha256" "$BACKUP_DIR/backup_info.sha256" || true
    fi
    # Rename moved backup-info to a canonical name so housekeeping can find it easily
    # Use 'backup_info' (no .backup suffix) and checksum 'backup_info.sha256'
    if [ -f "$BACKUP_DIR/${name}.backup" ]; then
      mv -- "$BACKUP_DIR/${name}.backup" "$BACKUP_DIR/backup_info" || true
    fi
    echo "Moved and renamed backup-info ${name}.backup -> $BACKUP_DIR/backup_info"
    return 0
  fi
  return 1
}

## Some backup-info producers append an extra component derived from Start-LSN
## Format: <walname>.00<last6hex>.backup  (where last6hex are the last 6 hex digits
## of the Start-LSN offset). Try both the plain WAL name and the extended name.
ALT_NAME=""
if [[ "$START_LSN" == */* ]]; then
  offset_hex=${START_LSN#*/}
  # normalize/pad then take last 6 chars
  if [ ${#offset_hex} -le 6 ]; then
    last6=$(printf "%06s" "$offset_hex")
  else
    last6=${offset_hex: -6}
  fi
  ALT_NAME="${WAL_NAME}.00${last6}"
fi

if [ -n "$WAL_NAME" ] && try_move_info "$WAL_NAME"; then
  exit 0
fi

if [ -n "$ALT_NAME" ] && try_move_info "$ALT_NAME"; then
  exit 0
fi

# Diagnostic: print exactly which paths were checked so operator can debug
CAND1="$INFO_DIR/${WAL_NAME}.backup"
CHK1="$INFO_DIR/${WAL_NAME}.backup.sha256"
CAND2=""
CHK2=""
if [ -n "$ALT_NAME" ]; then
  CAND2="$INFO_DIR/${ALT_NAME}.backup"
  CHK2="$INFO_DIR/${ALT_NAME}.backup.sha256"
fi
echo "No matching backup-info found in $INFO_DIR for Start-LSN=$START_LSN (WAL=$WAL_NAME); leaving files in place" >&2
echo "Checked: $CAND1 (exists: $( [ -f "$CAND1" ] && echo yes || echo no ))" >&2
echo "Checked: $CHK1 (exists: $( [ -f "$CHK1" ] && echo yes || echo no ))" >&2
if [ -n "$CAND2" ]; then
  echo "Checked: $CAND2 (exists: $( [ -f "$CAND2" ] && echo yes || echo no ))" >&2
  echo "Checked: $CHK2 (exists: $( [ -f "$CHK2" ] && echo yes || echo no ))" >&2
fi
exit 0
 
