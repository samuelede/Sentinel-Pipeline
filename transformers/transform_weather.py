"""
Reads the validated weather Parquet file from the S3 landing zone,
enforces typing, and writes the result to the processed zone at the
(zip_code, weather_date) grain.

Usage:
    python transformers/transform_weather.py --day 2026-01-15
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

    key = f"source=weather_api/day={run_date}/weather.parquet"
    buffer = io.BytesIO()
    s3_client.download_fileobj(landing_bucket, key, buffer)
    buffer.seek(0)
    df = pd.read_parquet(buffer)

    df = df.drop_duplicates(subset=["weather_date", "zip_code"])
    df["weather_date"] = pd.to_datetime(df["weather_date"]).dt.date
    for col in ["precipitation_mm", "max_wind_kmh", "max_temp_c", "min_temp_c"]:
        df[col] = df[col].astype(float).round(2)
    df["weather_code"] = df["weather_code"].astype(int)

    out_buffer = io.BytesIO()
    df.to_parquet(out_buffer, index=False, engine="pyarrow", compression="snappy")
    out_buffer.seek(0)

    out_key = f"weather_daily/day={run_date}/weather.parquet"
    s3_client.upload_fileobj(out_buffer, processed_bucket, out_key)
    print(f"weather_daily: wrote {len(df)} rows to s3://{processed_bucket}/{out_key}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Transform weather data.")
    parser.add_argument("--day", default=str(date.today()), help="Run date, YYYY-MM-DD")
    args = parser.parse_args()
    run(args.day)
