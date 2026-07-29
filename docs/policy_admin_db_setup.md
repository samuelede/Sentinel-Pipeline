# Policy Admin Database Setup

This document covers provisioning the RDS PostgreSQL instance that represents Sentinel's policy admin system, and reproducing the seeded database from scratch.

If you plan to use any AWS CLI commands referenced elsewhere in this project, set that up first: see [`aws_cli_setup.md`](aws_cli_setup.md).

## 1. Provision the RDS instance

1. In the AWS Console search bar, type **RDS** and open the **Aurora and RDS** service.
2. In the left nav pane, click **Databases**.
3. Click the orange **Create database** dropdown (top right). You'll see three options:
   - **Express configuration**
   - **Full configuration**
   - **Restore from S3**
   
   Click **Full configuration**. Express configuration hides settings this project needs (public access, security group, instance identifier detail), so it's the wrong one here.
4. Under **Engine options**, choose **PostgreSQL**, and leave the engine version at whatever is marked "Default" or "Recommended."
5. Under **Templates**, choose **Free tier** if it's shown, or **Sandbox** if your account is on a paid plan. Either works for this project.
6. Under **Settings**:
   - DB instance identifier: `sentinel-policy-admin`
   - Master username: choose one (e.g., `postgres`)
   - Turn off "Auto generate a password" so you can set and see it directly
   - Master password: set one and save it immediately, it's shown only once
7. Under **Instance configuration**, confirm a free-tier-eligible class like `db.t4g.micro` or `db.t3.micro` is selected (the exact default varies by region).
8. Under **Connectivity**:
   - If you see "Compute resource," choose **"Don't connect to an EC2 compute resource."**
   - Set **Public access** to **Yes** so the database can be reached from your local machine during development.
   - VPC security group: choose **Create new** and give it a name like `sentinel-policy-admin-sg`.
   - Leave the database port at `5432`.
9. Leave the remaining sections (Database authentication, Monitoring, Additional configuration) at their defaults and click **Create database** at the bottom of the page.
10. Wait for the instance status to change from "Creating" to "Available" (a few minutes). Click into the instance and copy the **Endpoint** from the **Connectivity & security** tab.
11. Lock down the inbound rule so only your IP can reach port `5432`:
    - Still on the **Connectivity & security** tab, click the security group link (e.g., `sentinel-policy-admin-sg`) to open it in the EC2 console.
    - Go to the **Inbound rules** tab and click **Edit inbound rules**.
    - If a rule already allows `0.0.0.0/0` on port 5432, remove it.
    - Add a rule: Type = **PostgreSQL**, Port = `5432`, Source = **My IP** (the console autofills your current public IP as a `/32`).
    - Save rules.

Your IP will change over time, especially on a home or mobile connection. If `psql` or the seed script starts timing out later, that's almost always this. Instead of repeating the Console steps above, run:

```bash
./scripts/update_rds_ip_allowlist.sh
```

This looks up your current public IP, finds the security group automatically, and swaps the old rule for the new IP in one command.

## 2. Store credentials

Add the following to your local `.env` file (never commit this file):

```
PG_HOST=<rds-endpoint>
PG_PORT=5432
PG_DB=policy_admin
PG_MASTER_USER=<master_user>
PG_MASTER_PASSWORD=<master_password>
PG_APP_USER=sentinel
PG_APP_PASSWORD=<a_new_password_for_the_app_role>
```

`PG_HOST`, `PG_MASTER_USER`, and `PG_MASTER_PASSWORD` come from AWS, they're whatever you set when provisioning the RDS instance in step 1.

`PG_APP_PASSWORD` does not come from anywhere, you invent it yourself, any password works. It doesn't exist in Postgres yet at this point. Pick one and put it in `.env` now, before running the bootstrap step below. The bootstrap step is what actually creates the `sentinel` role using this exact value (`CREATE ROLE sentinel LOGIN PASSWORD '<what you put here>'`), so this password becomes real only after that step runs. Every later connection (seeding, extractors) authenticates against whatever value is in `.env` at that time, so if you ever regenerate `.env` from scratch, this value must match what was originally used during bootstrap, or connections will fail with an auth error.

## 3. Confirm connectivity

```bash
psql "host=<endpoint> port=5432 dbname=postgres user=<master_user> password=<master_password> sslmode=require"
```

A successful connection returns a `postgres=>` prompt.

## 4. Bootstrap the app role and database

RDS master users cannot directly create a database owned by a role they have not yet been granted. The bootstrap step handles this in the correct order:

```bash
python scripts/seed_policy_admin_db.py --bootstrap
```

This creates the `sentinel` role, grants it to the master user, then creates the `policy_admin` database owned by `sentinel`.

## 5. Pull the source CSVs

The seed script expects `customers.csv`, `agents.csv`, `policies.csv`, and `coverages.csv` to already exist in the folder pointed to by `SOURCE_SYSTEMS_DIR` in `.env` (`source_systems/` by default). These come from the shared Google Drive folder, not from this repo.

Pull them automatically:

```bash
python scripts/pull_source_data.py --only policy_admin
```

Or download manually through the browser. For a first full pull, manual is faster and more reliable, it uses your authenticated Google session rather than `gdown`'s anonymous access, which Drive can rate-limit on larger folders. If you download the whole shared folder rather than just `policy_admin/`, the CSVs will land nested under `source_systems/policy_admin/`, flatten them to the top level before seeding:

```bash
mv source_systems/policy_admin/*.csv source_systems/
rmdir source_systems/policy_admin
```

See [`source_data_pull.md`](source_data_pull.md) for both options side by side, and what to do if the Drive folder's sharing permissions block the automatic download.

Confirm the files landed before continuing:

```bash
ls source_systems/
```

You should see all four CSVs sitting directly in that folder, not nested in a subfolder.

## 6. Seed the tables

```bash
python scripts/seed_policy_admin_db.py
```

This creates the four tables if they do not already exist and bulk-loads each from its CSV using `COPY ... FROM STDIN`.

## 7. Verify row counts

Expected counts after a successful seed:

| Table | Expected rows |
|---|---|
| customers | 300 |
| agents | 12 |
| policies | 385 |
| coverages | 1568 |

The seed script prints a per-table row count and flags any mismatch. You can also check manually:

```sql
SELECT COUNT(*) FROM customers;
SELECT COUNT(*) FROM agents;
SELECT COUNT(*) FROM policies;
SELECT COUNT(*) FROM coverages;
```

## Reproducing from scratch

To rebuild the database entirely: drop the RDS instance (or the `policy_admin` database), repeat steps 1 through 6, and confirm counts match the table above.