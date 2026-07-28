"""
Reads the nightly billing CSV export, groups rows by transaction_date, and
writes one Parquet file per date to the S3 landing zone.

Usage:
    python extractors/extract_billing.py
"""

import io
import os
from pathlib import Path

import boto3
import pandas as pd
from dotenv import load_dotenv

load_dotenv()

SOURCE_FILE = Path(os.environ.get("SOURCE_SYSTEMS_DIR", "./source_systems")) / "billing.csv"
S3_BUCKET = os.environ["S3_LANDING_BUCKET"]


def run():
    df = pd.read_csv(SOURCE_FILE, parse_dates=["transaction_date"])
    s3_client = boto3.client("s3")

    for txn_date, group in df.groupby(df["transaction_date"].dt.date):
        buffer = io.BytesIO()
        group.to_parquet(buffer, index=False, engine="pyarrow", compression="snappy")
        buffer.seek(0)

        key = f"source=billing/day={txn_date}/billing.parquet"
        s3_client.upload_fileobj(buffer, S3_BUCKET, key)
        print(f"{txn_date}: wrote {len(group)} rows to s3://{S3_BUCKET}/{key}")


if __name__ == "__main__":
    run()
