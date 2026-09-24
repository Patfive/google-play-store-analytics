-- File: 03_fct_app_performance.sql
-- Depends on: stg_apps
-- Purpose: Aggregates app performance by category for the App Performance KRA
--          (avg rating, review count, installs). Answers: which categories
--          perform best, and does install volume track with rating?
-- Hypothesis: certain categories (e.g. Games, Communication) have
-- systematically higher installs regardless of rating.

-- ============================================================
-- STEP 1: BUILD
-- ============================================================
CREATE OR REPLACE VIEW `playstore-analytics-508313.playstore_analytics.fct_app_performance` AS
SELECT
  category,
  COUNT(*) AS app_count,
  COUNTIF(rating IS NOT NULL) AS rated_app_count, -- avg_rating below is computed only over these, not app_count
  ROUND(AVG(rating), 2) AS avg_rating,
  SUM(review_count) AS total_reviews,
  SUM(installs) AS total_installs,
  ROUND(AVG(installs), 0) AS avg_installs_per_app
FROM `playstore-analytics-508313.playstore_analytics.stg_apps`
GROUP BY category
ORDER BY total_installs DESC;

-- Visual check: see the built dataset as-is before running formal validation
SELECT *
FROM `playstore-analytics-508313.playstore_analytics.fct_app_performance`;

-- ============================================================
-- STEP 2: BASELINE CHECKS (validate raw inputs before trusting the build)
-- ============================================================

-- 2a. Distinct category ground-truth -- this is the expected row count
-- for the fact table (one row per category)
SELECT COUNT(DISTINCT category) AS distinct_categories
FROM `playstore-analytics-508313.playstore_analytics.stg_apps`;

-- 2b. Look at the category values themselves -- catches stray blanks/typos
-- before they silently become their own "category" row
SELECT category, COUNT(*) AS c
FROM `playstore-analytics-508313.playstore_analytics.stg_apps`
GROUP BY category
ORDER BY category ASC;

-- 2c. NULL checks on the columns being aggregated
SELECT
  COUNTIF(rating IS NULL) AS null_rating,
  COUNTIF(review_count IS NULL) AS null_review_count,
  COUNTIF(installs IS NULL) AS null_installs
FROM `playstore-analytics-508313.playstore_analytics.stg_apps`;

-- ============================================================
-- STEP 3: STRUCTURAL CHECKS (did the transformation produce the expected shape?)
-- ============================================================

-- 3a. fct row count should equal distinct_categories from 2a -- confirms the
-- grain is exactly one row per category
SELECT COUNT(*) AS fct_row_count
FROM `playstore-analytics-508313.playstore_analytics.fct_app_performance`;

-- 3b. Two-grain check: SUM(app_count) across every category must equal the
-- total row count of stg_apps (9,659) -- if it doesn't, apps are being
-- dropped or double-counted in the GROUP BY
SELECT SUM(app_count) AS total_apps_in_fct
FROM `playstore-analytics-508313.playstore_analytics.fct_app_performance`;

-- 3c. Confirm no category is silently NULL/blank
SELECT category, app_count
FROM `playstore-analytics-508313.playstore_analytics.fct_app_performance`
WHERE category IS NULL OR category = '';

-- ============================================================
-- STEP 4: CONTENT CHECK (look at the actual values)
-- ============================================================

-- 4a. Top 10 categories by total installs
SELECT category, app_count, avg_rating, total_reviews, total_installs, avg_installs_per_app
FROM `playstore-analytics-508313.playstore_analytics.fct_app_performance`
ORDER BY total_installs DESC
LIMIT 10;

-- 4b. Bottom 10 categories by total installs -- sense-check the other end
SELECT category, app_count, avg_rating, total_reviews, total_installs, avg_installs_per_app
FROM `playstore-analytics-508313.playstore_analytics.fct_app_performance`
ORDER BY total_installs ASC
LIMIT 10;

-- 4c. Direct test of the hypothesis: rank by installs vs. rank by rating --
-- if a category is top-5 by installs but mid/low by rating, that's evidence
-- installs and rating are decoupled
SELECT
  category,
  total_installs,
  RANK() OVER (ORDER BY total_installs DESC) AS installs_rank,
  avg_rating,
  RANK() OVER (ORDER BY avg_rating DESC) AS rating_rank
FROM `playstore-analytics-508313.playstore_analytics.fct_app_performance`
ORDER BY installs_rank
LIMIT 10;

-- ============================================================
-- STEP 5: CONCLUSION
-- ============================================================
-- All structural checks pass: 33 distinct categories, one row per category,
-- and SUM(app_count) = 9,659 matches stg_apps exactly -- no apps dropped or
-- double-counted in the GROUP BY.
-- The Rating NaN-as-float bug (see 01_stg_apps.sql addendum) was caught here
-- when avg_rating returned NaN for every category; now corrected.
-- With avg_rating fixed, the hypothesis is CONFIRMED: install volume and
-- rating quality are decoupled. GAME is #1 by total installs but only #9 of
-- 33 by avg_rating (4.24); COMMUNICATION is #2 by installs but #24 by rating
-- (4.12); TOOLS is #3 by installs but #30 by rating (4.04) -- nearly the
-- bottom of the category list. Categories with far fewer installs (EVENTS,
-- BEAUTY, PARENTING) post higher average ratings (4.3-4.44) than any top-3
-- install category. Installs and rating should be treated as two independent
-- axes in the App Performance KRA, not a single quality signal.