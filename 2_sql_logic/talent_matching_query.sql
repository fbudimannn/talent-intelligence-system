---- PHASE 1: DATA CLEANING AND IMPUTATION------


--- STEP/CTE 1.A: Calculating Competency Medians ---
----Purpose: Calculate the median score per 'pillar_code' (only from the 2025 valid data)
----This is for imputation of missing/odd competency data.
with competency_medians as(
 SELECT 
    pillar_code, 
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY score) as median_score
    FROM competencies_yearly
    WHERE year = 2025 
    AND score IS NOT NULL 
    AND score NOT IN (0, 6, 99) 
    GROUP BY pillar_code
),

--- STEP/CTE 1.B: Clean and Impute Competency Scores ---
---Purpose: Create a clean 'competencies' table for 2025.
--- Use CTE 1.A to fill in missing/odd data.

competencies_cleaned_imputed as (
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
    ) as score_imputed
FROM competencies_yearly as c
LEFT JOIN competency_medians as cm 
ON c.pillar_code = cm.pillar_code
WHERE c.year = 2025 
),

--- STEP/CTE 1.C: Calculating Median IQ per Department ---
--Purpose: Calculate the median IQ per department.
-- This is for imputation of missing 'iq' data in the 'profiles_psych' table.
---- According to the step 1 , the department 4 has no value in iq amd qtq

cognitive_medians as(
SELECT 
    e.department_id,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY p.iq) FILTER (WHERE e.department_id != 4) as median_iq,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY p.gtq) FILTER (WHERE e.department_id != 4) as median_gtq
FROM employees as e
LEFT JOIN profiles_psych as p 
ON e.employee_id = p.employee_id
WHERE p.iq IS NOT NULL OR p.gtq IS NOT NULL
GROUP BY e.department_id
),


--- STEP/CTE  1.D (Final Version): Clean, Join, and Impute All Main Data ---
---Purpose: Replicate  `df_main_cleaned` from the notebook.
---1. Cleans MBTI typos ('intftj' -> 'UNKNOWN', UPPERCASE)
---2. Dynamically calculates the MBTI Mode (NOT hardcoded 'ENFP')
---3. Imputes NULL MBTI with the calculated mode
---4. JOINS all dimension tables (dim_department, dim_position, etc.)
---5. Imputes IQ and GTQ with departmental medians
---6. Imputes DISC from disc_word 

-- STEP 1.D.1: Clean MBTI Typos
-- Purpose: Clean typos BEFORE calculating the mode.

mbti_cleaned_typos as(
SELECT
  employee_id,
  CASE 
    WHEN mbti = 'inftj' THEN 'UNKNOWN'
    ELSE UPPER(mbti)
    END as mbti_cleaned
FROM profiles_psych
),      

-- STEP 1.D.2: Calculate MBTI Mode
-- Purpose: Find the most common MBTI value (Mode) from the cleaned data.
mbti_mode as (
SELECT 
  MODE() WITHIN GROUP (ORDER BY mbti_cleaned) as mbti_mode_value
FROM mbti_cleaned_typos
WHERE mbti_cleaned is NOT NULL
),


-- STEP/CTE 1.D (Final): Join, Clean, and Impute
-- Purpose: The main cleaned data table, replicating df_main_cleaned.
  -- Impute Cognitive scores (from 1.C)
  -- Impute MBTI (from 1.D.1 and 1.D.2)
      -- 1. Get the cleaned mbti value
      -- 2. If it's NULL, fill it with the calculated mode
  -- Impute DISC 
      -- 1. Use 'disc' if it exists
      -- 2. If 'disc' is NULL, try to map it from 'disc_word'

main_cleaned_imputed as (
SELECT 
    e.employee_id, 
    e.fullname, 
    e.nip,
    com.name as company,
    ar.name as area,
    e.years_of_service_months as tenure_months, 
    d.name as department,
    p.name as position,
    dir.name as directorate,
    g.name as grade,
    ed.name as education_level,
    maj.name as major,
    CASE
            WHEN e.department_id = 4 THEN NULL
            ELSE COALESCE(p_psych.iq, cog_m.median_iq)
        END as iq_imputed,
        CASE
            WHEN e.department_id = 4 THEN NULL
            ELSE COALESCE(p_psych.gtq, cog_m.median_gtq) -- Assuming 'gtq' is total
        END as gtq_imputed,
    COALESCE(mbti_clean.mbti_cleaned, mbti_m.mbti_mode_value) as mbti_final,
    COALESCE(p_psych.disc, 
      CASE 
          WHEN p_psych.disc_word = 'Dominant-Influencer' THEN 'DI'
          WHEN p_psych.disc_word = 'Dominant-Steadiness' THEN 'DS'
          WHEN p_psych.disc_word = 'Dominant-Conscientious' THEN 'DC'
          WHEN p_psych.disc_word = 'Influencer-Dominant' THEN 'ID'
          WHEN p_psych.disc_word = 'Influencer-Steadiness' THEN 'IS'
          WHEN p_psych.disc_word = 'Influencer-Conscientious' THEN 'IC'
          WHEN p_psych.disc_word = 'Steadiness-Dominant' THEN 'SD'
          WHEN p_psych.disc_word = 'Steadiness-Influencer' THEN 'SI'
          WHEN p_psych.disc_word = 'Steadiness-Conscientious' THEN 'SC'
          WHEN p_psych.disc_word = 'Conscientious-Dominant' THEN 'CD'
          WHEN p_psych.disc_word = 'Conscientious-Influencer' THEN 'CI'
          WHEN p_psych.disc_word = 'Conscientious-Steadiness' THEN 'CS'
          ELSE NULL 
      END
    ) as disc,
    p_psych.disc_word,
    p_psych.pauli as pauli_score,
    p_psych.tiki as tiki_score,
    p_psych.faxtor as faxtor_score, 
    py.rating
  
FROM employees as e

LEFT JOIN dim_departments as d 
ON e.department_id = d.department_id

LEFT JOIN dim_positions as p 
ON e.position_id = p.position_id

LEFT JOIN dim_grades as g 
ON e.grade_id = g.grade_id

LEFT JOIN dim_education as ed 
ON e.education_id = ed.education_id

LEFT JOIN dim_majors as maj 
ON e.major_id = maj.major_id

LEFT JOIN dim_companies as com 
ON e.company_id = com.company_id

LEFT JOIN dim_areas as ar 
ON e.area_id = ar.area_id

LEFT JOIN dim_directorates as dir
ON e.directorate_id = dir.directorate_id

-- Join psychometric data
LEFT JOIN profiles_psych as p_psych 
ON e.employee_id = p_psych.employee_id

-- Join our cleaning helper CTEs
LEFT JOIN cognitive_medians as cog_m 
ON e.department_id = cog_m.department_id

LEFT JOIN mbti_cleaned_typos as  mbti_clean 
ON e.employee_id = mbti_clean.employee_id

CROSS JOIN mbti_mode as mbti_m   -- CROSS JOIN for mode (it's only 1 row)

-- Join performance_yearly data
LEFT JOIN performance_yearly as py
ON e.employee_id = py.employee_id

WHERE   
py.rating BETWEEN 1 AND 5 
AND
py.year = 2025
),

---STEP/CTE 1.E: Clean Strengths Data ---
----Purpose: Filter 'rank' 1-5 and clean empty 'themes'.

-- STEP 1.E.1 : Clean all string-like NULLs 
-- PurposeClears strings '', 'nan', 'None', etc. to NULL
strengths_string_cleaned as (   
SELECT
  employee_id,
  "rank",
  CASE 
      WHEN LOWER(TRIM(theme)) IN ('', 'nan', 'none') THEN NULL
      ELSE theme
  END as  theme
FROM strengths
WHERE "rank" BETWEEN 1 AND 5 
),

-- STEP 1.E.2 : Find "Good" Employees 
-- Count the number of VALID themes in the Top 5 for EACH employee
employee_top5_completeness as (
SELECT
    employee_id,
    COUNT(theme) as  top_5_valid_themes_count
FROM strengths_string_cleaned
GROUP BY employee_id
),

-- STEP 1.E.3 (Final CTE): Filter based on the completeness check
strengths_cleaned as (
  SELECT
    s.employee_id,
    s.theme,
    s."rank"
  FROM strengths_string_cleaned as s
  INNER JOIN  employee_top5_completeness as c 
  ON s.employee_id = c.employee_id
  WHERE  c.top_5_valid_themes_count = 5
  ),

--- STEP 1.F: Clean and Impute PAPI Scores 
---Objective : Fill in NULL PAPI scores with the median per PAPI scale.

-- STEP/CTE 1.F.1: Calculate PAPI Medians
-- Objective: Calculate median score PER PAPI scale (similar to competencies).
papi_medians as (
  SELECT
    scale_code,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY score) as median_score
  FROM papi_scores
  WHERE score IS NOT NULL
  GROUP BY scale_code
  ),

-- STEP/CTE 1.F.2: Clean and Impute PAPI Scores
-- Objective: Create a clean 'papi_scores' table with NULLs filled by their scale's median.
papi_cleaned_imputed as (
    SELECT
        ps.employee_id,
        ps.scale_code,
        COALESCE(ps.score, pm.median_score) as score_imputed
    FROM papi_scores as ps
    LEFT JOIN papi_medians as pm 
    ON ps.scale_code = pm.scale_code
    ),


    
-- PHASE 2: BENCHMARKING---

-- STEP/CTE 2.A: Select Target Vacancy (SIMULATED)
-- Objective: Manually define our benchmark employee IDs (rating=5 Sales Supervisors) simulating a manager's input.

target_vacancy as(
  SELECT 
    ARRAY['EMP100012', 'EMP100524','EMP100548']::text[] as selected_talent_ids 
),


-- STEP/CTE 2.B: Calculate the "Ideal" Benchmark Baseline
-- Objective: Translate  TGV Mapping into a 1-row ideal profile.
benchmark_baseline as(
  SELECT   

  -- 1. TGV: Competency (Type: Numeric -> Median)

      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY c.avg_sea) as baseline_sea,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY c.avg_qdd) as baseline_qdd,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY c.avg_ftc) as baseline_ftc,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY c.avg_ids) as baseline_ids,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY c.avg_vcu) as baseline_vcu,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY c.avg_sto_lie) as baseline_sto_lie,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY c.avg_csi) as baseline_csi,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY c.avg_cex_gdr) as baseline_cex_gdr,


  -- 2. TGV: Psychometric (Cognitive) (Type: Numeric -> Median)

      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY m.iq_imputed) as baseline_iq,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY m.gtq_imputed) as baseline_gtq,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY m.pauli_score) as baseline_pauli,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY m.faxtor_score) as baseline_faxtor,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY m.tiki_score) as baseline_tiki,

  -- 3. TGV: Psychometric (Personality) (Type: Categorical -> Mode)

      MODE() WITHIN GROUP (ORDER BY m.mbti_final) as baseline_mbti,
      MODE() WITHIN GROUP (ORDER BY m.disc) as baseline_disc,

     -- PAPI Baseline: (Numeric -> Median)
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY p.score_imputed) FILTER (WHERE p.scale_code = 'Papi_P') as baseline_papi_p,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY p.score_imputed) FILTER (WHERE p.scale_code = 'Papi_S') as baseline_papi_s,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY p.score_imputed) FILTER (WHERE p.scale_code = 'Papi_G') as baseline_papi_g,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY p.score_imputed) FILTER (WHERE p.scale_code = 'Papi_T') as baseline_papi_t,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY p.score_imputed) FILTER (WHERE p.scale_code = 'Papi_W') as baseline_papi_w,

 
  -- 4. TGV: Behavioral (Strengths) (Type: Categorical -> Mode)
  
      -- (Take mode from Rank 1, 2, 3, 4, 5)
      MODE() WITHIN GROUP (ORDER BY s1.theme) as baseline_strength_1,
      MODE() WITHIN GROUP (ORDER BY s2.theme) as baseline_strength_2,
      MODE() WITHIN GROUP (ORDER BY s3.theme) as baseline_strength_3,
      MODE() WITHIN GROUP (ORDER BY s4.theme) as baseline_strength_4,
      MODE() WITHIN GROUP (ORDER BY s5.theme) as baseline_strength_5,

 
  -- 5. TGV: Contextual (Background)
  
      -- Categorical -> Mode
      MODE() WITHIN GROUP (ORDER BY m.education_level) as baseline_education,
      MODE() WITHIN GROUP (ORDER BY m.major) as baseline_major,
      MODE() WITHIN GROUP (ORDER BY m.department) as baseline_department,
      MODE() WITHIN GROUP (ORDER BY m.position) as baseline_position,
      MODE() WITHIN GROUP (ORDER BY m.area) as baseline_area,

      -- Numeric -> Median
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY m.tenure_months) as baseline_tenure
  
  FROM 
    (SELECT unnest(ARRAY['EMP100012','EMP100524', 'EMP100548']::text[]) as employee_id FROM target_vacancy) as benchmark_ids  -- Benchmark Employees
  
  LEFT JOIN main_cleaned_imputed as m 
  ON benchmark_ids.employee_id = m.employee_id
  
  -- Join 5 times for 5 rank (Strengths)
  LEFT JOIN strengths_cleaned  as s1 
  ON benchmark_ids.employee_id = s1.employee_id AND s1."rank" = 1 
  LEFT JOIN strengths_cleaned  as s2 
  ON benchmark_ids.employee_id = s2.employee_id AND s2."rank" = 2 
  LEFT JOIN strengths_cleaned as s3 
  ON benchmark_ids.employee_id = s3.employee_id AND s3."rank" = 3 
  LEFT JOIN strengths_cleaned as s4 
  ON benchmark_ids.employee_id = s4.employee_id AND s4."rank" = 4 
  LEFT JOIN strengths_cleaned as s5 
  ON benchmark_ids.employee_id = s5.employee_id AND s5."rank" = 5 
      
  -- Join for PAPI Scores
  LEFT JOIN papi_cleaned_imputed as p 
  ON benchmark_ids.employee_id = p.employee_id
      
  LEFT JOIN
    (SELECT 
        employee_id,
        AVG(score_imputed) FILTER (WHERE pillar_code = 'SEA') as avg_sea,
        AVG(score_imputed) FILTER (WHERE pillar_code = 'QDD') as avg_qdd,
        AVG(score_imputed) FILTER (WHERE pillar_code = 'FTC') as avg_ftc,
        AVG(score_imputed) FILTER (WHERE pillar_code = 'IDS') as avg_ids,
        AVG(score_imputed) FILTER (WHERE pillar_code = 'VCU') as avg_vcu,
        AVG(score_imputed) FILTER (WHERE pillar_code IN ('STO', 'LIE')) as avg_sto_lie,
        AVG(score_imputed) FILTER (WHERE pillar_code = 'CSI') as avg_csi,
        AVG(score_imputed) FILTER (WHERE pillar_code IN ('CEX', 'GDR')) as avg_cex_gdr
      FROM competencies_cleaned_imputed
      GROUP BY employee_id
    ) as c 
    ON benchmark_ids.employee_id = c.employee_id
),


---- PHASE 3: UNPIVOT ALL EMPLOYEES----- 

-- STEP/CTE 3.A: Unpivot All Employees
  -- Purpose: Create a "long-format" table of ALL employees to match the TGV Mapping.
  -- All user_score values are CAST to TEXT to ensure consistent data types across UNION ALL blocks.
all_employees_unpivoted as (
        
-- 1. TGV: Competency (8 TV blocks from 10 pillars)
  SELECT 
      employee_id, 'Competency' as tgv_name, 'SEA' as tv_name,
      AVG(score_imputed)::text as user_score, 
      'numeric' as tv_type
  FROM competencies_cleaned_imputed WHERE pillar_code = 'SEA' GROUP BY employee_id
  
  UNION ALL
  SELECT 
      employee_id, 'Competency' as tgv_name, 'QDD' as tv_name,
      AVG(score_imputed)::text as user_score, 
      'numeric' as tv_type
  FROM competencies_cleaned_imputed WHERE pillar_code = 'QDD' GROUP BY employee_id
  
  UNION ALL
  SELECT 
      employee_id, 'Competency' as tgv_name, 'FTC' as tv_name, 
      AVG(score_imputed)::text as user_score, 
      'numeric' as tv_type
  FROM competencies_cleaned_imputed WHERE pillar_code = 'FTC' GROUP BY employee_id
  
  UNION ALL
  SELECT
      employee_id, 'Competency' as tgv_name, 'IDS' as tv_name,
      AVG(score_imputed)::text as user_score, 
      'numeric' as tv_type
  FROM competencies_cleaned_imputed WHERE pillar_code = 'IDS' GROUP BY employee_id
  
  UNION ALL
  SELECT
      employee_id, 'Competency' as tgv_name, 'VCU' as tv_name, 
      AVG(score_imputed)::text as user_score, 
      'numeric' as tv_type
  FROM competencies_cleaned_imputed WHERE pillar_code = 'VCU' GROUP BY employee_id
  
  UNION ALL
  SELECT 
      employee_id, 'Competency' as tgv_name, 'STO_LIE' as tv_name, 
      AVG(score_imputed)::text as user_score, 
      'numeric' as tv_type
  FROM competencies_cleaned_imputed WHERE pillar_code IN ('STO', 'LIE') GROUP BY employee_id
  
  UNION ALL
  SELECT 
      employee_id, 'Competency' as tgv_name, 'CSI' as tv_name, 
      AVG(score_imputed)::text as user_score, 
      'numeric' as tv_type
  FROM competencies_cleaned_imputed WHERE pillar_code = 'CSI' GROUP BY employee_id
  
  UNION ALL
  SELECT 
      employee_id, 'Competency' as tgv_name, 'CEX_GDR' as tv_name, 
      AVG(score_imputed)::text as user_score, 
      'numeric' as tv_type
  FROM competencies_cleaned_imputed WHERE pillar_code IN ('CEX', 'GDR') GROUP BY employee_id

  -- 2. TGV: Psychometric (Cognitive) (5 TV)
  UNION ALL
  SELECT 
      employee_id, 'Psychometric (Cognitive)' as tgv_name, 'IQ' as tv_name, 
      iq_imputed::text as user_score, 
      'numeric' as tv_type
  FROM main_cleaned_imputed

  UNION ALL
  SELECT 
      employee_id, 'Psychometric (Cognitive)' as tgv_name, 'GTQ' as tv_name, 
      gtq_imputed::text as user_score, 
      'numeric' as tv_type
  FROM main_cleaned_imputed

  UNION ALL
  SELECT 
      employee_id, 'Psychometric (Cognitive)' as tgv_name, 'Pauli' as tv_name, 
      pauli_score::text as user_score, 
      'numeric' as tv_type
  FROM main_cleaned_imputed

  UNION ALL
  SELECT
      employee_id, 'Psychometric (Cognitive)' as tgv_name, 'Faxtor' as tv_name, 
      faxtor_score::text as user_score, 
      'numeric' as tv_type
  FROM main_cleaned_imputed
  
  UNION ALL
  SELECT 
      employee_id, 'Psychometric (Cognitive)' as tgv_name, 'Tiki' as tv_name, 
      tiki_score::text as user_score, 
      'numeric' as tv_type
  FROM main_cleaned_imputed

  -- 3. TGV: Psychometric (Personality) (MBTI, DISC, 5 PAPI)
  UNION ALL
  SELECT 
      employee_id, 'Psychometric (Personality)' as tgv_name, 'MBTI' as tv_name, 
      mbti_final as user_score, 
      'categorical' as tv_type
  FROM main_cleaned_imputed

  UNION ALL
  SELECT 
      employee_id, 'Psychometric (Personality)' as tgv_name, 'DISC' as tv_name,
      disc as user_score, 
      'categorical' as tv_type
  FROM main_cleaned_imputed

  UNION ALL
  SELECT 
      employee_id, 'Psychometric (Personality)' as tgv_name, 'Papi_P' as tv_name, 
      score_imputed::text as user_score,
      'numeric' as tv_type
  FROM papi_cleaned_imputed WHERE scale_code = 'Papi_P'

  UNION ALL
  SELECT 
      employee_id, 'Psychometric (Personality)' as tgv_name, 'Papi_S' as tv_name, 
      score_imputed::text as user_score,
      'numeric' as tv_type
  FROM papi_cleaned_imputed WHERE scale_code = 'Papi_S'

  UNION ALL
  SELECT 
      employee_id, 'Psychometric (Personality)' as tgv_name, 'Papi_G' as tv_name, 
      score_imputed::text as user_score, 
      'numeric' as tv_type
  FROM papi_cleaned_imputed WHERE scale_code = 'Papi_G'

  UNION ALL
  SELECT 
      employee_id, 'Psychometric (Personality)' as tgv_name, 'Papi_T' as tv_name, 
      score_imputed::text as user_score, 
      'numeric' as tv_type
  FROM papi_cleaned_imputed WHERE scale_code = 'Papi_T'

  UNION ALL
  SELECT 
      employee_id, 'Psychometric (Personality)' as tgv_name, 'Papi_W' as tv_name, 
      score_imputed::text as user_score, 
      'numeric' as tv_type
  FROM papi_cleaned_imputed WHERE scale_code = 'Papi_W'


  -- 4. TGV: Behavioral (Strengths) (5 TV)
  UNION ALL
  SELECT 
      employee_id, 'Behavioral (Strengths)' as tgv_name, 'Strength_1' as tv_name, 
      theme as user_score, 
      'categorical' as tv_type
  FROM strengths_cleaned WHERE "rank" = 1

  UNION ALL
  SELECT 
      employee_id, 'Behavioral (Strengths)' as tgv_name, 'Strength_2' as tv_name, 
      theme as user_score, 
      'categorical' as tv_type
  FROM strengths_cleaned WHERE "rank" = 2

  UNION ALL
  SELECT 
      employee_id, 'Behavioral (Strengths)' as tgv_name, 'Strength_3' as tv_name, 
      theme as user_score, 
      'categorical' as tv_type
  FROM strengths_cleaned WHERE "rank" = 3

  UNION ALL
  SELECT 
      employee_id, 'Behavioral (Strengths)' as tgv_name, 'Strength_4' as tv_name, 
      theme as user_score, 
      'categorical' as tv_type
  FROM strengths_cleaned WHERE "rank" = 4

  UNION ALL
  SELECT 
      employee_id, 'Behavioral (Strengths)' as tgv_name, 'Strength_5' as tv_name, 
      theme as user_score, 
      'categorical' as tv_type
  FROM strengths_cleaned WHERE "rank" = 5

  -- 5. TGV: Contextual (Background) (6 TV)
  UNION ALL
  SELECT 
      employee_id, 'Contextual (Background)' as tgv_name, 'Education' as tv_name, 
      education_level as user_score,
      'categorical' as tv_type
  FROM main_cleaned_imputed

  UNION ALL
  SELECT 
      employee_id, 'Contextual (Background)' as tgv_name, 'Major' as tv_name, 
      major as user_score, 
      'categorical' as tv_type
  FROM main_cleaned_imputed

  UNION ALL
  SELECT 
      employee_id, 'Contextual (Background)' as tgv_name, 'Department' as tv_name, 
      department as user_score, 
      'categorical' as tv_type
  FROM main_cleaned_imputed

  UNION ALL
  SELECT 
      employee_id, 'Contextual (Background)' as tgv_name, 'Position' as tv_name, 
      position as user_score, 
      'categorical' as tv_type
  FROM main_cleaned_imputed


  UNION ALL
  SELECT 
      employee_id, 'Contextual (Background)' as tgv_name, 'Area' as tv_name, 
      area as user_score, 
      'categorical' as tv_type
  FROM main_cleaned_imputed

   UNION ALL
  SELECT 
      employee_id, 'Contextual (Background)' as tgv_name, 'Tenure' as tv_name, 
      tenure_months::text as user_score, 
      'numeric' as tv_type
  FROM main_cleaned_imputed

),


-- PHASE 4: CALCULATE MATCH SCORE
-- STEP/CTE 4.A: Unpivot the Benchmark Baseline
    -- Purpose: To unpivot the 1-row "wide" baseline into a "long-format" table.
    -- Numeric comparisons are later restored by re-casting user_score::numeric in the match calculation step.
benchmark_unpivoted (tgv_name, tv_name, baseline_score, tv_type) as (

SELECT 'Competency', 'SEA', baseline_sea::text, 'numeric' FROM benchmark_baseline
UNION ALL
SELECT 'Competency', 'QDD', baseline_qdd::text, 'numeric' FROM benchmark_baseline
UNION ALL
SELECT 'Competency', 'FTC', baseline_ftc::text, 'numeric' FROM benchmark_baseline
UNION ALL
SELECT 'Competency', 'IDS', baseline_ids::text, 'numeric' FROM benchmark_baseline
UNION ALL
SELECT 'Competency', 'VCU', baseline_vcu::text, 'numeric' FROM benchmark_baseline
UNION ALL
SELECT 'Competency', 'STO_LIE', baseline_sto_lie::text, 'numeric' FROM benchmark_baseline
UNION ALL
SELECT 'Competency', 'CSI', baseline_csi::text, 'numeric' FROM benchmark_baseline
UNION ALL
SELECT 'Competency', 'CEX_GDR', baseline_cex_gdr::text, 'numeric' FROM benchmark_baseline
UNION ALL
SELECT 'Psychometric (Cognitive)', 'IQ', baseline_iq::text, 'numeric' FROM benchmark_baseline
UNION ALL
SELECT 'Psychometric (Cognitive)', 'GTQ', baseline_gtq::text, 'numeric' FROM benchmark_baseline
UNION ALL
SELECT 'Psychometric (Cognitive)', 'Pauli', baseline_pauli::text, 'numeric' FROM benchmark_baseline
UNION ALL
SELECT 'Psychometric (Cognitive)', 'Faxtor', baseline_faxtor::text, 'numeric' FROM benchmark_baseline
UNION ALL
SELECT 'Psychometric (Cognitive)', 'Tiki', baseline_tiki::text, 'numeric' FROM benchmark_baseline
UNION ALL
SELECT 'Psychometric (Personality)', 'MBTI', baseline_mbti, 'categorical' FROM benchmark_baseline
UNION ALL
SELECT 'Psychometric (Personality)', 'DISC', baseline_disc, 'categorical' FROM benchmark_baseline
UNION ALL
SELECT 'Psychometric (Personality)', 'Papi_P', baseline_papi_p::text, 'numeric' FROM benchmark_baseline
UNION ALL
SELECT 'Psychometric (Personality)', 'Papi_S', baseline_papi_s::text, 'numeric' FROM benchmark_baseline
UNION ALL
SELECT 'Psychometric (Personality)', 'Papi_G', baseline_papi_g::text, 'numeric' FROM benchmark_baseline
UNION ALL
SELECT 'Psychometric (Personality)', 'Papi_T', baseline_papi_t::text, 'numeric' FROM benchmark_baseline
UNION ALL
SELECT 'Psychometric (Personality)', 'Papi_W', baseline_papi_w::text, 'numeric' FROM benchmark_baseline
UNION ALL
SELECT 'Behavioral (Strengths)', 'Strength_1', baseline_strength_1, 'categorical' FROM benchmark_baseline
UNION ALL
SELECT 'Behavioral (Strengths)', 'Strength_2', baseline_strength_2, 'categorical' FROM benchmark_baseline
UNION ALL
SELECT 'Behavioral (Strengths)', 'Strength_3', baseline_strength_3, 'categorical' FROM benchmark_baseline
UNION ALL
SELECT 'Behavioral (Strengths)', 'Strength_4', baseline_strength_4, 'categorical' FROM benchmark_baseline
UNION ALL
SELECT 'Behavioral (Strengths)', 'Strength_5', baseline_strength_5, 'categorical' FROM benchmark_baseline
UNION ALL
SELECT 'Contextual (Background)', 'Education', baseline_education, 'categorical' FROM benchmark_baseline
UNION ALL
SELECT 'Contextual (Background)', 'Major', baseline_major, 'categorical' FROM benchmark_baseline
UNION ALL
SELECT 'Contextual (Background)', 'Department', baseline_department, 'categorical' FROM benchmark_baseline
UNION ALL
SELECT 'Contextual (Background)', 'Position', baseline_position, 'categorical' FROM benchmark_baseline
UNION ALL
SELECT 'Contextual (Background)', 'Area', baseline_area, 'categorical' FROM benchmark_baseline
UNION ALL
SELECT 'Contextual (Background)', 'Tenure', baseline_tenure::text, 'numeric' FROM benchmark_baseline
),

-- STEP/CTE 4.B: Join User Scores with Baseline Scores
  -- Purpose: Combining Phase 3 and Phase 4.A
comparison_table as (
    SELECT
        u.employee_id,
        u.tgv_name, 
        u.tv_name,
        u.tv_type,
        u.user_score,
        b.baseline_score
    FROM all_employees_unpivoted as u
    LEFT JOIN benchmark_unpivoted as b 
    ON u.tgv_name = b.tgv_name AND u.tv_name = b.tv_name
),

-- STEP/CTE 4.C: Calculate Individual Match Scores
   -- Purpose: To calculate a 0 or 100 score for each variable.
individual_scores as (
    SELECT
        employee_id,
        tgv_name,
        tv_name,
        tv_type,
        user_score,
        baseline_score,
        CASE
        -- Categorical: exact match = 100, else 0
        WHEN tv_type = 'categorical' THEN
            CASE WHEN user_score = baseline_score THEN 100.0 ELSE 0.0 END

            -- Numeric: proporsional user / baseline, limit to 0..100
            WHEN tv_type = 'numeric' THEN
                CASE
                    WHEN user_score IS NULL OR baseline_score IS NULL THEN 0.0
                    ELSE
                        GREATEST(0.0,
                            LEAST(100.0,
                                ( user_score::numeric / NULLIF(baseline_score::numeric, 0) ) * 100.0))END
        ELSE 0.0
        END as match_score
    FROM comparison_table
),

-- PHASE 5: APPLY WEIGHTING (SUCCESS FORMULA)
 -- Purpose: Transform the TGV Mapping to  SQL.
weights_mapping (tv_name, weight) AS (
    VALUES
        -- 1. Competency (Total: 0.675) - According to the TGV Map
        ('SEA', 0.1125),
        ('QDD', 0.1125),
        ('FTC', 0.075),
        ('IDS', 0.075),
        ('VCU', 0.075),
        ('STO_LIE', 0.075),
        ('CSI', 0.075),
        ('CEX_GDR', 0.075),
        
        -- 2. Psychometric (Cognitive) (Total: 0.05 / 5 TV = 0.01 per TV)
        ('IQ', 0.01),
        ('GTQ', 0.01),
        ('Pauli', 0.01),
        ('Faxtor', 0.01),
        ('Tiki', 0.01),
        
        -- 3. Psychometric (Personality) (Total: 0.05 / 7 TV = 0.00714 per TV)
        ('MBTI', 0.00714),
        ('DISC', 0.00714),
        ('Papi_P', 0.00714),
        ('Papi_S', 0.00714),
        ('Papi_G', 0.00714),
        ('Papi_T', 0.00714),
        ('Papi_W', 0.00714),
        
        -- 4. Behavioral (Strengths) (Total: 0.05 / 5 TV = 0.01 per TV)
        ('Strength_1', 0.01),
        ('Strength_2', 0.01),
        ('Strength_3', 0.01),
        ('Strength_4', 0.01),
        ('Strength_5', 0.01),
        
        -- 5. Contextual (Background) (Total: 0.175 / 6 TV = 0.02917 per TV)
        ('Education', 0.02917),
        ('Major', 0.02917),
        ('Department', 0.02917),
        ('Position', 0.02917),
        ('Area', 0.02917),
        ('Tenure', 0.02917)

),

-- STEP/CTE 5.B: Calculate Weighted Scores
    -- Purpose: Multiply score 0/1 with the weight
weighted_scores AS (
    SELECT
        i.employee_id,
        i.tgv_name,
        i.tv_name,
        i.match_score,
        w.weight,
        (i.match_score * w.weight) as weighted_score
    FROM individual_scores as i
    JOIN weights_mapping as w 
    ON i.tv_name = w.tv_name
),


-- PHASE 6: CALCULATE AGGREGATED & DETAILED SCORES 
 -- STEP/CTE 6.A: Calculate final scores (1 row per employee )
aggregated_scores as (
    SELECT
        w.employee_id,
        -- Final Match Rate
        SUM(w.weighted_score) as final_match_rate,
            
        -- TGV Scores (Raw)
        SUM(w.weighted_score) FILTER (WHERE w.tgv_name = 'Competency') as competency_raw_score,
        SUM(w.weighted_score) FILTER (WHERE w.tgv_name = 'Psychometric (Cognitive)') as cognitive_raw_score,
        SUM(w.weighted_score) FILTER (WHERE w.tgv_name = 'Psychometric (Personality)') as personality_raw_score,
        SUM(w.weighted_score) FILTER (WHERE w.tgv_name = 'Behavioral (Strengths)') as strengths_raw_score,
        SUM(w.weighted_score) FILTER (WHERE w.tgv_name = 'Contextual (Background)') as contextual_raw_score
    FROM weighted_scores as w 
    GROUP BY w.employee_id
),

-- STEP/CTE 6.B: Join details and calculate TGV Ratio
    -- Purpose: Combine individual variable-level scores with employee-level aggregates.
    -- Adds a TGV-level ratio (normalized per category weight) to measure proportional alignment
detailed_scores_with_ratio as (
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
            COALESCE(a.cognitive_raw_score, 0)::numeric / NULLIF(0.05, 0)::numeric
            WHEN c.tgv_name = 'Psychometric (Personality)' THEN 
            COALESCE(a.personality_raw_score, 0)::numeric / NULLIF(0.05, 0)::numeric
            WHEN c.tgv_name = 'Behavioral (Strengths)' THEN 
             COALESCE(a.strengths_raw_score, 0)::numeric / NULLIF(0.05, 0)::numeric
            WHEN c.tgv_name = 'Contextual (Background)' THEN 
             COALESCE(a.contextual_raw_score, 0)::numeric / NULLIF(0.175, 0)::numeric
            ELSE 0 -- Fallback if tgv_name is unexpected
        END as tgv_match_ratio -- Calculate ratio (0 to 1) first
        
    FROM comparison_table as c
    LEFT JOIN individual_scores as i 
    ON c.employee_id = i.employee_id AND c.tv_name = i.tv_name
    LEFT JOIN aggregated_scores as a
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
    dsr.baseline_score,
    dsr.user_score,
    
    -- Match Scores
    dsr.match_score  as tv_match_rate,
    ROUND(dsr.tgv_match_ratio,2) as tgv_match_rate,
    ROUND (dsr.final_match_rate,2) as final_match_rate,
    CASE WHEN m.employee_id = ANY(selected_talent_ids) THEN TRUE ELSE FALSE END AS is_benchmark
    
FROM detailed_scores_with_ratio as dsr 
    
LEFT JOIN  main_cleaned_imputed as m 
ON dsr.employee_id = m.employee_id
    

CROSS JOIN target_vacancy as tv
    
ORDER BY  is_benchmark ASC, 
    final_match_rate DESC,  
    m.employee_id
    