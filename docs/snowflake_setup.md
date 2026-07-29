# Snowflake Connection Setup

Configures `snowsql` so `sql/ddl/` and `sql/merge/` scripts can connect. Note: `.env`'s `SNOWFLAKE_*` values are not read by `snowsql`, that file is a separate `python-dotenv` convention; `snowsql` reads its own config below.

## 1. Install snowsql

No winget/chocolatey package, use the official installer:

1. Download `snowsql-<version>-windows_x86_64.msi` from `https://docs.snowflake.com/en/user-guide/snowsql-install-config`.
2. Run the installer (defaults are fine).
3. **Close and reopen your terminal** (PATH won't update in an already-open one).
4. Confirm: `snowsql -v`. If `command not found`, add it manually:
   ```bash
   echo 'export PATH="/c/Program Files/Snowflake SnowSQL:$PATH"' >> ~/.bashrc && source ~/.bashrc
   ```

## 2. Get your connection details

- **Account identifier**: log into Snowsight and copy the exact string between `https://` and `.snowflakecomputing.com`. Newer accounts look like `MYORG-MYACCOUNT` (e.g. `AIUJURL-KX11380`), don't guess a region suffix.
- **Username**: your Snowflake login.
- **Auth method**: password, or key pair if MFA is enabled (common on trial accounts). Password auth will fail with `MFA authentication is required...` if so, use key-pair below instead.

## 3. Configure `~/.snowsql/config`

**No MFA:**
```bash
mkdir -p ~/.snowsql
cat > ~/.snowsql/config << 'EOF'
[connections.sentinel]
accountname = MYORG-MYACCOUNT
username = your_snowflake_username
password = your_snowflake_password
warehousename = SENTINEL_WH
dbname = SENTINEL_DB
schemaname = ANALYTICS
EOF
```

**MFA enabled:** use a key pair instead, since `snowsql` can't complete an interactive MFA challenge.

1. Generate the key pair:
   ```bash
   openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out ~/.snowsql/snowflake_rsa_key.p8 -nocrypt
   openssl rsa -in ~/.snowsql/snowflake_rsa_key.p8 -pubout -out ~/.snowsql/snowflake_rsa_key.pub
   ```
2. Get the public key body: `grep -v "BEGIN PUBLIC KEY\|END PUBLIC KEY" ~/.snowsql/snowflake_rsa_key.pub | tr -d '\n'`
3. Register it: log directly into Snowsight in your browser (`https://<account>.snowflakecomputing.com`), approve MFA there (browser login handles it, `snowsql` can't), open a SQL worksheet, and run:
   ```sql
   ALTER USER your_snowflake_username SET RSA_PUBLIC_KEY='<paste key body here>';
   ```
   `scripts/register_snowflake_key.py` is an alternative, but only works for SSO/SAML-federated accounts, not native MFA (Duo/TOTP), if you see a SAML-related error from it, use the browser method above instead.
4. Point `snowsql` at the key:
   ```bash
   cat > ~/.snowsql/config << 'EOF'
   [connections.sentinel]
   accountname = MYORG-MYACCOUNT
   username = your_snowflake_username
   private_key_path = ~/.snowsql/snowflake_rsa_key.p8
   warehousename = SENTINEL_WH
   dbname = SENTINEL_DB
   schemaname = ANALYTICS
   EOF
   ```

`warehousename`/`dbname`/`schemaname` don't need to exist yet, step 5 creates them. Never commit `~/.snowsql/`, it's outside the repo.

## 4. Verify the connection

```bash
snowsql -c sentinel -q "SELECT CURRENT_VERSION();"
```

Should print a version and exit cleanly, no prompts. Fix any error here before continuing.

(To connect interactively instead: `snowsql -c sentinel`, exit with `!exit`, not `\q`/`quit`/`exit`, those aren't `snowsql` commands and will error.)

## 5. Create the warehouse, database, and tables

```bash
snowsql -c sentinel -f sql/ddl/create_warehouse_and_database.sql
snowsql -c sentinel -f sql/ddl/create_tables.sql
snowsql -c sentinel -f sql/ddl/create_stage.sql
```

The first script must run first, the other two assume `SENTINEL_WH`/`SENTINEL_DB` already exist. It creates an `XSMALL` warehouse that starts suspended and auto-suspends after 60 seconds idle, so it won't rack up cost sitting unused.

To drop `-c sentinel` from these commands, set a default connection once: add `[connections]` / `default = sentinel` to `~/.snowsql/config`.

## 6. If you're also running Airflow via Docker and use key-pair auth

`docker-compose.airflow.yml` mounts your Snowflake config into the container so the DAG's `snowsql` tasks work too. If you're on key-pair auth (step 3 above), your native config's `private_key_path` is a Windows path (e.g. `C:/Users/.../snowflake_rsa_key.p8`), which doesn't exist inside the Linux container. Create a second config just for Docker, identical except for that one line:

```bash
cat > ~/.snowsql/config.docker << 'EOF'
[connections.sentinel]
accountname = MYORG-MYACCOUNT
username = your_snowflake_username
private_key_path = /home/airflow/.snowsql/snowflake_rsa_key.p8
warehousename = SENTINEL_WH
dbname = SENTINEL_DB
schemaname = ANALYTICS
EOF
```

`docker-compose.airflow.yml` already mounts `config.docker` (not your native `config`) into the container, so this file just needs to exist with matching values. On password auth (no MFA)? Skip this, your native config works as-is since there's no OS-specific path involved.

## 7. Before `create_stage.sql` actually works

It references a storage integration needing a real IAM trust relationship with AWS, a two-phase process (create the integration, then use Snowflake-generated values to build the IAM role). See [`snowflake_s3_integration.md`](snowflake_s3_integration.md) for the full walkthrough.
