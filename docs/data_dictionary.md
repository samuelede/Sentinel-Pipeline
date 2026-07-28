# Data Dictionary

## Source Systems

| Source System | Format / Method | Refresh Cadence | Owns |
|---|---|---|---|
| Policy Admin System | PostgreSQL (psycopg2 + pandas) | Daily incremental | Customers, agents, policies, coverages |
| Claims Management System | JSON file drops via SFTP | Daily | Claim records with nested event histories |
| Billing System | CSV nightly export | Daily | Premium charges, payments, lapses |
| Open-Meteo Weather API | REST JSON over HTTPS | Daily (last 7 days refreshed) | Daily historical weather by zip code |

## claims_fact

Central fact table recording individual auto insurance claim events, financial amounts, and lifecycle status. Loaded from flattened claims JSON files.

Primary key: `claim_id`. Foreign keys: `policy_id`, `customer_id`.

| Column | Type | Description |
|---|---|---|
| claim_id | VARCHAR | Unique claim identifier (PK) |
| policy_id | VARCHAR | FK to dim_policy |
| customer_id | VARCHAR | FK to dim_customer |
| incident_date | DATE | Date of accident or loss event |
| report_date | DATE | Date claim was reported |
| incident_zip | VARCHAR | Zip code where incident occurred (joins to weather_daily) |
| incident_type | VARCHAR | Collision / Comprehensive / Liability / Theft |
| claim_status | VARCHAR | Open / Closed |
| claim_amount | DECIMAL(18,2) | Total claimed financial amount |
| approved_amount | DECIMAL(18,2) | Amount approved for payout (nullable for open claims) |
| description | VARCHAR | Free-text incident description from FNOL |
| created_at | TIMESTAMP | Record creation timestamp |

## dim_customer

Customer master data. Loaded from the policy admin PostgreSQL extract. Holds current state only.

Primary key: `customer_id`.

| Column | Type | Description |
|---|---|---|
| customer_id | VARCHAR | Unique customer identifier (PK) |
| first_name | VARCHAR | Customer first name |
| last_name | VARCHAR | Customer last name |
| dob | DATE | Date of birth |
| email | VARCHAR | Contact email |
| phone | VARCHAR | Contact phone |
| address | VARCHAR | Street address |
| city | VARCHAR | City |
| state | VARCHAR | State (OH / IN / IL) |
| zip_code | VARCHAR | Zip code |
| created_at | TIMESTAMP | Record creation timestamp |

## dim_agent

Sales agent dimension. Loaded from the policy admin PostgreSQL extract.

Primary key: `agent_id`.

| Column | Type | Description |
|---|---|---|
| agent_id | VARCHAR | Unique agent identifier (PK) |
| agent_name | VARCHAR | Agent full name |
| territory | VARCHAR | Sales territory (e.g., OH-Central) |
| hire_date | DATE | Date the agent joined Sentinel |
| license_number | VARCHAR | State P&C license number |

## dim_policy

Policy header dimension capturing coverage tier, term, premium, and status. Loaded from the policy admin PostgreSQL extract.

Primary key: `policy_id`. Foreign keys: `customer_id`, `agent_id`.

| Column | Type | Description |
|---|---|---|
| policy_id | VARCHAR | Unique policy identifier (PK) |
| customer_id | VARCHAR | FK to dim_customer |
| agent_id | VARCHAR | FK to dim_agent |
| policy_number | VARCHAR | Customer-facing policy reference |
| coverage_type | VARCHAR | Liability / Full / Comprehensive |
| start_date | DATE | Coverage start date |
| end_date | DATE | Coverage end date |
| premium_amount | DECIMAL(18,2) | Annual premium |
| status | VARCHAR | Active / Lapsed |
| created_at | TIMESTAMP | Record creation timestamp |

## dim_coverage

Coverage line items associated with each policy. A policy typically has between two and six coverage lines depending on its tier.

Primary key: `coverage_id`. Foreign keys: `policy_id`.

| Column | Type | Description |
|---|---|---|
| coverage_id | VARCHAR | Unique coverage line identifier (PK) |
| policy_id | VARCHAR | FK to dim_policy |
| coverage_code | VARCHAR | BI / PD / COLL / COMP / UM / MED |
| coverage_limit | INT | Per-claim limit ($) |
| deductible | INT | Deductible amount ($) |

## payments

Financial disbursements associated with claims. Derived by flattening the nested events array within each claim JSON document during transformation.

Primary key: `payment_id`. Foreign keys: `claim_id`.

| Column | Type | Description |
|---|---|---|
| payment_id | VARCHAR | Unique payment identifier (PK) |
| claim_id | VARCHAR | FK to claims_fact |
| payment_date | DATE | Date payment was issued |
| payment_amount | DECIMAL(18,2) | Amount disbursed |
| payment_type | VARCHAR | Repair_Settlement / Theft_Settlement / Liability_Settlement |
| adjuster_id | VARCHAR | Identifier of the adjuster who issued the payment |

## weather_daily

External enrichment table containing daily historical weather observations by zip code. Sourced from the Open-Meteo Archive API. Joined to claims_fact on `(incident_zip, incident_date)`.

Primary key: `(weather_date, zip_code)`.

| Column | Type | Description |
|---|---|---|
| weather_date | DATE | Day the weather observation refers to |
| zip_code | VARCHAR | Zip code (joins to claims_fact.incident_zip) |
| precipitation_mm | DECIMAL(8,2) | Total daily precipitation |
| max_wind_kmh | DECIMAL(8,2) | Maximum wind gust |
| max_temp_c | DECIMAL(5,2) | Daily maximum temperature |
| min_temp_c | DECIMAL(5,2) | Daily minimum temperature |
| weather_code | INT | WMO weather classification code |
| severity | VARCHAR | calm / moderate / extreme_cold / severe |

## Data Model

Star schema with `claims_fact` at the center, joined to four conformed dimensions (`dim_customer`, `dim_agent`, `dim_policy`, `dim_coverage`) and a `payments` table linked via `claim_id`. `weather_daily` is a separate enrichment table joined to `claims_fact` at the `(incident_zip, incident_date)` grain.

Dimensions hold current state only in this initial build. Historical state tracking (Slowly Changing Dimensions Type 2) is a planned future enhancement, scoped out of v1 to keep the architecture approachable and the timeline realistic. The model retains surrogate-free natural keys (`policy_id`, `customer_id`, `agent_id`) to simplify joins and debugging during initial development.
