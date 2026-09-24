-- File: 01_stg_apps.sql
-- Depends on: raw_apps
-- Purpose: Cleans column names/types, converts Installs to numeric, extracts
--          Size in MB, parses Last Updated to DATE, and guards against
--          duplicate app rows so the grain is one row per unique app.
-- Note: raw_apps was loaded with max_bad_records=5 due to 1 known malformed
-- row in the source CSV (column misalignment from a missing Category value).
-- That row is dropped at load time, not handled here.

-- ============================================================
-- STEP 1: BUILD
-- ============================================================
CREATE OR REPLACE VIEW `playstore-analytics-508313.playstore_analytics.stg_apps` AS
SELECT
  App AS app_name,
  Category AS category,
  IF(IS_NAN(Rating), NULL, Rating) AS rating,
  SAFE_CAST(Reviews AS INT64) AS review_count,
  CASE
    WHEN Size = 'Varies with device' THEN NULL
    WHEN REGEXP_CONTAINS(Size, r'M$') THEN SAFE_CAST(REPLACE(Size, 'M', '') AS FLOAT64)
    WHEN REGEXP_CONTAINS(Size, r'k$') THEN SAFE_CAST(REPLACE(Size, 'k', '') AS FLOAT64) / 1024
    ELSE NULL
  END AS size_mb,
  SAFE_CAST(REPLACE(REPLACE(Installs, '+', ''), ',', '') AS INT64) AS installs,
  Type AS type,
  CAST(Price AS FLOAT64) AS price,
  `Content Rating` AS content_rating,
  Genres AS genres,
  SAFE.PARSE_DATE('%B %d, %Y', `Last Updated`) AS last_updated,
  `Current Ver` AS current_version,
  `Android Ver` AS android_version
FROM `playstore-analytics-508313.playstore_analytics.raw_apps`
WHERE Installs IS NOT NULL
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY LOWER(TRIM(app_name))
  ORDER BY review_count DESC, last_updated DESC
) = 1;

-- ============================================================
-- STEP 2: BASELINE CHECKS (validate raw inputs before trusting the build)
-- ============================================================

-- 2a. Raw row count vs. distinct app count, exact-string AND case-insensitive
-- -- case-insensitive is the real ground truth this view is built to match
SELECT
  COUNT(*) AS raw_row_count,
  COUNT(DISTINCT App) AS raw_distinct_apps_exact,
  COUNT(DISTINCT LOWER(TRIM(App))) AS raw_distinct_apps_case_insensitive
FROM `playstore-analytics-508313.playstore_analytics.raw_apps`;

-- 2b. Blank/NULL checks on raw columns used in CASE/WHEN or CAST logic
SELECT
  COUNTIF(Installs IS NULL OR Installs = '') AS blank_installs,
  COUNTIF(Price IS NULL) AS blank_price,
  COUNTIF(Size IS NULL OR Size = '') AS blank_size,
  COUNTIF(`Last Updated` IS NULL OR `Last Updated` = '') AS blank_last_updated
FROM `playstore-analytics-508313.playstore_analytics.raw_apps`;

-- 2c. Confirm raw Price values are sane (Price is stored as FLOAT64, not text --
-- confirmed by the REPLACE type error when we first assumed it was a string)
SELECT
  MIN(Price) AS min_raw_price, MAX(Price) AS max_raw_price,
  COUNTIF(Price IS NULL) AS null_price,
  COUNTIF(Price < 0) AS negative_price
FROM `playstore-analytics-508313.playstore_analytics.raw_apps`;

-- 2d. Confirm the NaN-as-float hypothesis for Rating -- IS NULL alone won't
-- catch this, which is exactly how it got missed the first time
SELECT
  COUNTIF(Rating IS NULL) AS null_rating,
  COUNTIF(IS_NAN(Rating)) AS nan_rating
FROM `playstore-analytics-508313.playstore_analytics.raw_apps`;

-- ============================================================
-- STEP 3: STRUCTURAL CHECKS (did the transformation produce the expected shape?)
-- ============================================================

-- 3a. stg_apps row count should match raw_distinct_apps_case_insensitive from 2a
SELECT
  COUNT(*) AS stg_row_count,
  COUNT(DISTINCT LOWER(TRIM(app_name))) AS stg_distinct_apps_case_insensitive
FROM `playstore-analytics-508313.playstore_analytics.stg_apps`;

-- 3b. Confirm zero case-insensitive duplicate app_names remain -- the check
-- that actually matters now that dedup keys on LOWER(TRIM(app_name))
SELECT LOWER(TRIM(app_name)) AS app_key, COUNT(*) AS c
FROM `playstore-analytics-508313.playstore_analytics.stg_apps`
GROUP BY app_key
HAVING c > 1;

-- 3c. installs/price came out numeric and in sane ranges; confirm SAFE_CAST
-- didn't silently null out data it shouldn't have
SELECT
  MIN(installs) AS min_installs, MAX(installs) AS max_installs,
  COUNTIF(installs IS NULL) AS null_installs,
  MIN(price) AS min_price, MAX(price) AS max_price,
  COUNTIF(type = 'Paid' AND price IS NULL) AS paid_apps_with_null_price -- expect 0
FROM `playstore-analytics-508313.playstore_analytics.stg_apps`;

-- 3d. Confirm zero NaN ratings remain in stg_apps
SELECT COUNTIF(IS_NAN(rating)) AS leftover_nan_rating
FROM `playstore-analytics-508313.playstore_analytics.stg_apps`;

-- ============================================================
-- STEP 4: CONTENT CHECK (look at the actual values)
-- ============================================================

-- 4a. Paid apps sorted by price DESC -- surfaces the "I Am Rich" outlier cluster
SELECT app_name, price
FROM `playstore-analytics-508313.playstore_analytics.stg_apps`
WHERE type = 'Paid'
ORDER BY price DESC
LIMIT 10;

-- 4b. AVG vs MEDIAN price -- quantifies the outlier skew that drove the
-- median-over-average decision
SELECT
  ROUND(AVG(price), 2) AS avg_price,
  APPROX_QUANTILES(price, 2)[OFFSET(1)] AS median_price
FROM `playstore-analytics-508313.playstore_analytics.stg_apps`
WHERE type = 'Paid';

-- 4c. Range of Last Updated -- gives the dashboard's Title page an honest
-- "data reflects app updates through [date]" line, since this dataset is a
-- single scrape/snapshot, not a transactional date range like Superstore's
SELECT
  MIN(last_updated) AS earliest_update,
  MAX(last_updated) AS most_recent_update
FROM `playstore-analytics-508313.playstore_analytics.stg_apps`;

-- ============================================================
-- STEP 5: CONCLUSION
-- ============================================================
-- Raw data contains 10,840 rows; exact-string dedup alone left 9,659 rows,
-- but cross-checking against Power BI's DISTINCTCOUNT (9,638) surfaced a
-- second-order duplicate class: 21 apps were scraped multiple times under
-- different capitalization (e.g. "I Am Rich" / "I am rich" / "I AM RICH"),
-- which exact-string matching didn't catch. Fixed by deduping on
-- LOWER(TRIM(app_name)) instead of app_name; stg_apps now returns exactly
-- 9,638 rows, matching Power BI exactly, with zero case-variant duplicates
-- remaining. This also cleaned up the "I am rich" cluster in the paid-price
-- outlier list -- what looked like 5 separate $399.99 novelty apps was
-- actually one app scraped 5 times; the true distinct outlier list now
-- surfaces "most expensive app (H)" in its place.
-- Price is confirmed to load as FLOAT64 natively (0-400 range, no nulls or
-- negatives) -- no string cleanup was needed. Installs and Size are cast via
-- SAFE_CAST so a future malformed row degrades to NULL instead of failing
-- the whole view. Paid-app AVG price ($14.06) vs. MEDIAN ($2.99) confirms
-- the outliers meaningfully distort the average, so MEDIAN remains the
-- correct summary statistic for the Pricing Strategy KRA.