/* ============================================================
   Collections Master Dump — Daily Eligible Pool Build
   ------------------------------------------------------------
   Purpose: The master daily "single source of truth" collections
   view. Builds the eligible loan pool across multiple lending
   partners, classifies each loan into a DPD bucket, computes a
   day-over-day roll-rate stability tag, and enriches every loan
   with legal-process status, NACH bounce history, agent/visit
   allocation, charges, and applicant demographic attributes.
   This is the base table that most downstream collections
   dashboards and reports are built on top of.

   Approach (high level):
     1. Build a calendar-day spine and a base EMI/disbursement
        attribute table per loan.
     2. Determine loan "eligibility" for the collections pool
        per partner, using outstanding-balance and repo/
        liquidation-status rules (each partner has slightly
        different source tables and status conventions).
     3. Union all partners into one eligible pool, then cross
        it against the day spine to get one row per loan per day
        in the reporting window.
     4. Classify each day's DPD bucket, compute a rank-based
        "opening vs. current" bucket comparison, and derive a
        roll-rate stability label (improved/worsened/stable)
        from that comparison plus partner-specific overrides.
     5. Left-join in legal-tracker status, NACH bounce status,
        payment/charges data, excess-amount balances, and
        agent/visit allocation + applicant demographic data.
     6. Output one row per loan per day for the reporting window.

   Techniques demonstrated:
     - Large multi-partner UNION ALL eligibility model reconciled
       into one pool
     - Calendar spine generation and day-by-day snapshot joins
       (with a deliberate +/-1 day shift to fix month-end edge
       cases)
     - Rank-based bucket comparison (numeric DPD rank ladder) to
       derive roll-forward / roll-back / stable classifications
     - Multi-source enrichment via a long chain of LEFT JOINs
       (legal, NACH, payments, charges, excess balances, agent
       allocation, applicant demographics)
     - Heavy use of QUALIFY + ROW_NUMBER for point-in-time
       deduplication across nearly every source table
     - Region/city normalization via CASE-based lookup

   Note: Database/table/partner identifiers below are generalized
   for portfolio demonstration purposes and do not reflect any
   employer's actual schema, partner names, or org structure.
   This query is presented for structural/technique reference —
   it is not intended to be run as-is against any real warehouse.
   ============================================================ */

SET run_month = DATE_TRUNC('month', CURRENT_DATE - 1);

WITH date_filter AS (
    SELECT
        TRY_TO_DATE($run_month) AS run_month,

        /* 2nd of month */
        DATEADD(day, 1, DATE_TRUNC('month', TRY_TO_DATE($run_month))) AS start_date,

        /* dynamically caps at today — updates every day on refresh */
        CURRENT_DATE AS end_date
),

all_dates AS (
    -- primary key dts
    SELECT DISTINCT created_at::DATE dts
    FROM analytics_db.prod.user_details
    WHERE created_at::DATE <= CURRENT_DATE
      AND dts::DATE BETWEEN DATE_TRUNC('month', CURRENT_DATE - 90) AND CURRENT_DATE
),

emi_amount AS (
    SELECT DISTINCT
        loan_id,
        expected_emi AS monthly_emi_amount
    FROM analytics_db.prod.partner_y_daily_mis
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY loan_id
        ORDER BY TRY_TO_DATE(mis_date) DESC
    ) = 1

    UNION ALL

    SELECT DISTINCT loan_id, expected_emi AS monthly_emi_amount
    FROM analytics_db.prod.partner_z_daily_mis
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY loan_id
        ORDER BY TRY_TO_DATE(etl_date) DESC
    ) = 1
),

daily_monthly_mis AS (
    SELECT DISTINCT
        mf.loan_id,
        client_loan_sanction_date AS loan_disbursement_date,
        mf.first_emi_due_date     AS first_emi_date,
        total_ltv,
        COALESCE(mf.emi_amount, emi.monthly_emi_amount) AS monthly_emi_amount
    FROM analytics_db.prod.monthly_file_data_final mf
    LEFT JOIN emi_amount emi
        ON mf.loan_id = emi.loan_id
),

loan_dts_combinations AS (
    SELECT
        b.loan_id,
        b.first_emi_date,
        b.default_cycle_date,
        b.loan_disbursement_date,
        b.monthly_emi_amount,
        dt.dts
    FROM (
        SELECT
            loan_id,
            TRY_TO_DATE(first_emi_date) AS first_emi_date,
            TRY_TO_DATE(loan_disbursement_date) AS loan_disbursement_date,
            monthly_emi_amount,
            DAY(TRY_TO_DATE(first_emi_date)) AS default_cycle_date
        FROM daily_monthly_mis
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY loan_id
            ORDER BY TRY_TO_DATE(first_emi_date) DESC
        ) = 1
    ) b
    JOIN all_dates dt ON 1=1
    JOIN date_filter df ON 1=1
    WHERE dt.dts BETWEEN df.start_date AND df.end_date
      AND DATE_TRUNC('month', TRY_TO_DATE(b.first_emi_date)) <= df.start_date  -- ignore future EMIs
      AND b.loan_id IS NOT NULL
      AND LENGTH(b.loan_id) > 5
      AND b.loan_id NOT ILIKE 'DUMMY%'
      AND b.loan_id NOT ILIKE 'SAMP%'
      AND b.loan_id NOT ILIKE 'TES%'
),

/* Eligibility pool — primary partner (own-book loans) */
eligible_base AS (
    SELECT *
    FROM (
        SELECT
            cgh.loan_id,
            cgh.partner_loan_id,
            cgh.partner_name,
            cgh.loan_status,
            cgh.total_outstanding_amount AS tos,
            cgh.principal_outstanding_amount AS pos,

            CASE
                WHEN (cgh.principal_outstanding_amount > 100
                      AND cgh.total_outstanding_amount > 100)
                 AND COALESCE(repo_status, 'N') = 'N'
                 AND COALESCE(liquidation_status, 'N') = 'N'
                 AND loan_status IN ('Active', 'Subrogated', 'Write off 365')
                THEN '1.Eligible_Pool'

                WHEN (cgh.principal_outstanding_amount > 100
                      AND cgh.total_outstanding_amount > 100)
                 AND COALESCE(repo_status, 'N') = 'Y'
                 AND COALESCE(liquidation_status, 'N') = 'N'
                 AND loan_status IN ('Active', 'Active Repossession')
                THEN '2.Repossessed'

                WHEN (cgh.principal_outstanding_amount > 100
                      AND cgh.total_outstanding_amount > 100)
                 AND COALESCE(repo_status, 'N') = 'Y'
                 AND COALESCE(liquidation_status, 'N') = 'Y'
                THEN '3.Liquidated'
            END AS eligible_type,

            cgh.event_date AS pool_dump_date

        FROM analytics_db.prod.daily_collections_snapshot_hist cgh
        JOIN date_filter df ON 1=1
        WHERE cgh.event_date = df.start_date
          AND partner_name = 'PartnerX'
    )
    WHERE eligible_type IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY loan_id
        ORDER BY pool_dump_date DESC
    ) = 1
),

/* Eligibility pool — subrogated loans (moved between partners) */
subrogation_data AS (
    SELECT
        loan_id,
        partner_loan_id,
        partner_name,
        loan_status,
        current_balance AS tos,
        opening_balance AS pos,
        '1.Eligible_Pool' AS eligible_type,
        df.start_date AS pool_dump_date
    FROM analytics_db.pre_prod.collection_subrogation_snapshot s
    JOIN date_filter df ON 1=1
    WHERE cohort_month = (
        SELECT MAX(cohort_month)
        FROM analytics_db.pre_prod.collection_subrogation_snapshot
    )
),

/* Eligibility pool — secondary partner loans (co-lending / assigned book) */
eligible_pool_secondary_partners AS (
    SELECT
        loan_id,
        partner_loan_id,
        partner_name,
        loan_status,
        tos,
        pos,

        CASE
            WHEN (pos > 100 AND tos > 100)
                 AND (repo_status = 'N' AND liquidation_status = 'N')
                 AND loan_status IN ('Active', 'Write off 365')
            THEN '1.Eligible_Pool'

            WHEN (pos > 100 AND tos > 100)
                 AND (repo_status = 'Y' AND liquidation_status = 'N')
                 AND loan_status IN ('Active', 'Active Repossession')
            THEN '2.Repossessed'

            WHEN (pos > 100 AND tos > 100)
                 AND (repo_status = 'Y' AND liquidation_status = 'Y')
            THEN '3.Liquidated'

        END AS eligible_type,
        event_date AS pool_dump_date

    FROM (
        SELECT
            cgh.loan_id,
            cgh.partner_name,
            cgh.partner_loan_id,
            cgh.loan_status,
            COALESCE(cgh.repo_status, 'N') AS repo_status,
            cgh.event_date,
            cgh.total_outstanding_amount AS tos,
            cgh.principal_outstanding_amount AS pos,

            CASE
                WHEN liq.loan_id IS NOT NULL
                     AND liq.final_status = 'Payment Settled'
                     AND TRY_TO_DATE(liq.date_of_settlement, 'DD/MM/YYYY') <= cgh.event_date
                THEN 'Y'
                ELSE 'N'
            END AS liquidation_status

        FROM analytics_db.prod.daily_collections_snapshot_hist cgh
        JOIN date_filter df ON 1=1
        LEFT JOIN analytics_db.gsheet.collection_liquidation_data liq
            ON liq.loan_id = cgh.loan_id
        WHERE cgh.event_date = df.start_date
          AND cgh.loan_id NOT IN (
              SELECT DISTINCT partner_x_loan_id
              FROM analytics_db.prod.collections_subrogation_data
          )
          AND cgh.partner_name <> 'PartnerX'
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY cgh.loan_id
            ORDER BY event_date DESC
        ) = 1
    )
),

final_pool AS (
    SELECT * FROM eligible_pool_secondary_partners
    UNION ALL
    SELECT * FROM subrogation_data
    UNION ALL
    SELECT * FROM eligible_base
),

eligible_dts_combination AS (
    SELECT
        final_pool.loan_id, first_emi_date, loan_disbursement_date, monthly_emi_amount, default_cycle_date,
        lc.dts, partner_name, final_pool.partner_loan_id, loan_status, final_pool.pool_dump_date,
        pos AS opening_pos, eligible_type
    FROM final_pool
    JOIN date_filter df ON 1=1
    JOIN loan_dts_combinations lc
        ON lc.loan_id = final_pool.loan_id
       AND lc.dts BETWEEN df.start_date AND df.end_date
       AND DATE_TRUNC('month', loan_disbursement_date) < df.run_month  -- exclude loans with first EMI in the next month
),

eligible_pool_updated_data AS (
    SELECT base.*,
        CASE
            WHEN current_dpd IN ('Current', 'current') THEN 0
            WHEN current_dpd IN ('Current To X', 'current to x') THEN 1
            WHEN current_dpd = '1-29 DPD' THEN 2
            WHEN current_dpd = '30-59 DPD' THEN 3
            WHEN current_dpd = '60-89 DPD' THEN 4
            WHEN current_dpd = '90-119 DPD' THEN 5
            WHEN current_dpd = '120-149 DPD' THEN 6
            WHEN current_dpd = '150-179 DPD' THEN 7
            WHEN current_dpd = '180-209 DPD' THEN 8
            WHEN current_dpd = '210-239 DPD' THEN 9
            WHEN current_dpd = '240-269 DPD' THEN 10
            WHEN current_dpd = '270-299 DPD' THEN 11
            WHEN current_dpd = '300-329 DPD' THEN 12
            WHEN current_dpd = '330-359 DPD' THEN 13
            WHEN current_dpd = '360+' THEN 14
        END AS current_rank,
        CASE
            WHEN opening_bkt IN ('Current', 'current') THEN 0
            WHEN opening_bkt IN ('Current To X', 'current to x') THEN 1
            WHEN opening_bkt = '1-29 DPD' THEN 2
            WHEN opening_bkt = '30-59 DPD' THEN 3
            WHEN opening_bkt = '60-89 DPD' THEN 4
            WHEN opening_bkt = '90-119 DPD' THEN 5
            WHEN opening_bkt = '120-149 DPD' THEN 6
            WHEN opening_bkt = '150-179 DPD' THEN 7
            WHEN opening_bkt = '180-209 DPD' THEN 8
            WHEN opening_bkt = '210-239 DPD' THEN 9
            WHEN opening_bkt = '240-269 DPD' THEN 10
            WHEN opening_bkt = '270-299 DPD' THEN 11
            WHEN opening_bkt = '300-329 DPD' THEN 12
            WHEN opening_bkt = '330-359 DPD' THEN 13
            WHEN opening_bkt = '360+' THEN 14
        END AS opening_rank
    FROM (
        SELECT
            edc.loan_id,
            edc.loan_status,
            cg_run.loan_status AS loan_status_updated,
            edc.partner_name,
            edc.partner_loan_id,
            edc.eligible_type,
            edc.first_emi_date,
            edc.loan_disbursement_date,
            edc.monthly_emi_amount,
            edc.default_cycle_date,
            edc.opening_pos,

            /* allocation-day DPD bucket (no shift) */
            CASE
                WHEN sd.loan_id IS NOT NULL THEN sd.allocation_dpd_bracket
                ELSE cg_alloc.allocation_dpd_bracket
            END AS opening_bkt,

            /* current DPD bucket (shifted +1 day to fix month-end edge case) */
            CASE
                WHEN sd.loan_id IS NOT NULL THEN NULL
                ELSE cg_run.current_dpd
            END AS current_dpd,

            /* roll rate from the running snapshot */
            CASE
                WHEN sd.loan_id IS NOT NULL THEN sd.roll_rate
                ELSE cg_run.roll_rate
            END AS roll_rate,

            CASE
                WHEN sd.loan_id IS NOT NULL THEN sd.opening_balance
                ELSE cg_run.principal_outstanding_amount
            END AS principal_outstanding_amount,

            CASE
                WHEN sd.loan_id IS NOT NULL THEN sd.opening_balance
                ELSE cg_run.total_outstanding_amount
            END AS total_outstanding_amount,

            cg_run.repo_status,

            /* liquidation logic differs by partner source system */
            CASE
                WHEN edc.partner_name <> 'PartnerX' THEN
                    CASE
                        WHEN liq.loan_id IS NOT NULL
                             AND liq.final_status = 'Payment Settled'
                             AND TRY_TO_DATE(liq.date_of_settlement, 'DD/MM/YYYY') <= edc.dts
                        THEN 'Y'
                        ELSE 'N'
                    END
                WHEN edc.partner_name = 'PartnerX' THEN
                    COALESCE(cg_run.liquidation_status, 'N')
            END AS liquidation_status,

            cg_run.blacklisting_status,
            cg_run.blacklisting_date,
            cg_run.bounce_flag,
            cg_alloc.post_bounce_segment,
            cg_alloc.pre_bounce_segment,

            edc.dts,

            cg_run.rc_status,
            cg_run.rc_transfer_date,
            cg_run.live_tracking,
            cg_run.nach_status,
            cg_run.gps_status

        FROM eligible_dts_combination edc

        /* allocation-day snapshot (no shift) */
        LEFT JOIN analytics_db.prod.daily_collections_snapshot_hist cg_alloc
          ON edc.loan_id = cg_alloc.loan_id
         AND cg_alloc.event_date = DATEADD(day, -1, edc.dts)

        /* running snapshot (shifted +1 day, fixes month-end issue) */
        LEFT JOIN analytics_db.prod.daily_collections_snapshot_hist cg_run
          ON edc.loan_id = cg_run.loan_id
         AND cg_run.event_date = edc.dts

        /* subrogation */
        LEFT JOIN analytics_db.pre_prod.collection_subrogation_snapshot sd
          ON edc.loan_id = sd.loan_id
         AND sd.cohort_month = (
            SELECT MAX(cohort_month)
            FROM analytics_db.pre_prod.collection_subrogation_snapshot
        )

        /* liquidation */
        LEFT JOIN analytics_db.gsheet.collection_liquidation_data liq
          ON liq.loan_id = edc.loan_id
    ) base
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY loan_id, dts
        ORDER BY dts DESC
    ) = 1
),

user_mapping AS (
    SELECT case_type, agency_team, employee_id, emp_name, acm_name, rcm_name, ncm_name
    FROM analytics_db.pre_prod.user_details_mapping
),

allocation_remarks AS (
    SELECT
        COALESCE(a.loan_id, r.loan_id) AS loan_id,
        a.employee_id,
        a.source,
        a.case_type,
        r.visit_purpose,
        r.allocation_month,
        r.visit_status,
        r.visit_date,
        r.agent_disposition,
        r.remarks,
        r.visit_spoc
    FROM (
        SELECT
            loan_id,
            employee_id,
            source,
            CASE
                WHEN user_team IN ('PartnerX', 'partnerx') THEN 'Inhouse'
                ELSE user_team
            END AS case_type
        FROM analytics_db.prod.allocation_deallocation_data
        WHERE event = 'allocation' AND user_profession <> 'telecalling'
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY loan_id
            ORDER BY timestamp DESC
        ) = 1
    ) a
    FULL OUTER JOIN (
        SELECT
            loan_id,
            visit_purpose,
            allocation_month,
            visit_status,
            visit_date_time::DATE AS visit_date,
            agent_marked_status AS agent_disposition,
            remarks,
            author AS visit_spoc
        FROM analytics_db.external_stage.field_ops_vendor_feed
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY loan_id
            ORDER BY created DESC
        ) = 1
    ) r
    ON a.loan_id = r.loan_id
),

user_allocation_mapping AS (
    SELECT
        a.loan_id, a.employee_id, a.source, a.case_type, a.visit_purpose,
        a.allocation_month, a.visit_status, a.visit_date, a.agent_disposition,
        a.remarks, a.visit_spoc,
        um.emp_name, um.acm_name, um.rcm_name, um.ncm_name
    FROM allocation_remarks a
    LEFT JOIN user_mapping um
        ON (
            -- inhouse: join by employee_id
            (a.case_type = 'Inhouse' AND a.employee_id IS NOT NULL AND a.employee_id = um.employee_id)
            OR
            -- agency: join by agency name
            (a.case_type <> 'Inhouse' AND LOWER(TRIM(a.case_type)) = um.agency_team)
        )
    WHERE a.allocation_month >= '2026-04-01'
),

applicant_details AS (
    SELECT
        a.loan_id, lead_channel, a.appointment_id, vehicle_registration_number, make_and_model,
        cibil_score, last_risk_bucket, cibil_bucket, ds_channel, area_type,
        income_source AS occupation, a.accomodation, gross_loan, total_ltv, loan_tenure,
        employee_id, source, case_type, visit_purpose, allocation_month, visit_status, visit_date,
        agent_disposition, remarks, visit_spoc, emp_name, acm_name, rcm_name, ncm_name,
        applicant_pincode_1,
        CASE
            WHEN applicant_city_1 IN (
                'Delhi East', 'Ghaziabad', 'Greater Noida West', 'New Delhi West',
                'Delhi North', 'Faridabad', 'New Delhi South', 'New Delhi Central',
                'New Delhi South West', 'Noida', 'Gautam Buddha Nagar'
            ) THEN 'NCR'
            WHEN applicant_city_1 = 'Gurgaon' THEN 'Haryana'
            ELSE applicant_state_1
        END AS applicant_state_1,
        CASE
            WHEN applicant_city_1 IN (
                'New Delhi South', 'New Delhi Central', 'New Delhi South West',
                'New Delhi West', 'Delhi East', 'Delhi North', 'Delhi South', 'Delhi West'
            ) THEN 'Delhi'
            WHEN applicant_city_1 IN ('Greater Noida West') THEN 'Noida'
            ELSE applicant_city_1
        END AS applicant_city_1,
        CASE
            WHEN applicant_state_1 IN (
                'Karnataka', 'Tamil Nadu', 'Telangana', 'Kerala',
                'Andhra Pradesh', 'Hyderabad', 'Pondicherry'
            ) THEN 'South'
            WHEN applicant_state_1 IN (
                'Maharashtra', 'Madhya Pradesh', 'Gujarat', 'Goa',
                'Dadra & Nagar Haveli', 'Daman & Diu'
            ) THEN 'West'
            WHEN applicant_state_1 IN (
                'NCR', 'West Bengal', 'Uttar Pradesh', 'Punjab', 'Rajasthan',
                'Haryana', 'Uttarakhand', 'Bihar', 'Himachal Pradesh', 'Jharkhand',
                'Assam', 'Chandigarh', 'Odisha', 'Uttar Pradesh'
            ) THEN 'North & East'
        END AS applicant_region
    FROM analytics_db.prod.application_details a
    JOIN analytics_db.prod.monthly_file_data_final b ON a.loan_id = b.loan_id
    LEFT JOIN user_allocation_mapping ar ON ar.loan_id = a.loan_id
),

final_applicant_details AS (
    SELECT
        epud.loan_id, epud.loan_status, loan_status_updated, partner_name, eligible_type, dts,
        first_emi_date, loan_disbursement_date, monthly_emi_amount, default_cycle_date, opening_bkt,
        current_dpd, roll_rate, current_rank, opening_rank, opening_pos, principal_outstanding_amount,
        total_outstanding_amount, repo_status, liquidation_status, blacklisting_status, blacklisting_date,
        bounce_flag, rc_status, rc_transfer_date, live_tracking, nach_status, gps_status, gross_loan,
        lead_channel, appointment_id, vehicle_registration_number, make_and_model, cibil_score,
        last_risk_bucket, cibil_bucket, ds_channel, area_type, occupation, accomodation, total_ltv,
        loan_tenure, ap.employee_id, source, case_type, visit_purpose, allocation_month, visit_status,
        visit_date, agent_disposition, remarks, visit_spoc, emp_name, acm_name, rcm_name, ncm_name,
        applicant_pincode_1, applicant_city_1, applicant_state_1, applicant_region,
        pre_bounce_segment, post_bounce_segment, partner_loan_id
    FROM applicant_details ap
    RIGHT JOIN eligible_pool_updated_data epud ON epud.loan_id = ap.loan_id
),

legal AS (
    SELECT
        loan_id, lrn_status, lrn_date, dbn_status, dbn_date, section_138_stage, section_138_status,
        section_138_date, section_17_9_stage, section_17_9_status, section_17_or_9_date,
        final_legal_status, dts
    FROM (
        SELECT
            edc.loan_id,
            "2_LRN_ARBITRATION_STATUS" AS lrn_status,
            "2_LRN_ARBITRATION" AS lrn_date,
            "1_DEMAND_NOTICE_ARBITRATION_STATUS" AS dbn_status,
            "1_DEMAND_NOTICE_ARBITRATION" AS dbn_date,
            "4_NOTICE_FOR_BOUNCE_OF_CHEQUE_OR_NACH_SECTION_138_PROCEEDINGS" AS section_138_stage,
            "4_NOTICE_FOR_BOUNCE_OF_CHEQUE_OR_NACH_SECTION_138_PROCEEDINGS_STATUS" AS section_138_status,
            "SECTION_138_DATE" AS section_138_date,
            "5_SECTION_17_9_VEHICLE_REPOSSESSION_ORDER_ARBITRATION_2" AS section_17_9_stage,
            "5_SECTION_17_9_VEHICLE_REPOSSESSION_ORDER_ARBITRATION_STATUS_3" AS section_17_9_status,
            "SECTION_17_OR_9_DATE" AS section_17_or_9_date,
            final_legal_status,
            sync_time::DATE AS sync_date,
            dts
        FROM analytics_db.gsheet.legal_tracker l
        JOIN eligible_dts_combination edc ON edc.loan_id = l.loan_id AND edc.dts = l.sync_time::DATE
    )
    QUALIFY ROW_NUMBER() OVER (PARTITION BY loan_id, dts ORDER BY dts DESC) = 1
),

payment AS (
    SELECT
        loan_id, payment_type, amount,
        CASE WHEN mode_of_payment IN ('PRESENT', 'PRESENT-PRESENT') THEN 'NACH' ELSE mode_of_payment END AS payment_mode
    FROM analytics_db.prod.payment_transaction_data_v2
    JOIN date_filter df ON 1=1
    WHERE DATE(transaction_date) >= df.start_date
    QUALIFY ROW_NUMBER() OVER (PARTITION BY loan_id ORDER BY transaction_date DESC) = 1
),

excess_amount AS (
    SELECT finreference, SUM(balanceamt) / 100 AS excess_amount
    FROM analytics_db.vendor_system.excess_amount_data
    GROUP BY finreference
    HAVING excess_amount > 0
),

charges AS (
    SELECT
        loan_id, date_of_payment, repayment_received_during_the_month, payment_mode, payment_type,
        last_transaction_amount, total_charges_accrued_till_date, overall_due, monthly_charges_received,
        monthly_charges_pending, dts
    FROM (
        SELECT
            charges.loan_id,
            date_of_payment,
            repayment_received_during_the_month,
            payment.amount AS last_transaction_amount,
            payment_mode,
            payment_type,
            total_collection_charges_till_date AS total_charges_accrued_till_date,
            total_collection_charges_due_till_date AS overall_due,
            total_collection_charges_received_till_date,
            total_collection_charges_waiver_till_date,
            total_collection_charges_received_monthly AS monthly_charges_received,
            total_collection_charges_current_month_waiver,
            total_collection_charges_pending_monthly AS monthly_charges_pending,
            event_date, dts
        FROM analytics_db.pre_prod.loan_charges_split charges
        LEFT JOIN payment ON payment.loan_id = charges.loan_id
        JOIN eligible_dts_combination edc ON edc.loan_id = charges.loan_id AND edc.dts = charges.event_date
    )
    QUALIFY ROW_NUMBER() OVER (PARTITION BY loan_id, dts ORDER BY dts DESC) = 1
),

nach_data AS (
    SELECT
        loan_id, emi_due_date,
        CASE WHEN bounce_flag = 1 THEN 'REJECTED' WHEN bounce_flag = 0 THEN 'ACCEPTED' END AS bounce_status,
        nach_type_flag
    FROM analytics_db.prod.nach_status_data
    QUALIFY ROW_NUMBER() OVER (PARTITION BY loan_id, month ORDER BY bounce_flag ASC) = 1
),

final_dump AS (
    SELECT
        fap.loan_id,
        fap.loan_status,
        CASE WHEN (fap.loan_status = 'Subrogated' AND loan_status_updated <> 'Subrogated')
             THEN 'Subrogated' ELSE loan_status_updated END AS loan_status_updated,
        CASE WHEN partner_name = 'PartnerY' AND loan_status = 'Subrogated'
             THEN 'Subrogated' ELSE partner_name END AS partner_name,
        eligible_type,
        fap.dts AS dts,
        first_emi_date, loan_disbursement_date, monthly_emi_amount, default_cycle_date, opening_bkt,
        CASE
            WHEN opening_bkt IN ('Current', 'current') THEN 'Current'
            WHEN opening_bkt IN ('Current To X', 'current to x') THEN 'Current To X'
            WHEN opening_bkt = '1 to 29' THEN '1-29 DPD'
            WHEN opening_bkt = '30 to 59' THEN '30-59 DPD'
            WHEN opening_bkt = '60 to 89' THEN '60-89 DPD'
            WHEN opening_bkt = '90 to 119' THEN '90-119 DPD'
            WHEN opening_bkt = '120 to 149' THEN '120-149 DPD'
            WHEN opening_bkt = '150 to 179' THEN '150-179 DPD'
            WHEN opening_bkt = '180 to 209' THEN '180-209 DPD'
            WHEN opening_bkt = '210 to 239' THEN '210-239 DPD'
            WHEN opening_bkt = '240 to 269' THEN '240-269 DPD'
            WHEN opening_bkt = '270 to 299' THEN '270-299 DPD'
            WHEN opening_bkt = '300 to 329' THEN '300-329 DPD'
            WHEN opening_bkt = '330 to 359' THEN '330-359 DPD'
            WHEN opening_bkt = '360+' THEN 'Writeoff-365'
            ELSE opening_bkt
        END AS opening_bkt_updated,
        CASE
            WHEN opening_bkt IN ('Current', 'current') THEN 'Current'
            WHEN opening_bkt IN ('Current To X', 'current to x') THEN 'Current To X'
            WHEN opening_bkt = '1 to 29' THEN '1-29 DPD'
            WHEN opening_bkt = '30 to 59' THEN '30-59 DPD'
            WHEN opening_bkt = '60 to 89' THEN '60-89 DPD'
            WHEN opening_bkt IN ('90 to 119', '120 to 149', '150 to 179') THEN '90-179 DPD'
            WHEN opening_bkt IN ('180 to 209', '210 to 239', '240 to 269', '270 to 299', '300 to 329', '330 to 359') THEN '180-365 DPD'
            WHEN opening_bkt = '360+' THEN 'Writeoff-365'
            ELSE opening_bkt
        END AS opening_bkt_group,
        current_dpd,
        CASE
            WHEN current_dpd IN ('Current', 'current') THEN 'Current'
            WHEN current_dpd IN ('Current To X', 'current to x') THEN 'Current To X'
            WHEN current_dpd = '1 to 29' THEN '1-29 DPD'
            WHEN current_dpd = '30 to 59' THEN '30-59 DPD'
            WHEN current_dpd = '60 to 89' THEN '60-89 DPD'
            WHEN current_dpd = '90 to 119' THEN '90-119 DPD'
            WHEN current_dpd = '120 to 149' THEN '120-149 DPD'
            WHEN current_dpd = '150 to 179' THEN '150-179 DPD'
            WHEN current_dpd = '180 to 209' THEN '180-209 DPD'
            WHEN current_dpd = '210 to 239' THEN '210-239 DPD'
            WHEN current_dpd = '240 to 269' THEN '240-269 DPD'
            WHEN current_dpd = '270 to 299' THEN '270-299 DPD'
            WHEN current_dpd = '300 to 329' THEN '300-329 DPD'
            WHEN current_dpd = '330 to 359' THEN '330-359 DPD'
            WHEN current_dpd = '360+' THEN 'Writeoff-365'
            ELSE current_dpd
        END AS current_bkt_updated,
        CASE
            WHEN current_dpd IN ('Current', 'current') THEN 'Current'
            WHEN current_dpd IN ('Current To X', 'current to x') THEN 'Current To X'
            WHEN current_dpd = '1 to 29' THEN '1-29 DPD'
            WHEN current_dpd = '30 to 59' THEN '30-59 DPD'
            WHEN current_dpd = '60 to 89' THEN '60-89 DPD'
            WHEN current_dpd IN ('90 to 119', '120 to 149', '150 to 179') THEN '90-179 DPD'
            WHEN current_dpd IN ('180 to 209', '210 to 239', '240 to 269', '270 to 299', '300 to 329', '330 to 359') THEN '180-365 DPD'
            WHEN current_dpd = '360+' THEN 'Writeoff-365'
            ELSE current_dpd
        END AS closing_bkt_group,
        roll_rate,
        /* roll-rate stability classification — combines partner-specific
           overrides with the rank-based opening-vs-current comparison */
        CASE
            WHEN partner_name = 'PartnerX' AND roll_rate IN ('SR', 'SR_Sold') THEN 'Stable'
            WHEN partner_name <> 'PartnerX' AND repo_status = 'Y' THEN 'Stable'
            WHEN partner_name <> 'PartnerX' AND liquidation_status = 'Y' THEN 'Stable'
            WHEN loan_status = 'Subrogated' THEN roll_rate
            WHEN loan_status <> 'Subrogated' AND (current_rank = 0) THEN 'Normal'
            WHEN loan_status <> 'Subrogated' AND (current_rank < opening_rank) THEN 'Roll-back'
            WHEN loan_status <> 'Subrogated' AND (current_rank > opening_rank) THEN 'Roll-forward'
            WHEN loan_status <> 'Subrogated' AND (current_rank = 14 AND opening_rank = 14) THEN 'Roll-forward'
            WHEN partner_name = 'PartnerZ' AND (current_rank = opening_rank) THEN 'Roll-forward'
            WHEN current_rank = opening_rank THEN 'Stable'
            ELSE roll_rate
        END AS roll_rate_updated,
        opening_pos, principal_outstanding_amount, total_outstanding_amount, repo_status,
        liquidation_status, blacklisting_status, blacklisting_date, bounce_flag, rc_status,
        rc_transfer_date, live_tracking, nach_status, gps_status, gross_loan, lead_channel,
        appointment_id, vehicle_registration_number, make_and_model, cibil_score, last_risk_bucket,
        cibil_bucket, ds_channel, area_type, occupation, accomodation, total_ltv, loan_tenure,
        DATEDIFF(month, loan_disbursement_date, fap.dts) AS mob,
        employee_id, source, case_type, visit_purpose, allocation_month, visit_status, visit_date,
        agent_disposition, remarks, visit_spoc, applicant_pincode_1, applicant_city_1, applicant_state_1,
        applicant_region, lrn_status, lrn_date, dbn_status, dbn_date, section_138_stage, section_138_status,
        section_138_date, section_17_9_stage, section_17_9_status, section_17_or_9_date, final_legal_status,
        date_of_payment, repayment_received_during_the_month, c.last_transaction_amount, payment_mode,
        payment_type, total_charges_accrued_till_date, overall_due, monthly_charges_received,
        monthly_charges_pending, excess_amount, emp_name, acm_name, rcm_name, ncm_name,
        pre_bounce_segment, post_bounce_segment, bounce_status, nach_type_flag, partner_loan_id
    FROM final_applicant_details fap
    LEFT JOIN legal l ON l.loan_id = fap.loan_id AND fap.dts = l.dts
    LEFT JOIN charges c ON c.loan_id = fap.loan_id AND fap.dts = c.dts
    LEFT JOIN excess_amount ea ON ea.finreference = fap.loan_id
    LEFT JOIN nach_data n
        ON n.loan_id = fap.loan_id
       AND fap.dts >= n.emi_due_date
       AND fap.dts < DATEADD('month', 1, n.emi_due_date)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY fap.loan_id, fap.dts ORDER BY fap.dts DESC) = 1
)

SELECT * FROM final_dump WHERE dts >= '2026-05-02';
