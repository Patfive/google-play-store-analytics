-- File: 04_fct_pricing_strategy.sql
-- Depends on: stg_apps
-- Purpose: Aggregates by price tier for the Pricing Strategy KRA (free vs.
--          paid split, median price, rating/installs by tier).
-- Hypothesis: paid apps have similar/higher ratings but far lower installs
-- than free apps.

-- ============================================================
-- STEP 1: BUILD
-- ============================================================
CREATE OR REPLACE VIEW `playstore-analytics-508313.playstore_analytics.fct_pricing_strategy` AS
SELECT
  price_tier,
  tier_sort_order,
  COUNT(*) AS app_count,
  COUNTIF(rating IS NOT NULL) AS rated_app_count,
  ROUND(AVG(rating), 2) AS avg_rating,
  ROUND(AVG(installs), 0) AS avg_installs_per_app
FROM (
  SELECT
    *,
    CASE
      WHEN type = 'Free' THEN 'Free'
      WHEN price > 0 AND price < 1 THEN 'Paid: Under $1'
      WHEN price >= 1 AND price < 5 THEN 'Paid: $1-$4.99'
      WHEN price >= 5 AND price < 10 THEN 'Paid: $5-$9.99'
      WHEN price >= 10 AND price < 50 THEN 'Paid: $10-$49.99'
      WHEN price >= 50 THEN 'Paid: $50+'
      ELSE 'Unknown'
    END AS price_tier,
    CASE
      WHEN type = 'Free' THEN 0
      WHEN price > 0 AND price < 1 THEN 1
      WHEN price >= 1 AND price < 5 THEN 2
      WHEN price >= 5 AND price < 10 THEN 3
      WHEN price >= 10 AND price < 50 THEN 4
      WHEN price >= 50 THEN 5
      ELSE 6
    END AS tier_sort_order
  FROM `playstore-analytics-508313.playstore_analytics.stg_apps`
)
GROUP BY price_tier, tier_sort_order
ORDER BY tier_sort_order;
-- tier_sort_order exists so Power BI can sort price_tier chronologically by
-- price rather than alphabetically (Framework 4.4) -- "Paid: $10-$49.99"
-- would otherwise sort before "Paid: $1-$4.99" as plain text.

-- Visual check: see the built dataset as-is before running formal validation
SELECT *
FROM `playstore-analytics-508313.playstore_analytics.fct_pricing_strategy`;

-- ============================================================
-- STEP 2: BASELINE CHECKS (validate raw inputs before trusting the build)
-- ============================================================

-- 2a. Confirm `type` only contains the two values we're branching on --
-- catches any stray/unexpected type before it silently falls into "Unknown"
SELECT type, COUNT(*) AS c
FROM `playstore-analytics-508313.playstore_analytics.stg_apps`
GROUP BY type;

-- 2b. Cross-check type vs price consistency -- Free apps should have price = 0
-- and Paid apps should have price > 0; anything else means the two columns
-- disagree and the tiering logic needs to account for it
SELECT
  COUNTIF(type = 'Free' AND price != 0) AS free_with_nonzero_price,
  COUNTIF(type = 'Paid' AND price <= 0) AS paid_with_zero_or_negative_price
FROM `playstore-analytics-508313.playstore_analytics.stg_apps`;

-- 2c. Rating/installs NULL checks (re-confirming post rating-NaN fix from 01)
SELECT
  COUNTIF(rating IS NULL) AS null_rating,
  COUNTIF(installs IS NULL) AS null_installs
FROM `playstore-analytics-508313.playstore_analytics.stg_apps`;

-- ============================================================
-- STEP 3: STRUCTURAL CHECKS (did the transformation produce the expected shape?)
-- ============================================================

-- 3a. Confirm no app fell into "Unknown" -- if this is > 0, the price
-- boundaries don't fully cover the observed range and need adjusting
SELECT app_count FROM `playstore-analytics-508313.playstore_analytics.fct_pricing_strategy`
WHERE price_tier = 'Unknown';

-- 3b. Two-grain check: SUM(app_count) across all tiers must equal 9,659
SELECT SUM(app_count) AS total_apps_in_fct
FROM `playstore-analytics-508313.playstore_analytics.fct_pricing_strategy`;

-- 3c. Cross-validate the Free tier's app_count against the independent
-- type = 'Free' count from baseline 2a -- should match exactly
SELECT app_count AS free_tier_count
FROM `playstore-analytics-508313.playstore_analytics.fct_pricing_strategy`
WHERE price_tier = 'Free';

-- ============================================================
-- STEP 4: CONTENT CHECK (look at the actual values)
-- ============================================================

-- 4a. Full tier breakdown, in price order
SELECT price_tier, app_count, rated_app_count, avg_rating, avg_installs_per_app
FROM `playstore-analytics-508313.playstore_analytics.fct_pricing_strategy`
ORDER BY tier_sort_order;

-- 4b. Headline median vs. average price, paid apps only -- the actual
-- "median price" KPI number for the KRA
SELECT
  ROUND(AVG(price), 2) AS avg_paid_price,
  ROUND(APPROX_QUANTILES(price, 2)[OFFSET(1)], 2) AS median_paid_price
FROM `playstore-analytics-508313.playstore_analytics.stg_apps`
WHERE type = 'Paid';

-- 4c. Direct hypothesis test: Free vs. Paid, collapsed to two rows
-- (cleaner comparison than 5 separate paid tiers against one free row)
SELECT
  type,
  COUNT(*) AS app_count,
  ROUND(AVG(rating), 2) AS avg_rating,
  ROUND(AVG(installs), 0) AS avg_installs_per_app
FROM `playstore-analytics-508313.playstore_analytics.stg_apps`
GROUP BY type
ORDER BY type;

-- ============================================================
-- STEP 5: CONCLUSION
-- ============================================================
-- Structural checks pass cleanly: SUM(app_count) = 9,659 matches stg_apps
-- exactly, and the Free-tier count (8,904) cross-validates against the
-- independent type = 'Free' count. One data-quality edge case surfaced: 1 app
-- has type = "NaN" (literal text, same bug family as earlier NaN issues) --
-- it fell into the 'Unknown' price tier exactly as the CASE fallback was
-- designed to catch, confirmed isolated and accounted for; documented here
-- rather than special-cased in 01_stg_apps.sql given it's a single row.
-- Hypothesis CONFIRMED, and more dramatically than expected: paid apps carry
-- a slightly HIGHER average rating than free (4.26 vs. 4.17), but average
-- installs per app are ~111x lower (76,079 vs. 8,452,961). Median paid price
-- is $2.99 vs. an average of $14.06, reconfirming the outlier-driven skew
-- documented in 01_stg_apps.sql. Pricing has no meaningful relationship with
-- quality (rating) in this data, but a strong inverse relationship with
-- reach (installs) -- charging for an app trades install volume for a
-- roughly equivalent user-satisfaction outcome.