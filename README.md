# postgres_backup scripts

This repository contains small, deterministic scripts to archive and restore PostgreSQL WAL and to manage time-based housekeeping for backups.

Files of interest
- `scripts/archive_wal.sh` — archive a WAL segment (or `.backup` metadata) into the canonical backup layout and write a SHA256 checksum.
- `scripts/pgbase_backup.sh` — wrapper that runs `pg_basebackup` into a timestamped folder and associates the matching `backup_info` metadata.
- `scripts/backup_housekeeping.sh` — deterministic, lexicographic, time-based pruning of old backups, plus WAL and timeline history pruning; supports `DRY_RUN=1` for simulation.
- `scripts/restore_wal.sh` — restore a compressed WAL or timeline history file from the archive to a requested target and optionally verify checksum if present.

Quick principles
- Deterministic only: the scripts intentionally avoid heuristic filename guessing. They only accept canonical formats and canonical locations.
- Single canonical checksum format: checksum files are named `<basename>.sha256` and contain the SHA256 of the original (uncompressed) content.
- Non-destructive restores: `restore_wal.sh` reads and decompresses archives but does not delete source `.zst` files unless you explicitly change that behavior.

Prerequisites
- Bash (POSIX shell) environment for running scripts.
- Tools available in PATH on the host where you run the scripts:
  - `sha256sum` (required)
  - `zstd` (required for compression/decompression of WAL/history)
  - `pg_basebackup` and `psql` when using the `pgbase_backup.sh` wrapper
  - `date`, `find`, `grep`, `awk`, `sed`, `tr`, `cp`, `rm`

Layout expectations
- A backup base directory such as `/var/lib/postgresql/backup` with per-instance subdirectories:
  - `<backup-base>/<instance>/wal/` — compressed WAL and history archives (`<basename>.zst`) and checksums (`<basename>.sha256`).
  - `<backup-base>/<instance>/info/` — `.backup` metadata files produced by archiving and their checksums.
  - `<backup-base>/<instance>/<YYYYMMDDTHHMMSSZ>/` — `pg_basebackup` timestamped backup directories; inside each backup the `backup_info` and `backup_info.sha256` files are placed.

Usage examples

1) Archiving a WAL (run on the DB host or the archiver host):

  ./scripts/archive_wal.sh /var/lib/postgresql/backup main /path/to/00000001000000000000000A

  - Compresses to `/var/lib/postgresql/backup/main/wal/00000001000000000000000A.zst` and writes `/var/lib/postgresql/backup/main/wal/00000001000000000000000A.sha256` containing the SHA256 of the original segment.

2) Running a base backup (wrapper):

  ./scripts/pgbase_backup.sh /var/lib/postgresql/backup main

  - Runs `pg_basebackup` into a timestamped directory and attempts to associate the deterministic `backup_info` file with that backup (per the script's deterministic logic).

3) Housekeeping (safe simulation):

  DRY_RUN=1 ./scripts/backup_housekeeping.sh /var/lib/postgresql/backup main 30

  - Simulates pruning backups older than 30 days and shows which WAL and history files would be pruned (does not delete in DRY_RUN).

4) Restoring a WAL archive to a target file:

  ./scripts/restore_wal.sh /var/lib/postgresql/backup main 00000001000000000000000A /var/lib/postgresql/12/main/pg_wal/00000001000000000000000A

  - Looks for `/var/lib/postgresql/backup/main/wal/00000001000000000000000A.zst`, decompresses it to the given target and, if `/var/lib/postgresql/backup/main/wal/00000001000000000000000A.sha256` exists, verifies the decompressed file matches the checksum. The `.zst` file in the archive is left unchanged.

Notes & recommendations
- Test everything in a safe environment first. Use `DRY_RUN=1` for `backup_housekeeping.sh` until you are confident.
- Run archiving and housekeeping as the system user who owns the backup directory (often `postgres`), or ensure permissions are set such that the scripts can create and remove files in the target tree.
- Keep `zstd` and `sha256sum` versions consistent across hosts that produce and consume archives.
- `restore_wal.sh` will succeed even if the checksum file is missing; if the checksum file exists it will be validated and the script will fail if it doesn't match.

Excluding repo-local agent instructions
- The repository intentionally does not track `.github/copilot-instructions.md` (it is ignored). If you have other local files you want to keep but not push, add them to `.gitignore`.

Troubleshooting
- "command not found" errors: install missing tools (zstd, sha256sum, pg_basebackup, psql).
- Permission errors: verify ownership and permissions on `<backup-base>` and its subdirectories.
- If `backup_housekeeping.sh` appears to delete too many files in tests, re-run with `DRY_RUN=1` and inspect the computed cutoff timestamp and the `backup_info` of the oldest remaining backup.

Contributing
- Small, focused patches welcome. Keep changes deterministic and avoid introducing filename heuristics — the scripts were designed to be explicit and canonical on purpose.

License
- None included. Add a LICENSE file if you want to publish under a specific license.

*** End Patch