"""
Reads validated claim JSON files from the S3 landing zone, flattens the
nested events array, and writes two outputs to the processed zone:

  - claims_fact: one row per claim (event history removed)
  - payments: one row per Payment_Issued event, linked back via claim_id

Usage:
    python transformers/transform_claims.py --day 2026-01-15
"""

import argparse
import io
import json
from datetime import date
from decimal import Decimal

import boto3
import pandas as pd
from dotenv import load_dotenv

load_dotenv()


def load_claim_files(s3_client, bucket, run_date):
    prefix = f"source=claims_mgmt/day={run_date}/"
    response = s3_client.list_objects_v2(Bucket=bucket, Prefix=prefix)

    claims = []
    for obj in response.get("Contents", []):
        key = obj["Key"]
        if not key.endswith(".json"):
            continue
        body = s3_client.get_object(Bucket=bucket, Key=key)["Body"].read()
        claims.append(json.loads(body))
    return claims


def flatten_claims(claims):
    claim_rows = []
    payment_rows = []

    for claim in claims:
        events = claim.get("events", [])

        claim_rows.append(
            {
                "claim_id": claim["claim_id"],
                "policy_id": claim["policy_id"],
                "customer_id": claim["customer_id"],
                "incident_date": claim["incident_date"],
                "report_date": claim["report_date"],
                "incident_zip": claim["incident_location"]["zip"],
                "incident_type": claim["incident_type"],
                "claim_status": claim["status"],
                "claim_amount": Decimal(str(claim["claim_amount"])),
                "approved_amount": (
                    Decimal(str(claim["approved_amount"]))
                    if claim.get("approved_amount") is not None
                    else None
                ),
                "description": claim.get("description", ""),
                "created_at": claim["created_at"],
            }
        )

        payment_sequence = 0
        for event in events:
            if event.get("event_type") == "Payment_Issued":
                payment_sequence += 1
                # The source has no natural payment_id, synthesize a stable
                # one from the claim_id and a per-claim sequence number.
                payment_id = f"{claim['claim_id']}-PMT-{payment_sequence:02d}"
                payment_rows.append(
                    {
                        "payment_id": payment_id,
                        "claim_id": claim["claim_id"],
                        "payment_date": event["timestamp"],
                        "payment_amount": Decimal(str(event["payment_amount"])),
                        "payment_type": event["payment_type"],
                        "adjuster_id": event.get("adjuster_id"),
                    }
                )

    claims_df = pd.DataFrame(claim_rows)
    payments_df = pd.DataFrame(payment_rows)

    if not claims_df.empty:
        claims_df["incident_date"] = pd.to_datetime(claims_df["incident_date"]).dt.date
        claims_df["report_date"] = pd.to_datetime(claims_df["report_date"]).dt.date
        claims_df["created_at"] = pd.to_datetime(claims_df["created_at"])

    if not payments_df.empty:
        payments_df["payment_date"] = pd.to_datetime(payments_df["payment_date"]).dt.date

    return claims_df, payments_df


def write_parquet(s3_client, bucket, df, entity_name, run_date):
    buffer = io.BytesIO()
    df.to_parquet(buffer, index=False, engine="pyarrow", compression="snappy")
    buffer.seek(0)

    key = f"{entity_name}/day={run_date}/{entity_name}.parquet"
    s3_client.upload_fileobj(buffer, bucket, key)
    print(f"{entity_name}: wrote {len(df)} rows to s3://{bucket}/{key}")


def run(run_date):
    import os

    landing_bucket = os.environ["S3_LANDING_BUCKET"]
    processed_bucket = os.environ["S3_PROCESSED_BUCKET"]
    s3_client = boto3.client("s3")

    claims = load_claim_files(s3_client, landing_bucket, run_date)
    if not claims:
        print(f"No claim files found for day={run_date}")
        return

    claims_df, payments_df = flatten_claims(claims)
    claims_df = claims_df.drop_duplicates(subset="claim_id")
    payments_df = payments_df.drop_duplicates(subset="payment_id")

    write_parquet(s3_client, processed_bucket, claims_df, "claims_fact", run_date)
    write_parquet(s3_client, processed_bucket, payments_df, "payments", run_date)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Transform claim JSON into claims_fact and payments.")
    parser.add_argument("--day", default=str(date.today()), help="Run date, YYYY-MM-DD")
    args = parser.parse_args()
    run(args.day)
