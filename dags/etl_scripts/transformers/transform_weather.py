"""
Reads the validated weather Parquet file from the S3 landing zone,
enforces typing, classifies severity, and writes the result to the
processed zone at the (zip_code, weather_date) grain.

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

from etl_scripts.transformers.s3_helpers import load_parquet_or_exit

load_dotenv()

# WMO weather interpretation codes (Open-Meteo), grouped by how much they
# indicate a weather-driven risk on their own, independent of the raw
# precipitation/wind/temperature thresholds. Codes not listed here (clear,
# mainly clear, cloudy, fog) don't push severity up by themselves.
SEVERE_WMO_CODES = {65, 67, 75, 82, 86, 95, 96, 99}  # heavy rain/snow, violent showers, thunderstorms
MODERATE_WMO_CODES = {45, 48, 51, 53, 55, 56, 57, 61, 63, 66, 71, 73, 77, 80, 81}  # fog, drizzle, light/moderate rain or snow


def classify_severity(row):
    """Derives severity from precipitation, wind, temperature, and the WMO
    weather code together, taking the most severe signal across all four
    rather than any single one in isolation."""
    candidates = []

    if row["max_wind_kmh"] >= 65 or row["precipitation_mm"] >= 40:
        candidates.append("severe")
    elif row["max_wind_kmh"] >= 35 or row["precipitation_mm"] >= 10:
        candidates.append("moderate")
    else:
        candidates.append("calm")

    if row["min_temp_c"] <= -15:
        candidates.append("extreme_cold")

    code = int(row["weather_code"])
    if code in SEVERE_WMO_CODES:
        candidates.append("severe")
    elif code in MODERATE_WMO_CODES:
        candidates.append("moderate")

    for level in ("severe", "extreme_cold", "moderate", "calm"):
        if level in candidates:
            return level
    return "calm"


def run(run_date):
    landing_bucket = os.environ["S3_LANDING_BUCKET"]
    processed_bucket = os.environ["S3_PROCESSED_BUCKET"]
    s3_client = boto3.client("s3")

    key = f"source=weather_api/day={run_date}/weather.parquet"
    df = load_parquet_or_exit(s3_client, landing_bucket, key, "weather", run_date)

    df = df.drop_duplicates(subset=["weather_date", "zip_code"]).copy()
    df["weather_date"] = pd.to_datetime(df["weather_date"]).dt.date
    for col in ["precipitation_mm", "max_wind_kmh", "max_temp_c", "min_temp_c"]:
        df[col] = df[col].astype(float).round(2)
    df["weather_code"] = df["weather_code"].astype(int)
    df["severity"] = df.apply(classify_severity, axis=1)

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
