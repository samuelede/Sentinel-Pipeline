"""
Shared helper for transformer scripts: downloading a single day's
landing-zone Parquet file. Some source datasets (billing, weather, and
each individual policy admin table) only exist for part of a date range
in this environment, e.g. billing only covers 2026-07-04 through
2026-07-10. Running a transform for a day outside that range is not a
bug, it's expected, but by default boto3 raises a raw ClientError 404
with a full traceback, which looks like a crash. This wraps that into a
single clear sentence instead.
"""

import io
import sys

import pandas as pd
from botocore.exceptions import ClientError


def load_parquet_or_exit(s3_client, bucket, key, dataset_label, run_date):
    """Downloads and loads a single Parquet file from S3. If the key
    doesn't exist, prints a one-line explanation (almost always: this
    source simply has no data for this day, not an error) and exits,
    instead of letting a raw S3 404 traceback bubble up. Still exits
    non-zero, so Airflow's retry/alerting still treats it as a task that
    needs attention, just without the scary-looking traceback."""
    buffer = io.BytesIO()
    try:
        s3_client.download_fileobj(bucket, key, buffer)
    except ClientError as e:
        error_code = e.response.get("Error", {}).get("Code")
        if error_code in ("404", "NoSuchKey"):
            print(
                f"No {dataset_label} data found for day={run_date} "
                f"(s3://{bucket}/{key} does not exist). This almost always "
                f"means the source dataset simply doesn't have data for "
                f"this particular day, not a real error, check whether "
                f"this day is within that source's actual date range "
                f"before investigating further."
            )
            sys.exit(1)
        raise
    buffer.seek(0)
    return pd.read_parquet(buffer)
