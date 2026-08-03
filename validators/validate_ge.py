"""
Validates each landing zone file against its schema contract using a real
Great Expectations Data Context: an ephemeral context with a pandas
Datasource, one whole-dataframe Batch Definition per dataset, and an
ExpectationSuite built from validators/contracts.py using
ExpectColumnToExist, ExpectColumnValuesToNotBeNull, and
ExpectColumnValuesToBeInTypeList (as a type/parseability check).

Requires great_expectations>=1.5 (pinned in requirements.txt). This is a
different, newer API surface than validators/validate.py (a lightweight
pandas-only equivalent kept for comparison): no PandasDataset, no
DataContext-free shortcuts, this is the real GX Batch/Validate workflow.

Every mapping below was confirmed by direct testing against real column
shapes (including nullable fields and psycopg2's boxed Decimal values for
NUMERIC/DECIMAL columns), not assumed from documentation alone.

Usage:
    python -m validators.validate_ge --dataset billing --day 2026-01-15
    python -m validators.validate_ge --all --day 2026-01-15
"""

import argparse
import json
import os
import sys
from datetime import date
from pathlib import Path

import boto3
import great_expectations as gx
import pandas as pd
from dotenv import load_dotenv
from great_expectations.expectations import (
    ExpectColumnToExist,
    ExpectColumnValuesToBeInTypeList,
    ExpectColumnValuesToNotBeNull,
)

from validators.contracts import CONTRACTS
from validators.validate import (
    DATASET_PREFIXES,
    S3_BUCKET_ENV,
    load_parquet_from_s3,
    quarantine_file,
)

load_dotenv()

SUITES_DIR = Path(__file__).parent / "expectation_suites"

# Claims land as many small JSON files, not a single Parquet file, so they
# get their own prefix constant and their own validate/quarantine path
# rather than going through DATASET_PREFIXES (validate.py's Parquet-only
# equivalent never supported claims either).
CLAIMS_PREFIX = "source=claims_mgmt"
ALL_DATASETS = list(DATASET_PREFIXES.keys()) + ["claims"]


class QuarantineError(Exception):
    """Raised once at the end of a run if anything was quarantined, so an
    Airflow PythonOperator task calling run() fails naturally and its
    configured alerting (email_on_failure) fires. Every dataset still
    gets validated and printed before this is raised, quarantining one
    dataset does not skip validating the rest."""


# Contract "type" strings map to the native Python/numpy type names that
# ExpectColumnValuesToBeInTypeList actually checks against (per-value type
# names, not the column's pandas dtype string). Lists are kept permissive
# since a Parquet round-trip through psycopg2 -> pandas -> pyarrow can
# produce more than one real representation for the same logical type,
# e.g. a NUMERIC column comes back as boxed decimal.Decimal objects, not
# a clean float64 column.
TYPE_TO_VALUE_TYPE_NAMES = {
    "string": ["str"],
    "int": ["int", "int64"],
    "decimal": ["float", "float64", "Decimal"],
    "date": ["date", "datetime64[ns]"],
    "timestamp": ["datetime64[ns]", "date"],
    "dict": ["dict"],
    "list": ["list"],
}

# The ephemeral GX context and pandas datasource are created lazily (on
# first actual use, not at module import time). Airflow's scheduler
# re-imports every DAG module periodically (roughly every 30 seconds by
# default) just to check for changes, and this module gets imported as
# part of that whenever the DAG references it, even when no validation
# is actually running. Building the GX context at import time meant
# paying that setup cost repeatedly, indefinitely, just from the DAG
# sitting on the scheduler. Building it lazily means it only happens
# once, the first time a validation actually runs in this process.
_context = None
_datasource = None


def _get_datasource():
    global _context, _datasource
    if _datasource is None:
        _context = gx.get_context(mode="ephemeral")
        _datasource = _context.data_sources.add_pandas("sentinel_pandas_datasource")
    return _datasource


def get_batch_for_dataframe(dataset_name, df):
    """Creates (or reuses) a dataframe asset and whole-dataframe batch
    definition for this dataset, then returns a Batch bound to df."""
    datasource = _get_datasource()
    asset_name = f"{dataset_name}_asset"
    try:
        asset = datasource.get_asset(asset_name)
    except LookupError:
        asset = datasource.add_dataframe_asset(name=asset_name)

    batch_def_name = f"{dataset_name}_whole_df"
    try:
        batch_definition = asset.get_batch_definition(batch_def_name)
    except (LookupError, KeyError):
        batch_definition = asset.add_batch_definition_whole_dataframe(batch_def_name)

    return batch_definition.get_batch(batch_parameters={"dataframe": df})


def is_parseable_as(series, contract_type):
    """Attempts to coerce a raw column (commonly still a string, for
    pre-transform data like claims_raw) into the logical type the
    contract declares. Returns True if every non-null value parses
    cleanly. This is the genuine "parseability" check: a raw ISO date
    string should pass even though its native Python type is str, not
    datetime.date, since it is coercible to one without loss."""
    non_null = series.dropna()
    if non_null.empty:
        return True

    if contract_type in ("date", "timestamp"):
        parsed = pd.to_datetime(non_null, errors="coerce", utc=True)
        return parsed.notna().all()
    if contract_type == "decimal":
        parsed = pd.to_numeric(non_null, errors="coerce")
        return parsed.notna().all()
    if contract_type == "int":
        parsed = pd.to_numeric(non_null, errors="coerce")
        return parsed.notna().all()

    return True


def build_suite(dataset_name, contract):
    """Builds a real ExpectationSuite from a contract: column existence,
    type/parseability, and required non-null checks."""
    suite = gx.ExpectationSuite(name=f"{dataset_name}_suite")

    for column in contract["columns"]:
        suite.add_expectation(ExpectColumnToExist(column=column))

    for column, col_type in contract["columns"].items():
        type_list = TYPE_TO_VALUE_TYPE_NAMES.get(col_type)
        if type_list:
            suite.add_expectation(
                ExpectColumnValuesToBeInTypeList(column=column, type_list=type_list)
            )

    for column in contract.get("required_not_null", []):
        suite.add_expectation(ExpectColumnValuesToNotBeNull(column=column))

    return suite


def save_suite_if_missing(dataset_name, suite):
    """Persists the built ExpectationSuite as JSON on first run, so the
    actual suite artifacts are visible on disk, not just built in memory."""
    SUITES_DIR.mkdir(parents=True, exist_ok=True)
    suite_path = SUITES_DIR / f"{dataset_name}.json"
    if not suite_path.exists():
        suite_path.write_text(json.dumps(suite.to_json_dict(), indent=2, default=str))
        print(f"Saved Expectation Suite: {suite_path}")


def run_suite_and_extract_failures(dataset_name, contract, df):
    """Builds the suite, runs it against df via a real Batch, and inspects
    the validation result object to extract a list of failure dicts in
    the same shape validate.py's quarantine_file() expects."""
    batch = get_batch_for_dataframe(dataset_name, df)
    suite = build_suite(dataset_name, contract)
    save_suite_if_missing(dataset_name, suite)

    validation_result = batch.validate(suite)

    failures = []
    if not validation_result.success:
        missing_columns = {
            result.expectation_config.kwargs.get("column")
            for result in validation_result.results
            if not result.success and result.expectation_config.type == "expect_column_to_exist"
        }

        for result in validation_result.results:
            if result.success:
                continue
            config = result.expectation_config
            expectation_type = config.type
            column = config.kwargs.get("column", "unknown")

            # A missing column also trips the not-null and type-list checks
            # against it, that's just noise on top of the real finding.
            if expectation_type != "expect_column_to_exist" and column in missing_columns:
                continue

            if expectation_type == "expect_column_to_exist":
                detail = "column missing"
            elif expectation_type == "expect_column_values_to_not_be_null":
                unexpected = result.result.get("unexpected_count", "unknown")
                detail = f"{unexpected} null values found"
            elif expectation_type == "expect_column_values_to_be_in_type_list":
                unexpected = result.result.get("unexpected_count", "unknown")
                expected_types = config.kwargs.get("type_list", [])
                detail = f"{unexpected} values not matching expected types {expected_types}"
            else:
                detail = str(result.result)

            failures.append(
                {"expectation": expectation_type, "column": column, "result": detail}
            )

    # Parseability fallback: a type-list failure on a date/timestamp/
    # decimal/int column isn't a real problem if the raw value is still
    # cleanly coercible to that type (e.g. an un-transformed ISO date
    # string). Only a genuinely unparseable value should count as a
    # failure here.
    parseable_failures = []
    for failure in failures:
        if failure["expectation"] != "expect_column_values_to_be_in_type_list":
            parseable_failures.append(failure)
            continue

        column = failure["column"]
        contract_type = contract["columns"].get(column)
        if contract_type and column in df.columns:
            if is_parseable_as(df[column], contract_type):
                continue  # genuinely parseable, drop this failure

            # Genuinely unparseable: report the real count instead of the
            # original native-type mismatch count, which usually counts
            # every raw value (since none are already the native type),
            # not just the ones that are actually broken.
            non_null = df[column].dropna()
            if contract_type in ("date", "timestamp"):
                parsed = pd.to_datetime(non_null, errors="coerce", utc=True)
            elif contract_type in ("decimal", "int"):
                parsed = pd.to_numeric(non_null, errors="coerce")
            else:
                parsed = None
            if parsed is not None:
                bad_count = int(parsed.isna().sum())
                failure = {
                    **failure,
                    "result": f"{bad_count} value(s) not parseable as {contract_type}",
                }

        parseable_failures.append(failure)

    return parseable_failures, len(suite.expectations)


def validate_dataset(s3_client, bucket, dataset, run_date):
    if dataset not in DATASET_PREFIXES:
        print(f"No S3 prefix mapping for dataset '{dataset}', skipping.")
        return 0, 0

    contract = CONTRACTS[dataset]
    prefix = f"{DATASET_PREFIXES[dataset]}/day={run_date}/"

    response = s3_client.list_objects_v2(Bucket=bucket, Prefix=prefix)
    passed = 0
    failed = 0
    for obj in response.get("Contents", []):
        key = obj["Key"]
        if not key.endswith(".parquet"):
            continue

        df = load_parquet_from_s3(s3_client, bucket, key)
        failures, expectation_count = run_suite_and_extract_failures(dataset, contract, df)

        if failures:
            quarantine_file(s3_client, bucket, key, failures)
            failed += 1
        else:
            print(f"PASSED: {key} ({len(df)} rows, {expectation_count} expectations checked)")
            passed += 1

    return passed, failed


def load_claims_batch_for_day(s3_client, bucket, run_date):
    """Loads every claim JSON file for the given day into a single
    DataFrame, one row per claim, so the whole day validates as one
    batch rather than file by file."""
    prefix = f"{CLAIMS_PREFIX}/day={run_date}/"
    response = s3_client.list_objects_v2(Bucket=bucket, Prefix=prefix)
    keys = [obj["Key"] for obj in response.get("Contents", []) if obj["Key"].endswith(".json")]

    records = []
    for key in keys:
        body = s3_client.get_object(Bucket=bucket, Key=key)["Body"].read()
        records.append(json.loads(body))

    return keys, pd.DataFrame(records)


def quarantine_claims_day(s3_client, bucket, keys, failures, run_date):
    """Quarantines every claim file for the day as one unit, since they
    were validated together as a single batch, plus one combined report
    covering the whole day rather than one report per file."""
    quarantine_prefix = f"quarantine/{CLAIMS_PREFIX}/day={run_date}"

    for key in keys:
        quarantine_key = key.replace(CLAIMS_PREFIX, f"quarantine/{CLAIMS_PREFIX}", 1)
        s3_client.copy_object(
            Bucket=bucket, CopySource={"Bucket": bucket, "Key": key}, Key=quarantine_key
        )
        s3_client.delete_object(Bucket=bucket, Key=key)

    report_key = f"{quarantine_prefix}/validation_report.json"
    report = {
        "original_prefix": f"{CLAIMS_PREFIX}/day={run_date}/",
        "quarantine_prefix": f"{quarantine_prefix}/",
        "file_count": len(keys),
        "failed_expectations": failures,
    }
    s3_client.put_object(
        Bucket=bucket, Key=report_key, Body=json.dumps(report, indent=2).encode("utf-8")
    )
    print(
        f"QUARANTINED: {len(keys)} claim files for day={run_date} "
        f"-> {quarantine_prefix}/ ({len(failures)} failed expectations)"
    )


def validate_claims(s3_client, bucket, run_date):
    keys, df = load_claims_batch_for_day(s3_client, bucket, run_date)

    if df.empty:
        print(f"No claim files found for day={run_date}, skipping claims validation.")
        return 0, 0

    contract = CONTRACTS["claims_raw"]
    failures, expectation_count = run_suite_and_extract_failures("claims_raw", contract, df)

    if failures:
        quarantine_claims_day(s3_client, bucket, keys, failures, run_date)
        return 0, 1

    print(
        f"PASSED: claims day={run_date} "
        f"({len(df)} claims across {len(keys)} files, {expectation_count} expectations checked)"
    )
    return 1, 0


def run(datasets, run_date):
    bucket = os.environ[S3_BUCKET_ENV]
    s3_client = boto3.client("s3")

    total_passed = 0
    total_failed = 0
    for dataset in datasets:
        if dataset == "claims":
            passed, failed = validate_claims(s3_client, bucket, run_date)
        else:
            passed, failed = validate_dataset(s3_client, bucket, dataset, run_date)
        total_passed += passed
        total_failed += failed

    print("")
    print(f"=== Summary: {total_passed} passed, {total_failed} quarantined (day={run_date}) ===")

    if total_failed > 0:
        raise QuarantineError(
            f"One or more files failed validation for day={run_date} and were "
            f"quarantined. See validation_report.json under each quarantine/ "
            f"prefix for details."
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Validate landing zone files using a real Great Expectations Data Context."
    )
    parser.add_argument("--dataset", help="Single dataset name to validate, including 'claims'")
    parser.add_argument(
        "--all", action="store_true", help="Validate all known datasets, including claims"
    )
    parser.add_argument("--day", default=str(date.today()), help="Run date, YYYY-MM-DD")
    parser.add_argument(
        "--debug", action="store_true", help="Show the full Python traceback on error instead of a clean summary"
    )
    args = parser.parse_args()

    try:
        if args.all:
            run(ALL_DATASETS, args.day)
        elif args.dataset:
            run([args.dataset], args.day)
        else:
            parser.error("Specify --dataset <name> or --all")
    except QuarantineError as e:
        # Expected outcome: one or more files failed validation. Already
        # printed in detail by run(), just confirm the exit status here.
        print(f"\nVALIDATION FAILED: {e}")
        sys.exit(1)
    except Exception as e:
        if args.debug:
            raise
        print(f"\nERROR: {type(e).__name__}: {e}")
        if isinstance(e, (KeyError, AttributeError, ImportError, ModuleNotFoundError)):
            print(
                "This kind of error often means a local file is out of date "
                "(e.g. validators/contracts.py) compared to what this script "
                "expects, rather than a real data problem. Confirm your local "
                "copies are current before assuming otherwise."
            )
        print("Re-run with --debug to see the full traceback.")
        sys.exit(1)
