# Deploying to MWAA

Covers getting the DAG and its supporting code onto real MWAA, automating that with GitHub Actions, and debugging the first cloud run. Assumes the MWAA environment already exists (`docs/mwaa_setup.md`).

## 1. Restructure into the etl_scripts layout (one-time)

MWAA only puts the `dags/` folder itself on `sys.path`, not the repo root. The DAG currently imports `extractors`, `validators`, `transformers` as top-level packages, that works locally (Docker sets `PYTHONPATH` to the whole repo) but would fail to import at all on real MWAA.

```bash
python scripts/migrate_to_etl_scripts.py
```

Moves `extractors/`, `validators/`, `transformers/` into `dags/etl_scripts/` via `git mv` (history preserved), and rewrites every `from extractors ...` / `from validators ...` / `from transformers ...` import to `from etl_scripts.<package> ...`. Review before committing:

```bash
git diff --stat
```

The script also flags anything it couldn't confidently rewrite (dynamic imports, string references) under "Needs manual review", check those by hand.

### Update `docker-compose.airflow.yml`

Add `dags` to `PYTHONPATH` so local Docker resolves `etl_scripts` the same way MWAA will, without breaking anything that still imports from the repo root:

```yaml
- PYTHONPATH=/opt/airflow/project/dags:/opt/airflow/project
```

### Running the transformers/validators manually after this

They now live under `dags/etl_scripts/`. Either `cd dags` first, or export `PYTHONPATH` to include it:

```bash
PYTHONPATH=dags python -m etl_scripts.transformers.transform_billing --day 2026-07-04
```

### Test locally before deploying anywhere

```bash
docker compose -f docker-compose.airflow.yml restart airflow
```

Confirm the DAG still parses with no import errors in the Airflow UI before moving on, a broken import here means a broken import on MWAA too, better to catch it for free.

## 2. Deploy manually

```bash
./scripts/deploy_to_mwaa.sh
```

Syncs `dags/` (including `etl_scripts/`) to `s3://<mwaa-bucket>/dags/`, MWAA polls this automatically and picks up changes within a few minutes, no restart needed. Also uploads `requirements.txt` and points the environment at the new version, this part **does** require an environment update and takes longer (MWAA restarts workers to reinstall dependencies).

Requires the same admin profile used for `setup_mwaa.sh` (see docs/mwaa_setup.md's Permissions section), since it calls `aws mwaa update-environment`.

## 3. Automate with GitHub Actions

`.github/workflows/deploy-mwaa.yml` runs this same logic automatically on every push to `main` that touches `dags/**` or `requirements.txt`.

Add these as repository secrets (Settings → Secrets and variables → Actions):

| Secret | Value |
|---|---|
| `AWS_ACCESS_KEY_ID` | From a dedicated CI IAM user, not your personal admin credentials |
| `AWS_SECRET_ACCESS_KEY` | Same user |
| `AWS_REGION` | `us-east-2` (or wherever you provisioned MWAA) |
| `MWAA_BUCKET_NAME` | Your MWAA bucket name |

The CI IAM user needs: `s3:PutObject`/`s3:DeleteObject`/`s3:ListBucket` on the MWAA bucket, and `airflow:UpdateEnvironment` on the MWAA environment, narrower than the admin profile, since this identity only ever needs to sync files and trigger a requirements update, nothing else.

## 4. Trigger the DAG

Through the Web UI (Airflow's webserver URL is in the MWAA console) is simplest. From the CLI, MWAA doesn't expose a direct `aws mwaa trigger-dag` subcommand, it works through a short-lived token instead (valid 60 seconds, request one right before you use it):

```bash
CLI_JSON=$(aws mwaa create-cli-token --name sentinel-mwaa --profile Samuel --region us-east-2)
CLI_TOKEN=$(echo "$CLI_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin)['CliToken'])")
WEB_SERVER_HOSTNAME=$(echo "$CLI_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin)['WebServerHostname'])")

CLI_RESULTS=$(curl --request POST "https://$WEB_SERVER_HOSTNAME/aws_mwaa/cli" \
  --header "Authorization: Bearer $CLI_TOKEN" \
  --header "Content-Type: text/plain" \
  --data-raw "dags trigger sentinel_daily_pipeline -e 2026-07-04")

echo "$CLI_RESULTS" | python3 -c "import sys, json, base64; print(base64.b64decode(json.load(sys.stdin)['stdout']).decode())"
```

The response comes back as base64-encoded `stdout`/`stderr` fields, that last line decodes it into something readable. Same underlying mechanism as `docker compose exec airflow airflow dags trigger ...` locally, just reached over HTTPS with a token instead of a direct shell into the container.

## 5. Follow logs in CloudWatch

MWAA sends scheduler, webserver, and per-task logs to CloudWatch Log Groups named `airflow-sentinel-mwaa-<component>`:

```bash
aws logs tail airflow-sentinel-mwaa-task --follow --profile Samuel --region us-east-2
```

Or in the Console: CloudWatch → Log groups → filter by `airflow-sentinel-mwaa`. Task-level logs (`airflow-sentinel-mwaa-task`) are the equivalent of what you've been reading from the local Docker container's task logs all along, same content, different transport.

## 6. Debugging import or dependency issues

**DAG doesn't appear in the UI at all, or shows a broken-DAG icon**: almost always an import error. Check the scheduler log group first:
```bash
aws logs tail airflow-sentinel-mwaa-scheduler --profile Samuel --region us-east-2
```
Look for `ModuleNotFoundError` or `ImportError`, usually means `dags/etl_scripts/__init__.py` didn't sync, or an import inside `etl_scripts` still references the old top-level package name (check the migration script's "Needs manual review" list again).

**`requirements.txt` fails to install**: check the environment's error details:
```bash
aws mwaa get-environment --name sentinel-mwaa --query "Environment.LastUpdate" --profile Samuel --region us-east-2
```
This is exactly what the optional local-runner validation in `docs/mwaa_setup.md` exists to catch before it gets this far.

**Task runs but fails with a `ModuleNotFoundError` specifically inside a task (not at DAG-parse time)**: usually a package used by a transformer/extractor that's missing from `requirements.txt`, MWAA's runtime doesn't have anything installed beyond Airflow itself plus whatever your `requirements.txt` lists, unlike the local Docker image, which also had `build-essential`/`unzip`/`snowsql` baked in at the OS level, none of that exists on MWAA workers automatically.

**Task fails trying to reach Snowflake, AWS, or the Open-Meteo API**: check the execution role's permissions first (`docs/mwaa_setup.md`'s execution policy), then confirm the NAT Gateway is actually `available`, not just created, workers in the private subnets have zero internet access without it.
