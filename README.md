# postgres_backup scripts

This repository contains small, deterministic scripts to archive and restore PostgreSQL WAL and to manage time-based housekeeping for backups.

Files of interest
- `scripts/archive_wal.sh` — archive a WAL segment (or `.backup` metadata) into the canonical backup layout and write a SHA256 checksum.
- `scripts/pgbase_backup.sh` — wrapper that runs `pg_basebackup` into a timestamped folder and associates the matching `backup_info` metadata.
- `scripts/backup_housekeeping.sh` — deterministic, lexicographic, time-based pruning of old backups, plus WAL and timeline history pruning; supports `DRY_RUN=1` for simulation.
- `scripts/restore_wal.sh` — restore a compressed WAL or timeline history file from the archive to a requested target and optionally verify checksum if present.

Integration examples
Below are concrete examples showing how to hook the scripts into PostgreSQL and how to schedule backups and housekeeping. Adjust paths, users and permissions to match your environment.

1) PostgreSQL `postgresql.conf` (archive command)

Enable archiving and call the archiver script. Use the full path and run as the Postgres user.

Example (in `postgresql.conf`):

  archive_mode = on
  archive_command = '/usr/local/bin/archive_wal.sh /var/lib/postgresql/backup main %p'

Notes:
- `%p` expands to the absolute path of the WAL file; the archiver script expects a source path.
- If you prefer logging, wrap in a shell: `archive_command = 'sh -c "/usr/local/bin/archive_wal.sh /var/lib/postgresql/backup main %p >> /var/log/postgres/archive_wal.log 2>&1"'`

2) Scheduling `pgbase_backup.sh`

Cron example: full base backup every day at 02:00 as the `postgres` user

  # crontab -u postgres -e
  0 2 * * * /usr/local/bin/pgbase_backup.sh /var/lib/postgresql/backup main >> /var/log/pgbase_backup.log 2>&1

Systemd unit + timer example (recommended on systemd systems)

  # /etc/systemd/system/pgbase-backup.service
  [Unit]
  Description=Run pg_basebackup wrapper for main
  After=network.target

  [Service]
  Type=oneshot
  User=postgres
  ExecStart=/usr/local/bin/pgbase_backup.sh /var/lib/postgresql/backup main

  # /etc/systemd/system/pgbase-backup.timer
  [Unit]
  Description=Daily timer for pgbase-backup

  [Timer]
  OnCalendar=*-*-* 02:00:00
  Persistent=true

  [Install]
  WantedBy=timers.target

Enable and start the timer:

  systemctl daemon-reload
  systemctl enable --now pgbase-backup.timer

3) Scheduling `backup_housekeeping.sh`

Cron example: weekly housekeeping on Sunday at 03:00 (keeps 30 days by default)

  # crontab -u postgres -e
  0 3 * * 0 /usr/local/bin/backup_housekeeping.sh /var/lib/postgresql/backup main 30 >> /var/log/backup_housekeeping.log 2>&1

Systemd timer example (run weekly)

  # /etc/systemd/system/backup-housekeeping.service
  [Unit]
  Description=Run backup housekeeping for postgres backups
  After=network.target

  [Service]
  Type=oneshot
  User=postgres
  ExecStart=/usr/local/bin/backup_housekeeping.sh /var/lib/postgresql/backup main 30

  # /etc/systemd/system/backup-housekeeping.timer
  [Unit]
  Description=Weekly timer for backup-housekeeping

  [Timer]
  OnCalendar=weekly
  Persistent=true

  [Install]
  WantedBy=timers.target

Enable and start the timer:

  systemctl daemon-reload
  systemctl enable --now backup-housekeeping.timer

4) Restoring WAL / timeline history (used as PostgreSQL restore_command)

`restore_wal.sh` is written to be used automatically by PostgreSQL during recovery via the `restore_command` (or `recovery.conf`) as well as for manual, on-demand restores. Example `postgresql.conf` setting for recovery:

  restore_command = '/usr/local/bin/restore_wal.sh /var/lib/postgresql/backup main %f "%p"'

Notes:
- PostgreSQL expands `%f` to the requested WAL filename; the script will look for `/var/lib/postgresql/backup/main/wal/<filename>.zst` and decompress it to the requested path.
- If a checksum file exists (`<filename>.sha256`) the script will validate the decompressed file and fail on mismatch. If no checksum exists, a successful decompression is treated as success (exit 0).
- The archive `.zst` is left untouched by the restore operation so repeated recovery attempts remain possible.

Recommendation: install `jq` on systems that run `pg_basebackup` and housekeeping; some parts of the tooling and future helpers may use `jq` to parse JSON manifests and make deterministic decisions more robustly. It's small and widely available via package managers.

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