"""
Reads validated policy admin Parquet files from the S3 landing zone,
applies type enforcement, deduplication, and canonical casing on
categorical fields, and writes each to the processed zone.

Usage:
    python transformers/transform_policy_admin.py --day 2026-01-15
"""

import argparse
import io
import os
from datetime import date

import boto3
import pandas as pd
from dotenv import load_dotenv

load_dotenv()

TABLES = ["customers", "agents", "policies", "coverages"]

CANONICAL_CASE_COLUMNS = {
    "policies": ["coverage_type", "status"],
    "coverages": ["coverage_code"],
}

DECIMAL_COLUMNS = {
    "policies": ["premium_amount"],
}

DATE_COLUMNS = {
    "customers": ["dob"],
    "agents": ["hire_date"],
    "policies": ["start_date", "end_date"],
}

TIMESTAMP_COLUMNS = {
    "customers": ["created_at"],
    "policies": ["created_at"],
}


def read_landing_parquet(s3_client, bucket, table, run_date):
    key = f"source=policy_admin/table={table}/day={run_date}/{table}.parquet"
    buffer = io.BytesIO()
    s3_client.download_fileobj(bucket, key, buffer)
    buffer.seek(0)
    return pd.read_parquet(buffer)


def transform_table(df, table_name):
    df = df.drop_duplicates()

    for col in CANONICAL_CASE_COLUMNS.get(table_name, []):
        if col in df.columns:
            df[col] = df[col].astype(str).str.strip().str.title()

    for col in DECIMAL_COLUMNS.get(table_name, []):
        if col in df.columns:
            df[col] = df[col].astype(float).round(2)

    for col in DATE_COLUMNS.get(table_name, []):
        if col in df.columns:
            df[col] = pd.to_datetime(df[col]).dt.date

    for col in TIMESTAMP_COLUMNS.get(table_name, []):
        if col in df.columns:
            df[col] = pd.to_datetime(df[col])

    return df


def write_parquet(s3_client, bucket, df, table_name, run_date):
    buffer = io.BytesIO()
    df.to_parquet(buffer, index=False, engine="pyarrow", compression="snappy")
    buffer.seek(0)

    key = f"{table_name}/day={run_date}/{table_name}.parquet"
    s3_client.upload_fileobj(buffer, bucket, key)
    print(f"{table_name}: wrote {len(df)} rows to s3://{bucket}/{key}")


def run(run_date):
    landing_bucket = os.environ["S3_LANDING_BUCKET"]
    processed_bucket = os.environ["S3_PROCESSED_BUCKET"]
    s3_client = boto3.client("s3")

    for table in TABLES:
        df = read_landing_parquet(s3_client, landing_bucket, table, run_date)
        df = transform_table(df, table)
        write_parquet(s3_client, processed_bucket, df, table, run_date)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Transform policy admin tables.")
    parser.add_argument("--day", default=str(date.today()), help="Run date, YYYY-MM-DD")
    args = parser.parse_args()
    run(args.day)
