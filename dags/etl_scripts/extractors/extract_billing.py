"""
Reads the billing exports from source_systems/billing_exports/ (one CSV
per day, e.g. billing_2026-07-04.csv) and writes one Parquet file per date
to the S3 landing zone.

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

BILLING_DIR = Path(os.environ.get("SOURCE_SYSTEMS_DIR", "./source_systems")) / "billing_exports"
S3_BUCKET = os.environ["S3_LANDING_BUCKET"]


def load_all_billing_files():
    files = sorted(BILLING_DIR.glob("*.csv"))
    if not files:
        raise FileNotFoundError(f"No billing export CSVs found under {BILLING_DIR}")

    frames = [pd.read_csv(f, parse_dates=["transaction_date"]) for f in files]
    return pd.concat(frames, ignore_index=True)


def run():
    df = load_all_billing_files()
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