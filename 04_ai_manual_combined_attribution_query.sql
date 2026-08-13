/* ============================================================
   AI + Manual Calling Attribution Query (Combined)
   ------------------------------------------------------------
   Purpose: The most advanced attribution model in this
   portfolio — combines the AI voice-calling and manual
   agent-calling channels into a single tie-breaking model to
   decide which channel gets credit for a payment when a
   customer was contacted by BOTH channels in the same window.

   Tie-break hierarchy (in order):
     1. Only one channel made contact -> that channel wins
     2. Both contacted, only one got a PTP (promise-to-pay)
        -> the PTP channel wins
     3. Both contacted with equal PTP outcome -> the channel
        that called closer to the payment date wins
     4. Still tied on days-to-call -> the channel with the
        shorter total talk time wins (proxy for efficiency)
     5. No qualifying contact from either channel -> unattributed

   Techniques demonstrated:
     - Combining two independent attribution CTEs (AI, manual)
       into one base and applying a multi-condition priority
       CASE for conflict resolution
     - JSON parsing of call outcome fields (VARIANT columns)
     - UNION of raw event sources, two-source charges ledger
       reconciliation (due vs. collected vs. waived)
     - Window functions (ROW_NUMBER, RANK, QUALIFY) throughout
       for dedup and "most recent qualifying call" logic
     - Time-zone offset handling (UTC -> IST) and time-string
       parsing (HH24:MI:SS) into total seconds

   Note: Table/column/campaign identifiers below are 
   generalized for portfolio demonstration purposes and do 
   not reflect any employer's actual schema, campaign IDs, 
   or business thresholds.
   ============================================================ */

WITH base AS (
    SELECT DISTINCT
        request_data:loan_id::STRING AS loan_id,
        DATE_TRUNC('month', CAST(DATEADD(minute, 330, created_at) AS DATE)) AS call_month,
        CAST(DATEADD(minute, 330, created_at) AS DATE) AS call_date,
        1 AS attempted_flag
    FROM voice_analytics_db.prod.event_records
    WHERE campaign_id = 'CAMPAIGN_ID_PLACEHOLDER'
),

ai_calling_raw AS (
    SELECT
        loan_id,
        interaction_time::DATE                                                        AS call_date,
        DATE_TRUNC('month', interaction_time::DATE)                                   AS call_month,
        SUM(call_duration)                                                            AS total_tlk_duration,
        MAX(CASE WHEN LOWER(ptp_value) = 'yes' THEN 1 ELSE 0 END)                    AS ptp_flag,
        MAX(CASE WHEN right_party_contact_value >= 1 THEN 1 ELSE 0 END)              AS rpc_flag,
        MAX(CASE WHEN answered_flag >= 1 THEN 1 ELSE 0 END)                          AS answered_flag,
        MAX(CASE WHEN LOWER(refusal_to_pay_classification_value) = 'grievance or dispute' THEN 1 ELSE 0 END) AS grievance_count,
        MAX(CASE WHEN LOWER(refusal_to_pay_classification_value) = 'salary issue'         THEN 1 ELSE 0 END) AS salary_issue_count,
        MAX(CASE WHEN LOWER(refusal_to_pay_classification_value) = 'business loss'        THEN 1 ELSE 0 END) AS business_loss_count,
        MAX(CASE WHEN LOWER(refusal_to_pay_classification_value) = 'job loss'             THEN 1 ELSE 0 END) AS job_loss_count,
        MAX(CASE WHEN LOWER(refusal_to_pay_classification_value) = 'medical issue'        THEN 1 ELSE 0 END) AS medical_issue_count,
        MAX(CASE WHEN LOWER(refusal_to_pay_classification_value) = 'financial problem'    THEN 1 ELSE 0 END) AS financial_problem_count,
        1 AS connected_flag
    FROM (
        SELECT DISTINCT
            CAST(DATEADD(minute, 330, a.created_at) AS TIMESTAMP)                         AS interaction_time,
            metadata:dynamicVariables:loan_id::STRING                                      AS loan_id,
            metadata:callDuration::NUMERIC                                                 AS call_duration,
            RIGHT(metadata:dynamicVariables:phone::STRING, 10)                             AS customer_phone_no,
            CASE WHEN PARSE_JSON(result_insights):data:"Payment Intent Classification":value::STRING IS NULL
                 THEN 'NA'
                 ELSE PARSE_JSON(result_insights):data:"Payment Intent Classification":value::STRING
            END                                                                            AS ptp_value,
            PARSE_JSON(result_insights):data:"Right Party Contact":value::BOOLEAN          AS right_party_contact_value,
            PARSE_JSON(result_insights):data:"Refusal to Pay Classification":value::STRING AS refusal_to_pay_classification_value,
            CASE WHEN metadata:callDuration::NUMERIC >= 10 THEN 1 ELSE 0 END              AS answered_flag,
            result_insights,
            1 AS connected_flag
        FROM voice_analytics_db.calling.text_evaluation_schema a
        WHERE LOWER(metadata:campaignId::STRING) = 'CAMPAIGN_ID_PLACEHOLDER'

        UNION

        SELECT DISTINCT
            CAST(DATEADD(minute, 330, a.created_at) AS TIMESTAMP)                         AS interaction_time,
            metadata:dynamicVariables:loan_id::STRING                                      AS loan_id,
            metadata:callDuration::NUMERIC                                                 AS call_duration,
            RIGHT(metadata:dynamicVariables:phone::STRING, 10)                             AS customer_phone_no,
            CASE WHEN PARSE_JSON(result_insights):data:"Payment Intent Classification":value::STRING IS NULL
                 THEN 'NA'
                 ELSE PARSE_JSON(result_insights):data:"Payment Intent Classification":value::STRING
            END                                                                            AS ptp_value,
            PARSE_JSON(result_insights):data:"Right Party Contact":value::BOOLEAN          AS right_party_contact_value,
            PARSE_JSON(result_insights):data:"Refusal to Pay Classification":value::STRING AS refusal_to_pay_classification_value,
            CASE WHEN metadata:callDuration::NUMERIC >= 10 THEN 1 ELSE 0 END              AS answered_flag,
            result_insights,
            1 AS connected_flag
        FROM voice_analytics_db.calling.voice_analysis_data a
        WHERE LOWER(metadata:campaignId::STRING) = 'CAMPAIGN_ID_PLACEHOLDER'
    )
    GROUP BY 1, 2, 3
),

manual_calling AS (
    SELECT
        loan_id,
        DATE(call_start_time)                              AS call_date,
        DATE_TRUNC('month', call_start_time::DATE)          AS call_month,
        MAX(CASE WHEN call_start_time IS NOT NULL THEN 1 ELSE 0 END) AS f_allocated,
        MAX(CASE WHEN talk_dur > 0 THEN 1 ELSE 0 END)                AS f_connected,
        MAX(CASE WHEN talk_dur >= 10 THEN 1 ELSE 0 END)               AS f_answered,
        MAX(right_party_contacted_flag)                               AS right_party_contacted,
        MAX(CASE WHEN COALESCE(LOWER(disposition), '') IN ('promise to pay', 'future ptp') THEN 1 ELSE 0 END) AS ptp_flag,
        SUM(talk_dur)                                                  AS total_call_duration
    FROM (
        SELECT
            loan_id,
            RIGHT(customer_contact_number, 10)   AS phone_number,
            allocation_month,
            call_start_time,
            call_status,
            total_talk_time_duration,
            disposition,
            CASE WHEN disposition = 'rpc' THEN 1 ELSE 0 END AS right_party_contacted_flag,
            EXTRACT(HOUR   FROM TO_TIMESTAMP(total_talk_time_duration, 'HH24:MI:SS')) * 3600 +
            EXTRACT(MINUTE FROM TO_TIMESTAMP(total_talk_time_duration, 'HH24:MI:SS')) * 60 +
            EXTRACT(SECOND FROM TO_TIMESTAMP(total_talk_time_duration, 'HH24:MI:SS'))        AS talk_dur
        FROM analytics_db.prod.calling_vendor_data
        QUALIFY ROW_NUMBER() OVER (PARTITION BY shoot_id ORDER BY call_start_time DESC) = 1
    ) a
    GROUP BY 1, 2, 3
),

payment_mode AS (
    SELECT
        loan_id,
        mode_of_payment,
        transaction_date
    FROM (
        SELECT loan_id, mode_of_payment, transaction_date
        FROM analytics_db.prod.payment_transaction_data
        UNION
        SELECT loan_id, mode_of_payment, transaction_date
        FROM analytics_db.prod.payment_transaction_data_v2
    )
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY loan_id, DATE(transaction_date)
        ORDER BY transaction_date
    ) = 1
),

payment_data AS (
    SELECT *, DATE_TRUNC('month', transaction_date) AS transaction_month
    FROM (
        SELECT DISTINCT p.*,
               COALESCE(p.fee_charges_portion_derived, 0)
               + COALESCE(p.penalty_charges_portion_derived, 0) AS charges_payment
        FROM analytics_db.prod.payment_data_v2 p
        UNION
        SELECT DISTINCT p.*,
               COALESCE(p.fee_charges_portion_derived, 0)
               + COALESCE(p.penalty_charges_portion_derived, 0) AS charges_payment
        FROM analytics_db.prod.payment_data p
    )
    WHERE charges_payment > 0
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY loan_id, DATE_TRUNC('month', transaction_date)
        ORDER BY transaction_date
    ) = 1
),

ai_payment_base AS (
    SELECT DISTINCT
        pd.loan_id,
        pd.transaction_month,
        pd.transaction_date,
        pd.charges_payment,
        ac.call_date          AS ai_call_date,
        ac.call_month         AS ai_call_month,
        ac.ptp_flag           AS ai_ptp_flag,
        ac.rpc_flag           AS ai_rpc_flag,
        ac.answered_flag      AS ai_answered_flag,
        ac.connected_flag     AS ai_connected_flag,
        ac.total_tlk_duration AS ai_total_tlk_duration,
        DATEDIFF('day', ac.call_date, pd.transaction_date) AS days_to_ai_call
    FROM payment_data pd
    LEFT JOIN ai_calling_raw ac
           ON ac.loan_id          = pd.loan_id
          AND pd.transaction_date >= ac.call_date
          AND (ac.call_date >= pd.transaction_date - 7 OR ac.call_month = pd.transaction_month)
          AND ac.answered_flag    = 1
    QUALIFY RANK() OVER (
        PARTITION BY pd.loan_id, pd.transaction_month
        ORDER BY ac.call_date DESC
    ) = 1
),

manual_payment_base AS (
    SELECT DISTINCT
        pd.loan_id,
        pd.transaction_month,
        pd.transaction_date,
        pd.charges_payment,
        mc.call_date          AS manual_call_date,
        mc.call_month         AS manual_call_month,
        mc.ptp_flag           AS manual_ptp_flag,
        mc.f_answered         AS manual_answered_flag,
        mc.f_connected        AS manual_connected_flag,
        mc.total_call_duration AS manual_total_tlk_duration,
        DATEDIFF('day', mc.call_date, pd.transaction_date) AS days_to_manual_call
    FROM payment_data pd
    LEFT JOIN manual_calling mc
           ON mc.loan_id          = pd.loan_id
          AND pd.transaction_date >= mc.call_date
          AND (mc.call_date >= pd.transaction_date - 7 AND mc.call_month = pd.transaction_month)
          AND mc.f_answered       = 1
    QUALIFY RANK() OVER (
        PARTITION BY pd.loan_id, pd.transaction_month
        ORDER BY mc.call_date DESC
    ) = 1
),

/* Combined attribution — tie-break hierarchy described in the
   header comment above resolves cases where both channels
   contacted the same customer before the same payment */
payment_master AS (
    SELECT
        a.*,
        a.ai_call_date     AS ai_last_answered_call_date,
        a.manual_call_date AS manual_last_answered_call_date,
        pmd.mode_of_payment,
        CASE
            WHEN (charges_payment = 0)
              OR (a.ai_call_date IS NULL AND a.manual_call_date IS NULL)
              OR (LOWER(pmd.mode_of_payment) IN ('nach', 'online-nach'))
                THEN 'No one'
            WHEN a.ai_call_date IS NOT NULL AND a.manual_call_date IS NOT NULL
             AND a.ai_ptp_flag = 1 AND a.manual_ptp_flag = 0
                THEN 'ai'
            WHEN a.ai_call_date IS NOT NULL AND a.manual_call_date IS NOT NULL
             AND a.ai_ptp_flag = 0 AND a.manual_ptp_flag = 1
                THEN 'manual'
            WHEN a.ai_call_date IS NOT NULL AND a.manual_call_date IS NOT NULL
             AND a.ai_ptp_flag = a.manual_ptp_flag AND a.days_to_ai_call < a.days_to_manual_call
                THEN 'ai'
            WHEN a.ai_call_date IS NOT NULL AND a.manual_call_date IS NOT NULL
             AND a.ai_ptp_flag = a.manual_ptp_flag AND a.days_to_ai_call > a.days_to_manual_call
                THEN 'manual'
            WHEN a.ai_call_date IS NOT NULL AND a.manual_call_date IS NOT NULL
             AND a.days_to_ai_call = a.days_to_manual_call AND a.manual_total_tlk_duration < a.ai_total_tlk_duration
                THEN 'ai'
            WHEN a.ai_call_date IS NOT NULL AND a.manual_call_date IS NOT NULL
             AND a.days_to_ai_call = a.days_to_manual_call AND a.manual_total_tlk_duration > a.ai_total_tlk_duration
                THEN 'manual'
            WHEN a.ai_call_date IS NOT NULL AND a.manual_call_date IS NULL
                THEN 'ai'
            WHEN a.ai_call_date IS NULL AND a.manual_call_date IS NOT NULL
                THEN 'manual'
            ELSE 'No one'
        END AS payment_attribution
    FROM (
        SELECT
            apb.*,
            manual_call_date, manual_call_month, manual_ptp_flag,
            manual_answered_flag, manual_connected_flag,
            manual_total_tlk_duration, days_to_manual_call
        FROM ai_payment_base apb
        LEFT JOIN manual_payment_base mpb
               ON mpb.loan_id           = apb.loan_id
              AND mpb.transaction_date  = apb.transaction_date
              AND mpb.transaction_month = apb.transaction_month
              AND mpb.charges_payment   = apb.charges_payment
    ) a
    LEFT JOIN payment_mode pmd
           ON pmd.loan_id          = a.loan_id
          AND pmd.transaction_date = a.transaction_date
),

/* Charges ledger — reconciles two source feeds (vendor A / vendor B)
   into a single "due vs. collected vs. waived" view per loan */
charges_base AS (
    SELECT
        loan_id,
        COALESCE(total_charges_till_date, 0)                  AS total_charges_till_date,
        COALESCE(total_charges_received_till_date, 0)         AS total_charges_received_till_date,

        COALESCE(penal_interest_amount_till_date, 0)          AS penal_interest_amount_till_date,
        COALESCE(late_payment_amount_till_date, 0)            AS late_payment_amount_till_date,
        COALESCE(bounce_amount_till_date, 0)                  AS bounce_amount_till_date,
        COALESCE(legal_notice_charges_till_date, 0)           AS legal_notice_charges_till_date,
        COALESCE(fuel_till_date, 0)                           AS fuel_till_date,
        COALESCE(visit_charges_till_date, 0)                  AS visit_charges_till_date,

        COALESCE(penal_interest_amount_received_till_date, 0) AS penal_interest_amount_received_till_date,
        COALESCE(bounce_amount_received_till_date, 0)         AS bounce_amount_received_till_date,
        COALESCE(late_payment_amount_received_till_date, 0)   AS late_payment_amount_received_till_date,
        COALESCE(legal_notice_charges_received_till_date, 0)  AS legal_notice_charges_received_till_date,
        COALESCE(fuel_received_till_date, 0)                  AS fuel_received_till_date,
        COALESCE(visit_charges_received_till_date, 0)         AS visit_charges_received_till_date,

        COALESCE(penal_interest_amount_received_monthly, 0)   AS penal_interest_amount_received_monthly,
        COALESCE(late_payment_amount_received_monthly, 0)     AS late_payment_amount_received_monthly,
        COALESCE(bounce_amount_received_monthly, 0)           AS bounce_amount_received_monthly,
        COALESCE(legal_notice_charges_received_monthly, 0)    AS legal_notice_charges_received_monthly,
        COALESCE(fuel_received_monthly, 0)                    AS fuel_received_monthly,
        COALESCE(visit_charges_received_monthly, 0)           AS visit_charges_received_monthly,

        COALESCE(penal_interest_amount_waiver_till_date, 0)   AS penal_interest_amount_waiver_till_date,
        COALESCE(late_payment_amount_waiver_till_date, 0)     AS late_payment_amount_waiver_till_date,
        COALESCE(bounce_amount_waiver_till_date, 0)           AS bounce_amount_waiver_till_date,
        COALESCE(legal_notice_charges_waiver_till_date, 0)    AS legal_notice_charges_waiver_till_date,
        COALESCE(fuel_waiver_till_date, 0)                    AS fuel_waiver_till_date,
        COALESCE(visit_charges_waiver_till_date, 0)           AS visit_charges_waiver_till_date,
        event_date,
        'source_a' AS src
    FROM analytics_db.prod.loan_charges_split_a
    UNION
    SELECT
        loan_id,
        COALESCE(total_charges_till_date, 0)                  AS total_charges_till_date,
        COALESCE(total_charges_received_till_date, 0)         AS total_charges_received_till_date,

        COALESCE(penal_interest_amount_till_date, 0)          AS penal_interest_amount_till_date,
        COALESCE(late_payment_amount_till_date, 0)            AS late_payment_amount_till_date,
        COALESCE(bounce_amount_till_date, 0)                  AS bounce_amount_till_date,
        COALESCE(legal_notice_charges_till_date, 0)           AS legal_notice_charges_till_date,
        COALESCE(fuel_till_date, 0)                           AS fuel_till_date,
        COALESCE(visit_charges_till_date, 0)                  AS visit_charges_till_date,

        COALESCE(penal_interest_amount_received_till_date, 0) AS penal_interest_amount_received_till_date,
        COALESCE(bounce_amount_received_till_date, 0)         AS bounce_amount_received_till_date,
        COALESCE(late_payment_amount_received_till_date, 0)   AS late_payment_amount_received_till_date,
        COALESCE(legal_notice_charges_received_till_date, 0)  AS legal_notice_charges_received_till_date,
        COALESCE(fuel_received_till_date, 0)                  AS fuel_received_till_date,
        COALESCE(visit_charges_received_till_date, 0)         AS visit_charges_received_till_date,

        COALESCE(penal_interest_amount_received_monthly, 0)   AS penal_interest_amount_received_monthly,
        COALESCE(late_payment_amount_received_monthly, 0)     AS late_payment_amount_received_monthly,
        COALESCE(bounce_amount_received_monthly, 0)           AS bounce_amount_received_monthly,
        COALESCE(legal_notice_charges_received_monthly, 0)    AS legal_notice_charges_received_monthly,
        COALESCE(fuel_received_monthly, 0)                    AS fuel_received_monthly,
        COALESCE(visit_charges_received_monthly, 0)           AS visit_charges_received_monthly,

        COALESCE(penal_interest_amount_waiver_till_date, 0)   AS penal_interest_amount_waiver_till_date,
        COALESCE(late_payment_amount_waiver_till_date, 0)     AS late_payment_amount_waiver_till_date,
        COALESCE(bounce_amount_waiver_till_date, 0)           AS bounce_amount_waiver_till_date,
        COALESCE(legal_notice_charges_waiver_till_date, 0)    AS legal_notice_charges_waiver_till_date,
        COALESCE(fuel_waiver_till_date, 0)                    AS fuel_waiver_till_date,
        COALESCE(visit_charges_waiver_till_date, 0)           AS visit_charges_waiver_till_date,
        event_date,
        'source_b' AS src
    FROM analytics_db.prod.loan_charges_split_b
),

charges_base_final AS (
    SELECT
        loan_id,
        (penal_interest_amount_till_date + late_payment_amount_till_date + bounce_amount_till_date
          + legal_notice_charges_till_date + fuel_till_date + visit_charges_till_date)
        -
        (penal_interest_amount_received_till_date + bounce_amount_received_till_date + late_payment_amount_received_till_date
          + legal_notice_charges_received_till_date + fuel_received_till_date + visit_charges_received_till_date)
        -
        (penal_interest_amount_waiver_till_date + late_payment_amount_waiver_till_date + bounce_amount_waiver_till_date
          + legal_notice_charges_waiver_till_date + fuel_waiver_till_date + visit_charges_waiver_till_date)
        AS total_charges_due,
        (
            penal_interest_amount_received_monthly + late_payment_amount_received_monthly + bounce_amount_received_monthly +
            legal_notice_charges_received_monthly + fuel_received_monthly + visit_charges_received_monthly
        ) AS total_charges_collected,
        DATE_TRUNC('month', event_date::DATE) AS event_month
    FROM charges_base
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY loan_id, DATE_TRUNC('month', event_date)
        ORDER BY event_date DESC
    ) = 1
),

loan_status AS (
    SELECT DISTINCT
        loan_id,
        loan_status,
        DATE_TRUNC('month', ADD_MONTHS(loan_book_date, 1)) AS lb_date,
        current_dpd_bkt                                     AS prev_dpd_bucket
    FROM analytics_db.prod.loan_performance_details
)

SELECT DISTINCT
    b.loan_id,
    b.call_month                                                          AS lb_month,
    ls.loan_status,
    ls.prev_dpd_bucket,
    b.ai_attempted_calls,
    ai.ai_connected_calls,
    ai.ai_answered_calls,
    ai.ai_grievance_counts,
    ai.ai_ptp_calls,
    ai.ai_rpc_calls,
    ai.ai_tlk_duration,
    manual.manual_attempts,
    manual.manual_connected,
    manual.manual_answered,
    manual.manual_ptp,
    manual.manual_rpc_calls,
    manual.manual_tlk_duration,
    pm.transaction_date                                                   AS payment_date,
    pm.ai_last_answered_call_date,
    pm.manual_last_answered_call_date,
    cbf.total_charges_due,
    cbf.total_charges_collected,
    pm.charges_payment                                                    AS charges_paid,
    pm.mode_of_payment,
    CASE WHEN pm.loan_id IS NULL THEN 'Not paid' ELSE 'Paid' END          AS payment_status,
    CASE
        WHEN LOWER(ls.loan_status) = 'foreclosed' OR pm.loan_id IS NULL  THEN 'No one'
        ELSE pm.payment_attribution
    END                                                                   AS payment_attribution,
    CASE
        WHEN LOWER(ls.loan_status) = 'tenure closed' THEN 'Tenure Closed'
        WHEN prev_dpd_bucket = 0                     THEN 'Current'
        ELSE 'other'
    END                                                                   AS loan_bucket_new,
    ai.ai_job_loss_count,
    ai.ai_business_loss_count,
    ai.ai_financial_problem_count,
    ai.ai_salary_issue_count,
    ai.ai_medical_issue_count
FROM (
    SELECT loan_id, call_month, COUNT(DISTINCT call_date) AS ai_attempted_calls
    FROM base
    GROUP BY 1, 2
) b
LEFT JOIN (
    SELECT
        loan_id,
        call_month,
        SUM(connected_flag)          AS ai_connected_calls,
        SUM(answered_flag)           AS ai_answered_calls,
        SUM(grievance_count)         AS ai_grievance_counts,
        SUM(ptp_flag)                AS ai_ptp_calls,
        SUM(rpc_flag)                AS ai_rpc_calls,
        SUM(total_tlk_duration)      AS ai_tlk_duration,
        SUM(job_loss_count)          AS ai_job_loss_count,
        SUM(business_loss_count)     AS ai_business_loss_count,
        SUM(salary_issue_count)      AS ai_salary_issue_count,
        SUM(financial_problem_count) AS ai_financial_problem_count,
        SUM(medical_issue_count)     AS ai_medical_issue_count
    FROM ai_calling_raw
    GROUP BY 1, 2
) ai ON ai.loan_id = b.loan_id AND b.call_month = ai.call_month
LEFT JOIN (
    SELECT
        loan_id,
        call_month,
        SUM(f_allocated)             AS manual_attempts,
        SUM(f_connected)             AS manual_connected,
        SUM(f_answered)              AS manual_answered,
        SUM(ptp_flag)                AS manual_ptp,
        SUM(right_party_contacted)   AS manual_rpc_calls,
        SUM(total_call_duration)     AS manual_tlk_duration
    FROM manual_calling
    GROUP BY 1, 2
) manual ON manual.loan_id = b.loan_id AND manual.call_month = b.call_month
LEFT JOIN loan_status ls ON ls.loan_id = b.loan_id AND b.call_month = ls.lb_date
LEFT JOIN payment_master pm ON pm.loan_id = b.loan_id AND b.call_month = pm.transaction_month
LEFT JOIN charges_base_final cbf ON cbf.loan_id = b.loan_id AND cbf.event_month = b.call_month
WHERE b.call_month BETWEEN '2026-03-01' AND '2026-03-31';
