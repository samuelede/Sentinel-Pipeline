-- Proves idempotency directly: for every table, COUNT(*) should equal
-- COUNT(DISTINCT primary_key). If they match, no duplicates exist no
-- matter how many times a day has been loaded or re-run, this is a
-- stronger proof than just "the row count didn't change between two
-- runs," since it catches duplication even if unrelated rows were also
-- added or removed between checks.
--
-- Run any time, works regardless of what days have been loaded:
--   snowsql -c sentinel -f sql/checks/idempotency_check.sql
--
-- To actually exercise idempotency (not just check current state), run
-- the same day's load twice in a row and confirm this query returns
-- identical results both times:
--   snowsql -c sentinel -o variable_substitution=true -f sql/merge/copy_into_staging.sql -D RUN_DATE=2026-07-04
--   snowsql -c sentinel -f sql/merge/merge_dimensions_and_fact.sql
--   snowsql -c sentinel -f sql/checks/idempotency_check.sql   <- note the counts
--   (repeat the three commands above for the same date again)
--   snowsql -c sentinel -f sql/checks/idempotency_check.sql   <- counts should be unchanged

SELECT 'dim_customer' AS table_name,
       COUNT(*) AS total_rows,
       COUNT(DISTINCT customer_id) AS distinct_keys,
       COUNT(*) = COUNT(DISTINCT customer_id) AS no_duplicates
FROM dim_customer

UNION ALL
SELECT 'dim_agent', COUNT(*), COUNT(DISTINCT agent_id), COUNT(*) = COUNT(DISTINCT agent_id)
FROM dim_agent

UNION ALL
SELECT 'dim_policy', COUNT(*), COUNT(DISTINCT policy_id), COUNT(*) = COUNT(DISTINCT policy_id)
FROM dim_policy

UNION ALL
SELECT 'dim_coverage', COUNT(*), COUNT(DISTINCT coverage_id), COUNT(*) = COUNT(DISTINCT coverage_id)
FROM dim_coverage

UNION ALL
SELECT 'claims_fact', COUNT(*), COUNT(DISTINCT claim_id), COUNT(*) = COUNT(DISTINCT claim_id)
FROM claims_fact

UNION ALL
SELECT 'payments', COUNT(*), COUNT(DISTINCT payment_id), COUNT(*) = COUNT(DISTINCT payment_id)
FROM payments

UNION ALL
SELECT 'weather_daily',
       COUNT(*),
       COUNT(DISTINCT weather_date || '|' || zip_code),
       COUNT(*) = COUNT(DISTINCT weather_date || '|' || zip_code)
FROM weather_daily

UNION ALL
SELECT 'billing_transactions', COUNT(*), COUNT(DISTINCT transaction_id), COUNT(*) = COUNT(DISTINCT transaction_id)
FROM billing_transactions

ORDER BY table_name;
