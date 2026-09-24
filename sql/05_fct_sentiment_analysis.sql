-- File: 05_fct_sentiment_analysis.sql
-- Depends on: stg_apps, stg_reviews
-- Purpose: Aggregates review sentiment by category and compares it to average
--          app rating, for the Sentiment Analysis KRA (% positive/negative/
--          neutral, sentiment polarity vs. rating).
-- Hypothesis: sentiment polarity correlates with star rating.
-- Known limitations carried in from upstream files:
--   - ~54 of 9,659 apps have no matching reviews (documented in 02_stg_reviews.sql)
--   - raw_user_reviews contains exact duplicate review rows (documented in
--     02_stg_reviews.sql's content check) -- deduped here via SELECT DISTINCT
--     before aggregating, so repeated reviews don't double-count sentiment.

-- ============================================================
-- STEP 1: BUILD
-- ============================================================
CREATE OR REPLACE VIEW `playstore-analytics-508313.playstore_analytics.fct_sentiment_analysis` AS
WITH deduped_reviews AS (
  SELECT DISTINCT app_name, review_text, sentiment, sentiment_polarity, sentiment_subjectivity
  FROM `playstore-analytics-508313.playstore_analytics.stg_reviews`
  WHERE sentiment IS NOT NULL
)
SELECT
  a.category,
  COUNT(*) AS review_count,
  COUNTIF(r.sentiment = 'Positive') AS positive_count,
  COUNTIF(r.sentiment = 'Negative') AS negative_count,
  COUNTIF(r.sentiment = 'Neutral') AS neutral_count,
  ROUND(COUNTIF(r.sentiment = 'Positive') / COUNT(*) * 100, 1) AS pct_positive,
  ROUND(COUNTIF(r.sentiment = 'Negative') / COUNT(*) * 100, 1) AS pct_negative,
  ROUND(COUNTIF(r.sentiment = 'Neutral') / COUNT(*) * 100, 1) AS pct_neutral,
  ROUND(AVG(r.sentiment_polarity), 3) AS avg_sentiment_polarity,
  ROUND(AVG(a.rating), 2) AS avg_app_rating
FROM deduped_reviews AS r
JOIN `playstore-analytics-508313.playstore_analytics.stg_apps` AS a
  ON LOWER(TRIM(r.app_name)) = LOWER(TRIM(a.app_name))
GROUP BY a.category
ORDER BY avg_sentiment_polarity DESC;

-- Visual check
SELECT * FROM `playstore-analytics-508313.playstore_analytics.fct_sentiment_analysis`;

-- ============================================================
-- STEP 2: BASELINE CHECKS (validate raw inputs before trusting the build)
-- ============================================================

-- 2a. Confirm sentiment only contains the three values we're branching on
SELECT sentiment, COUNT(*) AS c
FROM `playstore-analytics-508313.playstore_analytics.stg_reviews`
GROUP BY sentiment;

-- 2b. Quantify the exact-duplicate-review problem before and after DISTINCT,
-- restricted to rows with a real sentiment (matches what the build filters on)
SELECT
  COUNT(*) AS raw_count,
  COUNT(DISTINCT CONCAT(app_name, '|', review_text, '|', sentiment,
                         '|', CAST(sentiment_polarity AS STRING))) AS distinct_count
FROM `playstore-analytics-508313.playstore_analytics.stg_reviews`
WHERE sentiment IS NOT NULL;

-- ============================================================
-- STEP 3: STRUCTURAL CHECKS (did the transformation produce the expected shape?)
-- ============================================================

-- 3a. fct row count vs. distinct categories that actually have a matched
-- review (may be < 33 if some category's apps are entirely unmatched)
SELECT COUNT(*) AS fct_row_count
FROM `playstore-analytics-508313.playstore_analytics.fct_sentiment_analysis`;

-- 3b. Two-grain check: SUM(review_count) across categories should equal the
-- deduped, sentiment-not-null, app-matched review total computed independently
SELECT COUNT(*) AS expected_total_reviews
FROM (
  SELECT DISTINCT r.app_name, r.review_text, r.sentiment, r.sentiment_polarity, r.sentiment_subjectivity
  FROM `playstore-analytics-508313.playstore_analytics.stg_reviews` AS r
  JOIN `playstore-analytics-508313.playstore_analytics.stg_apps` AS a
    ON LOWER(TRIM(r.app_name)) = LOWER(TRIM(a.app_name))
  WHERE r.sentiment IS NOT NULL
);

SELECT SUM(review_count) AS total_reviews_in_fct
FROM `playstore-analytics-508313.playstore_analytics.fct_sentiment_analysis`;

SELECT SUM(review_count) AS total_reviews_in_fct
FROM `playstore-analytics-508313.playstore_analytics.fct_sentiment_analysis`;

-- 3c. Confirm the three percentages sum to ~100 for every category (catches
-- a stray sentiment value 2a didn't expect)
SELECT category, ROUND(pct_positive + pct_negative + pct_neutral, 1) AS pct_total
FROM `playstore-analytics-508313.playstore_analytics.fct_sentiment_analysis`
WHERE ROUND(pct_positive + pct_negative + pct_neutral, 1) NOT BETWEEN 99.8 AND 100.2;

-- ============================================================
-- STEP 4: CONTENT CHECK (look at the actual values)
-- ============================================================

-- 4a. Full category breakdown, sorted by sentiment polarity
SELECT category, review_count, pct_positive, pct_negative, pct_neutral,
       avg_sentiment_polarity, avg_app_rating
FROM `playstore-analytics-508313.playstore_analytics.fct_sentiment_analysis`
ORDER BY avg_sentiment_polarity DESC;

-- 4b. Headline hypothesis test: actual correlation coefficient between
-- review-level sentiment polarity and the reviewed app's star rating
SELECT ROUND(CORR(a.rating, r.sentiment_polarity), 3) AS polarity_rating_correlation
FROM (
  SELECT DISTINCT app_name, review_text, sentiment, sentiment_polarity, sentiment_subjectivity
  FROM `playstore-analytics-508313.playstore_analytics.stg_reviews`
  WHERE sentiment IS NOT NULL
) AS r
JOIN `playstore-analytics-508313.playstore_analytics.stg_apps` AS a
  ON LOWER(TRIM(r.app_name)) = LOWER(TRIM(a.app_name));

-- 4c. Rank comparison: does a category's polarity rank track its rating rank?
SELECT
  category,
  avg_sentiment_polarity,
  RANK() OVER (ORDER BY avg_sentiment_polarity DESC) AS polarity_rank,
  avg_app_rating,
  RANK() OVER (ORDER BY avg_app_rating DESC) AS rating_rank
FROM `playstore-analytics-508313.playstore_analytics.fct_sentiment_analysis`
ORDER BY polarity_rank;

-- ============================================================
-- STEP 5: CONCLUSION
-- ============================================================
-- Structural integrity confirmed: the two-grain check matches exactly
-- (28,255 = 28,255), all 33 categories are represented, and every category's
-- pct_positive + pct_negative + pct_neutral sums to ~100. Deduping exact
-- duplicate reviews (flagged in 02_stg_reviews.sql) was essential, not
-- precautionary -- ~20.7% of sentiment-bearing reviews (7,740 of 37,432)
-- were exact duplicates that would have double-counted sentiment untreated.
-- Hypothesis DISCONFIRMED as stated, CONFIRMED only weakly: the review-level
-- correlation between sentiment_polarity and app rating is 0.111 -- a real
-- but weak positive relationship, not the strong correlation implied by
-- "sentiment polarity correlates with star rating." Category-level ranks
-- back this up: some categories track closely (AUTO_AND_VEHICLES: polarity
-- rank 3, rating rank 1), while others diverge sharply (EDUCATION: polarity
-- rank 5, rating rank 27 of 33). Star rating and review-text sentiment
-- should be treated as related but distinct signals for the Sentiment
-- Analysis KRA, not interchangeable proxies for each other. Top-polarity
-- categories with thin review counts (e.g. COMICS, n=46) should be read with
-- more caution than high-volume categories like HEALTH_AND_FITNESS (n=1,622).

-- Addendum to STEP 5 CONCLUSION (05_fct_sentiment_analysis.sql):
-- Post-dedup-fix re-check: the original exact-case join (r.app_name = a.app_name)
-- was found to silently orphan 2 apps' worth of reviews once stg_apps started
-- keeping only one case-variant per app (same bug class as the 9,659-vs-9,638
-- issue, one join downstream). Fixed by joining on LOWER(TRIM(app_name)) on
-- both sides. Two-grain check re-confirmed at 28,255 = 28,255; correlation
-- essentially unchanged (0.112 vs. 0.111). No conclusion changes as a result.