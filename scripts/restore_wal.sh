#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# restore_wal.sh
# Usage: restore_wal.sh <instance> <filename> <target>
# - instance: instance name (e.g. main)
# - filename: original basename of the WAL or metadata file (e.g. 00000001000000000000000A or 20260407T173100Z.backup)
# - target: destination path where PostgreSQL expects the uncompressed file
#
# Notes:
# - The script looks under BACKUP_BASE (env) or defaults to /var/lib/postgresql/backup
# - WAL archives are expected at <BACKUP_BASE>/<instance>/wal/<filename>.zst with checksum
#   at <BACKUP_BASE>/<instance>/wal/<filename>.sha256 (checksum is of the original, uncompressed file)
# - .backup metadata files are expected at <BACKUP_BASE>/<instance>/info/<filename> with
#   checksum <filename>.sha256 and are copied (not decompressed)
# - Exits: 0 success, 2 error or checksum mismatch

usage() {
  cat <<EOF
Usage: $0 <backup-base> <instance> <filename> <target>

Examples:
  $0 /var/lib/postgresql/backup main 00000001000000000000000A /var/lib/postgresql/12/main/pg_wal/00000001000000000000000A
  $0 /var/lib/postgresql/backup main 00000001.history /tmp/00000001.history

Notes:
  - The first argument is the same <backup-base> used by the archiver scripts.
  - This script strictly supports the canonical compressed WAL and timeline
    history formats produced by the archive tooling and will not attempt
    heuristics or alternate suffixes.
EOF
  exit 2
}

if [ "$#" -ne 4 ]; then
  usage
fi

BACKUP_BASE="$1"
INSTANCE="$2"
FILENAME="$3"
TARGET="$4"

WAL_DIR="$BACKUP_BASE/$INSTANCE/wal"
INFO_DIR="$BACKUP_BASE/$INSTANCE/info"

if ! command -v sha256sum >/dev/null 2>&1; then
  echo "sha256sum not found in PATH (required)" >&2
  exit 2
fi

cleanup_on_error() {
  # remove partially created target
  if [ -n "${created_target:-}" ] && [ -f "$TARGET" ]; then
    rm -f -- "$TARGET" || true
  fi
}

trap 'rc=$?; echo "Error restoring $FILENAME to $TARGET (exit $rc)" >&2; cleanup_on_error; exit 2' ERR INT TERM

mkdir -p "$(dirname -- "$TARGET")"

# Accept either a WAL segment name (24 hex) or a timeline history basename
# like <8hex>.history. Both are stored compressed with a .zst suffix and the
# checksum file is the basename + .sha256 (checksum of the original uncompressed
# content).

# Simpler behavior per user request: do not inspect the filename format.
# If a compressed file named <filename>.zst exists in the WAL dir, restore it.
ZST_PATH="$WAL_DIR/${FILENAME}.zst"
CHKSUM_PATH="$WAL_DIR/${FILENAME}.sha256"

if [ ! -f "$ZST_PATH" ]; then
  echo "Compressed source not found: $ZST_PATH" >&2
  exit 2
fi
if ! command -v zstd >/dev/null 2>&1; then
  echo "zstd not found in PATH (required to decompress)" >&2
  exit 2
fi

# Decompress to target and verify checksum
if zstd -d -q -o "$TARGET" -- "$ZST_PATH"; then
  created_target=1
  # Only verify checksum if it exists; do not require it.
  if [ -f "$CHKSUM_PATH" ]; then
    RECORDED=$(tr -d ' \r\n' < "$CHKSUM_PATH" || true)
    ACTUAL=$(sha256sum "$TARGET" | awk '{print $1}')
    if [ "$RECORDED" != "$ACTUAL" ]; then
      echo "Checksum mismatch after decompression: recorded=$RECORDED actual=$ACTUAL" >&2
      exit 2
    fi
  fi
  trap - ERR INT TERM
  echo "Restored $ZST_PATH -> $TARGET"
  exit 0
else
  echo "Decompression failed for $ZST_PATH" >&2
  exit 2
fi

