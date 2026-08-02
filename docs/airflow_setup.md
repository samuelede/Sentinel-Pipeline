# Airflow Setup (Docker)

Airflow doesn't support native Windows (only WSL2 or Linux containers, per its own startup warning), running it directly in Git Bash fails with a `Cannot use relative path: sqlite:///C:/...` error that no config tweak fixes. Docker sidesteps this, and it's the officially recommended way to run Airflow locally regardless of OS.

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running
- `.env` filled in (see [`SETUP_CHECKLIST.md`](SETUP_CHECKLIST.md))
- `~/.aws/credentials` set up (`aws configure`), mounted into the container automatically
- `~/.snowsql/config` set up with the `sentinel` connection (see [`snowflake_setup.md`](snowflake_setup.md)), also mounted in automatically, `snowsql` itself is baked into the image

## Run it

```bash
./scripts/run_airflow.sh
```

Builds the image, then starts Airflow with `airflow standalone` (DB init, admin user, webserver, and scheduler all in one). First build takes a few minutes.

- **Web UI**: `http://localhost:8080`
- **Username / Password**: whatever you set as `AIRFLOW_ADMIN_USERNAME` / `AIRFLOW_ADMIN_PASSWORD` in `.env`. These only take effect the first time the container initializes, if you already ran it once before adding them, remove the container (`docker compose -f docker-compose.airflow.yml down`) and re-run to pick up the new values.
- **Failure emails**: caught by Mailpit instead of sent for real, no SMTP credentials needed. View them at `http://localhost:8025`.

`Ctrl+C` to stop. Re-run the same command to restart, state persists.

## Trigger a run

```bash
docker compose -f docker-compose.airflow.yml exec airflow airflow dags trigger sentinel_daily_pipeline -e 2026-01-15
```

Or use the trigger button in the Web UI.

## Notes

- The whole repo is mounted into the container, so the DAG's `from extractors import ...` imports resolve without any manual `PYTHONPATH` setup.
- `.env`, your AWS credentials, and your `~/.snowsql/` config/key all pass through automatically, no duplicating anything.
- Already on WSL2 with a Linux distro? You can skip Docker and follow Airflow's native install steps directly inside WSL2 instead.
