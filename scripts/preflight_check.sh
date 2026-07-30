#!/usr/bin/env bash
#
# Single entry point: checks every setup dependency (AWS CLI, S3, RDS,
# Snowflake) actually works, prints a clear PASS/FAIL per item, and
# refuses to continue if anything critical is broken. Run this before
# ./scripts/sync_source_to_s3.sh or any manual pipeline step.
#
# Usage:
#   ./scripts/preflight_check.sh
#
# Exit code 0 means everything passed. Non-zero means at least one check
# failed, read the FAIL lines above the summary for what to fix and
# which doc covers it.

set -u  # error on unset variables, but don't exit early on command failures,
        # we want to run every check and report all failures at once

PASS_COUNT=0
FAIL_COUNT=0
FAILURES=()

pass() {
  echo "  PASS: $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "  FAIL: $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILURES+=("$1 -- see $2")
}

echo "=== Sentinel Pipeline Preflight Check ==="
echo ""

# ---- .env exists and has no leftover placeholder values ----
echo "-- .env configuration --"
if [ -f .env ]; then
  pass ".env file exists"

  # Source it in a subshell so we don't pollute this script's environment
  # with whatever's in there.
  ENV_VARS=$(bash -c 'set -a; source .env 2>/dev/null; set +a; env' 2>/dev/null)

  PLACEHOLDER_PATTERNS="your_master_user|your_master_password|choose_your_own_password|your_app_password"
  if echo "$ENV_VARS" | grep -qE "$PLACEHOLDER_PATTERNS"; then
    fail ".env still contains placeholder values (e.g. your_master_user)" "docs/policy_admin_db_setup.md"
  else
    pass ".env has no obvious leftover placeholder values"
  fi

  if echo "$ENV_VARS" | grep -qE "^AWS_ACCESS_KEY_ID=your_access_key$|^AWS_SECRET_ACCESS_KEY=your_secret_key$"; then
    fail "AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY are still placeholder text in .env, this overrides your real ~/.aws/credentials and breaks every AWS call" "docs/aws_cli_setup.md"
  fi
else
  fail ".env file not found (copy .env.example to .env and fill in real values)" "README.md Setup step 4"
fi
echo ""

# ---- AWS CLI ----
echo "-- AWS CLI --"
if command -v aws > /dev/null 2>&1; then
  pass "aws CLI is installed"

  if IDENTITY=$(aws sts get-caller-identity 2>&1); then
    pass "AWS credentials work ($(echo "$IDENTITY" | grep -o '"Account": "[0-9]*"'))"
  else
    fail "aws sts get-caller-identity failed: $IDENTITY" "docs/aws_cli_setup.md"
  fi
else
  fail "aws CLI not found on PATH" "docs/aws_cli_setup.md"
fi
echo ""

# ---- S3 buckets ----
echo "-- S3 buckets --"
if [ -f .env ]; then
  LANDING_BUCKET=$(grep -E "^S3_LANDING_BUCKET=" .env | cut -d= -f2)
  PROCESSED_BUCKET=$(grep -E "^S3_PROCESSED_BUCKET=" .env | cut -d= -f2)

  for BUCKET in "$LANDING_BUCKET" "$PROCESSED_BUCKET"; do
    if [ -z "$BUCKET" ]; then
      fail "bucket name not set in .env" "docs/aws_setup.md"
      continue
    fi
    if aws s3api head-bucket --bucket "$BUCKET" > /dev/null 2>&1; then
      pass "bucket $BUCKET exists and is reachable"
    else
      fail "bucket $BUCKET does not exist or is not reachable" "docs/aws_setup.md"
    fi
  done
else
  fail "cannot check S3 buckets without .env" "docs/aws_setup.md"
fi
echo ""

# ---- RDS instance ----
echo "-- RDS instance --"
if ! command -v aws > /dev/null 2>&1; then
  fail "cannot check RDS, aws CLI not available (see AWS CLI check above)" "docs/aws_cli_setup.md"
elif [ -f .env ]; then
  PG_HOST=$(grep -E "^PG_HOST=" .env | cut -d= -f2)
  DB_INSTANCE_ID="sentinel-policy-admin"

  STATUS=$(aws rds describe-db-instances \
    --db-instance-identifier "$DB_INSTANCE_ID" \
    --query "DBInstances[0].DBInstanceStatus" \
    --output text 2>&1)

  if [ "$STATUS" == "available" ]; then
    pass "RDS instance $DB_INSTANCE_ID is available"
  else
    fail "RDS instance $DB_INSTANCE_ID status: $STATUS" "docs/policy_admin_db_setup.md"
  fi

  if [ -n "${PG_HOST:-}" ] && command -v psql > /dev/null 2>&1; then
    PG_PORT=$(grep -E "^PG_PORT=" .env | cut -d= -f2)
    PG_APP_USER=$(grep -E "^PG_APP_USER=" .env | cut -d= -f2)
    PG_APP_PASSWORD=$(grep -E "^PG_APP_PASSWORD=" .env | cut -d= -f2)
    PG_DB=$(grep -E "^PG_DB=" .env | cut -d= -f2)

    if PGPASSWORD="$PG_APP_PASSWORD" psql "host=$PG_HOST port=${PG_PORT:-5432} dbname=${PG_DB:-policy_admin} user=$PG_APP_USER sslmode=require" -c "SELECT 1;" > /dev/null 2>&1; then
      pass "Postgres connection works with app credentials"
    else
      fail "Could not connect to Postgres with current .env credentials (check IP allowlist: ./scripts/update_rds_ip_allowlist.sh)" "docs/policy_admin_db_setup.md"
    fi
  fi
else
  fail "cannot check RDS without .env" "docs/policy_admin_db_setup.md"
fi
echo ""

# ---- Snowflake ----
echo "-- Snowflake --"
if command -v snowsql > /dev/null 2>&1; then
  pass "snowsql is installed"

  if [ -f ~/.snowsql/config ]; then
    pass "~/.snowsql/config exists"

    if grep -qE "accountname\s*=\s*.*snowflakecomputing\.com" ~/.snowsql/config; then
      fail "accountname in ~/.snowsql/config includes .snowflakecomputing.com, it should be just the identifier" "docs/snowflake_setup.md"
    fi

    CONN_NAME=$(sed -n 's/^\[connections\.\(.*\)\]/\1/p' ~/.snowsql/config | head -1)
    if [ -n "$CONN_NAME" ]; then
      if SF_RESULT=$(snowsql -c "$CONN_NAME" -q "SELECT CURRENT_VERSION();" 2>&1); then
        if echo "$SF_RESULT" | grep -q "SQL compilation error\|Failed to connect\|Could not connect"; then
          fail "snowsql connection test failed: $(echo "$SF_RESULT" | head -3 | tr '\n' ' ')" "docs/snowflake_setup.md"
        else
          pass "snowsql connects successfully using connection '$CONN_NAME'"
        fi
      else
        fail "snowsql connection test failed to run" "docs/snowflake_setup.md"
      fi

      if WH_CHECK=$(snowsql -c "$CONN_NAME" -q "SHOW WAREHOUSES LIKE 'SENTINEL_WH';" 2>&1) && echo "$WH_CHECK" | grep -qi "SENTINEL_WH"; then
        pass "SENTINEL_WH warehouse exists"
      else
        fail "SENTINEL_WH warehouse not found" "sql/ddl/create_warehouse_and_database.sql via docs/snowflake_setup.md"
      fi

      if DB_CHECK=$(snowsql -c "$CONN_NAME" -q "SHOW DATABASES LIKE 'SENTINEL_DB';" 2>&1) && echo "$DB_CHECK" | grep -qi "SENTINEL_DB"; then
        pass "SENTINEL_DB database exists"
      else
        fail "SENTINEL_DB database not found" "sql/ddl/create_warehouse_and_database.sql via docs/snowflake_setup.md"
      fi
    else
      fail "no named connection found in ~/.snowsql/config" "docs/snowflake_setup.md"
    fi
  else
    fail "~/.snowsql/config not found" "docs/snowflake_setup.md"
  fi
else
  fail "snowsql not found on PATH" "docs/snowflake_setup.md"
fi
echo ""

# ---- Summary ----
echo "=== Summary ==="
echo "Passed: $PASS_COUNT   Failed: $FAIL_COUNT"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "Fix these before running the pipeline:"
  for F in "${FAILURES[@]}"; do
    echo "  - $F"
  done
  exit 1
fi

echo "Everything checks out. Safe to run the pipeline:"
echo "  ./scripts/sync_source_to_s3.sh <YYYY-MM-DD>"
exit 0
