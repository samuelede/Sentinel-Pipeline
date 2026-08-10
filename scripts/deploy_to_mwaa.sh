#!/usr/bin/env bash
#
# Syncs the DAG and etl_scripts package to s3://<mwaa-bucket>/dags/, and
# requirements.txt to the bucket root. MWAA polls the dags/ prefix on
# its own (new/changed .py files show up within a few minutes, no
# action needed here), but a changed requirements.txt needs an explicit
# environment update pointing at the new object version, or MWAA keeps
# using whatever it already installed.
#
# Usage:
#   ./scripts/deploy_to_mwaa.sh

set -e

if [ ! -f .env ]; then
  echo "No .env file found."
  exit 1
fi
set -a
source .env
set +a

MWAA_ENV_NAME="sentinel-mwaa"
MWAA_BUCKET="${MWAA_BUCKET_NAME:-sentinel-mwaa-dags}"

if [ ! -d "dags/etl_scripts" ]; then
  echo "dags/etl_scripts/ not found. Run scripts/migrate_to_etl_scripts.py first,"
  echo "the DAG's imports depend on this layout existing before it'll deploy correctly."
  exit 1
fi

echo "== Syncing dags/ (including etl_scripts/) to s3://${MWAA_BUCKET}/dags/ =="
aws s3 sync ./dags "s3://${MWAA_BUCKET}/dags/" \
  --exclude "*.pyc" --exclude "__pycache__/*" --delete

echo ""
echo "== Uploading requirements.txt =="
# --constraint is required by MWAA for Airflow v2.7.2+, see
# https://docs.aws.amazon.com/mwaa/latest/userguide/best-practices-dependencies.html
# if requirements.txt doesn't already have one, the environment update
# below will fail with a clear error naming the required constraints URL.
UPLOAD_RESULT=$(aws s3api put-object --bucket "$MWAA_BUCKET" --key "requirements.txt" \
  --body ./requirements.txt --output json)
NEW_VERSION=$(echo "$UPLOAD_RESULT" | python -c "import sys, json; print(json.load(sys.stdin)['VersionId'])")
echo "Uploaded requirements.txt, version: $NEW_VERSION"

echo ""
echo "== Updating MWAA environment to use the new requirements.txt version =="
aws mwaa update-environment \
  --name "$MWAA_ENV_NAME" \
  --requirements-s3-path "requirements.txt" \
  --requirements-s3-object-version "$NEW_VERSION" > /dev/null

echo ""
echo "Deployed. DAG changes show up in the Airflow UI within a few minutes."
echo "The requirements.txt update takes longer, MWAA restarts workers to apply it,"
echo "check progress with:"
echo "  aws mwaa get-environment --name $MWAA_ENV_NAME --query 'Environment.Status'"
