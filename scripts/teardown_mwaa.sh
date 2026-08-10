#!/usr/bin/env bash
#
# Tears down everything setup_mwaa.sh created, in the order dependencies
# require (MWAA environment first, since the VPC/subnets/security group
# can't be deleted while it's still attached; NAT Gateway before its
# Elastic IP can be released; VPC last, once everything inside it is
# gone). This is the single biggest cost driver in this whole project,
# run this as soon as you're done testing, don't leave MWAA running
# between sessions the way RDS free tier can be left running longer.
#
# Usage:
#   ./scripts/teardown_mwaa.sh
#
# Requires the same .env used by setup_mwaa.sh (for bucket names).

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

echo "This will permanently delete the MWAA environment, its VPC, NAT Gateway,"
echo "security group, execution role, Secrets Manager secret, and S3 bucket."
read -p "Type 'yes' to continue: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted, nothing was deleted."
  exit 0
fi

# ---- 1. MWAA environment ----
echo "== Deleting MWAA environment (this takes several minutes) =="
if aws mwaa get-environment --name "$MWAA_ENV_NAME" > /dev/null 2>&1; then
  aws mwaa delete-environment --name "$MWAA_ENV_NAME"
  echo "Waiting for the environment to finish deleting..."
  while aws mwaa get-environment --name "$MWAA_ENV_NAME" > /dev/null 2>&1; do
    sleep 15
  done
  echo "MWAA environment deleted."
else
  echo "No MWAA environment named $MWAA_ENV_NAME found, skipping."
fi

# ---- 2. Find the VPC by tag, everything else is looked up from here ----
echo "== Looking up VPC =="
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=${MWAA_ENV_NAME}-vpc" \
  --query "Vpcs[0].VpcId" --output text)

if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
  echo "No VPC found for $MWAA_ENV_NAME, skipping networking teardown."
else
  echo "Found VPC: $VPC_ID"

  # ---- 3. NAT Gateway + its Elastic IP ----
  echo "== Deleting NAT Gateway =="
  NAT_GW_ID=$(aws ec2 describe-nat-gateways \
    --filter "Name=tag:Name,Values=${MWAA_ENV_NAME}-nat" "Name=state,Values=available" \
    --query "NatGateways[0].NatGatewayId" --output text)
  if [ -n "$NAT_GW_ID" ] && [ "$NAT_GW_ID" != "None" ]; then
    EIP_ALLOC_ID=$(aws ec2 describe-nat-gateways --nat-gateway-ids "$NAT_GW_ID" \
      --query "NatGateways[0].NatGatewayAddresses[0].AllocationId" --output text)
    aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_GW_ID" > /dev/null
    echo "Waiting for NAT Gateway to finish deleting..."
    aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$NAT_GW_ID"
    if [ -n "$EIP_ALLOC_ID" ] && [ "$EIP_ALLOC_ID" != "None" ]; then
      aws ec2 release-address --allocation-id "$EIP_ALLOC_ID" || true
    fi
    echo "NAT Gateway and Elastic IP released."
  else
    echo "No NAT Gateway found, skipping."
  fi

  # ---- 4. Security group ----
  echo "== Deleting security group =="
  SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${MWAA_ENV_NAME}-sg" "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[0].GroupId" --output text)
  if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
    aws ec2 delete-security-group --group-id "$SG_ID" || echo "Could not delete security group yet, may need a retry after other resources clear."
  fi

  # ---- 5. Subnets ----
  echo "== Deleting subnets =="
  for SUBNET_ID in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "Subnets[].SubnetId" --output text); do
    aws ec2 delete-subnet --subnet-id "$SUBNET_ID" || echo "Could not delete subnet $SUBNET_ID yet."
  done

  # ---- 6. Route tables (skip the main/default one, it deletes with the VPC) ----
  echo "== Deleting route tables =="
  for RT_ID in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" --output text); do
    aws ec2 delete-route-table --route-table-id "$RT_ID" || echo "Could not delete route table $RT_ID yet."
  done

  # ---- 7. Internet Gateway ----
  echo "== Deleting Internet Gateway =="
  IGW_ID=$(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
    --query "InternetGateways[0].InternetGatewayId" --output text)
  if [ -n "$IGW_ID" ] && [ "$IGW_ID" != "None" ]; then
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID"
  fi

  # ---- 8. VPC itself ----
  echo "== Deleting VPC =="
  aws ec2 delete-vpc --vpc-id "$VPC_ID" || echo "Could not delete VPC yet, some dependent resource may still be attached. Check the AWS Console for what's left."
fi

# ---- 9. Execution role ----
echo "== Deleting execution role =="
if aws iam get-role --role-name "${MWAA_ENV_NAME}-execution-role" > /dev/null 2>&1; then
  aws iam delete-role-policy --role-name "${MWAA_ENV_NAME}-execution-role" \
    --policy-name "${MWAA_ENV_NAME}-execution-policy" || true
  aws iam delete-role --role-name "${MWAA_ENV_NAME}-execution-role"
  echo "Execution role deleted."
else
  echo "No execution role found, skipping."
fi

# ---- 10. Secrets Manager secret ----
echo "== Deleting Secrets Manager secret =="
aws secretsmanager delete-secret --secret-id "sentinel/snowflake" \
  --force-delete-without-recovery > /dev/null 2>&1 || echo "No secret found, skipping."

# ---- 11. MWAA S3 bucket ----
echo "== Emptying and deleting MWAA S3 bucket =="
if aws s3api head-bucket --bucket "$MWAA_BUCKET" > /dev/null 2>&1; then
  aws s3api put-bucket-versioning --bucket "$MWAA_BUCKET" --versioning-configuration Status=Suspended

  # Versioned bucket: a plain `s3 rm --recursive` only removes current
  # versions and leaves old versions + delete markers behind, which
  # blocks `s3 rb`. Purge every version explicitly instead.
  echo "Purging all object versions (this bucket has versioning enabled)..."
  aws s3api list-object-versions --bucket "$MWAA_BUCKET" \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json > ./mwaa_versions.json 2>/dev/null || echo '{"Objects": []}' > ./mwaa_versions.json
  if [ "$(cat ./mwaa_versions.json | grep -c 'Key')" -gt 0 ]; then
    aws s3api delete-objects --bucket "$MWAA_BUCKET" --delete file://./mwaa_versions.json > /dev/null || true
  fi

  aws s3api list-object-versions --bucket "$MWAA_BUCKET" \
    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json > ./mwaa_markers.json 2>/dev/null || echo '{"Objects": []}' > ./mwaa_markers.json
  if [ "$(cat ./mwaa_markers.json | grep -c 'Key')" -gt 0 ]; then
    aws s3api delete-objects --bucket "$MWAA_BUCKET" --delete file://./mwaa_markers.json > /dev/null || true
  fi
  rm -f ./mwaa_versions.json ./mwaa_markers.json

  aws s3 rb "s3://${MWAA_BUCKET}"
  echo "MWAA bucket deleted."
else
  echo "Bucket $MWAA_BUCKET not found, skipping."
fi

echo ""
echo "Done. Verify nothing's left billing:"
echo "  aws mwaa list-environments"
echo "  aws ec2 describe-nat-gateways --filter Name=state,Values=available"
echo "  aws ec2 describe-vpcs"
