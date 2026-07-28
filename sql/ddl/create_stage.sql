-- Named external stage pointing at the S3 processed zone.
-- Replace the storage integration / credentials placeholders with the
-- values for your Snowflake + AWS setup.

CREATE STORAGE INTEGRATION IF NOT EXISTS sentinel_s3_integration
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'S3'
    ENABLED = TRUE
    STORAGE_AWS_ROLE_ARN = '<iam_role_arn>'
    STORAGE_ALLOWED_LOCATIONS = ('s3://sentinel-processed/');

CREATE FILE FORMAT IF NOT EXISTS parquet_format
    TYPE = 'PARQUET';

CREATE STAGE IF NOT EXISTS sentinel_s3_stage
    STORAGE_INTEGRATION = sentinel_s3_integration
    URL = 's3://sentinel-processed/'
    FILE_FORMAT = parquet_format;
