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
Usage: $0 <source-wal-file> <dest-dir>

Examples:
  $0 /var/lib/postgresql/wal/00000001000000000000000A /backups/wal
EOF
  exit 2
}

if [ "$#" -ne 2 ]; then
  usage
fi

SRC="$1"
DESTDIR="$2"

if [ ! -f "$SRC" ]; then
  echo "Source file not found: $SRC" >&2
  exit 2
fi

mkdir -p "$DESTDIR"

if ! command -v sha256sum >/dev/null 2>&1; then
  echo "sha256sum not found in PATH (required)" >&2
  exit 2
fi

if ! command -v zstd >/dev/null 2>&1; then
  echo "zstd not found in PATH (required)" >&2
  exit 2
fi

# Basename is the WAL filename (we store checksum for the original content)
BASENAME=$(basename -- "$SRC")
ZST_NAME="$BASENAME.zst"
ZST_PATH="$DESTDIR/$ZST_NAME"
# Checksum refers to the original WAL content; use <basename>.sha256
CHKSUM_PATH="$DESTDIR/$BASENAME.sha256"

# Compute checksum of source using sha256sum (fixed tool)
SRC_CHKSUM=$(sha256sum "$SRC" | awk '{print $1}')

created_zst=0
created_chksum=0

cleanup_on_error() {
  # remove files we created during this run
  if [ "$created_zst" -eq 1 ] && [ -f "$ZST_PATH" ]; then
    rm -f -- "$ZST_PATH" || true
  fi
  if [ "$created_chksum" -eq 1 ] && [ -f "$CHKSUM_PATH" ]; then
    rm -f -- "$CHKSUM_PATH" || true
  fi
}

trap 'cleanup_on_error; exit 2' ERR INT TERM

if [ -f "$ZST_PATH" ]; then
  # Archive exists; require exact checksum file name
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
  if zstd -T0 -o "$ZST_PATH" -- "$SRC"; then
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

