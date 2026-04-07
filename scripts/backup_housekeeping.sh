#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# backup_housekeeping.sh
# Usage: backup_housekeeping.sh <backup-base> <instance> [max-age-days]
# - backup-base: base path for backups, e.g. /var/lib/postgresql/backup
# - instance: instance name, e.g. main
# - max-age-days: optional integer, delete backups older than this many days (default: 30)
#
# Behavior:
# - lists timestamped backup directories under <backup-base>/<instance>
# - prunes backups older than a time window (max-age-days) and deletes older ones
#   The default is 30 days. The script always keeps the newest backup directory.
# - safe-by-default: pass DRY_RUN=1 in the environment to only print actions
#
# Example:
#   DRY_RUN=1 ./scripts/backup_housekeeping.sh /var/lib/postgresql/backup main 14

usage() {
  cat <<EOF
Usage: $0 <backup-base> <instance> [max-age-days]

Examples:
  $0 /var/lib/postgresql/backup main
  DRY_RUN=1 $0 /var/lib/postgresql/backup main 30

Notes:
- This script deletes directories under <backup-base>/<instance> that look like
  timestamped backup folders (pattern: YYYYMMDDTHHMMSSZ). It is conservative
  and will refuse to run if the target directory doesn't exist.
- By default it prunes backups older than 30 days (pass max-age-days to override).
- The script always keeps the newest backup directory regardless of age.
- Set DRY_RUN=1 to preview deletions.
EOF
  exit 2
}

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  usage
fi

BACKUP_BASE="$1"
INSTANCE="$2"
# default: delete backups older than 30 days
MAX_AGE_DAYS=${3:-30}

if ! [[ "$MAX_AGE_DAYS" =~ ^[0-9]+$ ]]; then
  echo "max-age-days must be a non-negative integer" >&2
  exit 2
fi

TARGET_DIR="$BACKUP_BASE/$INSTANCE"
if [ ! -d "$TARGET_DIR" ]; then
  echo "Target directory does not exist: $TARGET_DIR" >&2
  exit 0
fi

# Find candidate backup dirs matching the timestamp pattern YYYYMMDDTHHMMSSZ
# Consider only directories directly under $TARGET_DIR
mapfile -t candidates < <(find "$TARGET_DIR" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | grep -E '^[0-9]{8}T[0-9]{6}Z$' || true)

if [ "${#candidates[@]}" -le 1 ]; then
  echo "Nothing to prune: ${#candidates[@]} backup(s) present; always keep at least one."
  exit 0
fi

# Sort candidates lexicographically (timestamps are sortable in this format)
IFS=$'\n' sorted=($(printf "%s\n" "${candidates[@]}" | sort))
# newest is the last element; we always keep it
newest_index=$((${#sorted[@]} - 1))
newest_name="${sorted[$newest_index]}"

now=$(date -u +%s)
to_delete=()

for i in "${!sorted[@]}"; do
  name="${sorted[$i]}"
  # never delete the newest backup
  if [ "$i" -eq "$newest_index" ]; then
    continue
  fi
  # parse timestamp (YYYYMMDDTHHMMSSZ) into epoch seconds
  # GNU date accepted: date -u -d 'YYYYMMDDTHHMMSSZ' +%s
  ts_epoch=0
  if ts_epoch=$(date -u -d "$name" +%s 2>/dev/null || true); then
    : # parsed successfully
  else
    # try with replacing 'T' and 'Z' for some implementations
    if ts_epoch=$(date -u -d "${name/T/ }" +%s 2>/dev/null || true); then
      :
    else
      echo "Skipping unparsable timestamp folder: $name" >&2
      continue
    fi
  fi
  age_days=$(( (now - ts_epoch) / 86400 ))
  if [ "$age_days" -gt "$MAX_AGE_DAYS" ]; then
    to_delete+=("$TARGET_DIR/$name")
  fi
done

if [ "${#to_delete[@]}" -eq 0 ]; then
  echo "No backups older than ${MAX_AGE_DAYS} day(s) found (newest: $newest_name)."
  exit 0
fi

if [ -n "${DRY_RUN:-}" ]; then
  echo "DRY RUN: would delete the following ${#to_delete[@]} directories (older than ${MAX_AGE_DAYS} days):"
  for d in "${to_delete[@]}"; do
    echo "  $d"
  done
  exit 0
fi

echo "Pruning ${#to_delete[@]} backup(s) older than ${MAX_AGE_DAYS} day(s) under $TARGET_DIR (kept newest: $newest_name)"
for d in "${to_delete[@]}"; do
  if [ -d "$d" ]; then
    echo "Deleting $d"
    rm -rf -- "$d"
  else
    echo "Skipping non-existent $d"
  fi
done

# After deleting backups, determine the oldest existing backup (we always keep newest)
# and use its backup_info to compute the cutoff WAL. This ensures we remove
# WALs that are older than the earliest remaining backup.
WAL_DIR="$BACKUP_BASE/$INSTANCE/wal"

# Recompute remaining timestamped backups
mapfile -t remaining < <(find "$TARGET_DIR" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort || true)
if [ "${#remaining[@]}" -eq 0 ]; then
  echo "No backups remain after pruning; skipping WAL pruning" >&2
  echo "Housekeeping complete."
  exit 0
fi

# oldest remaining is the first element (sorted lexicographically)
oldest_remaining_name="${remaining[0]}"
oldest_dir="$TARGET_DIR/$oldest_remaining_name"

echo "Oldest remaining backup after pruning: $oldest_remaining_name"

manifest_info="$oldest_dir/backup_info"
if [ ! -f "$manifest_info" ]; then
  echo "backup_info not found in $oldest_dir; skipping WAL pruning" >&2
  echo "Housekeeping complete."
  exit 0
fi

# Extract Start-LSN (from textual backup info) and compute WAL filename
START_LSN=""
START_LSN=$(grep -m1 -oP 'START WAL LOCATION:\s*\K[0-9A-Fa-f/]+' "$manifest_info" 2>/dev/null || true)
if [ -z "$START_LSN" ]; then
  echo "Start-LSN not found in $manifest_info; skipping WAL pruning" >&2
  echo "Housekeeping complete."
  exit 0
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "psql not available; skipping WAL pruning" >&2
  echo "Housekeeping complete."
  exit 0
fi

CUTOFF_WAL=$(psql -t -A -c "SELECT pg_walfile_name('$START_LSN'::pg_lsn);" 2>/dev/null || true)
if [ -z "$CUTOFF_WAL" ]; then
  echo "Could not compute cutoff WAL from Start-LSN '$START_LSN'; skipping WAL pruning" >&2
  echo "Housekeeping complete."
  exit 0
fi

echo "Pruning WAL archives older than $CUTOFF_WAL in $WAL_DIR (based on oldest remaining backup $oldest_remaining_name)"
if [ -d "$WAL_DIR" ]; then
  for wf in "$WAL_DIR"/*.zst; do
    [ -e "$wf" ] || continue
    wbase="${wf##*/}"
    wbase="${wbase%.zst}"
    if [[ "$wbase" < "$CUTOFF_WAL" ]]; then
      if [ -n "${DRY_RUN:-}" ]; then
        echo "DRY RUN: would delete WAL $wf and checksum $WAL_DIR/${wbase}.sha256"
      else
        echo "Deleting WAL $wf"
        rm -f -- "$wf"
        rm -f -- "$WAL_DIR/${wbase}.sha256" || true
      fi
    fi
  done
else
  echo "WAL directory $WAL_DIR does not exist; nothing to prune" >&2
fi

echo "Housekeeping complete."
