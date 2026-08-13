/* ============================================================
   Input Metrics — Charges Calling Funnel Query
   ------------------------------------------------------------
   Purpose: Builds the core "calling funnel" input metrics used
   to evaluate a charges-collection calling campaign: attempts
   made, calls answered, talk time, right-party-contact rate,
   promise-to-pay rate, and downstream payment resolution —
   joined against behavioral segment tags and field-visit
   activity for context.

   Approach:
     1. Pull raw AI call attempts from the voice engine event
        log, counting attempts per phone/lead per day.
     2. Pull connected-call outcomes (answered flag, talk time,
        right-party-contact, payment intent) from the call
        evaluation log, restricted to specific campaign names.
     3. Attach each call to the customer's latest behavioral
        segment tag for that month.
     4. Pull the first field-visit date per loan per month, as
        a secondary collections-channel signal.
     5. Pull the earliest payment against that month's due
        date, to determine whether the account resolved.
     6. Join attempts -> connects -> payments and label each
        account as paid/unpaid for the period.

   Techniques demonstrated:
     - Parsing semi-structured JSON fields (VARIANT columns,
       ARRAY_SIZE on a nested call-log array)
     - COALESCE/NULLIF chains to normalize inconsistent field
       casing across upstream systems (loan_id vs loan_Id)
     - Hashed join key (MD5-based) to match phone numbers
       across systems without storing/joining on raw values
       side by side
     - Multi-source funnel construction: attempts -> connects
       -> segment enrichment -> field visits -> payment outcome

   Note: Table/campaign identifiers below are generalized for
   portfolio demonstration purposes and do not reflect any
   employer's actual schema or campaign configuration.
   ============================================================ */

WITH ai_calls AS (
    SELECT DISTINCT
        request_data:contact_string::STRING AS phone,
        created_at,
        ARRAY_SIZE(PARSE_JSON(meta_data):callRecordLogList) AS attempt_number,
        COALESCE(
            NULLIF(request_data:loan_id::STRING, ''),
            NULLIF(request_data:loan_Id::STRING, '')
        ) AS lead_id
    FROM voice_analytics_db.prod.event_records
    WHERE created_at >= '2026-02-01'
      AND campaign_id IN ('CAMPAIGN_ID_PLACEHOLDER_1', 'CAMPAIGN_ID_PLACEHOLDER_2')
),

ai_attempt_calls AS (
    SELECT
        phone, lead_id, created_at::DATE AS attempt_date, new_segments,
        SUM(attempt_number) AS total_calls
    FROM (
        SELECT a.*, new_segments
        FROM ai_calls a
        LEFT JOIN analytics_db.gsheet.post_emi_segmentation s
               ON a.lead_id = s.loan_id
              AND DATE_TRUNC('month', a.created_at::DATE) = DATE_TRUNC('month', etl_date::DATE)
    )
    GROUP BY 1, 2, 3, 4
),

connected_calls AS (
    SELECT
        COALESCE(t.metadata:phone::STRING, t.metadata:dynamicVariables.phone::STRING) AS phone,
        t.metadata:callDuration::INT AS call_duration,
        CASE WHEN LOWER(result_insights:data:"Open":value:callStatus::STRING) NOT ILIKE 'voicemail' THEN 1 ELSE 0 END AS call_answer_flag,
        t.metadata:campaignName::STRING AS campaign_name,
        CAST(DATEADD(minute, 330, t.created_at) AS DATE) AS connect_date,
        DATEADD(minute, 330, t.created_at) AS connect_time,
        DATE_TRUNC('month', connect_date::DATE) AS call_month,
        result_insights:data:"Right Party Contact":value::BOOLEAN AS right_party_contact,
        result_insights:data:"Payment Intent Classification":value::STRING AS payment_intent_classification,
        COALESCE(
            NULLIF(TRIM(metadata:dynamicVariables:loan_id::STRING), ''),
            NULLIF(TRIM(metadata:dynamicVariables:loan_Id::STRING), '')
        ) AS loan_id
    FROM voice_analytics_db.calling.text_evaluation_schema t
    WHERE LOWER(t.metadata:campaignName::STRING) IN ('charges_calling_campaign', 'charges_calling_campaign_ai_only')
      AND CAST(DATEADD(minute, 330, t.created_at) AS DATE) >= '2026-03-01'
),

connects_with_segments AS (
    SELECT
        phone, loan_id, connect_date, new_segments,
        COUNT(CASE WHEN call_answer_flag = 1 THEN phone END) AS answered,
        SUM(CASE WHEN call_answer_flag = 1 THEN call_duration ELSE 0 END) AS talk_time,
        COUNT(CASE WHEN LOWER(right_party_contact::STRING) = 'true' THEN phone END) AS rpc,
        COUNT(CASE WHEN LOWER(payment_intent_classification) = 'yes' THEN phone END) AS ptp
    FROM (
        SELECT c.*, new_segments
        FROM connected_calls c
        LEFT JOIN analytics_db.gsheet.post_emi_segmentation s
               ON c.loan_id = s.loan_id
              AND DATE_TRUNC('month', c.connect_date) = DATE_TRUNC('month', etl_date::DATE)
    )
    GROUP BY 1, 2, 3, 4
),

first_field_visit AS (
    SELECT
        loan_id,
        DATE_TRUNC('month', doc_created_at::DATE) AS fr_month,
        MIN(doc_created_at::DATE) AS first_field_visit_date
    FROM analytics_db.prod.allocation_deallocation_data
    WHERE LOWER(user_role) LIKE '%field%'
      AND doc_created_at >= '2026-02-01'
    GROUP BY 1, 2
),

payment_base AS (
    SELECT
        loan_id,
        DATE_TRUNC('month', due_date) AS due_month,
        MIN(payment_date) AS payment_date,
        MIN(due_date) AS due_date
    FROM analytics_db.prod.repayment_schedule
    WHERE due_date >= '2026-02-01'
    GROUP BY 1, 2
)

SELECT
    *,
    CASE WHEN payment_date IS NOT NULL THEN 'paid' ELSE 'unpaid' END AS resolved
FROM ai_attempt_calls a
LEFT JOIN connects_with_segments c
       ON MD5_NUMBER_LOWER64(a.phone) = c.phone
      AND a.attempt_date = c.connect_date
LEFT JOIN payment_base p
       ON p.loan_id = a.lead_id
      AND DATE_TRUNC('month', attempt_date::DATE) = p.due_month
WHERE a.attempt_date BETWEEN '2026-04-01' AND '2026-04-30';
