"""
Sentinel daily data pipeline DAG.

Runs four parallel extractors (policy admin, claims, billing, weather),
validates each landing dataset, transforms validated data to the
processed zone, then loads the processed zone into Snowflake via
COPY INTO and MERGE.

Parameterized on Airflow's execution_date so any historical day can be
backfilled with a single command:

    airflow dags trigger sentinel_daily_pipeline -e 2026-01-15
"""

from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.operators.bash import BashOperator
from airflow.utils.trigger_rule import TriggerRule

from etl_scripts.extractors import extract_policy_admin, extract_claims, extract_billing, extract_weather
from etl_scripts.validators import validate_ge
from etl_scripts.transformers import (
    transform_claims,
    transform_policy_admin,
    transform_billing,
    transform_weather,
)

default_args = {
    "owner": "data-engineering",
    "retries": 3,
    "retry_delay": timedelta(minutes=5),
    "email_on_failure": True,
    "email": ["data-eng-alerts@sentinelauto.example"],
}

with DAG(
    dag_id="sentinel_daily_pipeline",
    default_args=default_args,
    description="Extract, validate, transform, and load Sentinel's four source systems into Snowflake.",
    schedule_interval="@daily",
    start_date=datetime(2026, 1, 1),
    catchup=True,
    max_active_runs=1,
    tags=["sentinel", "warehouse"],
) as dag:

    def _run_date(context):
        return context["ds"]

    # ---- Extraction (runs in parallel across sources) ----
    extract_policy_admin_task = PythonOperator(
        task_id="extract_policy_admin",
        python_callable=lambda **ctx: extract_policy_admin.run(_run_date(ctx)),
    )

    extract_claims_task = PythonOperator(
        task_id="extract_claims",
        python_callable=lambda **ctx: extract_claims.run(),
    )

    extract_billing_task = PythonOperator(
        task_id="extract_billing",
        python_callable=lambda **ctx: extract_billing.run(),
    )

    extract_weather_task = PythonOperator(
        task_id="extract_weather",
        python_callable=lambda **ctx: extract_weather.run(_run_date(ctx)),
    )

    # ---- Validation ----
    validate_task = PythonOperator(
        task_id="validate_landing_zone",
        python_callable=lambda **ctx: validate_ge.run(
            validate_ge.ALL_DATASETS,
            _run_date(ctx),
        ),
    )

    # ---- Transformation ----
    transform_policy_admin_task = PythonOperator(
        task_id="transform_policy_admin",
        python_callable=lambda **ctx: transform_policy_admin.run(_run_date(ctx)),
    )

    transform_claims_task = PythonOperator(
        task_id="transform_claims",
        python_callable=lambda **ctx: transform_claims.run(_run_date(ctx)),
    )

    transform_billing_task = PythonOperator(
        task_id="transform_billing",
        python_callable=lambda **ctx: transform_billing.run(_run_date(ctx)),
    )

    transform_weather_task = PythonOperator(
        task_id="transform_weather",
        python_callable=lambda **ctx: transform_weather.run(_run_date(ctx)),
    )

    # ---- Snowflake load ----
    # cwd is required here: BashOperator runs its command from a fresh
    # temp directory by default (visible in task logs as "Tmp dir root
    # location: /tmp"), not from the container's working_dir, so the
    # relative sql/merge/... paths below would otherwise fail with
    # "No such file or directory" regardless of what working_dir is set
    # to in docker-compose.airflow.yml.
    #
    # trigger_rule=ALL_DONE (not the default ALL_SUCCESS): if one
    # source has no data for this day (a normal, expected condition in
    # this environment, e.g. billing and claims only exist for
    # different, non-overlapping date ranges), its transform task
    # exits non-zero and Airflow marks it failed. With the default
    # trigger rule, that alone would block this task from running at
    # all, meaning ANY single missing source blocks the whole day's
    # warehouse load even for sources that DO have data. ALL_DONE lets
    # this proceed once every upstream task has finished, regardless of
    # outcome. Snowflake's COPY INTO already handles an empty S3 prefix
    # gracefully (loads 0 rows, doesn't error), so the sources that did
    # have data still load correctly, only the missing one's staging
    # table simply doesn't get new rows that day.
    # -o exit_on_error=true is required: by default, snowsql does NOT
    # exit with a non-zero code just because a SQL statement inside the
    # script errored, it prints the error and keeps going, then still
    # exits 0. Without this flag, a genuine COPY INTO/MERGE failure
    # would show up as a false "success" in Airflow, exactly like
    # copy_into_staging did here.
    copy_into_staging_task = BashOperator(
        task_id="copy_into_staging",
        bash_command=(
            "snowsql -c sentinel -o exit_on_error=true -o variable_substitution=true "
            "-f sql/merge/copy_into_staging.sql -D RUN_DATE={{ ds }}"
        ),
        cwd="/opt/airflow/project",
        trigger_rule=TriggerRule.ALL_DONE,
    )

    merge_warehouse_task = BashOperator(
        task_id="merge_dimensions_and_fact",
        bash_command="snowsql -c sentinel -o exit_on_error=true -f sql/merge/merge_dimensions_and_fact.sql",
        cwd="/opt/airflow/project",
    )

    # ---- Dependencies ----
    [
        extract_policy_admin_task,
        extract_claims_task,
        extract_billing_task,
        extract_weather_task,
    ] >> validate_task

    validate_task >> transform_policy_admin_task
    validate_task >> transform_claims_task
    validate_task >> transform_billing_task
    validate_task >> transform_weather_task

    [
        transform_policy_admin_task,
        transform_claims_task,
        transform_billing_task,
        transform_weather_task,
    ] >> copy_into_staging_task >> merge_warehouse_task
