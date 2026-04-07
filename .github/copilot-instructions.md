<!--
  .github/copilot-instructions.md
  Purpose: concise, repo-specific guidance for AI coding agents to be productive here.
  Notes: workspace scan found no existing AGENT/README instruction files; this is a templated,
  evidence-driven starting point tailored to a PostgreSQL backup/restore project named
  `postgres_backup` (inferred from repository path). If this inference is wrong, update the
  "ASSUMPTIONS" section below or provide access to the code so the file can be refined.
-->

# Copilot / AI Agent Instructions — postgres_backup

Summary
- This repository appears to be a PostgreSQL backup/restore project. If code is present,
  expect components such as: backup orchestrator (scripts or service), storage adapters
  (S3/GCS/local), scheduling (cron/CronJob/GitHub Actions), and restore procedures.

Assumptions (verify with the maintainer)
- Project name: `postgres_backup` (from repo path).
- Typical locations to inspect: `scripts/`, `src/`, `cli/`, `docker/`, `.github/workflows/`,
  `deploy/`, `config/`, `Makefile`, `Dockerfile`, `requirements.txt`, `pyproject.toml`,
  `go.mod`, `package.json`.

What to do first (agent checklist)
1. Confirm repository contents. If empty, ask the user for the repo root or push access.
2. Search for these files (in order) and open any that exist: `Dockerfile`, `Makefile`,
   `.github/workflows/*`, `scripts/backup*`, `scripts/restore*`, `config/`, `README.md`.
3. Identify the backup tool used by detecting binaries/commands: `pg_dump`, `pg_basebackup`,
   `pgbackrest`, `wal-g`, or `pg_ctl`. Look for direct `pg_dump` invocation lines in scripts.
4. Find storage integrations: AWS SDK, `aws s3`, `gsutil`, `az storage`, or references to
   `S3_BUCKET`, `GCS_BUCKET`, `AZURE_STORAGE` environment variables or config keys.

Big-picture architecture cues to extract
- Orchestrator: A script (e.g., `scripts/backup.sh`) or a service (Python/Go) that runs backups.
- Storage layer: adapter modules or CLI calls that push dumps to S3/GCS/Blob storage.
- Scheduler: cron entries (in `deploy/` or `Dockerfile`), Kubernetes `CronJob` manifests, or
  GitHub Actions workflows in `.github/workflows/` that trigger backups.
- Retention/prune: look for code/CRON entries that delete old backups or lifecycle policies.

Project-specific conventions to watch for
- Environment variables prefixed with `POSTGRES_BACKUP_` or `PB_` (common here).
- Scripts under `scripts/` use `bash -euo pipefail` and log to stdout; prefer adding small
  wrapper tests rather than changing behaviors silently.
- Config files live in `config/` or at the repo root as `backup.yml` / `settings.json`.
- Secrets expected in GitHub Actions secrets — inspect `.github/workflows/*` for `secrets.` refs.

Developer workflows (how humans build/test/debug here)
- If repository contains a `Dockerfile` then images are the primary runtime; prefer running
  behavior inside the container to reproduce environment differences.

  Common quick checks (replace with actual file checks before running):
  - Build image: `docker build -t postgres-backup .` (if `Dockerfile` exists)
  - Run a script locally: `bash scripts/backup.sh --dry-run`
  - For Python projects: `python -m venv .venv ; .\.venv\Scripts\activate ; pip install -r requirements.txt ; pytest`

- CI: Look in `.github/workflows/` for scheduled workflows (they may be how backups are run in prod).

Integration points and external dependencies
- Database: PostgreSQL instances (connection strings often in env var `DATABASE_URL` or separate
  `POSTGRES_*` vars). Find examples in `config/` or `env.example`.
- Storage: S3 (AWS), GCS, Azure Blob — detect SDKs or CLI usage. If `boto3` or `aws cli` present,
  prefer reviewing code that constructs bucket keys and encryption/ACL settings.
- Monitoring/Alerts: check for Slack/webhook integrations or GitHub Actions that report success/failure.

How to make code changes safely (agent guidance)
- Never change backup/restore logic without a safe, reproducible test harness. Prefer adding a
  `--dry-run` flag or unit tests that mock external services.
- If modifying CI or schedules, add a clear changelog comment and keep the previous schedule as a
  commented-out reference so humans can review risk.

Examples / patterns to follow in this repo (templates)
- Backup script skeleton (search for `pg_dump` lines and mirror flags):
  pg_dump -Fc --no-acl --no-owner -h "$PG_HOST" -U "$PG_USER" "$PG_DB" -f "$OUT"

- S3 upload pattern (CLI example commonly found in `scripts/`):
  aws s3 cp "$OUT" "s3://$S3_BUCKET/$PREFIX/$(basename $OUT)"

Merge guidance (if an older `.github/copilot-instructions.md` exists)
- Preserve any repository-specific notes that reference actual file names and environment values.
- Keep the top-level structure but update the ASSUMPTIONS block if the code contradicts them.

When you’re blocked
- If the repo is empty or lacks clarity, ask the maintainer these explicit questions:
  1. Is `postgres_backup` the canonical repo name and what's the primary runtime (bash/Python/Go/Docker)?
  2. Where are production schedules (cron, Kubernetes, or GitHub Actions)?
  3. Which storage providers are supported/enabled in production?

Request feedback
- After edits, ask the maintainer for any files that are intentionally private (e.g., `deploy/`)
  so the agent can refine the instructions with concrete examples.

-- End of copilot-instructions
