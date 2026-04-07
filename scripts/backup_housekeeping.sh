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

to_delete=()

# Compute a cutoff timestamp string in the same sortable format as our
# backup folders (YYYYMMDDTHHMMSSZ). Any folder lexicographically less than
# this cutoff is older than MAX_AGE_DAYS. To avoid relying on date's
# heuristic text parsing we compute the cutoff epoch explicitly and then
# format it with an explicit '@epoch' style conversion.
NOW_EPOCH=$(date -u +%s 2>/dev/null || true)
if [ -z "$NOW_EPOCH" ]; then
  echo "Could not get current epoch time from 'date'; aborting to avoid accidental deletes" >&2
  exit 2
fi
CUT_EPOCH=$(( NOW_EPOCH - (MAX_AGE_DAYS * 86400) ))
CUT_OFF_STR=""
if CUT_OFF_STR=$(date -u -d "@${CUT_EPOCH}" +%Y%m%dT%H%M%SZ 2>/dev/null); then
  :
else
  echo "Could not format cutoff epoch ${CUT_EPOCH}; aborting to avoid accidental deletes" >&2
  exit 2
fi

for i in "${!sorted[@]}"; do
  name="${sorted[$i]}"
  # never delete the newest backup
  if [ "$i" -eq "$newest_index" ]; then
    continue
  fi
  # Lexicographic compare: timestamps in format YYYYMMDDTHHMMSSZ sort correctly
  if [[ "$name" < "$CUT_OFF_STR" ]]; then
    to_delete+=("$TARGET_DIR/$name")
  fi
done

if [ "${#to_delete[@]}" -eq 0 ]; then
  echo "No backups older than ${MAX_AGE_DAYS} day(s) found (newest: $newest_name)."
  echo "Continuing to WAL and timeline pruning based on current backups."
else
  :
fi

if [ -n "${DRY_RUN:-}" ]; then
  echo "DRY RUN: would delete the following ${#to_delete[@]} directories (older than ${MAX_AGE_DAYS} days):"
  for d in "${to_delete[@]}"; do
    echo "  $d"
  done
  echo "DRY RUN: continuing to WAL and history pruning simulation (no destructive actions will be performed)."
  # do not exit here; allow DRY_RUN to simulate WAL and history pruning as well
fi

if [ "${#to_delete[@]}" -gt 0 ]; then
  echo "Pruning ${#to_delete[@]} backup(s) older than ${MAX_AGE_DAYS} day(s) under $TARGET_DIR (kept newest: $newest_name)"
  for d in "${to_delete[@]}"; do
    if [ -d "$d" ]; then
      if [ -n "${DRY_RUN:-}" ]; then
        echo "DRY RUN: would delete $d"
      else
        echo "Deleting $d"
        rm -rf -- "$d"
      fi
    else
      echo "Skipping non-existent $d"
    fi
  done
fi

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

# The backup_info contains a line that already includes the WAL filename inside
# a '(file ...)' token, for example:
#   START WAL LOCATION: 0/20000028 (file 000000010000000000000020)
# We will extract the 'file' token directly and use it as the cutoff WAL name.
CUTOFF_WAL=""
CUTOFF_WAL=$(grep -m1 -oP '\(file\s*\K[0-9A-Fa-f]+' "$manifest_info" 2>/dev/null || true)
if [ -z "$CUTOFF_WAL" ]; then
  echo "WAL filename token '(file ...)' not found in $manifest_info; skipping WAL pruning" >&2
  echo "Housekeeping complete."
  exit 0
fi

echo "Pruning WAL archives older than $CUTOFF_WAL in $WAL_DIR (based on oldest remaining backup $oldest_remaining_name)"
if [ -d "$WAL_DIR" ]; then
  # validate cutoff is a 24-hex WAL segment name
  CUTOFF_WAL_UPPER=$(echo "$CUTOFF_WAL" | tr '[:lower:]' '[:upper:]')
  if ! [[ "$CUTOFF_WAL_UPPER" =~ ^[0-9A-F]{24}$ ]]; then
    echo "Computed cutoff WAL '$CUTOFF_WAL' does not look like a 24-hex WAL filename; skipping WAL pruning" >&2
  else
    # Only handle the canonical compressed suffix '.zst' (no fallbacks).
    for wf in "$WAL_DIR"/*.zst; do
      [ -e "$wf" ] || continue
      wbase="${wf##*/}"
      wbase="${wbase%.zst}"
      wbase_upper=$(echo "$wbase" | tr '[:lower:]' '[:upper:]')
      if ! [[ "$wbase_upper" =~ ^[0-9A-F]{24}$ ]]; then
        echo "Skipping non-conforming WAL file: $wf"
        continue
      fi
      if [[ "$wbase_upper" < "$CUTOFF_WAL_UPPER" ]]; then
        if [ -n "${DRY_RUN:-}" ]; then
          echo "DRY RUN: would delete WAL $wf and checksum $WAL_DIR/${wbase}.sha256"
        else
          echo "Deleting WAL $wf"
          rm -f -- "$wf"
          rm -f -- "$WAL_DIR/${wbase}.sha256" || true
        fi
      fi
    done
  fi
else
  echo "WAL directory $WAL_DIR does not exist; nothing to prune" >&2
fi


# Timeline history pruning: extract START TIMELINE from backup_info and remove
# older timeline history files from the WAL dir. The backup_info contains a
# line like: START TIMELINE: 2
# We convert that to an 8-digit hex (e.g. 00000002) and delete any
# '<8hex>.history*' where the hex numeric value is less than the cutoff.
TIMELINE_NUM=""
TIMELINE_NUM=$(grep -m1 -oP 'START TIMELINE:\s*\K[0-9]+' "$manifest_info" 2>/dev/null || true)
if [ -n "$TIMELINE_NUM" ]; then
  # Deterministic rule: START TIMELINE is always decimal.
  TIMELINE_DEC=$TIMELINE_NUM
  if [ -z "${TIMELINE_DEC:-}" ]; then
    # nothing sensible to do
    :
  else
    # Use arithmetic expansion to guarantee a numeric value is passed to printf
    TIMELINE_HEX=$(printf "%08X" "$((TIMELINE_DEC))")
    echo "Pruning timeline history files older than ${TIMELINE_HEX}.history in $WAL_DIR (based on START TIMELINE $TIMELINE_NUM)"
  fi
  if [ -d "$WAL_DIR" ]; then
    # Only handle canonical history suffix '.history' and compressed '.history.zst'
    for hf in "$WAL_DIR"/*.history "$WAL_DIR"/*.history.zst; do
      [ -e "$hf" ] || continue
      hbase="${hf##*/}"
      # extract leading 8-hex chars
      hist_hex=$(echo "$hbase" | sed -E 's/^([0-9A-Fa-f]{8}).*/\1/')
      if ! [[ "$hist_hex" =~ ^[0-9A-Fa-f]{8}$ ]]; then
        echo "Skipping non-conforming history file: $hf"
        continue
      fi
      # use uppercase fixed-width hex string for lexicographic compare
      hist_hex_up=$(echo "$hist_hex" | tr '[:lower:]' '[:upper:]')
      TIMELINE_HEX_UP=$(echo "$TIMELINE_HEX" | tr '[:lower:]' '[:upper:]')
      if [[ "$hist_hex_up" < "$TIMELINE_HEX_UP" ]]; then
        if [ -n "${DRY_RUN:-}" ]; then
          echo "DRY RUN: would delete history $hf"
        else
          echo "Deleting history $hf"
          rm -f -- "$hf"
        fi
      fi
    done
  else
    echo "WAL directory $WAL_DIR does not exist; skipping history pruning" >&2
  fi
fi

echo "Housekeeping complete."
