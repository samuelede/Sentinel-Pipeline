# Sentinel Auto Insurance - Data Platform Pipeline

A daily batch data pipeline that unifies Sentinel Auto Insurance's three siloed operational systems (policy admin, claims, billing) plus an external weather API into a single Snowflake dimensional warehouse, enabling cross-system analytics for underwriting, claims, and fraud review.

## Problem Statement

Sentinel's three core systems, a PostgreSQL-backed policy admin platform, a vendor-managed claims system exporting nested JSON, and a billing platform exporting nightly CSVs, were procured independently and were never built to share data. There is no unified customer view, no automated reconciliation between systems, and no integration with external risk data such as weather. Cross-system reporting currently requires manual, error-prone stitching in Excel, taking days to assemble and weeks to reconcile, which delays underwriting, reserving, and fraud-detection decisions.

This project builds an internal data platform that extracts from all four sources daily, lands and validates the data in a multi-zone S3 lake, transforms it with pandas, and loads it into a Snowflake star schema, replacing manual report assembly with same-day, query-ready analytics.

## Architecture

![Architecture Diagram](docs/architecture-diagram.svg)
*Placeholder. Shows the pipeline architecture diagram (extraction, S3 landing, validation, pandas transform, S3 processed, Snowflake COPY INTO, dimensional warehouse).*

**Flow:** `PostgreSQL / SFTP JSON / CSV / Weather API` feeds the **S3 Landing Zone** (raw, partitioned by source and day), which passes through **Great Expectations validation** (pass goes to processed, fail goes to quarantine), then **pandas transformation** (flatten, type, dedupe), landing in the **S3 Processed Zone** (Parquet), which loads via **Snowflake COPY INTO + MERGE** into the **Star Schema Warehouse**. All stages are orchestrated by **Apache Airflow**.

## Data Model

Star schema centered on `claims_fact`, joined to four conformed dimensions (`dim_customer`, `dim_agent`, `dim_policy`, `dim_coverage`) and a `payments` table. `weather_daily` is a separate enrichment table joined to `claims_fact` on `(incident_zip, incident_date)`. Dimensions hold current state only in v1 (SCD Type 2 is a scoped-out future enhancement). See [`docs/data_dictionary.md`](docs/data_dictionary.md) for full column-level definitions.

## Tech Stack

| Layer | Tools |
|---|---|
| Extraction | `psycopg2`, `pandas`, `boto3`, `requests` |
| Storage | Amazon S3 (multi-zone: landing / processed / quarantine) |
| Processing | pandas, PyArrow (Parquet, Snappy) |
| Validation | Great Expectations |
| Warehouse | Snowflake (COPY INTO + MERGE via external stage) |
| Orchestration | Apache Airflow |
| Source DB | Amazon RDS (PostgreSQL) |

## Project Structure

```
sentinel-pipeline/
├── dags/
│   └── sentinel_daily_pipeline.py      # Airflow DAG: extract, validate, transform, load
├── extractors/
│   ├── extract_policy_admin.py         # PostgreSQL to S3 landing (customers, agents, policies, coverages)
│   ├── extract_claims.py               # SFTP/S3 JSON to S3 landing
│   ├── extract_billing.py              # CSV to S3 landing (grouped by transaction_date)
│   └── extract_weather.py              # Open-Meteo API to S3 landing (trailing 7 day window)
├── validators/
│   ├── contracts.py                    # Expected schema/type/null contracts per dataset
│   ├── validate.py                     # Lightweight pandas-based suite runner and quarantine logic
│   └── validate_ge.py                  # Real GX ephemeral context + pandas datasource + batch definitions
│                                        #   (validate.py kept as a lighter-weight comparison)
├── transformers/
│   ├── transform_claims.py             # Flatten nested claim events, split out payments
│   ├── transform_policy_admin.py       # Type enforcement, dedupe
│   ├── transform_billing.py
│   └── transform_weather.py
├── scripts/
│   ├── pull_source_data.py             # Pulls source CSVs and claims JSON from Google Drive
│   ├── seed_policy_admin_db.py         # One-time RDS bootstrap and seed from source CSVs
│   ├── setup_aws.sh                    # Provisions S3 buckets and RDS from .env, mirrors teardown_aws.sh
│   ├── sync_source_to_s3.sh            # Chains pull, seed, and all four extractors
│   ├── update_rds_ip_allowlist.sh      # Updates the RDS security group to your current IP
│   ├── preflight_check.sh              # Verifies AWS/S3/RDS/Snowflake are all actually working
│   ├── teardown_aws.sh                 # Tears down RDS, S3, and the security group to stop billing
│   ├── register_snowflake_key.py       # Registers your RSA public key via browser MFA, no Snowsight needed
│   └── run_airflow.sh                  # Builds and runs Airflow via Docker (Airflow doesn't support native Windows)
├── docker/
│   └── airflow/
│       └── Dockerfile                  # Extends the official Airflow image with this project's dependencies
├── docker-compose.airflow.yml          # Single-container Airflow setup, see docs/airflow_setup.md
├── sql/
│   ├── ddl/                            # Snowflake table definitions (fact, dims, payments, weather, stage)
│   └── merge/                          # COPY INTO and MERGE statements per table
├── source_systems/                     # Local raw source data (gitignored)
├── docs/
│   ├── architecture-diagram.svg
│   ├── SETUP_CHECKLIST.md              # Start here: one page, what to fill in, then run preflight_check.sh
│   ├── data_dictionary.md
│   ├── aws_cli_setup.md
│   ├── aws_setup.md
│   ├── policy_admin_db_setup.md
│   ├── snowflake_setup.md
│   ├── snowflake_s3_integration.md
│   ├── airflow_setup.md
│   ├── aws_teardown.md
│   └── source_data_pull.md
├── tests/
├── .env.example
├── .gitignore
├── requirements.txt
├── LICENSE
└── README.md
```

## Prerequisites

- Python 3.10+
- AWS account with permissions to create S3 buckets and an RDS instance
- Snowflake account (trial or paid)
- Access to Sentinel source data drops (policy admin CSVs, claims JSON, billing CSV)

## Setup

**Fast path**: after cloning, see [`docs/SETUP_CHECKLIST.md`](docs/SETUP_CHECKLIST.md) for the single-page version of everything below, what to fill in, and `./scripts/preflight_check.sh` to verify it's all actually working before running the pipeline. The numbered steps below are the same information in full detail, useful the first time through or when troubleshooting a specific failure.

1. **Clone and create a virtual environment**
   ```bash
   git clone https://github.com/<your-org>/sentinel-pipeline.git
   cd sentinel-pipeline
   python -m venv venv
   source venv/bin/activate   # Windows: venv\Scripts\activate
   pip install -r requirements.txt
   ```

2. **Install and configure the AWS CLI**

   See [`docs/aws_cli_setup.md`](docs/aws_cli_setup.md) for install steps and `aws configure` walkthrough. Do this before provisioning any AWS resources, both the S3 and RDS setup docs below use it, and the extractors authenticate through the same credentials via `boto3`.

3. **Configure environment variables**
   ```bash
   cp .env.example .env
   ```
   Populate `.env` with RDS master/app credentials (you invent these yourself, they don't exist yet), S3 bucket names, and Snowflake account/user/password/warehouse/database/schema. AWS credentials are picked up from `~/.aws/credentials` (set in step 2) and do not need to be duplicated in `.env`. `.env` is gitignored. Never commit credentials. `PG_HOST` doesn't need filling in, it's written automatically by the next step.

4. **Provision AWS resources**
   ```bash
   ./scripts/setup_aws.sh
   ```
   Creates both S3 buckets, the RDS instance with a security group locked to your current IP, waits for it to become available, writes the real endpoint into `.env` automatically, and bootstraps the `sentinel` role and database. Safe to re-run, existing resources are detected and skipped. See [`docs/aws_setup.md`](docs/aws_setup.md) and [`docs/policy_admin_db_setup.md`](docs/policy_admin_db_setup.md) if you'd rather do each piece manually, or need to troubleshoot a specific step.

   Once this finishes, run `./scripts/preflight_check.sh` to confirm AWS, S3, and RDS are all actually reachable before continuing.

5. **Pull source data from Google Drive (manual download, recommended)**

   Download the shared Drive folder through your browser (logged in, so it uses your account's quota rather than an anonymous one) and place the contents in `source_systems/`, preserving the `billing_exports/` and `sftp_claim_source/` folder structure, and flattening the four policy admin CSVs to the top level:
   ```bash
   mv source_systems/policy_admin/*.csv source_systems/
   rmdir source_systems/policy_admin
   ```
   The automatic option (`python scripts/pull_source_data.py`) exists but repeatedly fails partway through with `FileURLRetrievalError`, Google Drive rate-limits anonymous downloads on large folders (the claims folder alone is 300+ files), and this has broken in practice more often than it's worked. Manual download avoids that entirely. See [`docs/source_data_pull.md`](docs/source_data_pull.md) for the full flow either way.

6. **Seed the policy admin database**
   ```bash
   python scripts/seed_policy_admin_db.py
   ```
   `--bootstrap` already ran as part of `setup_aws.sh` in step 4, no need to repeat it here unless you edited `PG_APP_PASSWORD` in `.env` afterward, in which case re-running `python scripts/seed_policy_admin_db.py --bootstrap` syncs the database to match. See [`docs/policy_admin_db_setup.md`](docs/policy_admin_db_setup.md) for the full RDS setup and role-bootstrapping walkthrough.

7. **Run extractors locally (ad hoc / testing)**
   ```bash
   python extractors/extract_policy_admin.py --day 2026-01-15
   python extractors/extract_claims.py
   python extractors/extract_billing.py
   python extractors/extract_weather.py --day 2026-01-15
   ```
   Steps 5 through 7 can be run together with `./scripts/sync_source_to_s3.sh 2026-01-15`.

8. **Run validation**
   ```bash
   python -m validators.validate --all --day 2026-01-15      # lightweight pandas version
   python -m validators.validate_ge --all --day 2026-01-15   # real Great Expectations version
   ```
   Both check the same contracts and quarantine the same way. `validate_ge.py` builds a real Great Expectations ephemeral Data Context with a pandas Datasource, one whole-dataframe Batch Definition per dataset, and a genuine `ExpectationSuite` (`ExpectColumnToExist`, `ExpectColumnValuesToNotBeNull`, `ExpectColumnValuesToBeInTypeList`), saved as JSON under `validators/expectation_suites/` on first run. This requires `great_expectations>=1.5` (not the older `0.18.x` API, which lacks the batch definition workflow). `validate.py` is a lighter pandas-only equivalent kept for comparison, it has no Great Expectations dependency at all.

9. **Run transformation**
   ```bash
   python transformers/transform_policy_admin.py --day 2026-01-15
   python transformers/transform_claims.py --day 2026-01-15
   python transformers/transform_billing.py --day 2026-01-15
   python transformers/transform_weather.py --day 2026-01-15
   ```

10. **Create Snowflake objects**

   First, confirm the connection actually works before running anything that creates objects:
   ```bash
   snowsql -c sentinel -q "SELECT CURRENT_VERSION();"
   ```
   This should print a version string and exit cleanly. If it fails (MFA error, 404, "could not connect," etc.), fix that first, see [`docs/snowflake_setup.md`](docs/snowflake_setup.md), rather than debugging it in the middle of a DDL run. `./scripts/preflight_check.sh` also covers this same check alongside AWS/S3/RDS.

   Once that passes:
   ```bash
   snowsql -c sentinel -f sql/ddl/create_warehouse_and_database.sql
   snowsql -c sentinel -f sql/ddl/create_tables.sql
   snowsql -c sentinel -f sql/ddl/create_stage.sql
   ```
   These commands assume `snowsql` is installed and `~/.snowsql/config` has a connection named `sentinel` (see setup below). If you set `default = sentinel` in the config's `[connections]` section, you can drop `-c sentinel` from these commands, but leaving it explicit avoids a confusing fallback to interactive password prompts if no default is set. The warehouse/database script must run first, the other two assume `SENTINEL_WH` and `SENTINEL_DB` already exist. See [`docs/snowflake_setup.md`](docs/snowflake_setup.md) for installing `snowsql`, setting up `~/.snowsql/config`, and MFA/key-pair authentication.

11. **Set up Airflow**

   Apache Airflow does not support native Windows (confirmed directly by Airflow's own startup warning: "you can run it via WSL2... or via Linux Containers"). Running it natively in Git Bash fails with a `Cannot use relative path: sqlite:///C:/...` error, that's not fixable with environment variables, it's a fundamental platform limitation.

   ```bash
   ./scripts/run_airflow.sh
   ```

   This runs Airflow inside a Docker container (via `docker-compose.airflow.yml`), sidestepping the Windows limitation entirely, and is also the officially recommended way to run Airflow locally regardless of OS. Login uses `AIRFLOW_ADMIN_USERNAME`/`AIRFLOW_ADMIN_PASSWORD` from `.env`, see [`docs/airflow_setup.md`](docs/airflow_setup.md) for the full walkthrough and how to trigger a DAG run.

   The DAG itself is parameterized on Airflow's `execution_date` macro, so backfills can be run for any historical day.

## Running the Full Pipeline

With `./scripts/run_airflow.sh` running, trigger a manual run for a given day through the Web UI (`http://localhost:8080`) or the CLI:
```bash
docker compose -f docker-compose.airflow.yml exec airflow airflow dags trigger sentinel_daily_pipeline -e 2026-01-15
```

## Teardown

AWS resources (RDS, S3) bill by the hour/GB whether or not they're in use. When stepping away from active development, tear them down:

```bash
./scripts/teardown_aws.sh
```

See [`docs/aws_teardown.md`](docs/aws_teardown.md) for the manual step-by-step breakdown and how to bring everything back up again later. Snowflake doesn't need equivalent teardown, trial accounts run on credits rather than a running meter, and warehouses auto-suspend on inactivity.

## Data Quality

Landing files are validated against schema contracts defined in `validators/contracts.py` (column existence, type/parseability, required non-null fields) before promotion to the processed zone. Files that fail validation are routed to `s3://sentinel-landing/quarantine/` along with a `validation_report.json` detailing every failed expectation, and an alert is raised.

## Testing

```bash
pytest tests/
```

## Roadmap / Future Enhancements

- Slowly Changing Dimensions (SCD Type 2) for historical state tracking
- Automated reconciliation between billed and earned premium
- Fraud-detection and catastrophe-exposure models built on the weather/claims join
- Real-time or micro-batch ingestion for high-priority sources

## Contributing

1. Create a feature branch off `main`: `git checkout -b feature/<short-description>`
2. Make your changes, following the existing code structure and naming conventions
3. Add or update tests under `tests/` where applicable
4. Open a Pull Request with a clear description of the change and any schema impacts
5. At least one review approval is required before merging

## License

Licensed under the [MIT License](LICENSE).
