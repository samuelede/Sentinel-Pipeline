"""
Pulls source data from the shared Google Drive folders into the local
source_systems/ directory, matching the layout the rest of the pipeline
expects.

Two folders are pulled:
  - policy_admin: customers.csv, agents.csv, policies.csv, coverages.csv,
    and billing.csv
  - claims: the day=YYYY-MM-DD partitioned claim JSON files

Usage:
    python scripts/pull_source_data.py                 # pull both
    python scripts/pull_source_data.py --only policy_admin
    python scripts/pull_source_data.py --only claims
"""

import argparse
import os
import shutil
from pathlib import Path

import gdown
from dotenv import load_dotenv

load_dotenv()

# Folder IDs from the shared Drive links.
DRIVE_FOLDERS = {
    "policy_admin": "1HI_GLBvD1MI6jmPNpYJsApxe7K2jlMLs",
    "claims": "1G_157kyy57n8KN5zrdLXSXCrnu7INSUV",
}

SOURCE_DIR = Path(os.environ.get("SOURCE_SYSTEMS_DIR", "./source_systems"))

EXPECTED_POLICY_ADMIN_FILES = [
    "customers.csv",
    "agents.csv",
    "policies.csv",
    "coverages.csv",
    "billing.csv",
]


def download_folder(folder_id, destination):
    """Downloads a Drive folder's contents into destination, flattening any
    nesting Drive introduces so the pipeline sees a predictable structure."""
    destination.mkdir(parents=True, exist_ok=True)
    gdown.download_folder(
        id=folder_id,
        output=str(destination),
        quiet=False,
        use_cookies=False,
    )


def flatten_policy_admin(destination):
    """gdown preserves the Drive folder's internal structure. Walk the
    download and move the expected CSVs up to the top level of
    source_systems/ if they landed in a subfolder."""
    for expected_file in EXPECTED_POLICY_ADMIN_FILES:
        target_path = destination / expected_file
        if target_path.exists():
            continue

        matches = list(destination.rglob(expected_file))
        if matches:
            shutil.move(str(matches[0]), str(target_path))
            print(f"Moved {matches[0]} -> {target_path}")
        else:
            print(f"WARNING: {expected_file} not found anywhere under {destination}")


def flatten_claims(destination):
    """Claims JSON files are expected under day=YYYY-MM-DD partitions. Drive's
    quarter-folder naming is inconsistent, so this only confirms at least one
    day= folder exists rather than trying to normalize quarter names."""
    day_folders = list(destination.rglob("day=*"))
    if not day_folders:
        print(f"WARNING: no day=YYYY-MM-DD folders found under {destination}")
    else:
        print(f"Found {len(day_folders)} day=YYYY-MM-DD partitions under {destination}")


def pull_policy_admin():
    destination = SOURCE_DIR
    print(f"Pulling policy admin + billing source data into {destination} ...")
    download_folder(DRIVE_FOLDERS["policy_admin"], destination)
    flatten_policy_admin(destination)


def pull_claims():
    destination = SOURCE_DIR / "claims"
    print(f"Pulling claims JSON source data into {destination} ...")
    download_folder(DRIVE_FOLDERS["claims"], destination)
    flatten_claims(destination)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Pull source data from Google Drive.")
    parser.add_argument(
        "--only",
        choices=["policy_admin", "claims"],
        help="Pull only one source instead of both.",
    )
    args = parser.parse_args()

    if args.only == "policy_admin":
        pull_policy_admin()
    elif args.only == "claims":
        pull_claims()
    else:
        pull_policy_admin()
        pull_claims()

    print("Done. Verify file layout with: ls -R source_systems/")
