# Setup Checklist

One page, everything you need to fill in before running anything. Fill these in, run the preflight check, and only chase the individual docs under `docs/` if the preflight check tells you something specific is broken, they exist for troubleshooting depth, not as required reading up front.

## 1. Fill in `.env`

```bash
cp .env.example .env
```

Then edit these values in `.env`:

| Variable | Where it comes from |
|---|---|
| `PG_MASTER_USER`, `PG_MASTER_PASSWORD` | invent these yourself, `setup_aws.sh` uses them to create the RDS instance |
| `PG_APP_USER` | leave as `sentinel` unless you have a reason to change it |
| `PG_APP_PASSWORD` | invent this yourself, it doesn't exist until the bootstrap script creates it |
| `PG_DB` | leave as `policy_admin` unless you have a reason to change it |
| `S3_LANDING_BUCKET`, `S3_PROCESSED_BUCKET` | pick names (may need a suffix if the plain name is taken globally) |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | leave commented out, `boto3` reads `~/.aws/credentials` instead, uncommenting these with placeholder text breaks every AWS call |

`PG_HOST` does not need filling in, it doesn't exist yet, `setup_aws.sh` writes it in automatically once RDS is up.

## 2. Configure the AWS CLI

```bash
aws configure
```

Needs a real IAM access key and secret (not the RDS/Postgres credentials, a separate IAM user), plus your region. Full walkthrough only if this is your first time: [`docs/aws_cli_setup.md`](aws_cli_setup.md).

## 3. Provision AWS: one command

```bash
./scripts/setup_aws.sh
```

Creates both S3 buckets, the RDS instance with a security group locked to your current IP, waits for it to become available, writes the real endpoint into `.env` automatically, and bootstraps the `sentinel` role and database. Safe to re-run, existing resources are detected and skipped rather than recreated.

If you'd rather do each piece manually (or understand exactly what this script does before running it): [`docs/aws_setup.md`](aws_setup.md) for S3, [`docs/policy_admin_db_setup.md`](policy_admin_db_setup.md) for RDS.

## 4. Fill in `~/.snowsql/config`

```ini
[connections.sentinel]
accountname = YOUR-ACCOUNT-IDENTIFIER
username = your_snowflake_username
password = your_snowflake_password      # or private_key_path, if MFA is enabled
warehousename = SENTINEL_WH
dbname = SENTINEL_DB
schemaname = ANALYTICS
```

Get `accountname` from the browser URL while logged into Snowsight, don't guess the region suffix. If your account has MFA enabled, use `private_key_path` instead of `password`, full walkthrough: [`docs/snowflake_setup.md`](snowflake_setup.md).

## 5. Run the preflight check

```bash
./scripts/preflight_check.sh
```

This actually tests every connection (AWS, S3, RDS, Snowflake) rather than just checking that config files exist. It prints PASS/FAIL for each item and tells you exactly which doc to open if something's broken. Don't move on to running the pipeline until this passes clean.

## 6. Run the pipeline

Once preflight passes, and after a manual Drive download into `source_systems/` (see [`source_data_pull.md`](source_data_pull.md), the automatic pull keeps failing on Drive's rate limit, don't rely on it):

```bash
python scripts/seed_policy_admin_db.py
python extractors/extract_policy_admin.py --day 2026-01-15
python extractors/extract_claims.py
python extractors/extract_billing.py
python extractors/extract_weather.py --day 2026-01-15
python -m validators.validate_ge --all --day 2026-01-15
python transformers/transform_policy_admin.py --day 2026-01-15
# ...and so on, see README.md Setup steps 7-9 for the full sequence
```

## When you're done for the session

```bash
./scripts/teardown_aws.sh
```

Tears down RDS and S3 so nothing keeps billing while you're away. Snowflake doesn't need this, it runs on credits and auto-suspends, not a running meter. Full detail: [`docs/aws_teardown.md`](aws_teardown.md).

## The detailed docs (only open these if preflight tells you to)

| Doc | When you need it |
|---|---|
| [`aws_cli_setup.md`](aws_cli_setup.md) | AWS CLI won't authenticate |
| [`aws_setup.md`](aws_setup.md) | S3 buckets missing or need recreating |
| [`policy_admin_db_setup.md`](policy_admin_db_setup.md) | RDS provisioning, or Postgres connection fails |
| [`snowflake_setup.md`](snowflake_setup.md) | `snowsql` install, config, MFA/key-pair auth |
| [`snowflake_s3_integration.md`](snowflake_s3_integration.md) | Setting up the Snowflake-to-S3 stage (one-time IAM handshake) |
| [`source_data_pull.md`](source_data_pull.md) | Pulling source CSVs/JSON from Google Drive |
| [`aws_teardown.md`](aws_teardown.md) | Full manual teardown/re-setup breakdown |
| [`data_dictionary.md`](data_dictionary.md) | Column-level schema reference |

Each one exists because a specific real failure happened during this project's setup and needed a real fix, not because the process is inherently this complicated. Day to day, this checklist plus the preflight script should be everything you actually need to touch.
