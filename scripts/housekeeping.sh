#!/usr/bin/env bash
echo "This script has been renamed to 'backup_housekeeping.sh'."
echo "Please run './scripts/backup_housekeeping.sh' instead."
echo "To preserve compatibility this wrapper will forward arguments now."
exec "$(dirname "$0")/backup_housekeeping.sh" "$@"
