# MWAA Setup

Provisions real Amazon MWAA (managed cloud Airflow), distinct from `docker-compose.airflow.yml` (the local Docker Airflow used for development). This is genuinely expensive to leave running, read the cost warning before doing anything here.

This doc covers infrastructure only, getting the environment itself into an `AVAILABLE` state. See [`docs/mwaa_deploy.md`](mwaa_deploy.md) for actually putting the DAG on it.

## Cost warning

Unlike RDS free tier or a few S3 buckets, MWAA is a real ongoing cost: the `mw1.small` environment alone runs roughly $0.49/hour, plus worker costs, plus the NAT Gateway (~$0.045/hour + data processing). Left running continuously, that's on the order of **$350-500+/month**. Always pair a session with `teardown_mwaa.sh` when you're done, the same discipline already used for RDS/S3 in this project, just with much higher stakes if forgotten.

## Prerequisites

Add this to your `.env`:

```
MWAA_BUCKET_NAME=sentinel-mwaa-dags
```

(pick a globally-unique name if that one's taken, S3 bucket names are global)

Your existing `S3_LANDING_BUCKET`, `S3_PROCESSED_BUCKET`, and `SNOWFLAKE_*` values are also read directly by `setup_mwaa.sh`, no new Snowflake config needed.

Your IAM user also needs permissions for EC2 (VPC/subnets/NAT), IAM (role creation), Secrets Manager, and MWAA itself. If you hit `AccessDenied` on any step, see **Permissions** below before re-running.

## What `setup_mwaa.sh` provisions, in order

1. A dedicated VPC (`10.192.0.0/16`) with 2 public + 2 private subnets across 2 availability zones, MWAA specifically requires 2 private subnets in different AZs, this isn't optional.
2. An Internet Gateway (public subnets) and a NAT Gateway (private subnets), workers run in the private subnets but still need internet egress to reach the Open-Meteo API.
3. A self-referencing security group, matching AWS's documented MWAA pattern.
4. The MWAA S3 bucket: versioned, private (all public access blocked), server-side encrypted, with an empty `dags/` prefix created.
5. An execution role with the trust policy MWAA requires, plus a permissions policy covering: S3 read on the MWAA bucket, S3 read/write on both data lake buckets (`S3_LANDING_BUCKET`/`S3_PROCESSED_BUCKET`), CloudWatch Logs, CloudWatch metrics, the Celery SQS queue, KMS (for SQS/S3 encryption), and Secrets Manager read scoped to `sentinel/snowflake*`.
6. A Secrets Manager secret (`sentinel/snowflake`) holding your Snowflake credentials as JSON.
7. The MWAA environment itself (`mw1.small`, pointing at the bucket's `dags/` prefix), **after an explicit confirmation prompt**, since this is the step that starts real billing.

```bash
./scripts/setup_mwaa.sh
```

Safe to re-run: every step checks whether its resource already exists before creating it, so if it fails partway through (a permissions gap, for example), fixing the issue and running the same command again picks up where it left off instead of erroring on duplicates or requiring you to hunt down already-created resource IDs.

**Important**: I wrote and reviewed the execution role's permissions policy against AWS's currently-documented MWAA requirements, but couldn't test it against a live AWS account from where I'm working. Cross-check it against AWS's own current sample execution role policy before relying on it beyond initial testing, that page changes as Airflow version support changes:
https://docs.aws.amazon.com/mwaa/latest/userguide/mwaa-create-role.html

## Permissions

Don't attach broad IAM permissions to `sentinel-pipeline-dev` (the scoped-down user this project uses day to day) for this. `IAMFullAccess` specifically is a privilege-escalation risk: a user with it can grant itself, or create a new user with, full account-admin access. That's a different risk tier from the scoped S3/EC2/RDS grants used elsewhere in this project, and not something worth attaching to a credential that sits in a local `.aws/credentials` file for routine pipeline runs.

**Run the whole MWAA setup under a separate admin profile instead** (`Samuel` in the examples below, substitute your own admin profile's actual name):

```bash
export AWS_PROFILE=Samuel
export AWS_DEFAULT_REGION=us-east-2
./scripts/setup_mwaa.sh
```

Exporting both together, not just passing `--profile` on individual commands, matters: the script and any status checks you run afterward all need to agree on the same profile *and* the same region, mixing them (e.g. creating resources under `Samuel`/`us-east-2` then checking status under the default profile, or without an explicit region) is exactly what causes confusing "resource not found" errors even when everything was actually created correctly.

Note: an AWS CLI **profile name** (`Samuel`, `default`) is a local alias you define via `aws configure --profile <name>`, it is not the same thing as an IAM **username** (`sentinel-pipeline-dev`), `--profile sentinel-pipeline-dev` will fail with "config profile could not be found" unless you specifically created a profile with that exact name.

Since `sentinel-pipeline-dev` is deliberately never given MWAA/IAM/Secrets Manager access here, **checking on the environment afterward also needs the same admin profile**, not your default:

```bash
aws mwaa get-environment --name sentinel-mwaa --query "Environment.Status" --profile Samuel --region us-east-2
```

If you'd rather not pass `--profile` every time you check status, `AmazonMWAAFullConsoleAccess` alone (not `IAMFullAccess`) is low-risk enough to attach directly to `sentinel-pipeline-dev`, same tier as the S3/EC2/RDS grants elsewhere in this project:

```bash
aws iam attach-user-policy --user-name sentinel-pipeline-dev \
  --policy-arn arn:aws:iam::aws:policy/AmazonMWAAFullConsoleAccess --profile Samuel
```

**When you're done with any `Samuel`-scoped work, unset it immediately, don't wait until you need the default profile back:**

```bash
unset AWS_PROFILE
```

`export AWS_PROFILE=Samuel` doesn't expire, it stays active for every command in that terminal window until you either unset it or close the window. Every plain `aws` command afterward, even ones that have nothing to do with MWAA, silently runs as `Samuel` instead of your regular pipeline identity. This has already caused a real false alarm in this project: `aws s3 ls s3://sentinel-landing-sm/...` returned `NoSuchBucket`, not because the bucket was gone, but because `Samuel` was never granted access to it, `sentinel-pipeline-dev` was. Run `aws configure list` any time an AWS command gives a confusing result, if it shows `profile: Samuel` and you didn't mean to still be using it, that's almost certainly the cause.

## Checking status

Environment creation takes 20-30 minutes. Use the same profile and region you provisioned with (see Permissions above):

```bash
aws mwaa get-environment --name sentinel-mwaa --query "Environment.Status" --profile Samuel --region us-east-2
```

Goes through `CREATING` → `AVAILABLE`. If it lands on `CREATE_FAILED`, that's almost always the execution role missing a permission MWAA actually needed, check the environment's error details:

```bash
aws mwaa get-environment --name sentinel-mwaa --query "Environment.LastUpdate" --profile Samuel --region us-east-2
```

## Validating requirements.txt before uploading (Optional)

**This does not run AWS or MWAA itself locally.** It's a separate tool from `docker-compose.airflow.yml`: a Docker container built from the same base image and dependency constraints real MWAA uses internally, purely to test whether `requirements.txt` installs cleanly in that exact environment, before uploading it to AWS. No AWS account, no cloud resources, and no DAG execution against real data are involved, it's a local compatibility check only.

```bash
git clone https://github.com/aws/aws-mwaa-local-runner.git
cd aws-mwaa-local-runner
cp /path/to/sentinel-pipeline/requirements.txt requirements/
./mwaa-local-env build-image
./mwaa-local-env start
```

If `requirements.txt` fails to install here, it will fail in real MWAA too, this catches that before you've spent any real MWAA time or money finding out.

## Teardown

Same profile and region as setup, `teardown_mwaa.sh` touches IAM, Secrets Manager, and MWAA itself, none of which `sentinel-pipeline-dev` has access to by design:

```bash
export AWS_PROFILE=Samuel
export AWS_DEFAULT_REGION=us-east-2
./scripts/teardown_mwaa.sh
```

Tears everything down in the correct dependency order: MWAA environment first (nothing else can be deleted while it's attached), then NAT Gateway + its Elastic IP, security group, subnets, route tables, Internet Gateway, VPC, execution role, Secrets Manager secret, and finally the versioned S3 bucket (with full version history purged, a plain delete only removes current versions and would otherwise block the bucket deletion).

Verify nothing's left billing afterward:

```bash
aws mwaa list-environments --profile Samuel --region us-east-2
aws ec2 describe-nat-gateways --filter Name=state,Values=available --profile Samuel --region us-east-2
aws ec2 describe-vpcs --profile Samuel --region us-east-2
```

All three should come back empty (aside from your account's default VPC, which is fine to leave, it's free).

## Next: deploy to this environment

Once the environment shows `AVAILABLE`, this doc is done, provisioning the infrastructure doesn't put anything runnable on it yet. Head to [`docs/mwaa_deploy.md`](mwaa_deploy.md) to continue: it covers the one-time `etl_scripts` restructuring this environment needs (MWAA only puts the `dags/` folder itself on `sys.path`, not the repo root, so the DAG's current top-level `extractors`/`validators`/`transformers` layout won't import correctly here as-is), then the actual deploy, GitHub Actions automation, triggering, and CloudWatch debugging.
