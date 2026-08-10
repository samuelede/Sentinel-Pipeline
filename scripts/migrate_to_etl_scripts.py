#!/usr/bin/env python3
"""
One-time migration: moves extractors/, validators/, transformers/ into
dags/etl_scripts/, and rewrites every import that referenced them.

Why: MWAA only puts the dags/ folder itself on sys.path, not the repo
root. The current top-level extractors/validators/transformers layout
works for local Docker (which sets PYTHONPATH to the whole repo) but
would fail to import at all on real MWAA. Consolidating into a single
etl_scripts package inside dags/ matches how MWAA actually resolves
imports, with no packaging step needed at deploy time.

This uses `git mv` (not a plain move), so file history is preserved.
Review the diff before committing, this is a mechanical migration but
worth a human look, especially at any import it couldn't confidently
rewrite (printed at the end under "Needs manual review").

Usage:
    python scripts/migrate_to_etl_scripts.py
"""

import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PACKAGES = ["extractors", "validators", "transformers"]
DAGS_DIR = REPO_ROOT / "dags"
ETL_SCRIPTS_DIR = DAGS_DIR / "etl_scripts"

# Matches "from extractors" / "from extractors.x" / "import extractors"
# for each of the three package names, so every reference gets the
# etl_scripts. prefix regardless of exact current import style.
IMPORT_PATTERN = re.compile(
    r"(?P<prefix>from|import)\s+(?P<pkg>" + "|".join(PACKAGES) + r")(?P<rest>\b)"
)


def run(cmd, check=True):
    print(f"  $ {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=REPO_ROOT, capture_output=True, text=True)
    if result.stdout.strip():
        print(f"    {result.stdout.strip()}")
    if check and result.returncode != 0:
        print(f"    ERROR: {result.stderr.strip()}")
        sys.exit(1)
    return result


def move_packages():
    print("== Moving packages into dags/etl_scripts/ ==")
    ETL_SCRIPTS_DIR.mkdir(parents=True, exist_ok=True)
    for pkg in PACKAGES:
        src = REPO_ROOT / pkg
        dst = ETL_SCRIPTS_DIR / pkg
        if not src.exists():
            print(f"  {pkg}/ not found at repo root, skipping (already migrated?)")
            continue
        if dst.exists():
            print(f"  {dst} already exists, skipping {pkg}/")
            continue
        run(["git", "mv", str(src.relative_to(REPO_ROOT)), str(dst.relative_to(REPO_ROOT))])

    init_file = ETL_SCRIPTS_DIR / "__init__.py"
    if not init_file.exists():
        init_file.write_text("")
        run(["git", "add", str(init_file.relative_to(REPO_ROOT))])
        print(f"  Created {init_file.relative_to(REPO_ROOT)}")


def fix_imports_in_file(path: Path, changed_files: list, needs_review: list):
    text = path.read_text()
    original = text

    def replace(match):
        prefix, pkg, rest = match.group("prefix"), match.group("pkg"), match.group("rest")
        if prefix == "from":
            return f"from etl_scripts.{pkg}{rest}"
        else:
            # bare "import extractors" -> keep the name usable unqualified
            return f"import etl_scripts.{pkg}{rest} as {pkg}"

    text = IMPORT_PATTERN.sub(replace, text)

    if text != original:
        path.write_text(text)
        changed_files.append(path)

    # Flag anything that still mentions the old package names in a way
    # this script's pattern might not have caught (e.g. importlib,
    # dynamic imports, string references), for a human to check.
    for pkg in PACKAGES:
        if re.search(rf"\b{pkg}\b", text) and "etl_scripts" not in text.split(pkg)[0][-40:]:
            if path not in needs_review:
                needs_review.append(path)


def fix_imports():
    print("\n== Fixing imports ==")
    changed_files, needs_review = [], []

    targets = list(ETL_SCRIPTS_DIR.rglob("*.py"))
    dag_file = DAGS_DIR / "sentinel_daily_pipeline.py"
    if dag_file.exists():
        targets.append(dag_file)

    for path in targets:
        fix_imports_in_file(path, changed_files, needs_review)

    print(f"  Rewrote imports in {len(changed_files)} file(s):")
    for f in changed_files:
        print(f"    {f.relative_to(REPO_ROOT)}")

    if needs_review:
        print("\n  Needs manual review (still mentions a package name, check it's not stale):")
        for f in needs_review:
            print(f"    {f.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    if not (REPO_ROOT / "dags").exists():
        print("Run this from the repo root (dags/ not found).")
        sys.exit(1)

    move_packages()
    fix_imports()

    print("\nDone. Now:")
    print("  1. git diff --stat   (review what changed)")
    print("  2. Update docker-compose.airflow.yml's PYTHONPATH, see docs/mwaa_deploy.md")
    print("  3. Test locally before pushing: docker compose -f docker-compose.airflow.yml restart airflow")
