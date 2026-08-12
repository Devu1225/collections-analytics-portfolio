/* ============================================================
   Collection Charges & Loan Status Classification Query
   ------------------------------------------------------------
   Purpose: Builds a daily collections snapshot per loan by
   combining DPD (Days Past Due) tracking, loan status 
   classification, and charge breakdowns (penal interest,
   late fees, legal notices, repossession-related charges, etc).

   Techniques demonstrated:
     - Multi-CTE pipeline for staged transformations
     - Window functions (ROW_NUMBER, LAG) for deduplication 
       and month-over-month lookback
     - Business rule engine via nested CASE WHEN for loan
       status classification
     - DPD bucketing into risk scenario bands
     - Multiple LEFT JOINs to enrich a loan-level fact table

   Note: Table/column names and thresholds below are 
   generalized for portfolio demonstration purposes and do 
   not reflect any employer's actual schema, partner data, 
   or business thresholds.
   ============================================================ */

WITH collections_raw AS (
    SELECT DISTINCT
        loan_id,
        loan_status,
        partner_name,
        allocation_dpd_bracket,
        current_dpd,
        roll_rate,
        repo_status,
        liquidation_status,
        event_date,
        principal_outstanding_amount,
        total_outstanding_amount,
        historical_charges
    FROM analytics_db.prod.daily_collections_snapshot
    WHERE partner_name = 'PartnerX'
      AND event_date BETWEEN '2026-03-01' AND CURRENT_DATE()
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY loan_id, event_date ORDER BY event_date DESC
    ) = 1
),

/* Allocation DPD bracket — carry forward previous month's 
   bracket on the 1st of each month via LAG */
collections AS (
    SELECT
        loan_id,
        loan_status,
        partner_name,
        CASE
            WHEN DAY(event_date) = 1
            THEN LAG(allocation_dpd_bracket) OVER (
                PARTITION BY loan_id ORDER BY event_date
            )
            ELSE allocation_dpd_bracket
        END AS allocation_dpd_bracket,
        current_dpd,
        roll_rate,
        repo_status,
        liquidation_status,
        event_date,
        principal_outstanding_amount,
        total_outstanding_amount,
        historical_charges
    FROM collections_raw
),

loan_master AS (
    SELECT
        applicant_name,
        applicant_contact_number,
        loan_id,
        make_and_model,
        vehicle_registration_number,
        maturity_date              AS loan_maturity_date,
        loan_sanction_date         AS loan_disbursement_date
    FROM analytics_db.pre_prod.loan_master_data
),

charges_raw AS (
    SELECT
        loan_id,
        COALESCE(total_charges_due_till_date,       0) AS total_charges_due_till_date,
        COALESCE(total_charges_waiver_till_date,    0) AS total_charges_waiver_till_date,
        COALESCE(total_charges_received_monthly,    0) AS total_charges_received_monthly,
        COALESCE(total_charges_till_date,           0) AS total_charges_till_date,
        COALESCE(total_charges_received_till_date,  0) AS total_charges_received_till_date,
        COALESCE(total_charges_current_month_waiver,0) AS total_charges_current_month_waiver,
        COALESCE(total_charges_pending_monthly,     0) AS total_charges_pending_monthly,
        event_date
    FROM analytics_db.pre_prod.loan_charges_split
    WHERE event_date BETWEEN '2026-03-01' AND CURRENT_DATE()
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY loan_id, event_date ORDER BY event_date DESC
    ) = 1
),

/* 2nd-of-month snapshot — locks key monthly status fields */
collections_2nd AS (
    SELECT
        c.loan_id,
        c.loan_status,
        c.repo_status,
        c.liquidation_status,
        c.historical_charges,
        c.principal_outstanding_amount,
        c.total_outstanding_amount,
        cr.total_charges_due_till_date,
        DATE_TRUNC('month', c.event_date) AS month_key,
        CASE
            WHEN lm.loan_maturity_date < c.event_date
            THEN DATEDIFF(month, lm.loan_maturity_date, c.event_date)
            ELSE 0
        END AS months_since_closure
    FROM collections c
    LEFT JOIN loan_master lm ON lm.loan_id = c.loan_id
    LEFT JOIN charges_raw cr ON cr.loan_id = c.loan_id AND cr.event_date = c.event_date
    WHERE DAY(c.event_date) = 2
),

/* Granular charge line-items — daily grain */
penal_charges AS (
    SELECT
        loan_id,
        COALESCE(bounce_amount_received_monthly,        0) AS bounce_amount_received_monthly,
        COALESCE(penal_interest_received_monthly,        0) AS penal_interest_received_monthly,
        COALESCE(late_payment_received_monthly,           0) AS late_payment_received_monthly,
        COALESCE(legal_notice_charges_received_monthly,   0) AS legal_notice_charges_received_monthly,
        COALESCE(visit_charges_received_monthly,          0) AS visit_charges_received_monthly,
        COALESCE(other_recovery_charges_received_monthly, 0) AS other_recovery_charges_received_monthly,
        (
            COALESCE(fuel_received_monthly,               0)
          + COALESCE(arbitration_charges_received_monthly,0)
          + COALESCE(repossession_charges_received_monthly,0)
          + COALESCE(field_agent_received_monthly,        0)
          + COALESCE(repair_received_monthly,              0)
          + COALESCE(blacklisting_charges_received_monthly,0)
        ) AS misc_charges_received_monthly,
        event_date
    FROM analytics_db.prod.penal_charges_split
    WHERE event_date BETWEEN '2026-03-01' AND CURRENT_DATE()
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY loan_id, event_date ORDER BY event_date DESC
    ) = 1
),

/* Loan status classification engine */
final_pool AS (
    SELECT
        s.loan_id,
        c.event_date,
        s.loan_status                    AS original_loan_status,
        s.repo_status,
        c.allocation_dpd_bracket,
        s.liquidation_status,
        s.historical_charges,
        s.principal_outstanding_amount,
        s.total_outstanding_amount,
        s.total_charges_due_till_date,
        s.months_since_closure,
        CASE
            WHEN COALESCE(s.repo_status, 'N') = 'N'
                 AND COALESCE(s.liquidation_status, 'N') = 'N'
                 AND c.allocation_dpd_bracket <> '360+'
                 AND s.loan_status = 'Active'
                 AND s.months_since_closure = 0
                THEN 'Active'
            WHEN (s.principal_outstanding_amount > 100 AND s.total_outstanding_amount > 100)
                 AND COALESCE(s.repo_status, 'N') = 'N'
                 AND COALESCE(s.liquidation_status, 'N') = 'N'
                 AND c.allocation_dpd_bracket = '360+'
                THEN 'Write-off 365+'
            WHEN (s.principal_outstanding_amount > 100 OR s.total_outstanding_amount > 100)
                 AND COALESCE(s.repo_status, 'N') = 'Y'
                 AND COALESCE(s.liquidation_status, 'N') = 'N'
                THEN 'Repossessed'
            WHEN (s.principal_outstanding_amount > 100 OR s.total_outstanding_amount > 100)
                 AND COALESCE(s.liquidation_status, 'N') = 'Y'
                THEN 'Liquidated'
            WHEN s.principal_outstanding_amount <= 100
                 AND s.total_outstanding_amount > 100
                 AND s.months_since_closure > 0
                 AND COALESCE(s.total_charges_due_till_date, 0) > 100
                 AND s.loan_status NOT IN ('Early Settlement', 'Settlement', 'Cancelled')
                THEN 'Tenure Closed - Charges Pending'
            ELSE 'Not Eligible'
        END AS loan_status_derived
    FROM collections_2nd s
    LEFT JOIN collections c ON s.loan_id = c.loan_id
),

base AS (
    SELECT
        c.loan_id,
        c.loan_status                                  AS latest_loan_status,
        c.event_date,
        lm.applicant_contact_number                    AS contact_number,
        lm.applicant_name,
        c.partner_name,
        lm.make_and_model,
        lm.vehicle_registration_number,
        fp.original_loan_status,
        fp.repo_status,
        fp.liquidation_status,
        fp.historical_charges,
        fp.principal_outstanding_amount,
        fp.total_outstanding_amount,
        fp.months_since_closure,
        fp.loan_status_derived,
        c.current_dpd,
        c.allocation_dpd_bracket,
        COALESCE(cr.total_charges_due_till_date,        0) AS total_charges_due_till_date,
        COALESCE(cr.total_charges_waiver_till_date,     0) AS total_charges_waiver_till_date,
        COALESCE(cr.total_charges_received_monthly,     0) AS total_charges_received_monthly,
        COALESCE(cr.total_charges_till_date,            0) AS total_charges_till_date,
        COALESCE(cr.total_charges_received_till_date,   0) AS total_charges_received_till_date,
        COALESCE(cr.total_charges_current_month_waiver, 0) AS total_charges_current_month_waiver,
        COALESCE(cr.total_charges_pending_monthly,      0) AS total_charges_pending_monthly,
        pc.bounce_amount_received_monthly,
        pc.penal_interest_received_monthly,
        pc.late_payment_received_monthly,
        pc.legal_notice_charges_received_monthly,
        pc.visit_charges_received_monthly,
        pc.other_recovery_charges_received_monthly,
        pc.misc_charges_received_monthly,
        DATEDIFF(month, lm.loan_disbursement_date, c.event_date) AS months_on_book
    FROM collections c
    LEFT JOIN loan_master lm  ON lm.loan_id = c.loan_id
    LEFT JOIN final_pool  fp  ON fp.loan_id = c.loan_id AND fp.event_date = c.event_date
    LEFT JOIN charges_raw cr  ON cr.loan_id = c.loan_id AND cr.event_date = c.event_date
    LEFT JOIN penal_charges pc ON pc.loan_id = c.loan_id AND pc.event_date = c.event_date
)

SELECT
    loan_id,
    latest_loan_status,
    event_date,
    contact_number,
    applicant_name,
    partner_name,
    make_and_model,
    vehicle_registration_number,
    original_loan_status,
    total_charges_due_till_date,
    total_charges_waiver_till_date,
    total_charges_received_monthly,
    total_charges_till_date,
    total_charges_received_till_date,
    total_charges_current_month_waiver,
    total_charges_pending_monthly,
    bounce_amount_received_monthly,
    penal_interest_received_monthly,
    late_payment_received_monthly,
    legal_notice_charges_received_monthly,
    visit_charges_received_monthly,
    other_recovery_charges_received_monthly,
    misc_charges_received_monthly,
    loan_status_derived,
    CASE
        WHEN allocation_dpd_bracket = 'Current'                                          THEN 'Current'
        WHEN allocation_dpd_bracket = 'Current to X'                                     THEN 'Current to X'
        WHEN allocation_dpd_bracket = '1 to 29'                                          THEN '1 to 29 DPD'
        WHEN allocation_dpd_bracket = '30 to 59'                                         THEN '30 to 59 DPD'
        WHEN allocation_dpd_bracket = '60 to 89'                                         THEN '60 to 89 DPD'
        WHEN allocation_dpd_bracket IN ('90 to 119', '120 to 149', '150 to 179')         THEN '90 to 179 DPD'
        WHEN allocation_dpd_bracket IN ('180 to 209', '210 to 239', '240 to 269',
                                         '270 to 299', '300 to 329', '330 to 359')        THEN '180 to 365 DPD'
        WHEN allocation_dpd_bracket = '360+'                                             THEN 'Write-off 365+'
        ELSE 'Others'
    END AS dpd_scenario,
    repo_status,
    liquidation_status,
    principal_outstanding_amount,
    total_outstanding_amount,
    historical_charges,
    allocation_dpd_bracket,
    current_dpd,
    months_on_book,
    months_since_closure
FROM base
ORDER BY event_date, loan_id;
