#!/usr/bin/env bash
#
# Chains the full local-to-S3 flow for a given run day:
#   1. Pull source CSVs and claims JSON from Google Drive
#   2. Seed the policy admin RDS database from the pulled CSVs
#   3. Run all four extractors, which write to the S3 landing zone
#
# Usage:
#   ./scripts/sync_source_to_s3.sh 2026-01-15
#
# Assumes the venv is already activated and .env is populated.

set -e

RUN_DATE="${1:?Usage: ./scripts/sync_source_to_s3.sh YYYY-MM-DD}"

echo "== Step 1: Pulling source data from Google Drive =="
python scripts/pull_source_data.py

echo "== Step 2: Seeding policy admin database =="
python scripts/seed_policy_admin_db.py

echo "== Step 3: Running extractors for day=$RUN_DATE =="
python extractors/extract_policy_admin.py --day "$RUN_DATE"
python extractors/extract_claims.py
python extractors/extract_billing.py
python extractors/extract_weather.py --day "$RUN_DATE"

echo "== Done. Verify with: aws s3 ls s3://\$S3_LANDING_BUCKET --recursive =="
