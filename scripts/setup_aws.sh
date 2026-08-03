#!/usr/bin/env bash
#
# Provisions Sentinel's AWS footprint from .env: the two S3 buckets, the
# RDS PostgreSQL instance (with a dedicated security group locked to your
# current IP), and bootstraps the app role/database on it. Mirrors
# teardown_aws.sh, run this to bring everything back up, run that to
# tear it back down.
#
# Requires .env to already have these filled in BEFORE running:
#   S3_LANDING_BUCKET, S3_PROCESSED_BUCKET
#   PG_MASTER_USER, PG_MASTER_PASSWORD   (you invent these yourself)
#   PG_APP_USER, PG_APP_PASSWORD         (you invent these yourself)
#   PG_DB
#
# PG_HOST does NOT need to be filled in beforehand, it doesn't exist
# until RDS creates it. This script writes it into .env automatically
# once the instance is available.
#
# Usage:
#   ./scripts/setup_aws.sh
#
# Requires the AWS CLI configured (see docs/aws_cli_setup.md). Safe to
# re-run: existing buckets/instances are detected and skipped rather
# than recreated.

set -e

DB_INSTANCE_ID="sentinel-policy-admin"
SG_NAME="sentinel-policy-admin-sg"
DB_PORT=5432

if [ ! -f .env ]; then
  echo "No .env file found. Run 'cp .env.example .env' and fill in the required values first."
  echo "See docs/SETUP_CHECKLIST.md for exactly what's needed."
  exit 1
fi

set -a
source .env
set +a

REQUIRED_VARS=(S3_LANDING_BUCKET S3_PROCESSED_BUCKET PG_MASTER_USER PG_MASTER_PASSWORD PG_APP_USER PG_APP_PASSWORD PG_DB)
MISSING=()
for VAR in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!VAR:-}" ]; then
    MISSING+=("$VAR")
  fi
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "These required variables are missing or empty in .env:"
  for VAR in "${MISSING[@]}"; do
    echo "  - $VAR"
  done
  echo "Fill them in first, see docs/SETUP_CHECKLIST.md."
  exit 1
fi

REGION=$(aws configure get region)
if [ -z "$REGION" ]; then
  echo "No default region set. Run 'aws configure' first (see docs/aws_cli_setup.md)."
  exit 1
fi
echo "Using region: $REGION"
echo ""

# ---- S3 buckets ----
echo "== Creating S3 buckets =="
for BUCKET in "$S3_LANDING_BUCKET" "$S3_PROCESSED_BUCKET"; do
  if aws s3api head-bucket --bucket "$BUCKET" > /dev/null 2>&1; then
    echo "$BUCKET already exists, skipping."
  else
    if [ "$REGION" == "us-east-1" ]; then
      aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
    else
      aws s3api create-bucket \
        --bucket "$BUCKET" \
        --region "$REGION" \
        --create-bucket-configuration LocationConstraint="$REGION"
    fi
    echo "$BUCKET created."
  fi
done
echo ""

# ---- RDS instance ----
echo "== Provisioning RDS instance =="
if aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" > /dev/null 2>&1; then
  echo "RDS instance $DB_INSTANCE_ID already exists, skipping creation."
else
  echo "Looking up default VPC..."
  DEFAULT_VPC_ID=$(aws ec2 describe-vpcs \
    --filters Name=isDefault,Values=true \
    --query "Vpcs[0].VpcId" \
    --output text)

  if [ -z "$DEFAULT_VPC_ID" ] || [ "$DEFAULT_VPC_ID" == "None" ]; then
    echo "No default VPC found in this region. This script assumes one exists (AWS creates one per region by default). Manual VPC setup is outside this script's scope."
    exit 1
  fi

  echo "Creating security group $SG_NAME in $DEFAULT_VPC_ID..."
  SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "Sentinel RDS access, restricted to developer IPs" \
    --vpc-id "$DEFAULT_VPC_ID" \
    --query "GroupId" \
    --output text)

  CURRENT_IP=$(curl -s https://checkip.amazonaws.com)
  echo "Authorizing your current IP ($CURRENT_IP) on port $DB_PORT..."
  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port "$DB_PORT" \
    --cidr "$CURRENT_IP/32" > /dev/null

  echo "Creating RDS instance $DB_INSTANCE_ID (db.t4g.micro, PostgreSQL, free-tier eligible)..."
  echo "If db.t4g.micro isn't available in $REGION, edit --db-instance-class to db.t3.micro and re-run."
  aws rds create-db-instance \
    --db-instance-identifier "$DB_INSTANCE_ID" \
    --db-instance-class db.t4g.micro \
    --engine postgres \
    --master-username "$PG_MASTER_USER" \
    --master-user-password "$PG_MASTER_PASSWORD" \
    --allocated-storage 20 \
    --publicly-accessible \
    --vpc-security-group-ids "$SG_ID" \
    --backup-retention-period 1 \
    --no-multi-az > /dev/null

  echo "Waiting for the instance to become available, this takes several minutes..."
  aws rds wait db-instance-available --db-instance-identifier "$DB_INSTANCE_ID"
  echo "RDS instance is available."
fi
echo ""

# ---- Update .env with the real endpoint ----
echo "== Updating .env with the RDS endpoint =="
ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --query "DBInstances[0].Endpoint.Address" \
  --output text)

if grep -q "^PG_HOST=" .env; then
  sed -i "s|^PG_HOST=.*|PG_HOST=$ENDPOINT|" .env
else
  echo "PG_HOST=$ENDPOINT" >> .env
fi
echo "PG_HOST set to $ENDPOINT"
echo ""

# ---- Bootstrap the app role and database ----
echo "== Bootstrapping the sentinel role and policy_admin database =="
python scripts/seed_policy_admin_db.py --bootstrap
echo ""

echo "Done. Next steps:"
echo "  1. Run ./scripts/preflight_check.sh to confirm everything actually connects"
echo "  2. Run ./scripts/pull_source_data.py (or the manual option) to get source CSVs and claims JSON"
echo "  3. Run python scripts/seed_policy_admin_db.py to load the CSVs"
echo "  4. Continue with README.md Setup steps 6 onward"
