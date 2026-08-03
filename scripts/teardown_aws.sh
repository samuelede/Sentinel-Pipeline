#!/usr/bin/env bash
#
# Tears down Sentinel's AWS footprint: RDS instance, S3 buckets, and the
# RDS security group. Safe to run anytime you're stepping away from
# active development, everything here is reproducible from
# docs/aws_setup.md and docs/policy_admin_db_setup.md.
#
# Usage:
#   ./scripts/teardown_aws.sh
#
# Requires the AWS CLI configured (see docs/aws_cli_setup.md).

set -e

DB_INSTANCE_IDENTIFIER="sentinel-policy-admin"
SG_NAME="sentinel-policy-admin-sg"
LANDING_BUCKET="${S3_LANDING_BUCKET:-sentinel-landing}"
PROCESSED_BUCKET="${S3_PROCESSED_BUCKET:-sentinel-processed}"

echo "This will permanently delete:"
echo "  - RDS instance: $DB_INSTANCE_IDENTIFIER (no final snapshot)"
echo "  - S3 bucket contents and buckets: $LANDING_BUCKET, $PROCESSED_BUCKET"
echo "  - Security group: $SG_NAME"
echo ""
read -p "Type 'yes' to continue: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted, nothing was deleted."
  exit 0
fi

echo ""
echo "== Deleting RDS instance =="
if aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" > /dev/null 2>&1; then
  aws rds delete-db-instance \
    --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
    --skip-final-snapshot \
    --delete-automated-backups
  echo "Waiting for deletion to complete (this takes a few minutes)..."
  aws rds wait db-instance-deleted --db-instance-identifier "$DB_INSTANCE_IDENTIFIER"
  echo "RDS instance deleted."
else
  echo "No RDS instance named $DB_INSTANCE_IDENTIFIER found, skipping."
fi

echo ""
echo "== Emptying and deleting S3 buckets =="
for BUCKET in "$LANDING_BUCKET" "$PROCESSED_BUCKET"; do
  if aws s3api head-bucket --bucket "$BUCKET" > /dev/null 2>&1; then
    aws s3 rm "s3://$BUCKET" --recursive
    aws s3 rb "s3://$BUCKET"
    echo "$BUCKET deleted."
  else
    echo "Bucket $BUCKET not found, skipping."
  fi
done

echo ""
echo "== Deleting RDS security group =="
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" \
  --query "SecurityGroups[0].GroupId" \
  --output text 2>/dev/null || true)

if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
  aws ec2 delete-security-group --group-id "$SG_ID"
  echo "Security group $SG_ID ($SG_NAME) deleted."
else
  echo "No security group named $SG_NAME found, skipping."
fi

echo ""
echo "== Verifying =="
echo "RDS instances remaining:"
aws rds describe-db-instances --query "DBInstances[].DBInstanceIdentifier" --output text
echo "S3 buckets remaining:"
aws s3 ls

echo ""
echo "Done. See docs/aws_teardown.md for re-setup steps when you pick this back up."
