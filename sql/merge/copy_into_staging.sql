-- Loads the day's processed Parquet files from S3 into staging tables.
--
-- &{RUN_DATE} is snowsql's own variable substitution syntax (NOT bash's
-- $RUN_DATE, which snowsql does not recognize and would just send to
-- Snowflake as a literal, unmatched string). Requires BOTH:
--   -D RUN_DATE=<value>              (defines the value)
--   -o variable_substitution=true    (turns substitution on at all)
-- Neither alone is sufficient. To run manually:
--
--   snowsql -c sentinel -o variable_substitution=true \
--     -f sql/merge/copy_into_staging.sql -D RUN_DATE=2026-07-04
--
-- Each COPY INTO is preceded by a TRUNCATE and uses FORCE = TRUE. Without
-- these, Snowflake silently skips files it has already "seen" for a given
-- target table, even across separate runs, even if an earlier attempt
-- never actually got real rows into the final table (e.g. it failed
-- downstream, or the IAM role wasn't set up correctly yet at the time).
-- That default behavior directly breaks the idempotent-reruns-and-backfills
-- requirement this pipeline is meant to satisfy, a legitimate retry for a
-- day already touched once would otherwise silently no-op forever.
-- FORCE = TRUE is safe here specifically because staging is a transient
-- loading buffer, not the final target: the MERGE statements that follow
-- upsert into the real warehouse tables on natural keys, so even if
-- staging gets reloaded on every retry, the final tables can never end up
-- with duplicates.

TRUNCATE TABLE staging.stg_customers;
COPY INTO staging.stg_customers
FROM @sentinel_s3_stage/dim_customer/day=&{RUN_DATE}/
FILE_FORMAT = parquet_format
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
FORCE = TRUE;

TRUNCATE TABLE staging.stg_agents;
COPY INTO staging.stg_agents
FROM @sentinel_s3_stage/dim_agent/day=&{RUN_DATE}/
FILE_FORMAT = parquet_format
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
FORCE = TRUE;

TRUNCATE TABLE staging.stg_policies;
COPY INTO staging.stg_policies
FROM @sentinel_s3_stage/dim_policy/day=&{RUN_DATE}/
FILE_FORMAT = parquet_format
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
FORCE = TRUE;

TRUNCATE TABLE staging.stg_coverages;
COPY INTO staging.stg_coverages
FROM @sentinel_s3_stage/dim_coverage/day=&{RUN_DATE}/
FILE_FORMAT = parquet_format
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
FORCE = TRUE;

TRUNCATE TABLE staging.stg_claims_fact;
COPY INTO staging.stg_claims_fact
FROM @sentinel_s3_stage/claims_fact/day=&{RUN_DATE}/
FILE_FORMAT = parquet_format
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
FORCE = TRUE;

TRUNCATE TABLE staging.stg_payments;
COPY INTO staging.stg_payments
FROM @sentinel_s3_stage/payments/day=&{RUN_DATE}/
FILE_FORMAT = parquet_format
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
FORCE = TRUE;

TRUNCATE TABLE staging.stg_weather_daily;
COPY INTO staging.stg_weather_daily
FROM @sentinel_s3_stage/weather_daily/day=&{RUN_DATE}/
FILE_FORMAT = parquet_format
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
FORCE = TRUE;

TRUNCATE TABLE staging.stg_billing_transactions;
COPY INTO staging.stg_billing_transactions
FROM @sentinel_s3_stage/billing_transactions/day=&{RUN_DATE}/
FILE_FORMAT = parquet_format
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
FORCE = TRUE;
