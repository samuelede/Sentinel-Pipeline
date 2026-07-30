-- Named external stage pointing at the S3 processed zone.
--
-- This is PHASE 1 of a two-phase process, see docs/snowflake_s3_integration.md
-- for the full walkthrough. Phase 1 creates the integration with a
-- placeholder role ARN so Snowflake can generate the values you need to
-- finish setting up the IAM trust relationship. After completing phase 2
-- (updating the IAM role's trust policy), re-run the ALTER STATEMENT at
-- the bottom of this file with your real role ARN.
--
-- Replace 'sentinel-processed' below with your actual bucket name if it
-- has a suffix (e.g. 'sentinel-processed-sm'), bucket names are globally
-- unique so yours may not match this literally.

CREATE STORAGE INTEGRATION IF NOT EXISTS sentinel_s3_integration
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'S3'
    ENABLED = TRUE
    STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::123456789012:role/placeholder_role'
    STORAGE_ALLOWED_LOCATIONS = ('s3://sentinel-processed-sm/');

CREATE FILE FORMAT IF NOT EXISTS parquet_format
    TYPE = 'PARQUET';

CREATE STAGE IF NOT EXISTS sentinel_s3_stage
    STORAGE_INTEGRATION = sentinel_s3_integration
    URL = 's3://sentinel-processed-sm/'
    FILE_FORMAT = parquet_format;

-- PHASE 2: after creating the real IAM role (see docs/snowflake_s3_integration.md),
-- run this to point the integration at it instead of the placeholder:
--
-- ALTER STORAGE INTEGRATION sentinel_s3_integration
--     SET STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::<your-account-id>:role/sentinel_snowflake_role';
