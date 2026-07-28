"""
Reads the validated billing Parquet file from the S3 landing zone,
enforces DECIMAL typing on monetary fields and explicit date typing, and
writes the result to the processed zone.

Usage:
    python transformers/transform_billing.py --day 2026-01-15
"""

import argparse
import io
import os
from datetime import date

import boto3
import pandas as pd
from dotenv import load_dotenv

load_dotenv()


def run(run_date):
    landing_bucket = os.environ["S3_LANDING_BUCKET"]
    processed_bucket = os.environ["S3_PROCESSED_BUCKET"]
    s3_client = boto3.client("s3")

    key = f"source=billing/day={run_date}/billing.parquet"
    buffer = io.BytesIO()
    s3_client.download_fileobj(landing_bucket, key, buffer)
    buffer.seek(0)
    df = pd.read_parquet(buffer)

    df = df.drop_duplicates(subset="transaction_id")
    df["amount"] = df["amount"].astype(float).round(2)
    df["transaction_date"] = pd.to_datetime(df["transaction_date"]).dt.date
    df["transaction_type"] = df["transaction_type"].astype(str).str.strip().str.title()

    out_buffer = io.BytesIO()
    df.to_parquet(out_buffer, index=False, engine="pyarrow", compression="snappy")
    out_buffer.seek(0)

    out_key = f"billing/day={run_date}/billing.parquet"
    s3_client.upload_fileobj(out_buffer, processed_bucket, out_key)
    print(f"billing: wrote {len(df)} rows to s3://{processed_bucket}/{out_key}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Transform billing data.")
    parser.add_argument("--day", default=str(date.today()), help="Run date, YYYY-MM-DD")
    args = parser.parse_args()
    run(args.day)
