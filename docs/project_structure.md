# Project Structure

Full file-by-file layout. See the [README](../README.md) for the high-level summary and setup instructions.

```
sentinel-pipeline/
├── dags/
│   ├── sentinel_daily_pipeline.py       # DAG: extract (x4 parallel) -> validate -> transform (x4) -> load
│   └── etl_scripts/                     # MWAA-mirroring layout: only dags/ is on sys.path in real MWAA
│       ├── __init__.py
│       ├── extractors/
│       │   ├── __init__.py
│       │   ├── extract_policy_admin.py
│       │   ├── extract_claims.py
│       │   ├── extract_billing.py
│       │   └── extract_weather.py
│       ├── validators/
│       │   ├── __init__.py
│       │   ├── contracts.py             # Schema contracts per dataset
│       │   ├── validate.py              # Lightweight pandas-only gate
│       │   ├── validate_ge.py           # Real Great Expectations gate
│       │   └── expectation_suites/      # Generated at runtime, gitignored
│       └── transformers/
│           ├── __init__.py
│           ├── s3_helpers.py            # Shared: clean handling for missing source-day data
│           ├── transform_policy_admin.py
│           ├── transform_claims.py
│           ├── transform_billing.py
│           └── transform_weather.py
├── scripts/
│   ├── setup_aws.sh                     # Provisions S3 + RDS from .env
│   ├── teardown_aws.sh                  # Tears down RDS, S3, security group
│   ├── preflight_check.sh               # Verifies AWS/S3/RDS/Snowflake before a run
│   ├── seed_policy_admin_db.py          # --bootstrap, --reset flags
│   ├── pull_source_data.py              # Automatic Drive pull (fallback; manual is default)
│   ├── sync_source_to_s3.sh
│   ├── update_rds_ip_allowlist.sh
│   ├── register_snowflake_key.py        # Key-pair registration for SSO/SAML accounts only
│   ├── run_airflow.sh                   # One-command local Airflow via Docker
│   ├── setup_mwaa.sh                    # Provisions real MWAA + VPC/NAT/IAM/Secrets Manager
│   ├── teardown_mwaa.sh                 # Tears MWAA down in correct dependency order
│   ├── migrate_to_etl_scripts.py        # One-time: restructures into the etl_scripts layout
│   └── deploy_to_mwaa.sh                # Syncs dags/ + requirements.txt to MWAA's S3 bucket
├── sql/
│   ├── ddl/
│   │   ├── create_warehouse_and_database.sql
│   │   ├── create_tables.sql            # 8 staging + 8 warehouse tables
│   │   └── create_stage.sql
│   ├── merge/
│   │   ├── copy_into_staging.sql        # FORCE=TRUE + TRUNCATE for idempotent reruns
│   │   └── merge_dimensions_and_fact.sql
│   ├── views/
│   │   └── create_analytics_views.sql   # Loss ratio, claim frequency, fraud flags, reconciliation
│   └── checks/
│       └── idempotency_check.sql        # Proves no duplicates regardless of rerun count
├── docker/
│   └── airflow/
│       └── Dockerfile                   # Extends official Airflow image + snowsql
├── docker-compose.airflow.yml           # Local Airflow (Airflow doesn't run natively on Windows)
├── .github/
│   └── workflows/
│       └── deploy-mwaa.yml              # Auto-deploys dags/ + requirements.txt on push to main
├── docs/
│   ├── project_structure.md             # This file
│   ├── architecture-diagram.svg
│   ├── SETUP_CHECKLIST.md               # Start here
│   ├── data_dictionary.md               # Includes analytics views + billing_transactions
│   ├── aws_cli_setup.md
│   ├── aws_setup.md
│   ├── policy_admin_db_setup.md
│   ├── snowflake_setup.md
│   ├── snowflake_s3_integration.md
│   ├── airflow_setup.md                 # Local Docker Airflow
│   ├── mwaa_setup.md                    # Real MWAA provisioning + cost warning
│   ├── mwaa_deploy.md                   # Migration, deploy, CI, triggering, CloudWatch debugging
│   ├── aws_teardown.md
│   └── source_data_pull.md
├── tests/
│   └── test_contracts.py
├── source_systems/                      # Local raw source data (gitignored)
├── .env.example
├── .gitignore
├── .dockerignore
├── requirements.txt
└── README.md
```
