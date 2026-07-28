# AWS Resource Setup

This document covers provisioning the two S3 buckets used by the pipeline. For the RDS PostgreSQL instance, see [`policy_admin_db_setup.md`](policy_admin_db_setup.md).

## Prerequisites

- An AWS account with permissions to create S3 buckets
- The AWS CLI installed and configured, if you plan to use the CLI steps (`aws configure`)

## Create the two S3 buckets

### Option A: Console

1. In the AWS Console search bar, type **S3** and open the service.
2. Click **Create bucket**.
3. Bucket name: `sentinel-landing`. Bucket names must be globally unique, so if it's taken, use something like `sentinel-landing-<yourname>` and use that same name consistently in your `.env` file and code.
4. Region: pick one and note it down, you'll use the same region for RDS. `us-east-2` is a reasonable default.
5. Leave **Block all public access** checked. Nothing in this pipeline needs to be public.
6. Enable bucket versioning if you want protection against accidental overwrites (optional, recommended for a landing zone).
7. Click **Create bucket**.
8. Repeat steps 2 through 7 for `sentinel-processed`.

### Option B: CLI

```bash
aws s3api create-bucket \
  --bucket sentinel-landing \
  --region us-east-2 \
  --create-bucket-configuration LocationConstraint=us-east-2

aws s3api create-bucket \
  --bucket sentinel-processed \
  --region us-east-2 \
  --create-bucket-configuration LocationConstraint=us-east-2
```

If your region is `us-east-1`, drop the `--create-bucket-configuration` flag entirely, that region doesn't accept a `LocationConstraint`.

### Verify

```bash
aws s3 ls
```

Both `sentinel-landing` and `sentinel-processed` should appear in the output.

## Next step

Once both buckets exist, move on to provisioning the policy admin database: [`policy_admin_db_setup.md`](policy_admin_db_setup.md).