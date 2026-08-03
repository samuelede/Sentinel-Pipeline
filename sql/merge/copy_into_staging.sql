-- Loads the day's processed Parquet files from S3 into staging tables.
-- $RUN_DATE should be substituted by the orchestrator (Airflow) at run time.

COPY INTO staging.stg_customers
FROM @sentinel_s3_stage/dim_customer/day=$RUN_DATE/
FILE_FORMAT = parquet_format
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

COPY INTO staging.stg_agents
FROM @sentinel_s3_stage/dim_agent/day=$RUN_DATE/
FILE_FORMAT = parquet_format
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

COPY INTO staging.stg_policies
FROM @sentinel_s3_stage/dim_policy/day=$RUN_DATE/
FILE_FORMAT = parquet_format
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

COPY INTO staging.stg_coverages
FROM @sentinel_s3_stage/dim_coverage/day=$RUN_DATE/
FILE_FORMAT = parquet_format
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

COPY INTO staging.stg_claims_fact
FROM @sentinel_s3_stage/claims_fact/day=$RUN_DATE/
FILE_FORMAT = parquet_format
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

COPY INTO staging.stg_payments
FROM @sentinel_s3_stage/payments/day=$RUN_DATE/
FILE_FORMAT = parquet_format
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

COPY INTO staging.stg_weather_daily
FROM @sentinel_s3_stage/weather_daily/day=$RUN_DATE/
FILE_FORMAT = parquet_format
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

COPY INTO staging.stg_billing_transactions
FROM @sentinel_s3_stage/billing_transactions/day=$RUN_DATE/
FILE_FORMAT = parquet_format
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
