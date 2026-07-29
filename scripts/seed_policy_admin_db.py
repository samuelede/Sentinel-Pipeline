"""
Seeds the Sentinel policy admin PostgreSQL database (RDS) from source CSVs.

Usage:
    python scripts/seed_policy_admin_db.py --bootstrap   # one-time role/db setup
    python scripts/seed_policy_admin_db.py                # load tables

The --bootstrap step creates a dedicated app role (sentinel) and the
policy_admin database using the RDS master credentials. Due to an RDS
quirk, the master user must run GRANT sentinel TO CURRENT_USER before it
can CREATE DATABASE ... OWNER sentinel.
"""

import argparse
import os

import psycopg2
from dotenv import load_dotenv

load_dotenv()

MASTER_CONN_PARAMS = {
    "host": os.environ["PG_HOST"],
    "port": os.environ.get("PG_PORT", "5432"),
    "dbname": "postgres",
    "user": os.environ["PG_MASTER_USER"],
    "password": os.environ["PG_MASTER_PASSWORD"],
    "sslmode": "require",
}

APP_CONN_PARAMS = {
    "host": os.environ["PG_HOST"],
    "port": os.environ.get("PG_PORT", "5432"),
    "dbname": os.environ.get("PG_DB", "policy_admin"),
    "user": os.environ.get("PG_APP_USER", "sentinel"),
    "password": os.environ.get("PG_APP_PASSWORD"),
    "sslmode": "require",
}

SOURCE_DIR = os.environ.get("SOURCE_SYSTEMS_DIR", "./source_systems")

TABLE_DDL = {
    "customers": """
        CREATE TABLE IF NOT EXISTS customers (
            customer_id VARCHAR PRIMARY KEY,
            first_name VARCHAR NOT NULL,
            last_name VARCHAR NOT NULL,
            dob DATE,
            email VARCHAR,
            phone VARCHAR,
            address VARCHAR,
            city VARCHAR,
            state VARCHAR,
            zip_code VARCHAR,
            created_at TIMESTAMP NOT NULL,
            updated_at TIMESTAMP
        );
    """,
    "agents": """
        CREATE TABLE IF NOT EXISTS agents (
            agent_id VARCHAR PRIMARY KEY,
            agent_name VARCHAR NOT NULL,
            territory VARCHAR,
            hire_date DATE,
            license_number VARCHAR,
            updated_at TIMESTAMP
        );
    """,
    "policies": """
        CREATE TABLE IF NOT EXISTS policies (
            policy_id VARCHAR PRIMARY KEY,
            customer_id VARCHAR NOT NULL REFERENCES customers(customer_id),
            agent_id VARCHAR NOT NULL REFERENCES agents(agent_id),
            policy_number VARCHAR NOT NULL,
            coverage_type VARCHAR NOT NULL,
            start_date DATE NOT NULL,
            end_date DATE NOT NULL,
            premium_amount DECIMAL(18,2) NOT NULL,
            status VARCHAR NOT NULL,
            created_at TIMESTAMP NOT NULL,
            updated_at TIMESTAMP
        );
    """,
    "coverages": """
        CREATE TABLE IF NOT EXISTS coverages (
            coverage_id VARCHAR PRIMARY KEY,
            policy_id VARCHAR NOT NULL REFERENCES policies(policy_id),
            coverage_code VARCHAR NOT NULL,
            coverage_limit INT NOT NULL,
            deductible INT NOT NULL,
            updated_at TIMESTAMP
        );
    """,
}

EXPECTED_ROW_COUNTS = {
    "customers": 300,
    "agents": 12,
    "policies": 385,
    "coverages": 1568,
}


def bootstrap():
    """One-time creation of the sentinel role and policy_admin database."""
    conn = psycopg2.connect(**MASTER_CONN_PARAMS)
    conn.autocommit = True
    cur = conn.cursor()

    app_user = os.environ.get("PG_APP_USER", "sentinel")
    app_password = os.environ.get("PG_APP_PASSWORD")

    cur.execute(
        f"DO $$ BEGIN "
        f"IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '{app_user}') THEN "
        f"CREATE ROLE {app_user} LOGIN PASSWORD '{app_password}'; "
        f"END IF; END $$;"
    )

    # Re-running bootstrap should always sync the role's password to whatever
    # is currently in .env, not just on first creation. Otherwise an existing
    # role silently keeps its original password forever, and future .env
    # changes go unnoticed until a connection fails with an auth error.
    cur.execute(f"ALTER ROLE {app_user} WITH PASSWORD '{app_password}';")
    print(f"Synced password for role {app_user} to current .env value.")

    # RDS quirk: master must grant the role to itself before it can
    # create a database owned by that role.
    cur.execute(f"GRANT {app_user} TO CURRENT_USER;")

    db_name = os.environ.get("PG_DB", "policy_admin")
    cur.execute(f"SELECT 1 FROM pg_database WHERE datname = '{db_name}';")
    if not cur.fetchone():
        cur.execute(f"CREATE DATABASE {db_name} OWNER {app_user};")
        print(f"Created database {db_name} owned by {app_user}.")
    else:
        print(f"Database {db_name} already exists, skipping.")

    cur.close()
    conn.close()
    print("Bootstrap complete.")


def create_tables(conn):
    cur = conn.cursor()
    for ddl in TABLE_DDL.values():
        cur.execute(ddl)

    # Safety net: if these tables were created by an earlier version of this
    # script (before updated_at was added), add the column now rather than
    # requiring a manual drop and recreate.
    for table_name in TABLE_DDL:
        cur.execute(
            f"ALTER TABLE {table_name} ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP;"
        )

    conn.commit()
    cur.close()
    print("Tables created (or already present, including updated_at backfill).")


def load_table(conn, table_name):
    csv_path = os.path.join(SOURCE_DIR, f"{table_name}.csv")
    if not os.path.exists(csv_path):
        raise FileNotFoundError(f"Expected source file not found: {csv_path}")

    cur = conn.cursor()
    with open(csv_path, "r") as f:
        header = f.readline().strip()
        columns = ", ".join(header.split(","))
        copy_sql = f"COPY {table_name} ({columns}) FROM STDIN WITH (FORMAT csv)"
        cur.copy_expert(copy_sql, f)
    conn.commit()

    cur.execute(f"SELECT COUNT(*) FROM {table_name};")
    count = cur.fetchone()[0]
    expected = EXPECTED_ROW_COUNTS.get(table_name)
    status = "OK" if count == expected else "MISMATCH"
    print(f"{table_name}: loaded {count} rows (expected {expected}) [{status}]")
    cur.close()


def reset_tables(conn):
    """Truncates all four tables in FK-safe order before a fresh load.
    Use when re-running the seed against a database that already has data,
    otherwise COPY hits primary key conflicts on the existing rows."""
    cur = conn.cursor()
    # Reverse dependency order: coverages and policies reference customers/
    # agents, so they must be cleared first.
    cur.execute("TRUNCATE TABLE coverages, policies, agents, customers;")
    conn.commit()
    cur.close()
    print("Truncated customers, agents, policies, coverages.")


def seed(reset=False):
    conn = psycopg2.connect(**APP_CONN_PARAMS)
    create_tables(conn)
    if reset:
        reset_tables(conn)
    for table in ["customers", "agents", "policies", "coverages"]:
        load_table(conn, table)
    conn.close()
    print("Seed complete.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Seed the policy admin database.")
    parser.add_argument(
        "--bootstrap",
        action="store_true",
        help="Run the one-time role and database bootstrap step first.",
    )
    parser.add_argument(
        "--reset",
        action="store_true",
        help="Truncate all four tables before loading. Use this when re-running "
        "the seed against a database that's already been seeded, otherwise "
        "COPY will fail with primary key conflicts on existing rows.",
    )
    args = parser.parse_args()

    if args.bootstrap:
        bootstrap()
    else:
        seed(reset=args.reset)