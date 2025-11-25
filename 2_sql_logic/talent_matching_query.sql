


-- === MODEL V2.0 - REFINEMENT NOTES ===
-- This SQL script reflects the final, optimized model presented in the report.
-- Key refinements from the initial exploration include:
--
-- 1. (REMOVED) 'Department': Removed from the final model, making the model more efficient.
--
-- 2. (ADDED) Inverse PAPI Logic: Implemented inverse scoring for 'Papi_S', 'Papi_G', and 'Papi_T'.
--    Deeper analysis revealed high performers score *lower* in these areas,
--    showing a "work smarter, more independent" profile that the model now captures.
--
-- 3. (UPDATED) Strength Logic:
--    - Strengths are no longer treated as 5 separate rank-based variables.
--    - For each employee, up to 5 valid strengths are taken (top non-null by rank).
--    - Benchmark strengths are aggregated into a set.
--    - Match score = (# overlapping strengths with benchmark / 5) * 100.
-- === END OF NOTES ===


---- PHASE 1: DATA CLEANING AND IMPUTATION------

--- STEP/CTE 1.A: Calculating Competency Medians ---
-- Objective: Calculate the median score per 'pillar_code' (only from the 2025 valid data)
-- This is for imputation of missing/odd competency data.
WITH competency_medians AS (
    SELECT 
        pillar_code, 
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY score) AS median_score
    FROM competencies_yearly
    WHERE year = 2025 
      AND score IS NOT NULL 
      AND score NOT IN (0, 6, 99) 
    GROUP BY pillar_code
),

--- STEP/CTE 1.B: Clean and Impute Competency Scores ---
-- Objective: Create a clean 'competencies' table for 2025.
-- Use CTE 1.A to fill in missing/odd data.
competencies_cleaned_imputed AS (
    SELECT 
        c.employee_id,
        c.pillar_code,
        c.year,
        COALESCE(
            CASE 
                WHEN c.score IN (0, 6, 99) THEN NULL 
                ELSE c.score 
            END, 
            cm.median_score
        ) AS score_imputed
    FROM competencies_yearly AS c
    LEFT JOIN competency_medians AS cm 
        ON c.pillar_code = cm.pillar_code
    WHERE c.year = 2025 
),

--- STEP/CTE 1.C: Calculating Median IQ per Department ---
-- Objective: Calculate the median IQ per department.
-- This is for imputation of missing 'iq' data in the 'profiles_psych' table.
-- Note: Department 4 has no value in iq and gtq, so we keep them NULL.
cognitive_medians AS (
    SELECT 
        e.department_id,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY p.iq)  FILTER (WHERE e.department_id != 4) AS median_iq,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY p.gtq) FILTER (WHERE e.department_id != 4) AS median_gtq
    FROM employees AS e
    LEFT JOIN profiles_psych AS p 
        ON e.employee_id = p.employee_id
    WHERE p.iq  IS NOT NULL 
       OR p.gtq IS NOT NULL
    GROUP BY e.department_id
),


--- STEP/CTE 1.D (Final Version): Clean, Join, and Impute All Main Data ---
-- Objective: Replicate `df_main_cleaned` from the notebook.
-- 1. Clean MBTI typos ('inftj' -> 'UNKNOWN', UPPERCASE)
-- 2. Dynamically calculate the MBTI Mode (NOT hardcoded 'ENFP')
-- 3. Impute NULL MBTI with the calculated mode
-- 4. Join all dimension tables (dim_department, dim_position, etc.)
-- 5. Impute IQ and GTQ with departmental medians
-- 6. Impute DISC from disc_word 

-- STEP 1.D.1: Clean MBTI Typos
-- Objective: Clean typos BEFORE calculating the mode.
mbti_cleaned_typos AS (
    SELECT
        employee_id,
        CASE 
            WHEN mbti = 'inftj' THEN 'UNKNOWN'
            ELSE UPPER(mbti)
        END AS mbti_cleaned
    FROM profiles_psych
),      

-- STEP 1.D.2: Calculate MBTI Mode
-- Objective: Find the most common MBTI value (Mode) from the cleaned data.
mbti_mode AS (
    SELECT 
        MODE() WITHIN GROUP (ORDER BY mbti_cleaned) AS mbti_mode_value
    FROM mbti_cleaned_typos
    WHERE mbti_cleaned IS NOT NULL
),

-- STEP/CTE 1.D (Final): Join, Clean, and Impute
-- Objective: The main cleaned data table, replicating df_main_cleaned.
main_cleaned_imputed AS (
    SELECT 
        e.employee_id, 
        e.fullname, 
        e.nip,
        com.name AS company,
        ar.name AS area,
        e.years_of_service_months AS tenure_months, 
        d.name AS department,
        p.name AS position,
        dir.name AS directorate,
        g.name AS grade,
        ed.name AS education_level,
        maj.name AS major,
        CASE
            WHEN e.department_id = 4 THEN NULL
            ELSE COALESCE(p_psych.iq,  cog_m.median_iq)
        END AS iq_imputed,
        CASE
            WHEN e.department_id = 4 THEN NULL
            ELSE COALESCE(p_psych.gtq, cog_m.median_gtq) 
        END AS gtq_imputed,
        COALESCE(mbti_clean.mbti_cleaned, mbti_m.mbti_mode_value) AS mbti_final,
        COALESCE(
            p_psych.disc, 
            CASE 
                WHEN p_psych.disc_word = 'Dominant-Influencer'          THEN 'DI'
                WHEN p_psych.disc_word = 'Dominant-Steadiness'          THEN 'DS'
                WHEN p_psych.disc_word = 'Dominant-Conscientious'       THEN 'DC'
                WHEN p_psych.disc_word = 'Influencer-Dominant'          THEN 'ID'
                WHEN p_psych.disc_word = 'Influencer-Steadiness'        THEN 'IS'
                WHEN p_psych.disc_word = 'Influencer-Conscientious'     THEN 'IC'
                WHEN p_psych.disc_word = 'Steadiness-Dominant'          THEN 'SD'
                WHEN p_psych.disc_word = 'Steadiness-Influencer'        THEN 'SI'
                WHEN p_psych.disc_word = 'Steadiness-Conscientious'     THEN 'SC'
                WHEN p_psych.disc_word = 'Conscientious-Dominant'       THEN 'CD'
                WHEN p_psych.disc_word = 'Conscientious-Influencer'     THEN 'CI'
                WHEN p_psych.disc_word = 'Conscientious-Steadiness'     THEN 'CS'
                ELSE NULL 
            END
        ) AS disc,
        p_psych.disc_word,
        p_psych.pauli  AS pauli_score,
        p_psych.tiki   AS tiki_score,
        p_psych.faxtor AS faxtor_score, 
        py.rating
    FROM employees AS e
    LEFT JOIN dim_departments  AS d   ON e.department_id   = d.department_id
    LEFT JOIN dim_positions    AS p   ON e.position_id     = p.position_id
    LEFT JOIN dim_grades       AS g   ON e.grade_id        = g.grade_id
    LEFT JOIN dim_education    AS ed  ON e.education_id    = ed.education_id
    LEFT JOIN dim_majors       AS maj ON e.major_id        = maj.major_id
    LEFT JOIN dim_companies    AS com ON e.company_id      = com.company_id
    LEFT JOIN dim_areas        AS ar  ON e.area_id         = ar.area_id
    LEFT JOIN dim_directorates AS dir ON e.directorate_id  = dir.directorate_id
    -- Join psychometric data
    LEFT JOIN profiles_psych       AS p_psych ON e.employee_id = p_psych.employee_id
    -- Join cleaning helper CTEs
    LEFT JOIN cognitive_medians    AS cog_m   ON e.department_id = cog_m.department_id
    LEFT JOIN mbti_cleaned_typos   AS mbti_clean ON e.employee_id = mbti_clean.employee_id
    CROSS JOIN mbti_mode           AS mbti_m   -- single row: global MBTI mode
    -- Join performance_yearly data
    LEFT JOIN performance_yearly   AS py       ON e.employee_id = py.employee_id
    WHERE py.rating BETWEEN 1 AND 5 
      AND py.year = 2025
),

------------------------------------------------------------------
-- STEP 1.E: Strength Cleaning (NEW LOGIC)
-- Goal:
--   1) Clean invalid strings (NULL, '', 'nan', 'none')
--   2) For each employee, take up to 5 valid strengths, ordered by rank
--      (if rank 1 is NULL, we skip it and keep next non-null in order)
------------------------------------------------------------------

-- 1.E.1: Clean raw strengths → normalize NULL-like values
strengths_pre AS (
    SELECT
        employee_id,
        "rank",
        CASE 
            WHEN theme IS NULL THEN NULL
            WHEN LOWER(TRIM(theme)) IN ('', 'nan', 'none') THEN NULL
            ELSE theme
        END AS theme_clean
    FROM strengths
),

-- 1.E.2: Re-order non-null strengths by rank per employee,
--        and keep only the first 5 (logical "Top 5" actually available)
strengths_ranked AS (
    SELECT
        employee_id,
        theme_clean AS theme,
        "rank",
        ROW_NUMBER() OVER (
            PARTITION BY employee_id 
            ORDER BY "rank"
        ) AS rn
    FROM strengths_pre
    WHERE theme_clean IS NOT NULL
),

-- 1.E.3: Final strengths_cleaned: up to 5 strengths / employee (no ranking used later)
strengths_cleaned AS (
    SELECT
        employee_id,
        theme
    FROM strengths_ranked
    WHERE rn <= 5
),


--- STEP 1.F: Clean and Impute PAPI Scores 
-- Objective: Fill in NULL PAPI scores with the median per PAPI scale.

-- STEP/CTE 1.F.1: Calculate PAPI Medians
papi_medians AS (
    SELECT
        scale_code,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY score) AS median_score
    FROM papi_scores
    WHERE score IS NOT NULL
    GROUP BY scale_code
),

-- STEP/CTE 1.F.2: Clean and Impute PAPI Scores
papi_cleaned_imputed AS (
    SELECT
        ps.employee_id,
        ps.scale_code,
        COALESCE(ps.score, pm.median_score) AS score_imputed
    FROM papi_scores AS ps
    LEFT JOIN papi_medians AS pm 
        ON ps.scale_code = pm.scale_code
),


    
-- PHASE 2: BENCHMARKING---

-- STEP/CTE 2.A: Select Target Vacancy (SIMULATED)
-- Objective: Manually define benchmark employee IDs (rating=5 Sales Supervisors) simulating a manager's input.
target_vacancy AS (
    SELECT 
        ARRAY['EMP100012','EMP100524','EMP100548']::text[] AS selected_talent_ids 
),

-- STEP/CTE 2.B: Calculate the "Ideal" Benchmark Baseline
-- Objective: Translate TGV Mapping into a 1-row ideal profile.
benchmark_baseline AS (
    SELECT   

        -- 1. TGV: Competency (Numeric -> Median)
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY c.avg_sea)     AS baseline_sea,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY c.avg_qdd)     AS baseline_qdd,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY c.avg_ftc)     AS baseline_ftc,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY c.avg_ids)     AS baseline_ids,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY c.avg_vcu)     AS baseline_vcu,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY c.avg_sto_lie) AS baseline_sto_lie,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY c.avg_csi)     AS baseline_csi,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY c.avg_cex_gdr) AS baseline_cex_gdr,

        -- 2. TGV: Psychometric (Cognitive) (Numeric -> Median)
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY m.iq_imputed)    AS baseline_iq,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY m.gtq_imputed)   AS baseline_gtq,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY m.pauli_score)   AS baseline_pauli,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY m.faxtor_score)  AS baseline_faxtor,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY m.tiki_score)    AS baseline_tiki,

        -- 3. TGV: Psychometric (Personality) (Categorical -> Mode)
        MODE() WITHIN GROUP (ORDER BY m.mbti_final) AS baseline_mbti,
        MODE() WITHIN GROUP (ORDER BY m.disc)       AS baseline_disc,

        -- PAPI Baseline: (Numeric -> Median)
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY p.score_imputed) 
            FILTER (WHERE p.scale_code = 'Papi_P') AS baseline_papi_p,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY p.score_imputed) 
            FILTER (WHERE p.scale_code = 'Papi_S') AS baseline_papi_s,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY p.score_imputed) 
            FILTER (WHERE p.scale_code = 'Papi_G') AS baseline_papi_g,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY p.score_imputed) 
            FILTER (WHERE p.scale_code = 'Papi_T') AS baseline_papi_t,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY p.score_imputed) 
            FILTER (WHERE p.scale_code = 'Papi_W') AS baseline_papi_w,

        -- 4. TGV: Behavioral (Strengths)
        -- NEW: Aggregate all benchmark strengths into a set (array of distinct themes).
        ARRAY_AGG(DISTINCT s.theme) AS baseline_strengths,

        -- 5. TGV: Contextual (Background)
        -- Categorical -> Mode
        MODE() WITHIN GROUP (ORDER BY m.education_level) AS baseline_education,
        MODE() WITHIN GROUP (ORDER BY m.major)           AS baseline_major,
        MODE() WITHIN GROUP (ORDER BY m.position)        AS baseline_position,
        MODE() WITHIN GROUP (ORDER BY m.area)            AS baseline_area,

        -- Numeric -> Median
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY m.tenure_months) AS baseline_tenure
  
    FROM 
        (SELECT unnest(ARRAY['EMP100012','EMP100524','EMP100548']::text[]) AS employee_id 
         FROM target_vacancy) AS benchmark_ids  -- Benchmark Employees
  
    LEFT JOIN main_cleaned_imputed AS m 
        ON benchmark_ids.employee_id = m.employee_id
  
    -- Join strengths (already cleaned & limited to max 5 / employee)
    LEFT JOIN strengths_cleaned AS s 
        ON benchmark_ids.employee_id = s.employee_id
      
    -- Join PAPI Scores
    LEFT JOIN papi_cleaned_imputed AS p 
        ON benchmark_ids.employee_id = p.employee_id
      
    -- Join competencies (aggregated by employee)
    LEFT JOIN (
        SELECT 
            employee_id,
            AVG(score_imputed) FILTER (WHERE pillar_code = 'SEA')             AS avg_sea,
            AVG(score_imputed) FILTER (WHERE pillar_code = 'QDD')             AS avg_qdd,
            AVG(score_imputed) FILTER (WHERE pillar_code = 'FTC')             AS avg_ftc,
            AVG(score_imputed) FILTER (WHERE pillar_code = 'IDS')             AS avg_ids,
            AVG(score_imputed) FILTER (WHERE pillar_code = 'VCU')             AS avg_vcu,
            AVG(score_imputed) FILTER (WHERE pillar_code IN ('STO', 'LIE'))   AS avg_sto_lie,
            AVG(score_imputed) FILTER (WHERE pillar_code = 'CSI')             AS avg_csi,
            AVG(score_imputed) FILTER (WHERE pillar_code IN ('CEX', 'GDR'))   AS avg_cex_gdr
        FROM competencies_cleaned_imputed
        GROUP BY employee_id
    ) AS c 
        ON benchmark_ids.employee_id = c.employee_id
),


---- PHASE 3: UNPIVOT ALL EMPLOYEES----- 

-- STEP/CTE 3.A: Unpivot All Employees
-- Objective: Create a "long-format" table of ALL employees to match the TGV Mapping.
-- All user_score values are CAST to TEXT to ensure consistent data types across UNION ALL blocks.
all_employees_unpivoted AS (
        
    -- 1. TGV: Competency (8 TV blocks from 10 pillars)
    SELECT 
        employee_id, 'Competency' AS tgv_name, 'SEA' AS tv_name,
        AVG(score_imputed)::text AS user_score, 
        'numeric' AS tv_type
    FROM competencies_cleaned_imputed 
    WHERE pillar_code = 'SEA' 
    GROUP BY employee_id
  
    UNION ALL
    SELECT 
        employee_id, 'Competency' AS tgv_name, 'QDD' AS tv_name,
        AVG(score_imputed)::text AS user_score, 
        'numeric' AS tv_type
    FROM competencies_cleaned_imputed 
    WHERE pillar_code = 'QDD' 
    GROUP BY employee_id
  
    UNION ALL
    SELECT 
        employee_id, 'Competency' AS tgv_name, 'FTC' AS tv_name, 
        AVG(score_imputed)::text AS user_score, 
        'numeric' AS tv_type
    FROM competencies_cleaned_imputed 
    WHERE pillar_code = 'FTC' 
    GROUP BY employee_id
  
    UNION ALL
    SELECT
        employee_id, 'Competency' AS tgv_name, 'IDS' AS tv_name,
        AVG(score_imputed)::text AS user_score, 
        'numeric' AS tv_type
    FROM competencies_cleaned_imputed 
    WHERE pillar_code = 'IDS' 
    GROUP BY employee_id
  
    UNION ALL
    SELECT
        employee_id, 'Competency' AS tgv_name, 'VCU' AS tv_name, 
        AVG(score_imputed)::text AS user_score, 
        'numeric' AS tv_type
    FROM competencies_cleaned_imputed 
    WHERE pillar_code = 'VCU' 
    GROUP BY employee_id
  
    UNION ALL
    SELECT 
        employee_id, 'Competency' AS tgv_name, 'STO_LIE' AS tv_name, 
        AVG(score_imputed)::text AS user_score, 
        'numeric' AS tv_type
    FROM competencies_cleaned_imputed 
    WHERE pillar_code IN ('STO', 'LIE') 
    GROUP BY employee_id
  
    UNION ALL
    SELECT 
        employee_id, 'Competency' AS tgv_name, 'CSI' AS tv_name, 
        AVG(score_imputed)::text AS user_score, 
        'numeric' AS tv_type
    FROM competencies_cleaned_imputed 
    WHERE pillar_code = 'CSI' 
    GROUP BY employee_id
  
    UNION ALL
    SELECT 
        employee_id, 'Competency' AS tgv_name, 'CEX_GDR' AS tv_name, 
        AVG(score_imputed)::text AS user_score, 
        'numeric' AS tv_type
    FROM competencies_cleaned_imputed 
    WHERE pillar_code IN ('CEX', 'GDR') 
    GROUP BY employee_id

    -- 2. TGV: Psychometric (Cognitive) (5 TV)
    UNION ALL
    SELECT 
        employee_id, 'Psychometric (Cognitive)' AS tgv_name, 'IQ' AS tv_name, 
        iq_imputed::text AS user_score, 
        'numeric' AS tv_type
    FROM main_cleaned_imputed

    UNION ALL
    SELECT 
        employee_id, 'Psychometric (Cognitive)' AS tgv_name, 'GTQ' AS tv_name, 
        gtq_imputed::text AS user_score, 
        'numeric' AS tv_type
    FROM main_cleaned_imputed

    UNION ALL
    SELECT 
        employee_id, 'Psychometric (Cognitive)' AS tgv_name, 'Pauli' AS tv_name, 
        pauli_score::text AS user_score, 
        'numeric' AS tv_type
    FROM main_cleaned_imputed

    UNION ALL
    SELECT
        employee_id, 'Psychometric (Cognitive)' AS tgv_name, 'Faxtor' AS tv_name, 
        faxtor_score::text AS user_score, 
        'numeric' AS tv_type
    FROM main_cleaned_imputed
  
    UNION ALL
    SELECT 
        employee_id, 'Psychometric (Cognitive)' AS tgv_name, 'Tiki' AS tv_name, 
        tiki_score::text AS user_score, 
        'numeric' AS tv_type
    FROM main_cleaned_imputed

    -- 3. TGV: Psychometric (Personality) (MBTI, DISC, 5 PAPI)
    UNION ALL
    SELECT 
        employee_id, 'Psychometric (Personality)' AS tgv_name, 'MBTI' AS tv_name, 
        mbti_final AS user_score, 
        'categorical' AS tv_type
    FROM main_cleaned_imputed

    UNION ALL
    SELECT 
        employee_id, 'Psychometric (Personality)' AS tgv_name, 'DISC' AS tv_name,
        disc AS user_score, 
        'categorical' AS tv_type
    FROM main_cleaned_imputed

    UNION ALL
    SELECT 
        employee_id, 'Psychometric (Personality)' AS tgv_name, 'Papi_P' AS tv_name, 
        score_imputed::text AS user_score,
        'numeric' AS tv_type
    FROM papi_cleaned_imputed 
    WHERE scale_code = 'Papi_P'

    UNION ALL
    SELECT 
        employee_id, 'Psychometric (Personality)' AS tgv_name, 'Papi_S' AS tv_name, 
        score_imputed::text AS user_score,
        'numeric' AS tv_type
    FROM papi_cleaned_imputed 
    WHERE scale_code = 'Papi_S'

    UNION ALL
    SELECT 
        employee_id, 'Psychometric (Personality)' AS tgv_name, 'Papi_G' AS tv_name, 
        score_imputed::text AS user_score, 
        'numeric' AS tv_type
    FROM papi_cleaned_imputed 
    WHERE scale_code = 'Papi_G'

    UNION ALL
    SELECT 
        employee_id, 'Psychometric (Personality)' AS tgv_name, 'Papi_T' AS tv_name, 
        score_imputed::text AS user_score, 
        'numeric' AS tv_type
    FROM papi_cleaned_imputed 
    WHERE scale_code = 'Papi_T'

    UNION ALL
    SELECT 
        employee_id, 'Psychometric (Personality)' AS tgv_name, 'Papi_W' AS tv_name, 
        score_imputed::text AS user_score, 
        'numeric' AS tv_type
    FROM papi_cleaned_imputed 
    WHERE scale_code = 'Papi_W'


    -- 4. TGV: Behavioral (Strengths) 
    -- IMPORTANT: Only ONE row per employee for Strength.
    -- The detailed match is computed later via overlap with benchmark strengths.
    UNION ALL
    SELECT 
        sc.employee_id, 
        'Behavioral (Strengths)' AS tgv_name, 
        'Strength' AS tv_name, 
        NULL::text AS user_score,   -- not used in scoring
        'categorical' AS tv_type
    FROM strengths_cleaned sc
    GROUP BY sc.employee_id

    -- 5. TGV: Contextual (Background) (5 TV)
    UNION ALL
    SELECT 
        employee_id, 'Contextual (Background)' AS tgv_name, 'Education' AS tv_name, 
        education_level AS user_score,
        'categorical' AS tv_type
    FROM main_cleaned_imputed

    UNION ALL
    SELECT 
        employee_id, 'Contextual (Background)' AS tgv_name, 'Major' AS tv_name, 
        major AS user_score, 
        'categorical' AS tv_type
    FROM main_cleaned_imputed

    UNION ALL
    SELECT 
        employee_id, 'Contextual (Background)' AS tgv_name, 'Position' AS tv_name, 
        position AS user_score, 
        'categorical' AS tv_type
    FROM main_cleaned_imputed

    UNION ALL
    SELECT 
        employee_id, 'Contextual (Background)' AS tgv_name, 'Area' AS tv_name, 
        area AS user_score, 
        'categorical' AS tv_type
    FROM main_cleaned_imputed

    UNION ALL
    SELECT 
        employee_id, 'Contextual (Background)' AS tgv_name, 'Tenure' AS tv_name, 
        tenure_months::text AS user_score, 
        'numeric' AS tv_type
    FROM main_cleaned_imputed
),


-- PHASE 4: CALCULATE MATCH SCORE

-- STEP/CTE 4.A: Unpivot the Benchmark Baseline
-- Objective: To unpivot the 1-row "wide" baseline into a "long-format" table
-- (except for Strengths, which are handled via a set overlap logic).
benchmark_unpivoted (tgv_name, tv_name, baseline_score, tv_type) AS (

    SELECT 'Competency', 'SEA',      baseline_sea::text,      'numeric'    FROM benchmark_baseline
    UNION ALL
    SELECT 'Competency', 'QDD',      baseline_qdd::text,      'numeric'    FROM benchmark_baseline
    UNION ALL
    SELECT 'Competency', 'FTC',      baseline_ftc::text,      'numeric'    FROM benchmark_baseline
    UNION ALL
    SELECT 'Competency', 'IDS',      baseline_ids::text,      'numeric'    FROM benchmark_baseline
    UNION ALL
    SELECT 'Competency', 'VCU',      baseline_vcu::text,      'numeric'    FROM benchmark_baseline
    UNION ALL
    SELECT 'Competency', 'STO_LIE',  baseline_sto_lie::text,  'numeric'    FROM benchmark_baseline
    UNION ALL
    SELECT 'Competency', 'CSI',      baseline_csi::text,      'numeric'    FROM benchmark_baseline
    UNION ALL
    SELECT 'Competency', 'CEX_GDR',  baseline_cex_gdr::text,  'numeric'    FROM benchmark_baseline

    UNION ALL
    SELECT 'Psychometric (Cognitive)', 'IQ',    baseline_iq::text,    'numeric' FROM benchmark_baseline
    UNION ALL
    SELECT 'Psychometric (Cognitive)', 'GTQ',   baseline_gtq::text,   'numeric' FROM benchmark_baseline
    UNION ALL
    SELECT 'Psychometric (Cognitive)', 'Pauli', baseline_pauli::text, 'numeric' FROM benchmark_baseline
    UNION ALL
    SELECT 'Psychometric (Cognitive)', 'Faxtor',baseline_faxtor::text,'numeric' FROM benchmark_baseline
    UNION ALL
    SELECT 'Psychometric (Cognitive)', 'Tiki',  baseline_tiki::text,  'numeric' FROM benchmark_baseline

    UNION ALL
    SELECT 'Psychometric (Personality)', 'MBTI',   baseline_mbti,        'categorical' FROM benchmark_baseline
    UNION ALL
    SELECT 'Psychometric (Personality)', 'DISC',   baseline_disc,        'categorical' FROM benchmark_baseline
    UNION ALL
    SELECT 'Psychometric (Personality)', 'Papi_P', baseline_papi_p::text,'numeric'     FROM benchmark_baseline
    UNION ALL
    SELECT 'Psychometric (Personality)', 'Papi_S', baseline_papi_s::text,'numeric'     FROM benchmark_baseline
    UNION ALL
    SELECT 'Psychometric (Personality)', 'Papi_G', baseline_papi_g::text,'numeric'     FROM benchmark_baseline
    UNION ALL
    SELECT 'Psychometric (Personality)', 'Papi_T', baseline_papi_t::text,'numeric'     FROM benchmark_baseline
    UNION ALL
    SELECT 'Psychometric (Personality)', 'Papi_W', baseline_papi_w::text,'numeric'     FROM benchmark_baseline

    -- NOTE: Strength is NOT unpivoted here, because we use a custom overlap-based formula.
    -- The "baseline_strengths" array is consumed later inside the Strength match logic.

    UNION ALL
    SELECT 'Contextual (Background)', 'Education', baseline_education, 'categorical' FROM benchmark_baseline
    UNION ALL
    SELECT 'Contextual (Background)', 'Major',     baseline_major,     'categorical' FROM benchmark_baseline
    UNION ALL
    SELECT 'Contextual (Background)', 'Position',  baseline_position,  'categorical' FROM benchmark_baseline
    UNION ALL
    SELECT 'Contextual (Background)', 'Area',      baseline_area,      'categorical' FROM benchmark_baseline
    UNION ALL
    SELECT 'Contextual (Background)', 'Tenure',    baseline_tenure::text, 'numeric'  FROM benchmark_baseline
),

-- STEP/CTE 4.B: Join User Scores with Baseline Scores
-- Objective: Combining Phase 3 and Phase 4.A
comparison_table AS (
    SELECT
        u.employee_id,
        u.tgv_name, 
        u.tv_name,
        u.tv_type,
        u.user_score,
        b.baseline_score
    FROM all_employees_unpivoted AS u
    LEFT JOIN benchmark_unpivoted AS b 
        ON u.tgv_name = b.tgv_name 
       AND u.tv_name  = b.tv_name
),

-- STEP/CTE 4.C: Calculate Individual Match Scores
-- Objective: To calculate a 0–100 score for each variable (TV).
individual_scores AS (
    SELECT
        c.employee_id,
        c.tgv_name,
        c.tv_name,
        c.tv_type,
        c.user_score,
        c.baseline_score,
        CASE
        
            ------------------------------------------------------------------
            -- SPECIAL CASE: Strength Match (Proportional)
            -- Logic:
            --   1) For each employee, take up to 5 strengths from strengths_cleaned.
            --   2) Compare against benchmark_baseline.baseline_strengths (set of themes).
            --   3) match_strength = ( #overlap / 5 ) * 100.
            --      - If employee has fewer than 5 strengths, denominator stays 5.
            --      - If no overlap, score = 0.
            ------------------------------------------------------------------
            WHEN c.tv_name = 'Strength' THEN (
                SELECT 
                    COALESCE( (COUNT(*)::float / 5.0) * 100.0, 0.0 )
                FROM strengths_cleaned sc
                CROSS JOIN benchmark_baseline bb
                WHERE sc.employee_id = c.employee_id
                  AND sc.theme = ANY(bb.baseline_strengths)
            )

            -- Categorical TV: exact match = 100, else 0
            WHEN c.tv_type = 'categorical' THEN
                CASE 
                    WHEN c.user_score = c.baseline_score THEN 100.0 
                    ELSE 0.0 
                END

            -- Numeric TV: proportional user / baseline, bounded to [0, 100]
            WHEN c.tv_type = 'numeric' THEN
                CASE 
                    WHEN c.user_score IS NULL OR c.baseline_score IS NULL THEN 0.0
                    -- Inverse scale for Papi_T, Papi_S, Papi_G
                    WHEN c.tv_name IN ('Papi_T','Papi_S','Papi_G') THEN 
                        GREATEST(
                            0.0, 
                            LEAST(
                                100.0,
                                ((2 * c.baseline_score::numeric - c.user_score::numeric)
                                  / NULLIF(c.baseline_score::numeric, 0)
                                ) * 100.0
                            )
                        )
                    ELSE 
                        GREATEST(
                            0.0, 
                            LEAST(
                                100.0,
                                (c.user_score::numeric 
                                  / NULLIF(c.baseline_score::numeric, 0)
                                ) * 100.0
                            )
                        )
                END
            ELSE 
                0.0
        END AS match_score
    FROM comparison_table AS c
),


-- PHASE 5: APPLY WEIGHTING (SUCCESS FORMULA)
-- Objective: Transform the TGV Mapping into SQL.
weights_mapping (tv_name, weight) AS (
    VALUES
        -- 1. Competency (Total: 0.675) - According to the TGV Map
        ('SEA',      0.084375),
        ('QDD',      0.084375),
        ('FTC',      0.084375),
        ('IDS',      0.084375),
        ('VCU',      0.084375),
        ('STO_LIE',  0.084375),
        ('CSI',      0.084375),
        ('CEX_GDR',  0.084375),
        
        -- 2. Psychometric (Cognitive) (Total: 0.05 / 5 TV = 0.01 per TV)
        ('IQ',       0.01),
        ('GTQ',      0.01),
        ('Pauli',    0.01),
        ('Faxtor',   0.01),
        ('Tiki',     0.01),
        
        -- 3. Psychometric (Personality) (Total: 0.05 / 7 TV = 0.00714 per TV)
        ('MBTI',     0.00714),
        ('DISC',     0.00714),
        ('Papi_P',   0.00714),
        ('Papi_S',   0.00714),
        ('Papi_G',   0.00714),
        ('Papi_T',   0.00714),
        ('Papi_W',   0.00714),
        
        -- 4. Behavioral (Strengths) (Total: 0.05) - now single TV
        ('Strength', 0.05),
        
        -- 5. Contextual (Background) (Total: 0.175 / 5 TV = 0.035 per TV)
        ('Education',0.035),
        ('Major',    0.035),
        ('Position', 0.035),
        ('Area',     0.035),
        ('Tenure',   0.035)
),

-- STEP/CTE 5.B: Calculate Weighted Scores
-- Objective: Multiply match_score (0–100) with the TV weight.
weighted_scores AS (
    SELECT
        i.employee_id,
        i.tgv_name,
        i.tv_name,
        i.match_score,
        w.weight,
        (i.match_score * w.weight) AS weighted_score
    FROM individual_scores AS i
    JOIN weights_mapping  AS w 
        ON i.tv_name = w.tv_name
),


-- PHASE 6: CALCULATE AGGREGATED & DETAILED SCORES 

-- STEP/CTE 6.A: Calculate final scores (1 row per employee )
aggregated_scores AS (
    SELECT
        w.employee_id,
        -- Final Match Rate
        SUM(w.weighted_score) AS final_match_rate,
            
        -- TGV Scores (Raw)
        SUM(w.weighted_score) FILTER (WHERE w.tgv_name = 'Competency')               AS competency_raw_score,
        SUM(w.weighted_score) FILTER (WHERE w.tgv_name = 'Psychometric (Cognitive)') AS cognitive_raw_score,
        SUM(w.weighted_score) FILTER (WHERE w.tgv_name = 'Psychometric (Personality)') AS personality_raw_score,
        SUM(w.weighted_score) FILTER (WHERE w.tgv_name = 'Behavioral (Strengths)')   AS strengths_raw_score,
        SUM(w.weighted_score) FILTER (WHERE w.tgv_name = 'Contextual (Background)') AS contextual_raw_score
    FROM weighted_scores AS w 
    GROUP BY w.employee_id
),

-- STEP/CTE 6.B: Join details and calculate TGV Ratio
-- Objective: Combine individual variable-level scores with employee-level aggregates.
-- Adds a TGV-level ratio (normalized per category weight) to measure proportional alignment
detailed_scores_with_ratio AS (
    SELECT
        c.employee_id,
        c.tgv_name,
        c.tv_name,
        c.user_score,
        c.baseline_score,
        i.match_score,
        a.final_match_rate,
        -- Calculate TGV Ratio here, using explicit weights
        CASE 
            WHEN c.tgv_name = 'Competency' THEN 
                COALESCE(a.competency_raw_score, 0)::numeric / NULLIF(0.675, 0)::numeric
            WHEN c.tgv_name = 'Psychometric (Cognitive)' THEN 
                COALESCE(a.cognitive_raw_score, 0)::numeric  / NULLIF(0.05,  0)::numeric
            WHEN c.tgv_name = 'Psychometric (Personality)' THEN 
                COALESCE(a.personality_raw_score, 0)::numeric / NULLIF(0.05,  0)::numeric
            WHEN c.tgv_name = 'Behavioral (Strengths)' THEN 
                COALESCE(a.strengths_raw_score, 0)::numeric   / NULLIF(0.05,  0)::numeric
            WHEN c.tgv_name = 'Contextual (Background)' THEN 
                COALESCE(a.contextual_raw_score, 0)::numeric  / NULLIF(0.175, 0)::numeric
            ELSE 0 -- Fallback if tgv_name is unexpected
        END AS tgv_match_ratio
    FROM comparison_table   AS c
    LEFT JOIN individual_scores AS i 
        ON c.employee_id = i.employee_id 
       AND c.tv_name     = i.tv_name
    LEFT JOIN aggregated_scores AS a
        ON c.employee_id = a.employee_id
)

-- FINAL SELECT: 
    

SELECT
    m.employee_id,
    m.directorate,
    m.position as role,
    m.grade,

    -- TGV/TV Info
    dsr.tgv_name, 
    dsr.tv_name, 

    -- Replace baseline & user score khusus Strength
    CASE 
        WHEN dsr.tv_name = 'Strength' THEN 
            (
                SELECT STRING_AGG(DISTINCT sc.theme, ', ')
                FROM strengths_cleaned sc
                JOIN target_vacancy tv2 
                    ON sc.employee_id = ANY(tv2.selected_talent_ids)
            )
        ELSE dsr.baseline_score
    END AS baseline_score,

    CASE 
        WHEN dsr.tv_name = 'Strength' THEN 
            (
                SELECT STRING_AGG(DISTINCT sc.theme, ', ')
                FROM strengths_cleaned sc
                WHERE sc.employee_id = dsr.employee_id
                LIMIT 5
            )
        ELSE dsr.user_score
    END AS user_score,

    -- Match Scores
    dsr.match_score  as tv_match_rate,
    ROUND(dsr.tgv_match_ratio::numeric, 2) as tgv_match_rate,
    ROUND(dsr.final_match_rate::numeric, 2) as final_match_rate,

    CASE WHEN m.employee_id = ANY(selected_talent_ids) THEN TRUE ELSE FALSE END AS is_benchmark
FROM detailed_scores_with_ratio as dsr 
LEFT JOIN main_cleaned_imputed as m 
    ON dsr.employee_id = m.employee_id
CROSS JOIN target_vacancy as tv
ORDER BY 
    is_benchmark ASC, 
    final_match_rate DESC,  
    m.employee_id
