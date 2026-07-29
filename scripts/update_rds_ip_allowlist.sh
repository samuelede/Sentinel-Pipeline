#!/usr/bin/env bash
#
# Updates the sentinel-policy-admin RDS security group so port 5432 is only
# open to your current public IP. Run this whenever psql or the seed script
# starts timing out, that almost always means your IP changed since the
# rule was last set.
#
# Usage:
#   ./scripts/update_rds_ip_allowlist.sh
#
# Requires the AWS CLI to be configured (see docs/aws_cli_setup.md) and the
# IAM user to have ec2:AuthorizeSecurityGroupIngress and
# ec2:RevokeSecurityGroupIngress permissions.

set -e

DB_INSTANCE_IDENTIFIER="sentinel-policy-admin"
PORT=5432

echo "== Looking up current public IP =="
CURRENT_IP="$(curl -s https://checkip.amazonaws.com)"
if [ -z "$CURRENT_IP" ]; then
  echo "Could not determine current IP. Check your internet connection."
  exit 1
fi
echo "Current IP: $CURRENT_IP"

echo "== Looking up security group for $DB_INSTANCE_IDENTIFIER =="
SG_ID="$(aws rds describe-db-instances \
  --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
  --query "DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId" \
  --output text)"

if [ -z "$SG_ID" ] || [ "$SG_ID" == "None" ]; then
  echo "Could not find a security group for $DB_INSTANCE_IDENTIFIER. Is the instance name correct and is it running?"
  exit 1
fi
echo "Security group: $SG_ID"

echo "== Removing any existing rules for port $PORT =="
EXISTING_CIDRS="$(aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query "SecurityGroups[0].IpPermissions[?ToPort==\`$PORT\`].IpRanges[].CidrIp" \
  --output text)"

for CIDR in $EXISTING_CIDRS; do
  if [ "$CIDR" == "$CURRENT_IP/32" ]; then
    echo "Rule for $CIDR already matches current IP, nothing to do."
    echo "Done."
    exit 0
  fi
  echo "Revoking old rule for $CIDR"
  aws ec2 revoke-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port "$PORT" \
    --cidr "$CIDR" > /dev/null
done

echo "== Authorizing $CURRENT_IP/32 on port $PORT =="
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port "$PORT" \
  --cidr "$CURRENT_IP/32" > /dev/null

echo "Done. Port $PORT is now open only to $CURRENT_IP/32."
