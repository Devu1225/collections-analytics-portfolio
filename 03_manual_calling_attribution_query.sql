/* ============================================================
   Manual Calling Attribution Query
   ------------------------------------------------------------
   Purpose: Attributes monthly collections/charge payments to
   a manual (agent-driven) calling channel, mirroring the same
   attribution framework used for the AI calling channel, so
   the two can be compared side by side. Links call disposition
   logs (talk time, PTP, right-party-contact) with payment
   transactions, builds a due-vs-collected charges ledger from
   two source systems, and classifies loans into DPD/status
   buckets.

   Techniques demonstrated:
     - Time-string parsing (HH24:MI:SS) into total seconds via
       EXTRACT + TO_TIMESTAMP
     - UNION of two vendor/source charge feeds into a single
       reconciled "due vs. collected vs. waived" ledger
     - Window functions (ROW_NUMBER, RANK, QUALIFY) for
       deduplication and "most recent qualifying call before
       payment" attribution logic
     - Multi-stage CTE pipeline: call log -> payment join ->
       attribution rule -> charges ledger -> final rollup
     - DPD bucket / loan status classification via CASE

   Note: Table/column/source identifiers below are generalized
   for portfolio demonstration purposes and do not reflect any
   employer's actual schema, vendor names, or campaign IDs.
   ============================================================ */

WITH base AS (
    SELECT DISTINCT
        loan_id, '2026-03-01' AS call_month
    FROM analytics_db.pre_prod.manual_charges_calling_base
    WHERE 1=1
    -- campaign filter applied upstream in source extract
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
    WHERE call_date >= '2025-12-01'
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
        WHERE transaction_date >= '2025-12-01'
        UNION
        SELECT loan_id, mode_of_payment, transaction_date
        FROM analytics_db.prod.payment_transaction_data_v2
        WHERE transaction_date >= '2025-12-01'
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

payment_master AS (
    SELECT
        a.*,
        a.manual_call_date AS manual_last_answered_call_date,
        pmd.mode_of_payment,
        CASE
            WHEN (charges_payment = 0)
              OR (a.manual_call_date IS NULL)
              OR (LOWER(pmd.mode_of_payment) IN ('nach', 'online-nach')) THEN 'No one'
            WHEN a.manual_call_date IS NOT NULL
             AND (a.manual_ptp_flag = 1 OR a.manual_answered_flag = 1)  THEN 'manual'
            ELSE 'No one'
        END AS payment_attribution
    FROM (
        SELECT mpb.*
        FROM manual_payment_base mpb
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
    manual.manual_attempts,
    manual.manual_connected,
    manual.manual_answered,
    manual.manual_ptp,
    manual.manual_rpc_calls,
    manual.manual_tlk_duration,
    pm.transaction_date                                                   AS payment_date,
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
    END                                                                   AS loan_bucket_new
FROM (
    SELECT loan_id, call_month
    FROM base
    GROUP BY 1, 2
) b
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
WHERE b.call_month >= '2025-12-01';
