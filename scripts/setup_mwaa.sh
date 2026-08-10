#!/usr/bin/env bash
#
# Provisions the AWS infrastructure Amazon MWAA needs: a dedicated VPC
# with 2 private + 2 public subnets across 2 AZs, an Internet Gateway, a
# NAT Gateway (workers in the private subnets need internet egress to
# reach the Open-Meteo API), a security group, the MWAA S3 bucket, the
# execution role, a Secrets Manager secret for Snowflake credentials,
# and finally the MWAA environment itself.
#
# Every step checks whether its resource already exists before creating
# it. Safe to re-run after a partial failure (a missing IAM permission,
# for example), it picks up from wherever it stopped instead of erroring
# on duplicates or leaving you to hunt down already-created resource IDs.
#
# COST WARNING: unlike everything else provisioned in this project so
# far (RDS free tier, small S3 buckets), MWAA is genuinely expensive to
# leave running: the mw1.small environment alone is roughly $0.49/hour,
# plus worker costs, plus the NAT Gateway (~$0.045/hour + data
# processing). Left running continuously this is on the order of
# $350-500+/month. Pair every session with teardown_mwaa.sh, the same
# way RDS/S3 get torn down between sessions in this project.
#
# UNTESTED AGAINST LIVE AWS: this script was written and reviewed
# against AWS's current documented MWAA requirements (VPC/subnet
# constraints, CLI parameter names, the general execution-role
# permission pattern), but has not been run against a real AWS account.
# Read through it before running, watch each step's output, and cross-
# check the execution role policy below against AWS's current sample
# execution role policy before creating the environment (that page
# changes with Airflow's own version support), see
# https://docs.aws.amazon.com/mwaa/latest/userguide/mwaa-create-role.html
#
# If a step fails with AccessDenied, see docs/mwaa_setup.md's
# Permissions section, then just re-run this same script.
#
# Usage:
#   ./scripts/setup_mwaa.sh
#
# Requires: AWS CLI configured (docs/aws_cli_setup.md), .env filled in.

set -e

if [ ! -f .env ]; then
  echo "No .env file found. See docs/SETUP_CHECKLIST.md."
  exit 1
fi

set -a
source .env
set +a

REGION=$(aws configure get region)
if [ -z "$REGION" ]; then
  echo "No default region set. Run 'aws configure' first."
  exit 1
fi

MWAA_ENV_NAME="sentinel-mwaa"
MWAA_BUCKET="${MWAA_BUCKET_NAME:-sentinel-mwaa-dags}"
VPC_CIDR="10.192.0.0/16"
PUBLIC_SUBNET_1_CIDR="10.192.10.0/24"
PUBLIC_SUBNET_2_CIDR="10.192.11.0/24"
PRIVATE_SUBNET_1_CIDR="10.192.20.0/24"
PRIVATE_SUBNET_2_CIDR="10.192.21.0/24"

echo "Using region: $REGION"
echo "MWAA environment name: $MWAA_ENV_NAME"
echo "MWAA S3 bucket: $MWAA_BUCKET"
echo ""

# ---- 1. VPC ----
echo "== Step 1: VPC =="
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${MWAA_ENV_NAME}-vpc" \
  --query "Vpcs[0].VpcId" --output text)
if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
  VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${MWAA_ENV_NAME}-vpc}]" \
    --query "Vpc.VpcId" --output text)
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support "{\"Value\":true}"
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames "{\"Value\":true}"
  echo "VPC created: $VPC_ID"
else
  echo "VPC already exists, using it: $VPC_ID"
fi

# ---- 2. Internet Gateway ----
echo "== Step 2: Internet Gateway =="
IGW_ID=$(aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
  --query "InternetGateways[0].InternetGatewayId" --output text)
if [ -z "$IGW_ID" ] || [ "$IGW_ID" == "None" ]; then
  IGW_ID=$(aws ec2 create-internet-gateway \
    --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${MWAA_ENV_NAME}-igw}]" \
    --query "InternetGateway.InternetGatewayId" --output text)
  aws ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID"
  echo "Internet Gateway created and attached: $IGW_ID"
else
  echo "Internet Gateway already attached, using it: $IGW_ID"
fi

# ---- 3. Subnets across 2 AZs (MWAA requires exactly this: 2 private subnets in different AZs) ----
echo "== Step 3: Subnets =="
AZ_1=$(aws ec2 describe-availability-zones --query "AvailabilityZones[0].ZoneName" --output text)
AZ_2=$(aws ec2 describe-availability-zones --query "AvailabilityZones[1].ZoneName" --output text)
echo "Using availability zones: $AZ_1, $AZ_2"

get_or_create_subnet() {
  local name="$1" cidr="$2" az="$3"
  local subnet_id
  subnet_id=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=${name}" "Name=vpc-id,Values=${VPC_ID}" \
    --query "Subnets[0].SubnetId" --output text)
  if [ -z "$subnet_id" ] || [ "$subnet_id" == "None" ]; then
    subnet_id=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$cidr" --availability-zone "$az" \
      --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${name}}]" \
      --query "Subnet.SubnetId" --output text)
    echo "Created subnet $name: $subnet_id" >&2
  else
    echo "Subnet $name already exists, using it: $subnet_id" >&2
  fi
  echo "$subnet_id"
}

PUBLIC_SUBNET_1=$(get_or_create_subnet "${MWAA_ENV_NAME}-public-1" "$PUBLIC_SUBNET_1_CIDR" "$AZ_1")
PUBLIC_SUBNET_2=$(get_or_create_subnet "${MWAA_ENV_NAME}-public-2" "$PUBLIC_SUBNET_2_CIDR" "$AZ_2")
PRIVATE_SUBNET_1=$(get_or_create_subnet "${MWAA_ENV_NAME}-private-1" "$PRIVATE_SUBNET_1_CIDR" "$AZ_1")
PRIVATE_SUBNET_2=$(get_or_create_subnet "${MWAA_ENV_NAME}-private-2" "$PRIVATE_SUBNET_2_CIDR" "$AZ_2")

aws ec2 modify-subnet-attribute --subnet-id "$PUBLIC_SUBNET_1" --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --subnet-id "$PUBLIC_SUBNET_2" --map-public-ip-on-launch

# ---- 4. NAT Gateway (needs an Elastic IP, lives in a public subnet) ----
echo "== Step 4: NAT Gateway (this is the expensive always-on piece, see cost warning above) =="
NAT_GW_ID=$(aws ec2 describe-nat-gateways \
  --filter "Name=tag:Name,Values=${MWAA_ENV_NAME}-nat" "Name=state,Values=pending,available" \
  --query "NatGateways[0].NatGatewayId" --output text)
if [ -z "$NAT_GW_ID" ] || [ "$NAT_GW_ID" == "None" ]; then
  EIP_ALLOC_ID=$(aws ec2 allocate-address --domain vpc --query "AllocationId" --output text)
  NAT_GW_ID=$(aws ec2 create-nat-gateway --subnet-id "$PUBLIC_SUBNET_1" --allocation-id "$EIP_ALLOC_ID" \
    --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${MWAA_ENV_NAME}-nat}]" \
    --query "NatGateway.NatGatewayId" --output text)
  echo "Waiting for NAT Gateway to become available, this takes a few minutes..."
  aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW_ID"
  echo "NAT Gateway ready: $NAT_GW_ID"
else
  echo "NAT Gateway already exists, using it: $NAT_GW_ID"
  aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW_ID" 2>/dev/null || true
fi

# ---- 5. Route tables ----
echo "== Step 5: Route tables =="
PUBLIC_RT_ID=$(aws ec2 describe-route-tables --filters "Name=tag:Name,Values=${MWAA_ENV_NAME}-public-rt" \
  --query "RouteTables[0].RouteTableId" --output text)
if [ -z "$PUBLIC_RT_ID" ] || [ "$PUBLIC_RT_ID" == "None" ]; then
  PUBLIC_RT_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${MWAA_ENV_NAME}-public-rt}]" \
    --query "RouteTable.RouteTableId" --output text)
  aws ec2 create-route --route-table-id "$PUBLIC_RT_ID" --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID" > /dev/null
  aws ec2 associate-route-table --route-table-id "$PUBLIC_RT_ID" --subnet-id "$PUBLIC_SUBNET_1" > /dev/null 2>&1 || true
  aws ec2 associate-route-table --route-table-id "$PUBLIC_RT_ID" --subnet-id "$PUBLIC_SUBNET_2" > /dev/null 2>&1 || true
  echo "Public route table created: $PUBLIC_RT_ID"
else
  echo "Public route table already exists, using it: $PUBLIC_RT_ID"
fi

PRIVATE_RT_ID=$(aws ec2 describe-route-tables --filters "Name=tag:Name,Values=${MWAA_ENV_NAME}-private-rt" \
  --query "RouteTables[0].RouteTableId" --output text)
if [ -z "$PRIVATE_RT_ID" ] || [ "$PRIVATE_RT_ID" == "None" ]; then
  PRIVATE_RT_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${MWAA_ENV_NAME}-private-rt}]" \
    --query "RouteTable.RouteTableId" --output text)
  aws ec2 create-route --route-table-id "$PRIVATE_RT_ID" --destination-cidr-block "0.0.0.0/0" --nat-gateway-id "$NAT_GW_ID" > /dev/null
  aws ec2 associate-route-table --route-table-id "$PRIVATE_RT_ID" --subnet-id "$PRIVATE_SUBNET_1" > /dev/null 2>&1 || true
  aws ec2 associate-route-table --route-table-id "$PRIVATE_RT_ID" --subnet-id "$PRIVATE_SUBNET_2" > /dev/null 2>&1 || true
  echo "Private route table created: $PRIVATE_RT_ID"
else
  echo "Private route table already exists, using it: $PRIVATE_RT_ID"
fi

# ---- 6. Security group (self-referencing, per AWS's documented MWAA pattern) ----
echo "== Step 6: Security group =="
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${MWAA_ENV_NAME}-sg" "Name=vpc-id,Values=${VPC_ID}" \
  --query "SecurityGroups[0].GroupId" --output text)
if [ -z "$SG_ID" ] || [ "$SG_ID" == "None" ]; then
  SG_ID=$(aws ec2 create-security-group --group-name "${MWAA_ENV_NAME}-sg" \
    --description "Sentinel MWAA environment security group" --vpc-id "$VPC_ID" \
    --query "GroupId" --output text)
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol -1 --source-group "$SG_ID" > /dev/null
  echo "Security group created: $SG_ID"
else
  echo "Security group already exists, using it: $SG_ID"
fi

# ---- 7. MWAA S3 bucket (versioned, private) ----
echo "== Step 7: MWAA S3 bucket =="
if aws s3api head-bucket --bucket "$MWAA_BUCKET" > /dev/null 2>&1; then
  echo "Bucket already exists, using it: $MWAA_BUCKET"
else
  if [ "$REGION" == "us-east-1" ]; then
    aws s3api create-bucket --bucket "$MWAA_BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$MWAA_BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
  echo "Bucket created: $MWAA_BUCKET"
fi
# Safe to re-apply regardless of whether the bucket already existed.
aws s3api put-bucket-versioning --bucket "$MWAA_BUCKET" --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$MWAA_BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket "$MWAA_BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-object --bucket "$MWAA_BUCKET" --key "dags/" > /dev/null 2>&1 || true
echo "Bucket confirmed versioned, private, and encrypted."

# ---- 8. Execution role ----
echo "== Step 8: Execution role =="
echo "IMPORTANT: cross-check the policy this step attaches against AWS's current"
echo "sample execution role policy before relying on it in anything beyond testing:"
echo "https://docs.aws.amazon.com/mwaa/latest/userguide/mwaa-create-role.html"

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
LANDING_BUCKET="${S3_LANDING_BUCKET}"
PROCESSED_BUCKET="${S3_PROCESSED_BUCKET}"

if aws iam get-role --role-name "${MWAA_ENV_NAME}-execution-role" > /dev/null 2>&1; then
  echo "Execution role already exists, re-applying its policy in case anything changed."
else
  cat > ./mwaa_trust_policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": ["airflow-env.amazonaws.com", "airflow.amazonaws.com"]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
  aws iam create-role --role-name "${MWAA_ENV_NAME}-execution-role" \
    --assume-role-policy-document file://./mwaa_trust_policy.json > /dev/null
  rm ./mwaa_trust_policy.json
  echo "Execution role created."
fi

cat > ./mwaa_execution_policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "airflow:PublishMetrics",
      "Resource": "arn:aws:airflow:${REGION}:${ACCOUNT_ID}:environment/${MWAA_ENV_NAME}"
    },
    {
      "Effect": "Deny",
      "Action": "s3:ListAllMyBuckets",
      "Resource": ["arn:aws:s3:::${MWAA_BUCKET}", "arn:aws:s3:::${MWAA_BUCKET}/*"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject*", "s3:GetBucket*", "s3:List*"],
      "Resource": ["arn:aws:s3:::${MWAA_BUCKET}", "arn:aws:s3:::${MWAA_BUCKET}/*"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject*", "s3:GetBucket*", "s3:List*", "s3:PutObject*", "s3:DeleteObject*"],
      "Resource": [
        "arn:aws:s3:::${LANDING_BUCKET}", "arn:aws:s3:::${LANDING_BUCKET}/*",
        "arn:aws:s3:::${PROCESSED_BUCKET}", "arn:aws:s3:::${PROCESSED_BUCKET}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogStream", "logs:CreateLogGroup", "logs:PutLogEvents",
        "logs:GetLogEvents", "logs:GetLogRecord", "logs:GetLogGroupFields",
        "logs:GetQueryResults", "logs:DescribeLogGroups"
      ],
      "Resource": "arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:airflow-${MWAA_ENV_NAME}-*"
    },
    {
      "Effect": "Allow",
      "Action": "cloudwatch:PutMetricData",
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "sqs:ChangeMessageVisibility", "sqs:DeleteMessage", "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl", "sqs:ReceiveMessage", "sqs:SendMessage"
      ],
      "Resource": "arn:aws:sqs:${REGION}:*:airflow-celery-*"
    },
    {
      "Effect": "Allow",
      "Action": ["kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey*", "kms:Encrypt"],
      "NotResource": "arn:aws:kms:*:${ACCOUNT_ID}:key/*",
      "Condition": {
        "StringLike": {
          "kms:ViaService": ["sqs.${REGION}.amazonaws.com", "s3.${REGION}.amazonaws.com"]
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:${REGION}:${ACCOUNT_ID}:secret:sentinel/snowflake*"
    }
  ]
}
EOF

aws iam put-role-policy --role-name "${MWAA_ENV_NAME}-execution-role" \
  --policy-name "${MWAA_ENV_NAME}-execution-policy" \
  --policy-document file://./mwaa_execution_policy.json
EXECUTION_ROLE_ARN=$(aws iam get-role --role-name "${MWAA_ENV_NAME}-execution-role" \
  --query "Role.Arn" --output text)
rm ./mwaa_execution_policy.json
echo "Execution role ready: $EXECUTION_ROLE_ARN"

# ---- 9. Secrets Manager: Snowflake credentials ----
echo "== Step 9: Secrets Manager secret for Snowflake credentials =="
SECRET_STRING="{\"account\":\"${SNOWFLAKE_ACCOUNT}\",\"user\":\"${SNOWFLAKE_USER}\",\"password\":\"${SNOWFLAKE_PASSWORD}\",\"warehouse\":\"${SNOWFLAKE_WAREHOUSE}\",\"database\":\"${SNOWFLAKE_DATABASE}\",\"schema\":\"${SNOWFLAKE_SCHEMA}\"}"
if aws secretsmanager describe-secret --secret-id "sentinel/snowflake" > /dev/null 2>&1; then
  aws secretsmanager put-secret-value --secret-id "sentinel/snowflake" \
    --secret-string "$SECRET_STRING" > /dev/null
  echo "Secret already existed, updated its value: sentinel/snowflake"
else
  aws secretsmanager create-secret --name "sentinel/snowflake" \
    --description "Snowflake credentials for the Sentinel MWAA DAG" \
    --secret-string "$SECRET_STRING" > /dev/null
  echo "Secret created: sentinel/snowflake"
fi

# ---- 10. MWAA environment itself ----
echo "== Step 10: MWAA environment (this is the expensive, slow step, 20-30 minutes) =="
if aws mwaa get-environment --name "$MWAA_ENV_NAME" > /dev/null 2>&1; then
  ENV_STATUS=$(aws mwaa get-environment --name "$MWAA_ENV_NAME" --query "Environment.Status" --output text)
  echo "MWAA environment already exists, status: $ENV_STATUS"
  echo "Nothing more to do here. Check status any time with:"
  echo "  aws mwaa get-environment --name $MWAA_ENV_NAME --query 'Environment.Status'"
  exit 0
fi

read -p "About to create the MWAA environment. This starts real billing immediately. Type 'yes' to continue: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Stopped before creating the MWAA environment. Everything else is already created."
  echo "Re-run this script whenever you're ready, it will skip straight to this step."
  exit 0
fi

aws mwaa create-environment \
  --name "$MWAA_ENV_NAME" \
  --source-bucket-arn "arn:aws:s3:::${MWAA_BUCKET}" \
  --dag-s3-path "dags" \
  --execution-role-arn "$EXECUTION_ROLE_ARN" \
  --environment-class "mw1.small" \
  --network-configuration "SubnetIds=${PRIVATE_SUBNET_1},${PRIVATE_SUBNET_2},SecurityGroupIds=${SG_ID}" \
  --webserver-access-mode "PUBLIC_ONLY"

echo ""
echo "MWAA environment creation started. This takes 20-30 minutes."
echo "Check status with:"
echo "  aws mwaa get-environment --name $MWAA_ENV_NAME --query 'Environment.Status'"
