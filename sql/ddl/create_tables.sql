-- Sentinel warehouse DDL: staging + dimensional model
-- Run against the target Snowflake database and schema.

CREATE SCHEMA IF NOT EXISTS staging;

-- ===== Staging tables (loaded directly via COPY INTO) =====

CREATE TABLE IF NOT EXISTS staging.stg_customers (
    customer_id VARCHAR,
    first_name VARCHAR,
    last_name VARCHAR,
    dob DATE,
    email VARCHAR,
    phone VARCHAR,
    address VARCHAR,
    city VARCHAR,
    state VARCHAR,
    zip_code VARCHAR,
    created_at TIMESTAMP_NTZ
);

CREATE TABLE IF NOT EXISTS staging.stg_agents (
    agent_id VARCHAR,
    agent_name VARCHAR,
    territory VARCHAR,
    hire_date DATE,
    license_number VARCHAR
);

CREATE TABLE IF NOT EXISTS staging.stg_policies (
    policy_id VARCHAR,
    customer_id VARCHAR,
    agent_id VARCHAR,
    policy_number VARCHAR,
    coverage_type VARCHAR,
    start_date DATE,
    end_date DATE,
    premium_amount DECIMAL(18,2),
    status VARCHAR,
    created_at TIMESTAMP_NTZ
);

CREATE TABLE IF NOT EXISTS staging.stg_coverages (
    coverage_id VARCHAR,
    policy_id VARCHAR,
    coverage_code VARCHAR,
    coverage_limit INT,
    deductible INT
);

CREATE TABLE IF NOT EXISTS staging.stg_claims_fact (
    claim_id VARCHAR,
    policy_id VARCHAR,
    customer_id VARCHAR,
    incident_date DATE,
    report_date DATE,
    incident_zip VARCHAR,
    incident_type VARCHAR,
    claim_status VARCHAR,
    claim_amount DECIMAL(18,2),
    approved_amount DECIMAL(18,2),
    description VARCHAR,
    created_at TIMESTAMP_NTZ
);

CREATE TABLE IF NOT EXISTS staging.stg_payments (
    payment_id VARCHAR,
    claim_id VARCHAR,
    payment_date DATE,
    payment_amount DECIMAL(18,2),
    payment_type VARCHAR,
    adjuster_id VARCHAR
);

CREATE TABLE IF NOT EXISTS staging.stg_weather_daily (
    weather_date DATE,
    zip_code VARCHAR,
    precipitation_mm DECIMAL(8,2),
    max_wind_kmh DECIMAL(8,2),
    max_temp_c DECIMAL(5,2),
    min_temp_c DECIMAL(5,2),
    weather_code INT,
    severity VARCHAR
);

CREATE TABLE IF NOT EXISTS staging.stg_billing_transactions (
    transaction_id VARCHAR,
    policy_id VARCHAR,
    transaction_date DATE,
    transaction_type VARCHAR,
    amount DECIMAL(18,2)
);

-- ===== Warehouse tables (target of MERGE from staging) =====

CREATE TABLE IF NOT EXISTS dim_customer (
    customer_id VARCHAR NOT NULL PRIMARY KEY,
    first_name VARCHAR NOT NULL,
    last_name VARCHAR NOT NULL,
    dob DATE,
    email VARCHAR,
    phone VARCHAR,
    address VARCHAR,
    city VARCHAR,
    state VARCHAR,
    zip_code VARCHAR,
    created_at TIMESTAMP_NTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS dim_agent (
    agent_id VARCHAR NOT NULL PRIMARY KEY,
    agent_name VARCHAR NOT NULL,
    territory VARCHAR,
    hire_date DATE,
    license_number VARCHAR
);

CREATE TABLE IF NOT EXISTS dim_policy (
    policy_id VARCHAR NOT NULL PRIMARY KEY,
    customer_id VARCHAR NOT NULL,
    agent_id VARCHAR NOT NULL,
    policy_number VARCHAR NOT NULL,
    coverage_type VARCHAR NOT NULL,
    start_date DATE NOT NULL,
    end_date DATE NOT NULL,
    premium_amount DECIMAL(18,2) NOT NULL,
    status VARCHAR NOT NULL,
    created_at TIMESTAMP_NTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS dim_coverage (
    coverage_id VARCHAR NOT NULL PRIMARY KEY,
    policy_id VARCHAR NOT NULL,
    coverage_code VARCHAR NOT NULL,
    coverage_limit INT NOT NULL,
    deductible INT NOT NULL
);

CREATE TABLE IF NOT EXISTS claims_fact (
    claim_id VARCHAR NOT NULL PRIMARY KEY,
    policy_id VARCHAR NOT NULL,
    customer_id VARCHAR NOT NULL,
    incident_date DATE NOT NULL,
    report_date DATE NOT NULL,
    incident_zip VARCHAR NOT NULL,
    incident_type VARCHAR NOT NULL,
    claim_status VARCHAR NOT NULL,
    claim_amount DECIMAL(18,2) NOT NULL,
    approved_amount DECIMAL(18,2),
    description VARCHAR,
    created_at TIMESTAMP_NTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS payments (
    payment_id VARCHAR NOT NULL PRIMARY KEY,
    claim_id VARCHAR NOT NULL,
    payment_date DATE NOT NULL,
    payment_amount DECIMAL(18,2) NOT NULL,
    payment_type VARCHAR NOT NULL,
    adjuster_id VARCHAR
);

CREATE TABLE IF NOT EXISTS weather_daily (
    weather_date DATE NOT NULL,
    zip_code VARCHAR NOT NULL,
    precipitation_mm DECIMAL(8,2),
    max_wind_kmh DECIMAL(8,2),
    max_temp_c DECIMAL(5,2),
    min_temp_c DECIMAL(5,2),
    weather_code INT,
    severity VARCHAR,
    PRIMARY KEY (weather_date, zip_code)
);

CREATE TABLE IF NOT EXISTS billing_transactions (
    transaction_id VARCHAR NOT NULL PRIMARY KEY,
    policy_id VARCHAR NOT NULL,
    transaction_date DATE NOT NULL,
    transaction_type VARCHAR NOT NULL,
    amount DECIMAL(18,2) NOT NULL
);
