# AWS Setup and Teardown

Sentinel's AWS footprint (RDS + S3) costs money by the hour/GB regardless of whether it's actively used. This document covers tearing it all down cleanly between work sessions, and bringing it back up again, so nothing keeps billing while the project sits idle.

This is separate from Snowflake: Snowflake trial accounts run on credits, not a running meter, and warehouses auto-suspend on inactivity by default, so there's no equivalent urgency to tear that down between sessions. See [`snowflake_setup.md`](snowflake_setup.md) for that setup, it doesn't need to be repeated.

## When to tear down

Any time you're stepping away from active development for more than a few hours and don't need the RDS instance or S3 buckets reachable. There's no benefit to leaving them up "just in case", re-creating them from scratch takes a few minutes with this repo's scripts.

## Teardown

Run this to do all of it in one step, with a confirmation prompt before anything is deleted:

```bash
./scripts/teardown_aws.sh
```

It reads `S3_LANDING_BUCKET` / `S3_PROCESSED_BUCKET` from your environment if set (matching `.env`), otherwise falls back to the default names. It's safe to re-run, anything already deleted is skipped rather than erroring.

The manual steps below are the same thing broken out individually, useful if you want to tear down only part of it, or understand exactly what the script does before running it. Order matters: RDS first, since its security group can't be deleted while still attached to a running instance.

### 1. Delete the RDS instance

```bash
aws rds delete-db-instance \
  --db-instance-identifier sentinel-policy-admin \
  --skip-final-snapshot \
  --delete-automated-backups
```

`--skip-final-snapshot` avoids AWS creating (and billing for) a final snapshot, this is dev data reseedable from CSVs, so there's nothing worth preserving here. Wait for deletion to actually finish before continuing:

```bash
aws rds wait db-instance-deleted --db-instance-identifier sentinel-policy-admin
```

### 2. Empty and delete the S3 buckets

Buckets with objects can't be deleted directly:

```bash
aws s3 rm s3://sentinel-landing-sm --recursive
aws s3 rm s3://sentinel-processed-sm --recursive
aws s3 rb s3://sentinel-landing-sm
aws s3 rb s3://sentinel-processed-sm
```

Replace `sentinel-landing-sm` / `sentinel-processed-sm` with your actual bucket names if you used different ones (bucket names are globally unique, so yours may have a suffix, see [`aws_setup.md`](aws_setup.md)).

### 3. Delete the RDS security group

```bash
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=sentinel-policy-admin-sg" \
  --query "SecurityGroups[0].GroupId" \
  --output text
```

```bash
aws ec2 delete-security-group --group-id sg-xxxxxxxx
```

(use the actual group ID returned above)

### 4. Leave the VPC alone

If you followed the setup docs, RDS ran in your account's default VPC. AWS doesn't charge for VPCs, subnets, or route tables sitting idle, only for resources running inside them, which are now gone. There's nothing to gain from deleting a default VPC, and it complicates re-setup. Skip this step.

### 5. Verify everything is actually gone

```bash
aws rds describe-db-instances --query "DBInstances[].DBInstanceIdentifier"
aws s3 ls
```

Both should return empty.

### 6. Check for leftover storage that snuck in

Occasionally a snapshot or orphaned volume survives a teardown and quietly keeps billing. Worth a quick check:

```bash
aws rds describe-db-snapshots --query "DBSnapshots[].DBSnapshotIdentifier"
aws ec2 describe-volumes --query "Volumes[].VolumeId"
```

Both should be empty. If either shows something, delete it before walking away.

## Re-setup (when picking the project back up)

Follow the main [`README.md`](../README.md) setup steps in order, this teardown doesn't change any of them:

1. `docs/aws_cli_setup.md` if the AWS CLI itself needs reconfiguring (it usually doesn't, credentials persist in `~/.aws/credentials` independent of AWS resources)
2. `docs/aws_setup.md` to recreate the two S3 buckets
3. `docs/policy_admin_db_setup.md` to reprovision RDS, bootstrap the role, and reseed from the source CSVs (which should still be sitting locally in `source_systems/`, they were never deleted, only the AWS resources were)

Since `source_systems/` isn't touched by this teardown, re-setup should not require re-pulling from Google Drive, only re-provisioning AWS and re-running the seed and extractor scripts.

## Cost sanity check before walking away

A quick way to confirm nothing's still running, from anywhere, anytime:

```bash
aws rds describe-db-instances --query "DBInstances[].DBInstanceIdentifier" --output text
aws s3 ls
aws ec2 describe-volumes --query "Volumes[].VolumeId" --output text
```

All three empty means nothing in this project is currently costing money.
