-- File: 06_fct_market_landscape.sql
-- Depends on: fct_app_performance (not stg_apps directly -- reuses the
--             category-level app_count and avg_installs_per_app already
--             computed and validated in 03_fct_app_performance.sql)
-- Purpose: Classifies each category into a saturation/opportunity quadrant
--          for the Market Landscape KRA.
-- Hypothesis: some categories are "crowded but low-opportunity" (high app
-- count, low avg installs per app).

-- ============================================================
-- STEP 1: BUILD
-- ============================================================
CREATE OR REPLACE VIEW `playstore-analytics-508313.playstore_analytics.fct_market_landscape` AS
WITH thresholds AS (
  SELECT
    APPROX_QUANTILES(app_count, 2)[OFFSET(1)] AS median_app_count,
    APPROX_QUANTILES(avg_installs_per_app, 2)[OFFSET(1)] AS median_avg_installs
  FROM `playstore-analytics-508313.playstore_analytics.fct_app_performance`
)
SELECT
  f.category,
  f.app_count,
  f.avg_installs_per_app,
  f.avg_rating,
  t.median_app_count,
  t.median_avg_installs,
  CASE
    WHEN f.app_count >= t.median_app_count AND f.avg_installs_per_app >= t.median_avg_installs THEN 'Crowded, High Opportunity'
    WHEN f.app_count >= t.median_app_count AND f.avg_installs_per_app < t.median_avg_installs THEN 'Crowded, Low Opportunity'
    WHEN f.app_count < t.median_app_count AND f.avg_installs_per_app >= t.median_avg_installs THEN 'Niche, High Opportunity'
    ELSE 'Niche, Low Opportunity'
  END AS market_quadrant
FROM `playstore-analytics-508313.playstore_analytics.fct_app_performance` f
CROSS JOIN thresholds t
ORDER BY f.app_count DESC;

-- Visual check
SELECT * FROM `playstore-analytics-508313.playstore_analytics.fct_market_landscape`;

-- ============================================================
-- STEP 2: BASELINE CHECKS (validate inputs before trusting the build)
-- ============================================================

-- 2a. Distribution of app_count and avg_installs_per_app across the 33
-- categories -- confirms the median thresholds land somewhere reasonable,
-- not skewed by an outlier
SELECT
  MIN(app_count) AS min_app_count, MAX(app_count) AS max_app_count,
  APPROX_QUANTILES(app_count, 2)[OFFSET(1)] AS median_app_count,
  MIN(avg_installs_per_app) AS min_avg_installs, MAX(avg_installs_per_app) AS max_avg_installs,
  APPROX_QUANTILES(avg_installs_per_app, 2)[OFFSET(1)] AS median_avg_installs
FROM `playstore-analytics-508313.playstore_analytics.fct_app_performance`;

-- ============================================================
-- STEP 3: STRUCTURAL CHECKS (did the transformation produce the expected shape?)
-- ============================================================

-- 3a. fct row count should still be 33 -- confirms the CROSS JOIN against
-- thresholds didn't fan out
SELECT COUNT(*) AS fct_row_count
FROM `playstore-analytics-508313.playstore_analytics.fct_market_landscape`;

-- 3b. Defensive check: thresholds must resolve to exactly one row, or the
-- CROSS JOIN above would silently multiply every category row
SELECT COUNT(*) AS threshold_row_count
FROM (
  SELECT APPROX_QUANTILES(app_count, 2)[OFFSET(1)] AS m1,
         APPROX_QUANTILES(avg_installs_per_app, 2)[OFFSET(1)] AS m2
  FROM `playstore-analytics-508313.playstore_analytics.fct_app_performance`
);

-- 3c. Quadrant counts should sum to 33
SELECT market_quadrant, COUNT(*) AS category_count
FROM `playstore-analytics-508313.playstore_analytics.fct_market_landscape`
GROUP BY market_quadrant;

-- ============================================================
-- STEP 4: CONTENT CHECK (look at the actual values)
-- ============================================================

-- 4a. Full landscape, sorted by app count (most crowded first)
SELECT category, app_count, avg_installs_per_app, avg_rating, market_quadrant
FROM `playstore-analytics-508313.playstore_analytics.fct_market_landscape`
ORDER BY app_count DESC;

-- 4b. Direct hypothesis test: which categories are "crowded but
-- low-opportunity"?
SELECT category, app_count, avg_installs_per_app
FROM `playstore-analytics-508313.playstore_analytics.fct_market_landscape`
WHERE market_quadrant = 'Crowded, Low Opportunity'
ORDER BY app_count DESC;

-- 4c. The other interesting corner: "Niche, High Opportunity" -- small app
-- count but strong installs per app, i.e. an underserved category
SELECT category, app_count, avg_installs_per_app
FROM `playstore-analytics-508313.playstore_analytics.fct_market_landscape`
WHERE market_quadrant = 'Niche, High Opportunity'
ORDER BY avg_installs_per_app DESC;

-- ============================================================
-- STEP 5: CONCLUSION
-- ============================================================
-- Structural checks confirm integrity: 33 rows preserved through the CROSS
-- JOIN (verified safe since the thresholds subquery resolves to exactly 1
-- row), and the four market_quadrant buckets sum to 33 exactly
-- (5 + 12 + 5 + 11). Using MEDIAN for both thresholds (app_count: 53-1,874,
-- avg_installs_per_app: 96,944-35,042,147) was the right call given both
-- distributions are wide and skewed, consistent with the median-over-average
-- decision made in 01_stg_apps.sql.
-- Hypothesis CONFIRMED: 5 categories are "Crowded, Low Opportunity." FAMILY
-- is the standout case -- the most crowded category in the dataset (1,874
-- apps, ~8.5x the median) yet sitting just under the install-opportunity
-- threshold (3,319,926 vs. 3,373,768 median). MEDICAL is the more extreme
-- example: 395 apps but only 96,944 avg installs, near the bottom of the
-- entire range.
-- A complementary finding for the Market Landscape KRA: "Niche, High
-- Opportunity" categories (VIDEO_PLAYERS, ENTERTAINMENT, SHOPPING, WEATHER,
-- MAPS_AND_NAVIGATION) represent under-saturated categories with outsized
-- installs per app -- VIDEO_PLAYERS in particular (164 apps, 23,975,017 avg
-- installs) is a stronger "opportunity" signal than any crowded category in
-- the dataset.