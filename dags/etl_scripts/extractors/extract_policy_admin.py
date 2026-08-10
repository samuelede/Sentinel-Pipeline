"""
Extracts the four policy admin tables from PostgreSQL and writes each as a
Parquet file into the S3 landing zone, partitioned by source system, table,
and ingestion date.

Usage:
    python extractors/extract_policy_admin.py --day 2026-01-15
"""

import argparse
import io
import os
from datetime import date

import boto3
import pandas as pd
import psycopg2
from dotenv import load_dotenv

load_dotenv()

TABLES = ["customers", "agents", "policies", "coverages"]

CONN_PARAMS = {
    "host": os.environ["PG_HOST"],
    "port": os.environ.get("PG_PORT", "5432"),
    "dbname": os.environ.get("PG_DB", "policy_admin"),
    "user": os.environ.get("PG_APP_USER", "sentinel"),
    "password": os.environ.get("PG_APP_PASSWORD"),
    "sslmode": "require",
}

S3_BUCKET = os.environ["S3_LANDING_BUCKET"]


def extract_table(conn, s3_client, table_name, run_date):
    df = pd.read_sql(f"SELECT * FROM {table_name}", conn)

    buffer = io.BytesIO()
    df.to_parquet(buffer, index=False, engine="pyarrow", compression="snappy")
    buffer.seek(0)

    key = f"source=policy_admin/table={table_name}/day={run_date}/{table_name}.parquet"
    s3_client.upload_fileobj(buffer, S3_BUCKET, key)
    print(f"{table_name}: wrote {len(df)} rows to s3://{S3_BUCKET}/{key}")


def run(run_date):
    conn = psycopg2.connect(**CONN_PARAMS)
    s3_client = boto3.client("s3")

    for table in TABLES:
        extract_table(conn, s3_client, table, run_date)

    conn.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Extract policy admin tables to S3.")
    parser.add_argument("--day", default=str(date.today()), help="Run date, YYYY-MM-DD")
    args = parser.parse_args()
    run(args.day)
