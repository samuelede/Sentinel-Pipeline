# Pulling Source Data: Drive to Local to S3

Gets source data from the shared Google Drive folder into `source_systems/`, then into the S3 landing zone via the extractors.

**Default: manual download.** The automatic option (`pull_source_data.py`) exists but has repeatedly failed partway through in practice with `FileURLRetrievalError`, Google Drive rate-limits anonymous downloads on large folders (the claims folder alone is 300+ files), and this isn't a one-off, it's happened multiple times on this project. Manual download uses your logged-in Google session instead of anonymous access, so it doesn't hit that limit at all.

| | Manual (default) | Automatic |
|---|---|---|
| Best for | Everything, this is the default | Only if you've confirmed it works reliably in your environment |
| Why | Uses your logged-in Google session, no rate limit | Runs through `gdown`'s anonymous access, which Drive throttles, this has broken repeatedly in practice |
| Resumable | Yes, retry just the folder that failed | No, a failed run restarts from nothing |

## Manual download (default)

1. Open the shared Drive folder in your browser, logged in.
2. Download the folder (or each subfolder: `policy_admin/`, `billing_exports/`, `sftp_claim_source/`), Drive zips it client-side.
3. Extract and copy into `source_systems/`, keeping `billing_exports/` and `sftp_claim_source/` structure intact (don't flatten the claims quarter/day folders).
4. Flatten the policy admin CSVs to the top level, since the seed script expects them there directly:
   ```bash
   mv source_systems/policy_admin/*.csv source_systems/
   rmdir source_systems/policy_admin
   ```
5. Verify:
   ```bash
   ls source_systems/
   find source_systems/sftp_claim_source -name "*.json" | wc -l
   ```

## Automatic download (not recommended, kept for reference)

```bash
pip install gdown   # already in requirements.txt
python scripts/pull_source_data.py
```

This flattens the policy admin CSVs for you automatically, when it works. In practice it has repeatedly failed partway through the claims folder with `FileURLRetrievalError`, this is Drive's rate limit, not a permissions bug, and it doesn't resolve by retrying immediately, a retry restarts the whole download from scratch rather than resuming. Given how often this has broken, default to the manual option above instead of troubleshooting this further.

To pull everything but only organize one part afterward (if you do use it):
```bash
python scripts/pull_source_data.py --only policy_admin
python scripts/pull_source_data.py --only billing
python scripts/pull_source_data.py --only claims
```

Note: there's a separately shared "2026 Q1 SFTP data" link that hasn't been confirmed as distinct from `sftp_claim_source`, it may be redundant, worth checking with the team lead.

## Next: seed and extract

Once the pull looks right:

```bash
python scripts/seed_policy_admin_db.py
python extractors/extract_policy_admin.py --day 2026-01-15
python extractors/extract_claims.py
python extractors/extract_billing.py
python extractors/extract_weather.py --day 2026-01-15
```

`./scripts/sync_source_to_s3.sh` also exists and chains a pull with the seed and extractors, but it always uses the automatic pull internally, given that keeps failing, prefer running the steps above manually after a browser download instead.

Verify in S3:

```bash
aws s3 ls s3://sentinel-landing --recursive
```

You should see partitions under `source=policy_admin/`, `source=claims_mgmt/`, `source=billing/`, and `source=weather_api/`.

## When neither applies

This Drive-pull flow, manual or automatic, is a stand-in for the real source systems during development. Once the pipeline points at Sentinel's actual policy admin database, claims SFTP drop, and billing export, none of this is needed.

