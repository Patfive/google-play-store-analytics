-- File: 02_stg_reviews.sql
-- Depends on: raw_user_reviews, stg_apps
-- Purpose: Cleans review-level data; converts NaN sentiment scores AND
--          "nan"-string text fields to true NULL; checks join integrity
--          against stg_apps.

-- ============================================================
-- STEP 1: BUILD
-- ============================================================
CREATE OR REPLACE VIEW `playstore-analytics-508313.playstore_analytics.stg_reviews` AS
SELECT
  App AS app_name,
  IF(Translated_Review = 'nan', NULL, Translated_Review) AS review_text,
  IF(Sentiment = 'nan', NULL, Sentiment) AS sentiment,
  IF(IS_NAN(Sentiment_Polarity), NULL, Sentiment_Polarity) AS sentiment_polarity,
  IF(IS_NAN(Sentiment_Subjectivity), NULL, Sentiment_Subjectivity) AS sentiment_subjectivity
FROM `playstore-analytics-508313.playstore_analytics.raw_user_reviews`;

-- ============================================================
-- STEP 2: BASELINE CHECKS (validate raw inputs before trusting the build)
-- ============================================================

-- 2a. Confirm the "nan"-as-text hypothesis against the raw data, and check it
-- lines up with the already-confirmed NaN counts in the numeric columns
SELECT
  COUNT(*) AS raw_row_count,
  COUNTIF(Translated_Review = 'nan') AS nan_string_review_text,
  COUNTIF(Sentiment = 'nan') AS nan_string_sentiment,
  COUNTIF(IS_NAN(Sentiment_Polarity)) AS nan_polarity,
  COUNTIF(IS_NAN(Sentiment_Subjectivity)) AS nan_subjectivity
FROM `playstore-analytics-508313.playstore_analytics.raw_user_reviews`;

-- ============================================================
-- STEP 3: STRUCTURAL CHECKS (did the transformation produce the expected shape?)
-- ============================================================

-- 3a. Row count unchanged -- this view should never drop rows, only null out values
SELECT COUNT(*) AS stg_row_count
FROM `playstore-analytics-508313.playstore_analytics.stg_reviews`;

-- 3b. NULL counts post-fix -- review_text/sentiment nulls should now roughly
-- match the polarity null count from 2a, instead of showing 0 like before
SELECT
  COUNTIF(review_text IS NULL) AS null_review_text,
  COUNTIF(sentiment IS NULL) AS null_sentiment,
  COUNTIF(sentiment_polarity IS NULL) AS null_polarity
FROM `playstore-analytics-508313.playstore_analytics.stg_reviews`;

-- 3c. Confirm zero "nan" strings and zero NaN floats remain anywhere
SELECT
  COUNTIF(review_text = 'nan') AS leftover_nan_text,
  COUNTIF(sentiment = 'nan') AS leftover_nan_sentiment,
  COUNTIF(IS_NAN(sentiment_polarity)) AS leftover_nan_polarity,
  COUNTIF(IS_NAN(sentiment_subjectivity)) AS leftover_nan_subjectivity
FROM `playstore-analytics-508313.playstore_analytics.stg_reviews`;

-- 3d. Sentiment score ranges still within theoretical bounds
SELECT
  MIN(sentiment_polarity) AS min_polarity, MAX(sentiment_polarity) AS max_polarity,
  MIN(sentiment_subjectivity) AS min_subjectivity, MAX(sentiment_subjectivity) AS max_subjectivity
FROM `playstore-analytics-508313.playstore_analytics.stg_reviews`;

-- 3e. Unmatched apps against the CURRENT (deduped) stg_apps, exact match --
-- re-baselines the "54 unmatched" figure now that stg_apps has changed
SELECT COUNT(DISTINCT r.app_name) AS unmatched_apps_exact
FROM `playstore-analytics-508313.playstore_analytics.stg_reviews` AS r
LEFT JOIN `playstore-analytics-508313.playstore_analytics.stg_apps` AS a
  ON r.app_name = a.app_name
WHERE a.app_name IS NULL;

-- 3f. Same check with a normalized join -- tests whether casing/whitespace
-- explains some of the mismatches, as originally guessed but never verified
SELECT COUNT(DISTINCT r.app_name) AS unmatched_apps_normalized
FROM `playstore-analytics-508313.playstore_analytics.stg_reviews` AS r
LEFT JOIN `playstore-analytics-508313.playstore_analytics.stg_apps` AS a
  ON LOWER(TRIM(r.app_name)) = LOWER(TRIM(a.app_name))
WHERE a.app_name IS NULL;

-- ============================================================
-- STEP 4: CONTENT CHECK (look at the actual values)
-- ============================================================

-- 4a. Sample real review text to eyeball quality post-cleanup
SELECT app_name, review_text, sentiment, sentiment_polarity
FROM `playstore-analytics-508313.playstore_analytics.stg_reviews`
WHERE review_text IS NOT NULL
LIMIT 10;

-- 4b. Most negative and most positive reviews by polarity -- sense-check that
-- extreme scores actually read as extreme
(SELECT app_name, review_text, sentiment_polarity
 FROM `playstore-analytics-508313.playstore_analytics.stg_reviews`
 WHERE review_text IS NOT NULL
 ORDER BY sentiment_polarity ASC LIMIT 5)
UNION ALL
(SELECT app_name, review_text, sentiment_polarity
 FROM `playstore-analytics-508313.playstore_analytics.stg_reviews`
 WHERE review_text IS NOT NULL
 ORDER BY sentiment_polarity DESC LIMIT 5);

 -- ============================================================
-- STEP 5: CONCLUSION
-- ============================================================
-- The "nan"-as-text bug affected exactly the same 26,863 rows across
-- review_text, sentiment, sentiment_polarity, and sentiment_subjectivity
-- (confirmed in 2a) -- all four are now correctly NULL for those rows, with
-- zero "nan" strings or NaN floats remaining (3c). review_text shows 5 more
-- NULLs (26,868) than the "nan" count -- a small number of rows were already
-- genuinely empty in the source, unrelated to the nan-string bug; negligible.
-- The normalized-join test disproves the original casing/whitespace guess:
-- 3e and 3f both return exactly 54 unmatched apps. These are genuine
-- mismatches (true naming differences, typos, or apps present in one file
-- but not the other), not a formatting issue. Documented as a known
-- limitation: ~54 of 9,659 apps' reviews are excluded from any
-- stg_reviews-to-stg_apps join -- acceptable given the scale.
-- Content check surfaced exact duplicate review rows in raw_user_reviews
-- (same app + same review text, e.g. "Golfshot") -- not fixed here since it
-- doesn't affect stg_reviews' grain, but 05_fct_sentiment_analysis.sql should
-- dedup at the review level before computing % positive/negative to avoid
-- double-counting repeated reviews.
