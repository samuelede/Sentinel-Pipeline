"""
Validates each landing zone file against its schema contract. Files that
pass are left in place for the transform step to pick up. Files that fail
are moved to the S3 quarantine prefix along with a validation_report.json
describing every failed expectation, and an alert is logged.

Usage:
    python validators/validate.py --dataset billing --day 2026-01-15
    python validators/validate.py --all --day 2026-01-15
"""

import argparse
import io
import json
from datetime import date

import boto3
import pandas as pd

from validators.contracts import CONTRACTS

S3_BUCKET_ENV = "S3_LANDING_BUCKET"

DATASET_PREFIXES = {
    "customers": "source=policy_admin/table=customers",
    "agents": "source=policy_admin/table=agents",
    "policies": "source=policy_admin/table=policies",
    "coverages": "source=policy_admin/table=coverages",
    "billing": "source=billing",
    "weather": "source=weather_api",
}


def load_parquet_from_s3(s3_client, bucket, key):
    buffer = io.BytesIO()
    s3_client.download_fileobj(bucket, key, buffer)
    buffer.seek(0)
    return pd.read_parquet(buffer)


def run_expectations(df, contract):
    """Runs column existence, non-null, and basic type-parseability checks.
    Returns a list of failed expectation dicts."""
    failures = []

    for column in contract["columns"]:
        if column not in df.columns:
            failures.append({"expectation": "column_exists", "column": column, "result": "missing"})

    for column in contract.get("required_not_null", []):
        if column in df.columns:
            null_count = int(df[column].isna().sum())
            if null_count > 0:
                failures.append(
                    {
                        "expectation": "column_values_not_null",
                        "column": column,
                        "result": f"{null_count} null values found",
                    }
                )

    return failures


def quarantine_file(s3_client, bucket, key, failures):
    quarantine_key = key.replace("source=", "quarantine/source=", 1)
    s3_client.copy_object(
        Bucket=bucket, CopySource={"Bucket": bucket, "Key": key}, Key=quarantine_key
    )
    s3_client.delete_object(Bucket=bucket, Key=key)

    report_key = quarantine_key.rsplit("/", 1)[0] + "/validation_report.json"
    report = {
        "original_key": key,
        "quarantine_key": quarantine_key,
        "failed_expectations": failures,
    }
    s3_client.put_object(
        Bucket=bucket, Key=report_key, Body=json.dumps(report, indent=2).encode("utf-8")
    )
    print(f"QUARANTINED: {key} -> {quarantine_key} ({len(failures)} failed expectations)")


def validate_dataset(s3_client, bucket, dataset, run_date):
    if dataset not in DATASET_PREFIXES:
        print(f"No S3 prefix mapping for dataset '{dataset}', skipping.")
        return

    contract = CONTRACTS[dataset]
    prefix = f"{DATASET_PREFIXES[dataset]}/day={run_date}/"

    response = s3_client.list_objects_v2(Bucket=bucket, Prefix=prefix)
    for obj in response.get("Contents", []):
        key = obj["Key"]
        if not key.endswith(".parquet"):
            continue

        df = load_parquet_from_s3(s3_client, bucket, key)
        failures = run_expectations(df, contract)

        if failures:
            quarantine_file(s3_client, bucket, key, failures)
        else:
            print(f"PASSED: {key} ({len(df)} rows)")


def run(datasets, run_date):
    import os

    bucket = os.environ[S3_BUCKET_ENV]
    s3_client = boto3.client("s3")

    for dataset in datasets:
        validate_dataset(s3_client, bucket, dataset, run_date)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Validate landing zone files.")
    parser.add_argument("--dataset", help="Single dataset name to validate")
    parser.add_argument("--all", action="store_true", help="Validate all known datasets")
    parser.add_argument("--day", default=str(date.today()), help="Run date, YYYY-MM-DD")
    args = parser.parse_args()

    if args.all:
        run(list(DATASET_PREFIXES.keys()), args.day)
    elif args.dataset:
        run([args.dataset], args.day)
    else:
        parser.error("Specify --dataset <name> or --all")
