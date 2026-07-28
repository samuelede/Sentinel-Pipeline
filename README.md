# Sentinel Auto Insurance - Data Platform Pipeline

A daily batch data pipeline that unifies Sentinel Auto Insurance's three siloed operational systems (policy admin, claims, billing) plus an external weather API into a single Snowflake dimensional warehouse, enabling cross-system analytics for underwriting, claims, and fraud review.

## Problem Statement

Sentinel's three core systems, a PostgreSQL-backed policy admin platform, a vendor-managed claims system exporting nested JSON, and a billing platform exporting nightly CSVs, were procured independently and were never built to share data. There is no unified customer view, no automated reconciliation between systems, and no integration with external risk data such as weather. Cross-system reporting currently requires manual, error-prone stitching in Excel, taking days to assemble and weeks to reconcile, which delays underwriting, reserving, and fraud-detection decisions.

This project builds an internal data platform that extracts from all four sources daily, lands and validates the data in a multi-zone S3 lake, transforms it with pandas, and loads it into a Snowflake star schema, replacing manual report assembly with same-day, query-ready analytics.

## Architecture

![Architecture Diagram](docs/architecture-diagram.png)
*Placeholder. Add the pipeline architecture diagram (extraction, S3 landing, validation, pandas transform, S3 processed, Snowflake COPY INTO, dimensional warehouse) here.*

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
│   └── validate.py                     # Great Expectations suite runner and quarantine logic
├── transformers/
│   ├── transform_claims.py             # Flatten nested claim events, split out payments
│   ├── transform_policy_admin.py       # Type enforcement, dedupe
│   ├── transform_billing.py
│   └── transform_weather.py
├── scripts/
│   └── seed_policy_admin_db.py         # One-time RDS bootstrap and seed from source CSVs
├── sql/
│   ├── ddl/                            # Snowflake table definitions (fact, dims, payments, weather, stage)
│   └── merge/                          # COPY INTO and MERGE statements per table
├── source_systems/                     # Local raw source data (gitignored)
├── docs/
│   ├── architecture-diagram.png
│   ├── data_dictionary.md
│   ├── aws_cli_setup.md
│   ├── aws_setup.md
│   └── policy_admin_db_setup.md
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

1. **Clone and create a virtual environment**
   ```bash
   git clone https://github.com/samuelede/sentinel-pipeline.git
   cd sentinel-pipeline
   python -m venv venv
   source venv/bin/activate   # Windows: venv\Scripts\activate
   pip install -r requirements.txt
   ```

2. **Install and configure the AWS CLI**

   See [`docs/aws_cli_setup.md`](docs/aws_cli_setup.md) for install steps and `aws configure` walkthrough. Do this before provisioning any AWS resources, both the S3 and RDS setup docs below use it, and the extractors authenticate through the same credentials via `boto3`.

3. **Provision AWS resources**
   - Create two S3 buckets: `sentinel-landing`, `sentinel-processed`
   - Provision an RDS PostgreSQL instance (`sentinel-policy-admin`), restrict inbound `5432` to your IP

   See [`docs/aws_setup.md`](docs/aws_setup.md) for the S3 bucket steps, and [`docs/policy_admin_db_setup.md`](docs/policy_admin_db_setup.md) for the full RDS provisioning and security group walkthrough.

4. **Configure environment variables**
   ```bash
   cp .env.example .env
   ```
   Populate `.env` with RDS host/user/password, S3 bucket names, and Snowflake account/user/password/warehouse/database/schema. AWS credentials are picked up from `~/.aws/credentials` (set in step 2) and do not need to be duplicated in `.env`. `.env` is gitignored. Never commit credentials.

5. **Seed the policy admin database**
   ```bash
   python scripts/seed_policy_admin_db.py --bootstrap
   python scripts/seed_policy_admin_db.py
   ```
   See [`docs/policy_admin_db_setup.md`](docs/policy_admin_db_setup.md) for the full RDS setup and role-bootstrapping walkthrough.

6. **Run extractors locally (ad hoc / testing)**
   ```bash
   python extractors/extract_policy_admin.py --day 2026-01-15
   python extractors/extract_claims.py
   python extractors/extract_billing.py
   python extractors/extract_weather.py --day 2026-01-15
   ```

7. **Run validation**
   ```bash
   python validators/validate.py --all --day 2026-01-15
   ```

8. **Run transformation**
   ```bash
   python transformers/transform_policy_admin.py --day 2026-01-15
   python transformers/transform_claims.py --day 2026-01-15
   python transformers/transform_billing.py --day 2026-01-15
   python transformers/transform_weather.py --day 2026-01-15
   ```

9. **Create Snowflake objects**
   ```bash
   snowsql -f sql/ddl/create_tables.sql
   snowsql -f sql/ddl/create_stage.sql
   ```

10. **Set up Airflow**
   ```bash
   export AIRFLOW_HOME=$(pwd)/airflow
   airflow db init
   airflow users create --username admin --role Admin --email admin@example.com
   cp dags/sentinel_daily_pipeline.py $AIRFLOW_HOME/dags/
   airflow webserver -p 8080
   airflow scheduler
   ```
   The DAG is parameterized on Airflow's `execution_date` macro, so backfills can be run for any historical day.

## Running the Full Pipeline

Trigger a manual run for a given day through the Airflow UI or CLI:
```bash
airflow dags trigger sentinel_daily_pipeline -e 2026-01-15
```

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
