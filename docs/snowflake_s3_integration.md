# Snowflake to S3 Storage Integration (IAM Trust Setup)

This document covers the one manual piece `sql/ddl/create_stage.sql` can't do on its own: setting up the IAM trust relationship between your AWS account and Snowflake. This has to happen in two passes, because Snowflake generates an IAM user ARN and external ID that your AWS role's trust policy needs, and that identity doesn't exist until the storage integration itself is created first.

## Why this can't be one script

- AWS needs to trust a specific Snowflake-owned IAM identity before Snowflake can assume a role in your account.
- That Snowflake-owned identity (`STORAGE_AWS_IAM_USER_ARN`) and a matching `STORAGE_AWS_EXTERNAL_ID` are only generated once you create the storage integration in Snowflake.
- So: create the integration first (with a placeholder role ARN), read the values Snowflake generated, use those to create the real IAM role in AWS, then point the integration at that real role.

## Phase 1: create the integration with a placeholder (already done)

```bash
snowsql -c sentinel -f sql/ddl/create_stage.sql
```

This creates `sentinel_s3_integration` with a syntactically valid but non-existent placeholder role ARN, this is expected to "succeed" at the SQL level even though the role doesn't exist yet, Snowflake only validates the ARN's format at creation time, not that it's real. The `CREATE STAGE` statement in the same file may also report success even though it can't actually list or read anything yet, that's fine, it gets fixed in phase 3.

## Phase 2: get Snowflake's generated identity

```bash
snowsql -c sentinel -q "DESC STORAGE INTEGRATION sentinel_s3_integration;"
```

Look for two rows in the output:
- `STORAGE_AWS_IAM_USER_ARN`, something like `arn:aws:iam::123456789012:user/abc1-a-2b3c`
- `STORAGE_AWS_EXTERNAL_ID`, something like `AB12345_SFCRole=2_xyz...`

Copy both values exactly, you'll need them in the next step.

## Phase 3: create the real IAM role in AWS

1. Create a trust policy file using the two values from phase 2:

   ```bash
   cat > /tmp/snowflake_trust_policy.json << 'EOF'
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Principal": {
           "AWS": "<STORAGE_AWS_IAM_USER_ARN from phase 2>"
         },
         "Action": "sts:AssumeRole",
         "Condition": {
           "StringEquals": {
             "sts:ExternalId": "<STORAGE_AWS_EXTERNAL_ID from phase 2>"
           }
         }
       }
     ]
   }
   EOF
   ```

   Replace both placeholder values with what you copied, keep the quotes.

2. Create the role:

   ```bash
   aws iam create-role \
     --role-name sentinel_snowflake_role \
     --assume-role-policy-document file:///tmp/snowflake_trust_policy.json
   ```

3. Create a permissions policy scoped to just the processed bucket:

   ```bash
   cat > /tmp/snowflake_s3_permissions.json << 'EOF'
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": ["s3:GetObject", "s3:GetObjectVersion"],
         "Resource": "arn:aws:s3:::sentinel-processed-sm/*"
       },
       {
         "Effect": "Allow",
         "Action": "s3:ListBucket",
         "Resource": "arn:aws:s3:::sentinel-processed-sm",
         "Condition": {
           "StringLike": {
             "s3:prefix": ["*"]
           }
         }
       }
     ]
   }
   EOF
   ```

   Replace `sentinel-processed-sm` with your actual bucket name if different.

4. Attach it:

   ```bash
   aws iam put-role-policy \
     --role-name sentinel_snowflake_role \
     --policy-name sentinel_snowflake_s3_access \
     --policy-document file:///tmp/snowflake_s3_permissions.json
   ```

5. Get the role's ARN (you'll need your AWS account ID, which `aws sts get-caller-identity` already gave you earlier in this project):

   ```bash
   aws iam get-role --role-name sentinel_snowflake_role --query "Role.Arn" --output text
   ```

## Phase 4: point the integration at the real role

```bash
snowsql -c sentinel -q "ALTER STORAGE INTEGRATION sentinel_s3_integration SET STORAGE_AWS_ROLE_ARN = '<role ARN from phase 3 step 5>';"
```

## Verify it actually works

```bash
snowsql -c sentinel -q "SELECT SYSTEM\$VALIDATE_STORAGE_INTEGRATION('sentinel_s3_integration', 's3://sentinel-processed-sm/', 'ALL');"
```

Or more directly, confirm the stage can actually list files:

```bash
snowsql -c sentinel -q "LIST @sentinel_s3_stage;"
```

If your processed zone already has files (from running the transformers earlier), you should see them listed. Empty output with no error also means it's working, it just means nothing's landed in that bucket path yet.

## If this account gets torn down and recreated later

Since [`docs/aws_teardown.md`](aws_teardown.md) tears down the S3 buckets between sessions, this IAM role and trust relationship survive teardown (IAM roles aren't part of that script), so you should NOT need to repeat this whole process on every re-setup, only if you delete the IAM role itself or change bucket names. Worth double-checking `aws iam get-role --role-name sentinel_snowflake_role` still exists next time you set the bucket back up, if it does, phases 1-4 don't need repeating, the stage will just start working again once the bucket exists with the same name.
