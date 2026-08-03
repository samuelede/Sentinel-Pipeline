"""
One-time script to register your RSA public key on your Snowflake user,
without needing to navigate the Snowsight UI. Uses the "externalbrowser"
authenticator, which opens your default browser for a fully interactive
login (completing MFA there), then runs the ALTER USER command directly.

IMPORTANT: this only works if your Snowflake account uses SSO/SAML
federation (Okta, ADFS, Azure AD, etc.) as its identity provider. If your
account uses Snowflake's native MFA (Duo push, TOTP) instead, this will
fail with an error like "error related to the SAML Identity Provider
account parameter", that means this script is the wrong tool for your
account, not that something is misconfigured. In that case, skip this
script and instead log directly into Snowsight in your browser
(https://<your-account>.snowflakecomputing.com), which handles native MFA
correctly, and run the ALTER USER command there in a SQL worksheet. See
docs/snowflake_setup.md step 3 for the exact steps.

Usage:
    python scripts/register_snowflake_key.py

You will be prompted for your account identifier and username, then your
browser will open for you to log in and approve MFA as usual. Once that
completes, the script reads your public key file and registers it.
"""

import getpass
from pathlib import Path

import snowflake.connector

PUBLIC_KEY_PATH = Path.home() / ".snowsql" / "snowflake_rsa_key.pub"


def read_public_key_body(path):
    lines = path.read_text().splitlines()
    body_lines = [
        line for line in lines
        if "BEGIN PUBLIC KEY" not in line and "END PUBLIC KEY" not in line
    ]
    return "".join(body_lines)


def main():
    if not PUBLIC_KEY_PATH.exists():
        raise SystemExit(
            f"Public key not found at {PUBLIC_KEY_PATH}. Generate it first with the "
            f"openssl commands in docs/snowflake_setup.md."
        )

    account = input("Snowflake account identifier (e.g. AIUJURL-KX11380): ").strip()
    username = input("Snowflake username: ").strip()

    print("")
    print("Note: this only works for SSO/SAML-federated accounts (Okta, ADFS, etc.).")
    print("If your account uses native MFA (Duo push, TOTP), this will fail, that's")
    print("expected, use direct Snowsight browser login instead (see docs/snowflake_setup.md).")
    print("")
    print("Opening your browser to complete login and MFA...")
    conn = snowflake.connector.connect(
        account=account,
        user=username,
        authenticator="externalbrowser",
    )

    public_key_body = read_public_key_body(PUBLIC_KEY_PATH)

    cur = conn.cursor()
    cur.execute(f"ALTER USER {username} SET RSA_PUBLIC_KEY='{public_key_body}';")
    print(f"Public key registered on user {username}.")
    cur.close()
    conn.close()


if __name__ == "__main__":
    main()