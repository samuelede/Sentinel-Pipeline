"""
Reads the validated billing Parquet file from the S3 landing zone,
enforces real DECIMAL typing on monetary fields (not floats) and
explicit date typing, and writes the result to the processed zone.

Usage:
    python transformers/transform_billing.py --day 2026-01-15
"""

import argparse
import io
import os
from datetime import date
from decimal import Decimal, ROUND_HALF_UP

import boto3
import pandas as pd
from dotenv import load_dotenv

from transformers.s3_helpers import load_parquet_or_exit

load_dotenv()


def to_decimal(value):
    """Casts a value to a real decimal.Decimal, not a float, rounded to 2
    places. Going through str(value) rather than float(value) avoids
    binary floating-point rounding error."""
    if value is None:
        return None
    if isinstance(value, float) and pd.isna(value):
        return None
    return Decimal(str(value)).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


def run(run_date):
    landing_bucket = os.environ["S3_LANDING_BUCKET"]
    processed_bucket = os.environ["S3_PROCESSED_BUCKET"]
    s3_client = boto3.client("s3")

    key = f"source=billing/day={run_date}/billing.parquet"
    df = load_parquet_or_exit(s3_client, landing_bucket, key, "billing", run_date)

    df = df.drop_duplicates(subset="transaction_id").copy()
    df["amount"] = df["amount"].apply(to_decimal)
    df["transaction_date"] = pd.to_datetime(df["transaction_date"]).dt.date
    df["transaction_type"] = df["transaction_type"].astype(str).str.strip().str.title()

    out_buffer = io.BytesIO()
    df.to_parquet(out_buffer, index=False, engine="pyarrow", compression="snappy")
    out_buffer.seek(0)

    out_key = f"billing_transactions/day={run_date}/billing_transactions.parquet"
    s3_client.upload_fileobj(out_buffer, processed_bucket, out_key)
    print(f"billing_transactions: wrote {len(df)} rows to s3://{processed_bucket}/{out_key}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Transform billing data.")
    parser.add_argument("--day", default=str(date.today()), help="Run date, YYYY-MM-DD")
    args = parser.parse_args()
    run(args.day)
