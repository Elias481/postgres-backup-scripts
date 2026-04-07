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
Usage: $0 <instance> <filename> <target>

Examples:
  $0 main 00000001000000000000000A /var/lib/postgresql/12/main/pg_wal/00000001000000000000000A
  $0 main 20260407T173100Z.backup /tmp/20260407T173100Z.backup

Environment:
  BACKUP_BASE (optional) - default: /var/lib/postgresql/backup

This script strictly supports the canonical formats produced by the archiver
and will not attempt heuristics or alternate suffixes.
EOF
  exit 2
}

if [ "$#" -ne 3 ]; then
  usage
fi

INSTANCE="$1"
FILENAME="$2"
TARGET="$3"

BACKUP_BASE="${BACKUP_BASE:-/var/lib/postgresql/backup}"
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

case "$FILENAME" in
  *.backup)
    SRC="$INFO_DIR/$FILENAME"
    CHKSUM_FILE="$SRC.sha256"
    if [ ! -f "$SRC" ]; then
      echo "Backup metadata not found: $SRC" >&2
      exit 2
    fi
    if [ ! -f "$CHKSUM_FILE" ]; then
      echo "Checksum file missing for backup metadata: $CHKSUM_FILE" >&2
      exit 2
    fi
    # compute checksum of the stored file and compare to recorded checksum
    RECORDED=$(tr -d ' \r\n' < "$CHKSUM_FILE" || true)
    ACTUAL=$(sha256sum "$SRC" | awk '{print $1}')
    if [ "$RECORDED" != "$ACTUAL" ]; then
      echo "Checksum mismatch for $SRC: recorded=$RECORDED actual=$ACTUAL" >&2
      exit 2
    fi
    # copy to target
    if cp -- "$SRC" "$TARGET"; then
      created_target=1
      trap - ERR INT TERM
      echo "Restored backup metadata $SRC -> $TARGET"
      exit 0
    else
      echo "Failed to copy $SRC to $TARGET" >&2
      exit 2
    fi
    ;;
  *)
    # canonical WAL segment: expect <filename>.zst and <filename>.sha256
    # validate filename looks like a WAL segment (24 hex) to avoid accidental paths
    F_UPPER=$(echo "$FILENAME" | tr '[:lower:]' '[:upper:]')
    if ! [[ "$F_UPPER" =~ ^[0-9A-F]{24}$ ]]; then
      echo "WAL filename does not look like a 24-hex segment name: $FILENAME" >&2
      exit 2
    fi
    ZST_PATH="$WAL_DIR/$FILENAME.zst"
    CHKSUM_PATH="$WAL_DIR/$FILENAME.sha256"
    if [ ! -f "$ZST_PATH" ]; then
      echo "Compressed WAL not found: $ZST_PATH" >&2
      exit 2
    fi
    if [ ! -f "$CHKSUM_PATH" ]; then
      echo "Checksum file missing for WAL: $CHKSUM_PATH" >&2
      exit 2
    fi
    if ! command -v zstd >/dev/null 2>&1; then
      echo "zstd not found in PATH (required to decompress WAL)" >&2
      exit 2
    fi

    # Decompress directly to the requested target
    if zstd -d -q -o "$TARGET" -- "$ZST_PATH"; then
      created_target=1
      # verify checksum of decompressed file matches recorded checksum (which is checksum of original content)
      RECORDED=$(tr -d ' \r\n' < "$CHKSUM_PATH" || true)
      ACTUAL=$(sha256sum "$TARGET" | awk '{print $1}')
      if [ "$RECORDED" != "$ACTUAL" ]; then
        echo "Checksum mismatch after decompression: recorded=$RECORDED actual=$ACTUAL" >&2
        exit 2
      fi
      trap - ERR INT TERM
      echo "Restored WAL $ZST_PATH -> $TARGET"
      exit 0
    else
      echo "Decompression failed for $ZST_PATH" >&2
      exit 2
    fi
    ;;
esac
