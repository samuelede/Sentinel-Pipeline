"""
Calls the Open-Meteo Archive API for each zip code in scope and writes a
combined Parquet file of the trailing 7-day window to the S3 landing zone.
The trailing window re-refreshes recent days to account for late-arriving
claims that reference a recent incident date.

Usage:
    python extractors/extract_weather.py --day 2026-01-15
"""

import argparse
import io
import os
from datetime import date, timedelta

import boto3
import pandas as pd
import requests
from dotenv import load_dotenv

load_dotenv()

# Zip code -> approximate lat/lon centroid used for the Open-Meteo query.
ZIP_COORDINATES = {
    "43215": {"latitude": 39.9622, "longitude": -83.0007},   # Columbus, OH
    "46201": {"latitude": 39.7773, "longitude": -86.1310},   # Indianapolis, IN
    "60601": {"latitude": 41.8858, "longitude": -87.6229},   # Chicago, IL
}

BASE_URL = os.environ.get(
    "OPEN_METEO_BASE_URL", "https://archive-api.open-meteo.com/v1/archive"
)
S3_BUCKET = os.environ["S3_LANDING_BUCKET"]

DAILY_FIELDS = [
    "precipitation_sum",
    "windgusts_10m_max",
    "temperature_2m_max",
    "temperature_2m_min",
    "weathercode",
]


def classify_severity(row):
    if row["max_wind_kmh"] >= 65 or row["precipitation_mm"] >= 40:
        return "severe"
    if row["min_temp_c"] <= -15:
        return "extreme_cold"
    if row["max_wind_kmh"] >= 35 or row["precipitation_mm"] >= 10:
        return "moderate"
    return "calm"


def fetch_zip_weather(zip_code, start_date, end_date):
    coords = ZIP_COORDINATES[zip_code]
    params = {
        "latitude": coords["latitude"],
        "longitude": coords["longitude"],
        "start_date": str(start_date),
        "end_date": str(end_date),
        "daily": ",".join(DAILY_FIELDS),
        "timezone": "America/New_York",
    }
    response = requests.get(BASE_URL, params=params, timeout=30)
    response.raise_for_status()
    payload = response.json()["daily"]

    df = pd.DataFrame(
        {
            "weather_date": pd.to_datetime(payload["time"]).date,
            "zip_code": zip_code,
            "precipitation_mm": payload["precipitation_sum"],
            "max_wind_kmh": payload["windgusts_10m_max"],
            "max_temp_c": payload["temperature_2m_max"],
            "min_temp_c": payload["temperature_2m_min"],
            "weather_code": payload["weathercode"],
        }
    )
    df["severity"] = df.apply(classify_severity, axis=1)
    return df


def run(run_date):
    end_date = date.fromisoformat(run_date)
    start_date = end_date - timedelta(days=6)

    zip_codes = os.environ.get("WEATHER_ZIP_CODES", "").split(",")
    zip_codes = [z.strip() for z in zip_codes if z.strip()] or list(ZIP_COORDINATES)

    frames = [fetch_zip_weather(z, start_date, end_date) for z in zip_codes]
    combined = pd.concat(frames, ignore_index=True)

    buffer = io.BytesIO()
    combined.to_parquet(buffer, index=False, engine="pyarrow", compression="snappy")
    buffer.seek(0)

    s3_client = boto3.client("s3")
    key = f"source=weather_api/day={run_date}/weather.parquet"
    s3_client.upload_fileobj(buffer, S3_BUCKET, key)
    print(f"Wrote {len(combined)} rows across {len(zip_codes)} zip codes to s3://{S3_BUCKET}/{key}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Extract weather data to S3.")
    parser.add_argument("--day", default=str(date.today()), help="Run date, YYYY-MM-DD")
    args = parser.parse_args()
    run(args.day)
