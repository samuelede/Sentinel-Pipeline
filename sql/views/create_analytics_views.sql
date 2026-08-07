-- Analytics views answering the case study's headline business questions.
-- Run after the warehouse tables exist and have data (sql/ddl/create_tables.sql,
-- sql/merge/copy_into_staging.sql, sql/merge/merge_dimensions_and_fact.sql).
--
--   snowsql -c sentinel -f sql/views/create_analytics_views.sql

-- ===== 1. Loss ratio by agent and territory =====
--
-- Loss ratio = incurred losses / earned premium. Two versions of the
-- numerator are provided since the schema doesn't track reserves
-- separately: claim_amount (total claimed exposure, including claims
-- still open or later denied) and approved_amount (what was actually
-- approved for payout, NULL for open claims). Pick whichever matches how
-- the business wants to define "incurred": claim_amount is the more
-- conservative, exposure-based view; approved_amount reflects claims
-- that have actually reached a payout decision.

CREATE OR REPLACE VIEW analytics_loss_ratio_by_agent_territory AS
SELECT
    a.agent_id,
    a.agent_name,
    a.territory,
    COUNT(DISTINCT p.policy_id) AS policy_count,
    SUM(p.premium_amount) AS total_premium,
    SUM(COALESCE(cf.claim_amount, 0)) AS total_claimed,
    SUM(COALESCE(cf.approved_amount, 0)) AS total_approved,
    CASE WHEN SUM(p.premium_amount) = 0 THEN NULL
         ELSE ROUND(SUM(COALESCE(cf.claim_amount, 0)) / SUM(p.premium_amount), 4)
    END AS loss_ratio_claimed,
    CASE WHEN SUM(p.premium_amount) = 0 THEN NULL
         ELSE ROUND(SUM(COALESCE(cf.approved_amount, 0)) / SUM(p.premium_amount), 4)
    END AS loss_ratio_approved
FROM dim_agent a
JOIN dim_policy p ON p.agent_id = a.agent_id
LEFT JOIN claims_fact cf ON cf.policy_id = p.policy_id
GROUP BY a.agent_id, a.agent_name, a.territory
ORDER BY loss_ratio_claimed DESC NULLS LAST;


-- ===== 2. Claim frequency by zip code =====
--
-- Based on incident_zip (where the loss occurred), not the customer's
-- home zip_code in dim_customer, these can differ, and incident_zip is
-- also the join key weather_daily uses, keeping this consistent with
-- the fraud-review view below.

CREATE OR REPLACE VIEW analytics_claim_frequency_by_zip AS
SELECT
    incident_zip AS zip_code,
    COUNT(*) AS claim_count,
    COUNT(DISTINCT policy_id) AS distinct_policies_with_claims,
    SUM(claim_amount) AS total_claimed_amount,
    MIN(incident_date) AS earliest_claim_date,
    MAX(incident_date) AS latest_claim_date
FROM claims_fact
GROUP BY incident_zip
ORDER BY claim_count DESC;


-- ===== 3. Weather-context fraud review flags =====
--
-- Flags Comprehensive claims (the coverage type that would plausibly
-- cover weather-driven damage) filed on a day/zip where the weather
-- record shows no severe conditions. This is a candidate-for-review
-- signal, not a fraud determination, a flagged claim still needs a
-- human adjuster to actually investigate.

CREATE OR REPLACE VIEW analytics_weather_fraud_review_flags AS
SELECT
    cf.claim_id,
    cf.policy_id,
    cf.customer_id,
    cf.incident_date,
    cf.incident_zip,
    cf.incident_type,
    cf.claim_amount,
    cf.claim_status,
    cf.description,
    w.severity AS weather_severity_that_day,
    w.precipitation_mm,
    w.max_wind_kmh,
    w.weather_code,
    CASE
        WHEN cf.incident_type = 'Comprehensive' AND (w.severity IS NULL OR w.severity = 'calm')
            THEN TRUE
        ELSE FALSE
    END AS flagged_for_review,
    CASE
        WHEN cf.incident_type = 'Comprehensive' AND w.severity IS NULL
            THEN 'No weather record found for this zip/date'
        WHEN cf.incident_type = 'Comprehensive' AND w.severity = 'calm'
            THEN 'Comprehensive claim filed with calm weather on record for that zip/date'
        ELSE NULL
    END AS flag_reason
FROM claims_fact cf
LEFT JOIN weather_daily w
    ON w.zip_code = cf.incident_zip AND w.weather_date = cf.incident_date
ORDER BY flagged_for_review DESC, cf.incident_date DESC;


-- ===== 4. Billed vs. collected premium reconciliation =====
--
-- CAUTION: transaction_type's actual distinct values aren't documented
-- anywhere in this project (source system description only says
-- "Premium charges, payments, lapses"). This view sums ALL
-- billing_transactions rows per policy regardless of type. If charges
-- and payments/refunds use a sign convention (e.g. negative for
-- refunds), this nets out correctly. If they're both stored as positive
-- amounts under different transaction_type values without offsetting
-- signs, this view will overstate collections rather than reconcile.
-- Run this first to confirm before trusting the output:
--   SELECT DISTINCT transaction_type FROM billing_transactions;

CREATE OR REPLACE VIEW analytics_billed_vs_collected_reconciliation AS
SELECT
    p.policy_id,
    p.policy_number,
    p.status AS policy_status,
    p.premium_amount AS billed_premium,
    COALESCE(SUM(bt.amount), 0) AS total_collected,
    p.premium_amount - COALESCE(SUM(bt.amount), 0) AS variance,
    CASE
        WHEN COALESCE(SUM(bt.amount), 0) < p.premium_amount THEN 'Under-collected'
        WHEN COALESCE(SUM(bt.amount), 0) > p.premium_amount THEN 'Over-collected'
        ELSE 'Reconciled'
    END AS reconciliation_status
FROM dim_policy p
LEFT JOIN billing_transactions bt ON bt.policy_id = p.policy_id
GROUP BY p.policy_id, p.policy_number, p.status, p.premium_amount
ORDER BY ABS(p.premium_amount - COALESCE(SUM(bt.amount), 0)) DESC;
