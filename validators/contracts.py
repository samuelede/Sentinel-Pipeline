"""
Schema contracts for each landing dataset: expected columns, types, and
required non-null fields. Used by validate.py to build Great Expectations
suites and to run lightweight standalone checks.
"""

CONTRACTS = {
    "customers": {
        "columns": {
            "customer_id": "string",
            "first_name": "string",
            "last_name": "string",
            "dob": "date",
            "email": "string",
            "phone": "string",
            "address": "string",
            "city": "string",
            "state": "string",
            "zip_code": "string",
            "created_at": "timestamp",
        },
        "required_not_null": ["customer_id", "first_name", "last_name", "created_at"],
    },
    "agents": {
        "columns": {
            "agent_id": "string",
            "agent_name": "string",
            "territory": "string",
            "hire_date": "date",
            "license_number": "string",
        },
        "required_not_null": ["agent_id", "agent_name"],
    },
    "policies": {
        "columns": {
            "policy_id": "string",
            "customer_id": "string",
            "agent_id": "string",
            "policy_number": "string",
            "coverage_type": "string",
            "start_date": "date",
            "end_date": "date",
            "premium_amount": "decimal",
            "status": "string",
            "created_at": "timestamp",
        },
        "required_not_null": [
            "policy_id",
            "customer_id",
            "agent_id",
            "premium_amount",
            "status",
        ],
    },
    "coverages": {
        "columns": {
            "coverage_id": "string",
            "policy_id": "string",
            "coverage_code": "string",
            "coverage_limit": "int",
            "deductible": "int",
        },
        "required_not_null": ["coverage_id", "policy_id", "coverage_code"],
    },
    "claims_raw": {
        # Describes the raw claim JSON as it lands from source_systems, before
        # transform_claims.py flattens it. Field names here match the real
        # source structure confirmed against actual claim files: "status"
        # (not "claim_status"), a nested "incident_location" object rather
        # than a flat "incident_zip", and an "events" list.
        "columns": {
            "claim_id": "string",
            "policy_id": "string",
            "customer_id": "string",
            "incident_date": "date",
            "report_date": "date",
            "incident_location": "dict",
            "incident_type": "string",
            "description": "string",
            "status": "string",
            "claim_amount": "decimal",
            "approved_amount": "decimal",
            "created_at": "timestamp",
            "events": "list",
        },
        "required_not_null": [
            "claim_id",
            "policy_id",
            "customer_id",
            "incident_date",
            "incident_location",
            "status",
            "claim_amount",
        ],
    },
    "claims_fact": {
        "columns": {
            "claim_id": "string",
            "policy_id": "string",
            "customer_id": "string",
            "incident_date": "date",
            "report_date": "date",
            "incident_zip": "string",
            "incident_type": "string",
            "claim_status": "string",
            "claim_amount": "decimal",
            "approved_amount": "decimal",
            "description": "string",
            "created_at": "timestamp",
        },
        "required_not_null": [
            "claim_id",
            "policy_id",
            "customer_id",
            "incident_date",
            "claim_status",
            "claim_amount",
        ],
    },
    "payments": {
        "columns": {
            "payment_id": "string",
            "claim_id": "string",
            "payment_date": "date",
            "payment_amount": "decimal",
            "payment_type": "string",
            "adjuster_id": "string",
        },
        "required_not_null": ["payment_id", "claim_id", "payment_amount"],
    },
    "billing": {
        "columns": {
            "transaction_id": "string",
            "policy_id": "string",
            "transaction_date": "date",
            "transaction_type": "string",
            "amount": "decimal",
        },
        "required_not_null": ["transaction_id", "policy_id", "transaction_date", "amount"],
    },
    "weather": {
        "columns": {
            "weather_date": "date",
            "zip_code": "string",
            "precipitation_mm": "decimal",
            "max_wind_kmh": "decimal",
            "max_temp_c": "decimal",
            "min_temp_c": "decimal",
            "weather_code": "int",
            "severity": "string",
        },
        "required_not_null": ["weather_date", "zip_code"],
    },
}
