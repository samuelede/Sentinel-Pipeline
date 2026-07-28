# AWS CLI Setup

This document covers installing and configuring the AWS CLI so the extractors (`boto3`) and the CLI options in [`aws_setup.md`](aws_setup.md) and [`policy_admin_db_setup.md`](policy_admin_db_setup.md) can authenticate against your AWS account. Do this before provisioning any AWS resources.

These steps are written for Windows with Git Bash (the environment this project is developed in). If you're on macOS or Linux, the install step differs slightly but everything from `aws configure` onward is the same.

## 1. Install the AWS CLI

Download and run the MSI installer:

```
https://awscli.amazonaws.com/AWSCLIV2.msi
```

Or via `winget` from any terminal:

```bash
winget install Amazon.AWSCLI
```

After installing, close and reopen VS Code entirely (not just the terminal). Windows needs to refresh PATH for new installs to be picked up by Git Bash.

## 2. Verify it's on PATH in Git Bash

Open a new VS Code terminal, confirm it's set to Git Bash (bottom right of the terminal panel, or `Ctrl+Shift+P` then "Terminal: Select Default Profile" then Git Bash), and run:

```bash
aws --version
```

Expected output looks like `aws-cli/2.x.x Python/3.x.x Windows/...`.

If you get "command not found," the install didn't land on PATH. Confirm `/c/Program Files/Amazon/AWSCLIV2/` exists, and if it does, add it manually to Git Bash's PATH by adding this line to `~/.bashrc`:

```bash
export PATH="/c/Program Files/Amazon/AWSCLIV2:$PATH"
```

then run `source ~/.bashrc`.

## 3. Create an IAM user with programmatic access

Don't use root account credentials for this project.

1. Go to IAM in the Console, then **Users**, then **Create user**.
2. Name it something like `sentinel-pipeline-dev`.
3. Attach permissions for `AmazonS3FullAccess` and `AmazonRDSFullAccess`, either directly or through a group like `sentinel-dev-group`.
4. After the user is created, click into it, go to the **Security credentials** tab, and click **Create access key**.
5. Choose **Command Line Interface (CLI)** as the use case.
6. Save the Access key ID and Secret access key immediately. The secret is shown only once.

## 4. Run `aws configure`

In the VS Code Git Bash terminal:

```bash
aws configure
```

It prompts for four values:

```
AWS Access Key ID [None]: <paste your access key>
AWS Secret Access Key [None]: <paste your secret key>
Default region name [None]: us-east-2
Default output format [None]: json
```

Use the same region here as the one used for the S3 buckets and RDS instance in [`aws_setup.md`](aws_setup.md) and [`policy_admin_db_setup.md`](policy_admin_db_setup.md).

## 5. Verify it works

```bash
aws sts get-caller-identity
```

This returns your account ID, user ARN, and user ID as JSON, confirming the CLI can authenticate.

```bash
aws s3 ls
```

This confirms the CLI can see your resources once they exist.

## Credential storage and `.env`

`aws configure` writes credentials to `~/.aws/credentials` (`C:\Users\<you>\.aws\credentials` on Windows), which is separate from this project's `.env` file. The `boto3` calls in `extractors/extract_policy_admin.py` and elsewhere in this repo pick up credentials from `~/.aws/credentials` automatically, so `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` do not need to be set in `.env` unless you want to override them per project.

`~/.aws/credentials` lives outside the repo folder, so there's no risk of committing it by way of `git add .`. Still worth a periodic check that nothing under `sentinel-pipeline/` or `source_systems/` has a stray copy of it.

## Next step

Once `aws sts get-caller-identity` succeeds, move on to provisioning resources: [`aws_setup.md`](aws_setup.md) for the S3 buckets, then [`policy_admin_db_setup.md`](policy_admin_db_setup.md) for RDS.