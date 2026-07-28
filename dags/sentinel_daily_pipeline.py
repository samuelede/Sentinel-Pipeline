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

from extractors import extract_policy_admin, extract_claims, extract_billing, extract_weather
from validators import validate
from transformers import (
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
        python_callable=lambda **ctx: validate.run(
            ["customers", "agents", "policies", "coverages", "billing", "weather"],
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
    copy_into_staging_task = BashOperator(
        task_id="copy_into_staging",
        bash_command=(
            "snowsql -f sql/merge/copy_into_staging.sql "
            "-D RUN_DATE={{ ds }}"
        ),
    )

    merge_warehouse_task = BashOperator(
        task_id="merge_dimensions_and_fact",
        bash_command="snowsql -f sql/merge/merge_dimensions_and_fact.sql",
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
