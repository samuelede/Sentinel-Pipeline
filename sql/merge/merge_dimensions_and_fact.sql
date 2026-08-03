-- Merges staging tables into the dimensional warehouse tables, keyed on
-- natural primary keys. Run after copy_into_staging.sql.

MERGE INTO dim_customer AS target
USING staging.stg_customers AS source
ON target.customer_id = source.customer_id
WHEN MATCHED THEN UPDATE SET
    first_name = source.first_name,
    last_name = source.last_name,
    dob = source.dob,
    email = source.email,
    phone = source.phone,
    address = source.address,
    city = source.city,
    state = source.state,
    zip_code = source.zip_code
WHEN NOT MATCHED THEN INSERT (
    customer_id, first_name, last_name, dob, email, phone,
    address, city, state, zip_code, created_at
) VALUES (
    source.customer_id, source.first_name, source.last_name, source.dob,
    source.email, source.phone, source.address, source.city, source.state,
    source.zip_code, source.created_at
);

MERGE INTO dim_agent AS target
USING staging.stg_agents AS source
ON target.agent_id = source.agent_id
WHEN MATCHED THEN UPDATE SET
    agent_name = source.agent_name,
    territory = source.territory,
    hire_date = source.hire_date,
    license_number = source.license_number
WHEN NOT MATCHED THEN INSERT (
    agent_id, agent_name, territory, hire_date, license_number
) VALUES (
    source.agent_id, source.agent_name, source.territory, source.hire_date,
    source.license_number
);

MERGE INTO dim_policy AS target
USING staging.stg_policies AS source
ON target.policy_id = source.policy_id
WHEN MATCHED THEN UPDATE SET
    customer_id = source.customer_id,
    agent_id = source.agent_id,
    policy_number = source.policy_number,
    coverage_type = source.coverage_type,
    start_date = source.start_date,
    end_date = source.end_date,
    premium_amount = source.premium_amount,
    status = source.status
WHEN NOT MATCHED THEN INSERT (
    policy_id, customer_id, agent_id, policy_number, coverage_type,
    start_date, end_date, premium_amount, status, created_at
) VALUES (
    source.policy_id, source.customer_id, source.agent_id, source.policy_number,
    source.coverage_type, source.start_date, source.end_date, source.premium_amount,
    source.status, source.created_at
);

MERGE INTO dim_coverage AS target
USING staging.stg_coverages AS source
ON target.coverage_id = source.coverage_id
WHEN MATCHED THEN UPDATE SET
    policy_id = source.policy_id,
    coverage_code = source.coverage_code,
    coverage_limit = source.coverage_limit,
    deductible = source.deductible
WHEN NOT MATCHED THEN INSERT (
    coverage_id, policy_id, coverage_code, coverage_limit, deductible
) VALUES (
    source.coverage_id, source.policy_id, source.coverage_code,
    source.coverage_limit, source.deductible
);

MERGE INTO claims_fact AS target
USING staging.stg_claims_fact AS source
ON target.claim_id = source.claim_id
WHEN MATCHED THEN UPDATE SET
    claim_status = source.claim_status,
    claim_amount = source.claim_amount,
    approved_amount = source.approved_amount,
    description = source.description
WHEN NOT MATCHED THEN INSERT (
    claim_id, policy_id, customer_id, incident_date, report_date,
    incident_zip, incident_type, claim_status, claim_amount,
    approved_amount, description, created_at
) VALUES (
    source.claim_id, source.policy_id, source.customer_id, source.incident_date,
    source.report_date, source.incident_zip, source.incident_type, source.claim_status,
    source.claim_amount, source.approved_amount, source.description, source.created_at
);

MERGE INTO payments AS target
USING staging.stg_payments AS source
ON target.payment_id = source.payment_id
WHEN MATCHED THEN UPDATE SET
    payment_amount = source.payment_amount,
    payment_type = source.payment_type,
    adjuster_id = source.adjuster_id
WHEN NOT MATCHED THEN INSERT (
    payment_id, claim_id, payment_date, payment_amount, payment_type, adjuster_id
) VALUES (
    source.payment_id, source.claim_id, source.payment_date, source.payment_amount,
    source.payment_type, source.adjuster_id
);

MERGE INTO weather_daily AS target
USING staging.stg_weather_daily AS source
ON target.weather_date = source.weather_date AND target.zip_code = source.zip_code
WHEN MATCHED THEN UPDATE SET
    precipitation_mm = source.precipitation_mm,
    max_wind_kmh = source.max_wind_kmh,
    max_temp_c = source.max_temp_c,
    min_temp_c = source.min_temp_c,
    weather_code = source.weather_code,
    severity = source.severity
WHEN NOT MATCHED THEN INSERT (
    weather_date, zip_code, precipitation_mm, max_wind_kmh, max_temp_c,
    min_temp_c, weather_code, severity
) VALUES (
    source.weather_date, source.zip_code, source.precipitation_mm, source.max_wind_kmh,
    source.max_temp_c, source.min_temp_c, source.weather_code, source.severity
);

MERGE INTO billing_transactions AS target
USING staging.stg_billing_transactions AS source
ON target.transaction_id = source.transaction_id
WHEN MATCHED THEN UPDATE SET
    policy_id = source.policy_id,
    transaction_date = source.transaction_date,
    transaction_type = source.transaction_type,
    amount = source.amount
WHEN NOT MATCHED THEN INSERT (
    transaction_id, policy_id, transaction_date, transaction_type, amount
) VALUES (
    source.transaction_id, source.policy_id, source.transaction_date,
    source.transaction_type, source.amount
);
