# Policy Admin Database Setup

This document covers provisioning the RDS PostgreSQL instance that represents Sentinel's policy admin system, and reproducing the seeded database from scratch.

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
   - Under **Additional configuration**, leave the database port at `5432`.
9. Leave the remaining sections (Database authentication, Monitoring, Additional configuration) at their defaults and click **Create database** at the bottom of the page.
10. Wait for the instance status to change from "Creating" to "Available" (a few minutes). Click into the instance and copy the **Endpoint** from the **Connectivity & security** tab.
11. Lock down the inbound rule so only your IP can reach port `5432`:
    - Still on the **Connectivity & security** tab, click the security group link (e.g., `sentinel-policy-admin-sg`) to open it in the EC2 console.
    - Go to the **Inbound rules** tab and click **Edit inbound rules**.
    - If a rule already allows `0.0.0.0/0` on port 5432, remove it.
    - Add a rule: Type = **PostgreSQL**, Port = `5432`, Source = **My IP** (the console autofills your current public IP as a `/32`).
    - Save rules.

Your IP will change over time, especially on a home or mobile connection. If `psql` starts timing out later, come back to this security group and update the "My IP" rule.

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

## 5. Seed the tables

Place the four source CSVs (`customers.csv`, `agents.csv`, `policies.csv`, `coverages.csv`) in the folder pointed to by `SOURCE_SYSTEMS_DIR` in `.env`, then run:

```bash
python scripts/seed_policy_admin_db.py
```

This creates the four tables if they do not already exist and bulk-loads each from its CSV using `COPY ... FROM STDIN`.

## 6. Verify row counts

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

To rebuild the database entirely: drop the RDS instance (or the `policy_admin` database), repeat steps 1 through 5, and confirm counts match the table above.