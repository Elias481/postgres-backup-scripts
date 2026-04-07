#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Simplified archive script per user request:
# - Use fixed checksum filename: <basename>.zst.chksum
# - Always use `sha256sum` (fail if missing)
# - No atomic temp-file + mv; write directly and remove partial files on error
# - Exit codes: 0 = success (including already-present+matching), 2 = error or mismatch

usage() {
  cat <<EOF
Usage: $0 <backup-base> <instance> <source-file>

Examples:
  $0 /var/lib/postgresql/backup main /var/lib/postgresql/wal/00000001000000000000000A
  $0 /var/lib/postgresql/backup main /var/lib/postgresql/backup/main/20260407T173100Z.backup

Notes:
- WAL archives go to <backup-base>/<instance>/wal as <basename>.zst
- Files ending with .backup are copied (not compressed) to <backup-base>/<instance>/backup/info
- A checksum file <basename>.sha256 (SHA256 of original content) is created next to the stored file
EOF
  exit 2
}

if [ "$#" -ne 3 ]; then
  usage
fi

BACKUP_BASE="$1"
INSTANCE="$2"
SRC="$3"

if [ ! -f "$SRC" ]; then
  echo "Source file not found: $SRC" >&2
  exit 2
fi

WAL_DIR="$BACKUP_BASE/$INSTANCE/wal"
BACKUP_INFO_DIR="$BACKUP_BASE/$INSTANCE/backup/info"

mkdir -p "$WAL_DIR" "$BACKUP_INFO_DIR"

if ! command -v sha256sum >/dev/null 2>&1; then
  echo "sha256sum not found in PATH (required)" >&2
  exit 2
fi

# Basename is the WAL filename (we store checksum for the original content)
BASENAME=$(basename -- "$SRC")

# Determine whether this is a .backup metadata file (do not compress)
case "$BASENAME" in
  *.backup)
    IS_BACKUP=1
    DEST_PATH="$BACKUP_INFO_DIR/$BASENAME"
    CHKSUM_PATH="$BACKUP_INFO_DIR/$BASENAME.sha256"
    ;;
  *)
    IS_BACKUP=0
    ZST_NAME="$BASENAME.zst"
    ZST_PATH="$WAL_DIR/$ZST_NAME"
    CHKSUM_PATH="$WAL_DIR/$BASENAME.sha256"
    ;;
esac

# If we will compress, require zstd
if [ "$IS_BACKUP" -eq 0 ]; then
  if ! command -v zstd >/dev/null 2>&1; then
    echo "zstd not found in PATH (required for WAL compression)" >&2
    exit 2
  fi
fi

# Compute checksum of source using sha256sum (fixed tool)
SRC_CHKSUM=$(sha256sum "$SRC" | awk '{print $1}')

created_zst=0
created_copy=0
created_chksum=0

cleanup_on_error() {
  # remove files we created during this run
  if [ "$IS_BACKUP" -eq 1 ]; then
    if [ "$created_copy" -eq 1 ] && [ -f "$DEST_PATH" ]; then
      rm -f -- "$DEST_PATH" || true
    fi
  else
    if [ "$created_zst" -eq 1 ] && [ -f "$ZST_PATH" ]; then
      rm -f -- "$ZST_PATH" || true
    fi
  fi
  if [ "$created_chksum" -eq 1 ] && [ -f "$CHKSUM_PATH" ]; then
    rm -f -- "$CHKSUM_PATH" || true
  fi
}

trap 'rc=$?; echo "Error archiving $SRC (exit code $rc)" >&2; cleanup_on_error; exit 2' ERR INT TERM

if [ "$IS_BACKUP" -eq 1 ]; then
  # Handle .backup files: copy (no compression) into BACKUP_INFO_DIR
  if [ -f "$DEST_PATH" ]; then
    if [ -f "$CHKSUM_PATH" ]; then
      EXIST_CHKSUM=$(tr -d ' \r\n' < "$CHKSUM_PATH" ) || EXIST_CHKSUM=""
      if [ "$EXIST_CHKSUM" = "$SRC_CHKSUM" ]; then
        echo "Backup metadata already exists and checksum matches: $DEST_PATH"
        exit 0
      else
        echo "Backup metadata exists but checksum differs: $DEST_PATH" >&2
        exit 2
      fi
    else
      echo "Backup metadata exists ($DEST_PATH) but checksum missing ($CHKSUM_PATH)." >&2
      exit 2
    fi
  else
    # copy file directly
    if cp -- "$SRC" "$DEST_PATH"; then
      created_copy=1
      printf '%s\n' "$SRC_CHKSUM" > "$CHKSUM_PATH"
      created_chksum=1
      trap - ERR INT TERM
      echo "Copied backup metadata $SRC -> $DEST_PATH"
      exit 0
    else
      echo "Copy failed for $SRC" >&2
      exit 2
    fi
  fi
else
  # Handle normal WAL entries: compress to WAL_DIR
  if [ -f "$ZST_PATH" ]; then
    if [ -f "$CHKSUM_PATH" ]; then
      EXIST_CHKSUM=$(tr -d ' \r\n' < "$CHKSUM_PATH" ) || EXIST_CHKSUM=""
      if [ "$EXIST_CHKSUM" = "$SRC_CHKSUM" ]; then
        echo "Archive exists and checksum matches: $ZST_PATH"
        exit 0
      else
        echo "Archive exists but checksum differs: $ZST_PATH" >&2
        exit 2
      fi
    else
      echo "Archive exists ($ZST_PATH) but checksum file missing ($CHKSUM_PATH)." >&2
      exit 2
    fi
  else
    # Compress directly into destination path (no temp files)
    # run zstd quietly to avoid progress bars in logs
    if zstd -q -T0 -o "$ZST_PATH" -- "$SRC"; then
      created_zst=1
      # write checksum file (newline-terminated) named after original WAL
      printf '%s\n' "$SRC_CHKSUM" > "$CHKSUM_PATH"
      created_chksum=1
      # disable trap for normal exit
      trap - ERR INT TERM
      echo "Archived $SRC -> $ZST_PATH"
      exit 0
    else
      # zstd failed; trap will run cleanup_on_error
      echo "Compression failed for $SRC" >&2
      exit 2
    fi
  fi
fi

