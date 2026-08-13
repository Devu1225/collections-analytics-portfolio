/* ============================================================
   Soft Collection Segment Query
   ------------------------------------------------------------
   Purpose: Identifies the current month's "soft collection"
   calling list — active loans that are still in an early/low
   DPD bracket (Current / Current to X) but have NOT yet paid
   this month's EMI, have pending collection charges above a
   minimum threshold, and haven't made a payment since last
   month. This is the pool that gets proactively called before
   they roll into a harder delinquency bucket.

   Approach:
     1. Pull this month's EMI due-schedule row per loan, flag
        whether it's been paid, and track the most recent
        payment date overall.
     2. Bring in the loan's latest post-EMI behavioral segment
        tag (from a periodically refreshed segmentation feed).
     3. Bring in the latest pending/due collection charges.
     4. Bring in loan/applicant static attributes (contact,
        vehicle, DPD bracket) from the monthly master file.
     5. Join everything together and filter down to the
        specific soft-collection criteria, classifying each
        loan into a recovery-type label.

   Techniques demonstrated:
     - Window functions (MAX() OVER, ROW_NUMBER) for flagging
       and deduplication across multiple source feeds
     - Multi-CTE staged pipeline combining EMI schedule,
       segmentation, charges, and static loan attributes
     - Business rule filtering on multiple simultaneous
       conditions (DPD bracket, payment flag, charge
       threshold, recency of last payment)
     - Recovery-type classification via CASE

   Note: Table/column identifiers below are generalized for
   portfolio demonstration purposes and do not reflect any
   employer's actual schema or partner names.
   ============================================================ */

WITH emi_data AS (
    SELECT
        loan_id,
        due_date,
        installment_amount,
        principal,
        interest,
        payment_date,
        last_payment_date,
        payment_flag
    FROM (
        SELECT
            loan_id,
            due_date,
            DATE_TRUNC('month', due_date)      AS due_month_date,
            DATE_TRUNC('month', CURRENT_DATE)  AS current_date_month,
            installment_amount,
            principal,
            interest,
            payment_date,
            MAX(payment_date) OVER (PARTITION BY loan_id) AS last_payment_date,
            CASE WHEN payment_date IS NULL THEN 0 ELSE 1 END AS payment_flag
        FROM analytics_db.prod.repayment_schedule
    )
    WHERE due_month_date = current_date_month
),

post_emi_segment AS (
    SELECT
        s.loan_id,
        new_segments
    FROM analytics_db.gsheet.post_emi_segmentation s
    JOIN emi_data ON emi_data.loan_id = s.loan_id
    QUALIFY ROW_NUMBER() OVER (PARTITION BY s.loan_id ORDER BY etl_date DESC) = 1
),

charges AS (
    SELECT
        s.loan_id,
        total_collection_charges_pending_monthly,
        total_collection_charges_due_till_date,
        event_date
    FROM analytics_db.pre_prod.loan_charges_split s
    JOIN emi_data ON emi_data.loan_id = s.loan_id
    QUALIFY ROW_NUMBER() OVER (PARTITION BY s.loan_id ORDER BY event_date DESC) = 1
),

monthly_data AS (
    SELECT
        applicant_contact_number,
        applicant_name,
        emi_date,
        current_dpd,
        allocation_dpd_bracket,
        emi_amount,
        credit_bank_name,
        month_on_book,
        loan_end_date,
        cg.loan_id,
        vehicle_registration_number,
        make_and_model
    FROM analytics_db.pre_prod.monthly_file_data_final cg
    LEFT JOIN analytics_db.prod.daily_collections_output dcg
           ON dcg.loan_id = cg.loan_id
    WHERE loan_status = 'Active'
      AND product_type = 'PartnerX'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY cg.loan_id ORDER BY emi_date DESC) = 1
)

SELECT
    emi_data.loan_id,
    applicant_contact_number,
    applicant_name,
    emi_date,
    current_dpd,
    allocation_dpd_bracket,
    emi_amount,
    credit_bank_name,
    month_on_book,
    loan_end_date,
    vehicle_registration_number,
    make_and_model,
    due_date,
    installment_amount,
    principal,
    interest,
    payment_date,
    payment_flag,
    new_segments,
    total_collection_charges_pending_monthly,
    total_collection_charges_due_till_date,
    event_date,
    last_payment_date,
    CASE
        WHEN payment_flag = 1
         AND total_collection_charges_due_till_date > 100  THEN 'PARTIAL_RECOVERY'
        WHEN payment_flag = 1
         AND total_collection_charges_due_till_date < 100  THEN 'FULL_RECOVERY'
        WHEN payment_flag = 0
         AND total_collection_charges_due_till_date > 100  THEN 'NOT_RECOVERED'
    END AS recovery_type
FROM emi_data
JOIN monthly_data
  ON monthly_data.loan_id = emi_data.loan_id
LEFT JOIN post_emi_segment
  ON post_emi_segment.loan_id = emi_data.loan_id
LEFT JOIN charges
  ON charges.loan_id = emi_data.loan_id
WHERE allocation_dpd_bracket IN ('Current', 'Current to X')
  AND current_dpd NOT IN ('Current')
  AND payment_flag = 0
  AND total_collection_charges_due_till_date > 100
  AND due_date <= LAST_DAY(DATEADD(MONTH, 1, CURRENT_DATE))
  AND (
      last_payment_date IS NULL
      OR DATE_TRUNC('month', last_payment_date) < DATE_TRUNC('month', CURRENT_DATE)
  )
;
