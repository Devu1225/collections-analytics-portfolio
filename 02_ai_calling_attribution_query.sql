/* ============================================================
   AI Calling Attribution Query
   ------------------------------------------------------------
   Purpose: Attributes monthly collections/charge payments to
   an AI voice-calling channel vs. other recovery channels, by
   linking call interaction logs (PTP, RPC, answered/connected
   flags, refusal-to-pay reason classification) with payment
   transaction data, then rolling up into a monthly attribution
   summary (collections credited to AI calling vs. no channel).

   Techniques demonstrated:
     - Parsing semi-structured JSON fields (VARIANT columns)
       for call outcome classification
     - UNION of multiple raw event sources into one call log
     - Window functions (ROW_NUMBER, RANK) for dedup and
       "most recent qualifying call before payment" logic
     - Time-zone offset handling (UTC -> IST via DATEADD)
     - Multi-stage attribution logic: raw call log -> payment
       join -> attribution rule -> monthly rollup
     - Recovery-type and DPD-bucket classification via CASE

   Note: Table/column/campaign identifiers below are 
   generalized for portfolio demonstration purposes and do 
   not reflect any employer's actual schema, campaign IDs, 
   or business thresholds.
   ============================================================ */

WITH base AS (
    SELECT DISTINCT
        request_data:loan_id::STRING AS loan_id,
        DATE_TRUNC('month', CAST(DATEADD(minute, 330, created_at) AS DATE)) AS call_month,
        CAST(DATEADD(minute, 330, created_at) AS DATE) AS call_date
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
    WHERE interaction_time::DATE >= '2026-02-01'
    GROUP BY 1, 2, 3
),

payment_mode AS (
    SELECT loan_id, mode_of_payment, transaction_date
    FROM (
        SELECT loan_id, mode_of_payment, transaction_date
        FROM analytics_db.prod.payment_transaction_data
        WHERE transaction_date >= '2026-02-01'
        UNION
        SELECT loan_id, mode_of_payment, transaction_date
        FROM analytics_db.prod.payment_transaction_data_v2
        WHERE transaction_date >= '2026-02-01'
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
               + COALESCE(p.penalty_charges_portion_derived, 0) AS charges_payment,
               COALESCE(p.principal_portion_derived, 0)
               + COALESCE(p.interest_portion_derived, 0)        AS emi_payment
        FROM analytics_db.prod.payment_data_v2 p
        UNION
        SELECT DISTINCT p.*,
               COALESCE(p.fee_charges_portion_derived, 0)
               + COALESCE(p.penalty_charges_portion_derived, 0) AS charges_payment,
               COALESCE(p.principal_portion_derived, 0)
               + COALESCE(p.interest_portion_derived, 0)        AS emi_payment
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
        pd.emi_payment,
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

payment_master AS (
    SELECT
        a.*,
        a.ai_call_date AS ai_last_answered_call_date,
        pmd.mode_of_payment,
        CASE
            WHEN (a.charges_payment = 0)
              OR (a.ai_call_date IS NULL)
              OR (LOWER(pmd.mode_of_payment) IN ('nach', 'online-nach')) THEN 'No one'
            WHEN a.ai_call_date IS NOT NULL
             AND (a.ai_ptp_flag = 1 OR a.ai_answered_flag = 1)           THEN 'ai'
            ELSE 'No one'
        END AS payment_attribution
    FROM ai_payment_base a
    LEFT JOIN payment_mode pmd
           ON pmd.loan_id          = a.loan_id
          AND pmd.transaction_date = a.transaction_date
),

loan_master AS (
    SELECT
        loan_id,
        applicant_name,
        applicant_contact_number,
        emi_amount,
        emi_date,
        loan_end_date,
        first_emi_due_date,
        loan_sanction_date
    FROM analytics_db.prod.loan_master_data
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY loan_id
        ORDER BY emi_date DESC
    ) = 1
),

charges_final AS (
    SELECT
        loan_id,
        total_charges_due_till_date      AS total_charges_due,
        total_charges_received_till_date AS total_charges_collected,
        DATE_TRUNC('month', event_date::DATE) AS event_month
    FROM analytics_db.pre_prod.loan_charges_split
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY loan_id, DATE_TRUNC('month', event_date)
        ORDER BY event_date DESC
    ) = 1
),

/* Corrected attribution — computed after applying foreclosed / unpaid overrides */
corrected_attribution AS (
    SELECT
        b.loan_id,
        b.call_month,
        pm.transaction_date,
        COALESCE(pm.charges_payment, 0) AS charges_payment
    FROM (
        SELECT loan_id, call_month
        FROM base
        GROUP BY 1, 2
    ) b
    LEFT JOIN payment_master pm
           ON pm.loan_id        = b.loan_id
          AND b.call_month      = pm.transaction_month
),

attribution_summary AS (
    SELECT
        call_month                                                                              AS transaction_month,
        SUM(CASE WHEN payment_attribution = 'ai'     THEN charges_payment ELSE 0 END)         AS ai_attributed_total_collection,
        SUM(CASE WHEN payment_attribution = 'No one' THEN charges_payment ELSE 0 END)         AS no_one_attributed_total_collection,
        SUM(charges_payment)                                                                   AS overall_total_collection,
        COUNT(DISTINCT CASE WHEN payment_attribution = 'ai'     THEN loan_id END)             AS ai_attributed_loan_count,
        COUNT(DISTINCT CASE WHEN payment_attribution = 'No one' THEN loan_id END)             AS no_one_attributed_loan_count,
        COUNT(DISTINCT loan_id)                                                                AS total_attributed_loan_count
    FROM corrected_attribution
    GROUP BY call_month
)

SELECT DISTINCT
    b.loan_id,
    b.call_month                                                          AS lb_month,

    -- Loan attributes
    lm.applicant_name,
    lm.applicant_contact_number,
    lm.emi_amount                                                         AS installment_amount,
    lm.emi_date,
    lm.loan_end_date,
    lm.first_emi_due_date,
    lm.loan_sanction_date,

    -- Loan performance status
    ls.loan_status                                                        AS perf_loan_status,
    ls.prev_dpd_bucket,

    -- AI calling metrics
    b.ai_attempted_calls,
    ai.ai_connected_calls,
    ai.ai_answered_calls,
    ai.ai_grievance_counts,
    ai.ai_ptp_calls,
    ai.ai_rpc_calls,
    ai.ai_tlk_duration,
    ai.ai_job_loss_count,
    ai.ai_business_loss_count,
    ai.ai_financial_problem_count,
    ai.ai_salary_issue_count,
    ai.ai_medical_issue_count,

    -- Payment details
    pm.transaction_date                                                   AS payment_date,
    pm.ai_last_answered_call_date,
    pm.mode_of_payment,
    CASE WHEN pm.loan_id IS NULL THEN 'Not paid' ELSE 'Paid' END          AS payment_status,
    CASE
        WHEN LOWER(ls.loan_status) = 'foreclosed' OR pm.loan_id IS NULL  THEN 'No one'
        ELSE pm.payment_attribution
    END                                                                   AS payment_attribution,

    -- Charges
    cbf.total_charges_due,
    cbf.total_charges_collected,
    pm.charges_payment                                                    AS charges_paid_this_month,

    -- EMI paid this month
    COALESCE(pm.emi_payment, 0)                                           AS emi_paid_this_month,

    -- Total due = installment + outstanding charges
    COALESCE(lm.emi_amount, 0)
        + COALESCE(cbf.total_charges_due, 0)                             AS total_due_this_month,

    -- Total received = EMI paid + charges paid
    COALESCE(pm.emi_payment, 0)
        + COALESCE(pm.charges_payment, 0)                                AS total_received_this_month,

    -- Recovery type
    CASE
        WHEN COALESCE(pm.emi_payment, 0) = 0
         AND COALESCE(pm.charges_payment, 0) = 0
            THEN 'NOT_RECOVERED'
        WHEN COALESCE(pm.emi_payment, 0) >= COALESCE(lm.emi_amount, 0)
         AND COALESCE(pm.charges_payment, 0) >= COALESCE(cbf.total_charges_due, 0)
            THEN 'FULL_RECOVERY'
        WHEN COALESCE(pm.emi_payment, 0) >= COALESCE(lm.emi_amount, 0)
          OR COALESCE(pm.charges_payment, 0) = 0
            THEN 'PARTIAL_RECOVERY'
        ELSE 'NOT_RECOVERED'
    END                                                                   AS recovery_type,

    -- Loan bucket
    CASE
        WHEN LOWER(ls.loan_status) = 'tenure closed' THEN 'Tenure Closed'
        WHEN ls.prev_dpd_bucket = 0                  THEN 'Current'
        ELSE 'other'
    END                                                                   AS loan_bucket_new,

    -- Monthly attribution summary (joined at month grain)
    att.ai_attributed_total_collection,
    att.no_one_attributed_total_collection,
    att.overall_total_collection,
    att.ai_attributed_loan_count,
    att.no_one_attributed_loan_count,
    att.total_attributed_loan_count

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

LEFT JOIN payment_master pm
       ON pm.loan_id        = b.loan_id
      AND b.call_month      = pm.transaction_month

LEFT JOIN charges_final cbf
       ON cbf.loan_id     = b.loan_id
      AND cbf.event_month = b.call_month

LEFT JOIN attribution_summary att
       ON att.transaction_month = b.call_month

LEFT JOIN loan_status_master ls
       ON ls.loan_id   = b.loan_id
      AND b.call_month = ls.lb_date

LEFT JOIN loan_master lm
       ON lm.loan_id = b.loan_id

WHERE b.call_month >= '2026-02-01'
;
