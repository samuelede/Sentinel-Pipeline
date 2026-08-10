"""
Uploads claim JSON files to the S3 landing zone, preserving the
day=YYYY-MM-DD partition structure. Idempotent: files already present in
S3 are skipped.

The quarter folders on the source drive use inconsistent naming, so this
script discovers files by globbing for day=YYYY-MM-DD subfolders rather
than computing expected folder names from a date range.

Usage:
    python extractors/extract_claims.py
"""

import os
from collections import defaultdict
from pathlib import Path

import boto3
from dotenv import load_dotenv

load_dotenv()

SOURCE_DIR = Path(os.environ.get("SOURCE_SYSTEMS_DIR", "./source_systems")) / "sftp_claim_source"
S3_BUCKET = os.environ["S3_LANDING_BUCKET"]


def find_day_partitions(source_dir):
    """Glob for day=YYYY-MM-DD folders anywhere under source_dir, regardless
    of inconsistent quarter-folder naming above them."""
    return sorted(source_dir.glob("**/day=*"))


def object_exists(s3_client, bucket, key):
    try:
        s3_client.head_object(Bucket=bucket, Key=key)
        return True
    except s3_client.exceptions.ClientError:
        return False


def run():
    s3_client = boto3.client("s3")
    day_folders = find_day_partitions(SOURCE_DIR)

    if not day_folders:
        print(f"No day=YYYY-MM-DD folders found under {SOURCE_DIR}")
        return

    uploaded_per_day = defaultdict(int)
    skipped_per_day = defaultdict(int)

    for day_folder in day_folders:
        day = day_folder.name.split("=", 1)[1]
        for json_file in day_folder.glob("*.json"):
            key = f"source=claims_mgmt/day={day}/{json_file.name}"

            if object_exists(s3_client, S3_BUCKET, key):
                skipped_per_day[day] += 1
                continue

            s3_client.upload_file(str(json_file), S3_BUCKET, key)
            uploaded_per_day[day] += 1

    print("Upload summary:")
    for day in sorted(set(list(uploaded_per_day) + list(skipped_per_day))):
        print(
            f"  {day}: uploaded {uploaded_per_day.get(day, 0)}, "
            f"skipped (already present) {skipped_per_day.get(day, 0)}"
        )


if __name__ == "__main__":
    run()