/* ============================================================
   AOP Collection Target — Daily Interpolation View
   ------------------------------------------------------------
   Purpose: Converts monthly Annual Operating Plan (AOP)
   collection targets — set as three checkpoints per month
   (10th, 20th, Month End) for two metrics, Resolution % and
   Roll-back % — into a smooth daily target curve per
   Region x Bucket. This lets actual daily collections
   performance be tracked against a day-by-day target rather
   than only checked at month-end.

   Approach:
     1. Parse target values from string percentages ('26.08%')
        into decimals.
     2. Pivot the three checkpoints (10th / 20th / Month End)
        into columns per Region x Bucket x Month.
     3. Generate a calendar-day spine and linearly interpolate
        between checkpoints:
          - Day 1  -> 10th:   ramps from 0 to the 10th-checkpoint target
          - 11th   -> 20th:   ramps from the 10th to the 20th checkpoint
          - 21st   -> month end: ramps from the 20th checkpoint
            to the month-end target
     4. Output one row per Region x Bucket x Date with the
        interpolated Resolution % and Roll-back % target.

   Techniques demonstrated:
     - Pivoting long-format checkpoint data into wide format
       via conditional aggregation (MAX + CASE)
     - Generating a date spine with a row-generator function
       (GENERATOR + SEQ4) and joining it to bound each month
     - Piecewise linear interpolation implemented in pure SQL
     - View creation for a reusable, queryable daily target
       curve consumed downstream by dashboards

   Note: Database/table identifiers below are generalized for
   portfolio demonstration purposes and do not reflect any
   employer's actual schema.
   ============================================================ */

CREATE OR REPLACE VIEW analytics_db.pre_prod.vw_collection_aop_targets_daily AS
WITH src AS (
    SELECT
        region, region_sort, bucket, bucket_sort, month, month_sort,
        checkpoint, metric,
        TRY_CAST(REPLACE(value, '%', '') AS FLOAT) / 100 AS v   -- '26.08%' -> 0.2608
    FROM analytics_db.pre_prod.collection_aop_targets
),

-- one row per Region/Bucket/Month with the three checkpoints pivoted out
targets AS (
    SELECT
        region, region_sort, bucket, bucket_sort, month, month_sort,
        COALESCE(MAX(CASE WHEN checkpoint = '10th'      AND metric = 'Res%' THEN v END), 0) AS r10,
        COALESCE(MAX(CASE WHEN checkpoint = '10th'      AND metric = 'RB%'  THEN v END), 0) AS rb10,
        COALESCE(MAX(CASE WHEN checkpoint = '20th'      AND metric = 'Res%' THEN v END), 0) AS r20,
        COALESCE(MAX(CASE WHEN checkpoint = '20th'      AND metric = 'RB%'  THEN v END), 0) AS rb20,
        COALESCE(MAX(CASE WHEN checkpoint = 'Month End' AND metric = 'Res%' THEN v END), 0) AS rme,
        COALESCE(MAX(CASE WHEN checkpoint = 'Month End' AND metric = 'RB%'  THEN v END), 0) AS rbme
    FROM src
    GROUP BY region, region_sort, bucket, bucket_sort, month, month_sort
),

-- derives month-start / month-end calendar dates from a sortable month index
month_map AS (
    SELECT DISTINCT
        month, month_sort,
        DATEADD(month, month_sort - 1, DATE '2026-05-01')           AS ms,
        LAST_DAY(DATEADD(month, month_sort - 1, DATE '2026-05-01')) AS me
    FROM analytics_db.pre_prod.collection_aop_targets
),

-- 0..30 day offsets (trimmed per-month by the join below)
days AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS n
    FROM TABLE(GENERATOR(ROWCOUNT => 31))
),

daily AS (
    SELECT
        t.region, t.region_sort, t.bucket, t.bucket_sort,
        t.month, t.month_sort,
        DATEADD(day, d.n, mm.ms) AS dt, mm.me,
        t.r10, t.rb10, t.r20, t.rb20, t.rme, t.rbme
    FROM targets t
    JOIN month_map mm ON t.month = mm.month
    JOIN days d       ON DATEADD(day, d.n, mm.ms) <= mm.me
)

SELECT
    region,
    bucket,
    dt AS "Date",
    -- Res%: ramp 0->R10 (days 1-11), R10->R20 (days 11-21), R20->month end (day 21->last)
    CASE
        WHEN DAY(dt) <= 10 THEN r10 / 10 * (DAY(dt) - 1)
        WHEN DAY(dt) <= 20 THEN (r20 - r10) / 10 * (DAY(dt) - 11) + r10
        WHEN dt = me        THEN rme
        ELSE (rme - r20) / (DAY(me) - 20) * (DAY(dt) - 21) + r20
    END AS "Res%",
    CASE
        WHEN DAY(dt) <= 10 THEN rb10 / 10 * (DAY(dt) - 1)
        WHEN DAY(dt) <= 20 THEN (rb20 - rb10) / 10 * (DAY(dt) - 11) + rb10
        WHEN dt = me        THEN rbme
        ELSE (rbme - rb20) / (DAY(me) - 20) * (DAY(dt) - 21) + rb20
    END AS "RB%"
FROM daily
ORDER BY region_sort, bucket_sort, "Date";
