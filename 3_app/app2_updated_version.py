import streamlit as st
import pandas as pd
import numpy as np
import os
from dotenv import load_dotenv
from sqlalchemy import create_engine, text
import openai
import plotly.express as px
import plotly.graph_objects as go

# --- PAGE CONFIGURATION ---
st.set_page_config(layout="wide", page_title="Talent Match App")

# --- DATABASE CONNECTION ---
@st.cache_resource
def get_db_engine():
    """Establishes a connection pool to the PostgreSQL database using credentials from .env."""
    dotenv_path = os.path.join(os.path.dirname(__file__), '..', '.env')
    load_dotenv(dotenv_path=dotenv_path) 

    db_host = os.getenv('DB_HOST')
    db_port = os.getenv('DB_PORT')
    db_name = os.getenv('DB_NAME')
    db_user = os.getenv('DB_USER')
    db_password = os.getenv('DB_PASSWORD')

    connection_string = f"postgresql://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}"
    return create_engine(connection_string)

engine = get_db_engine()

# --- LOAD BASE SQL QUERY ---
@st.cache_data
def load_base_query():
    """Loads the main talent matching SQL query from an external file."""
    sql_file_path = os.path.join(os.path.dirname(__file__), '..', '2_sql_logic', 'talent_matching_query.sql')
    with open(sql_file_path, 'r') as file:
        return file.read()

base_sql_query = load_base_query()

# --- FETCH EMPLOYEE LIST ---
@st.cache_data
def get_employee_list():
    """
    Fetches a comprehensive list of employees with their roles, grades,
    and 2025 rating for filtering and selection widgets.
    """
    query = """
    SELECT 
        e.employee_id, 
        e.fullname, 
        p.name as role,  -- Position name
        g.name as grade, -- Grade name
        py.rating        -- 2025 Rating (will be 5 or NULL)
    FROM employees as e
    LEFT JOIN dim_positions as p ON e.position_id = p.position_id
    LEFT JOIN dim_grades as g ON e.grade_id = g.grade_id
    LEFT JOIN performance_yearly as py ON e.employee_id = py.employee_id AND py.year = 2025 AND py.rating = 5
    ORDER BY e.fullname;
    """
    
    with engine.connect() as connection:
        df = pd.read_sql(text(query), connection)
    
    # Create a display column combining name and ID
    df['display'] = df['fullname'] + " (" + df['employee_id'] + ")"
    
    # Handle potential NULLs in filter columns
    df['role'] = df['role'].fillna('Unknown')
    df['grade'] = df['grade'].fillna('Unknown')
    
    return df



# --- GENERATE AI JOB PROFILE (HYBRID V3) ---
@st.cache_data
def generate_job_profile(role_name, job_level, role_purpose, benchmark_profile: pd.Series):
    """Generates a hybrid job profile using data (benchmark) and context (purpose)."""
    api_key = os.getenv("OPENROUTER_API_KEY")
    if not api_key:
        return "Error: Missing OpenRouter API key. Please set it in your .env file."

    # --- PART 1: THE DATA ---
    try:
        # Competency fields evaluated as part of the benchmark analysis.
        competency_fields = [
            'baseline_sea',
            'baseline_qdd',
            'baseline_ftc',
            'baseline_ids',
            'baseline_vcu',
            'baseline_sto_lie',
            'baseline_csi',
            'baseline_cex_gdr'
        ]

        # These are grouped competency pillars, representing combined behavioral strengths.
        grouped_competency_labels = {
            'CEX_GDR': 'Curiosity & Experimentation + Growth Drive & Resilience',
            'STO_LIE': 'Synergy & Team Orientation + Lead, Inspire & Empower'
        }

        # This dictionary contains the standard names of each competency pillar.
        pillar_labels = {
            'GDR': 'Growth Drive & Resilience',
            'CEX': 'Curiosity & Experimentation',
            'IDS': 'Insight & Decision Sharpness',
            'QDD': 'Quality Delivery Discipline',
            'STO': 'Synergy & Team Orientation',
            'SEA': 'Social Empathy & Awareness',
            'VCU': 'Value Creation for Users',
            'LIE': 'Lead, Inspire & Empower',
            'FTC': 'Forward Thinking & Clarity',
            'CSI': 'Commercial Savvy & Impact'
        }

        # The system extracts only competencies that scored the maximum benchmark rating (5.0).
        competencies_list = []
        for field in competency_fields:
            score = benchmark_profile[field]
            if score == 5.0:
                comp_code = field.replace('baseline_', '').upper()
                comp_label = grouped_competency_labels.get(
                    comp_code,
                    pillar_labels.get(comp_code.split('_')[0], comp_code)
                )
                competencies_list.append(f"{comp_label} ({score:.1f}/5.0)")

        # If no competency scored 5.0, the system falls back to displaying all available benchmark competencies.
        if not competencies_list:
            competencies_list = [
                f"{field.replace('baseline_', '').upper()} ({benchmark_profile[field]:.1f}/5.0)"
                for field in competency_fields
            ]

        competency_descriptions = "\n".join([f"- {c}" for c in competencies_list])

        # Select key data points from the SQL benchmark
        profile_details = f"""
- Ideal Education: {benchmark_profile['baseline_education']}
- Ideal Major: {benchmark_profile['baseline_major']}
- Ideal Position: {benchmark_profile['baseline_position']}
- Average Tenure: {benchmark_profile['baseline_tenure']:.0f} months
- Key Competency (SEA): {benchmark_profile['baseline_sea']:.1f}/5.0
- Key Competencies Scored 5.0/5.0 (Benchmark Top Performers):{competency_descriptions}
- Key Competency (QDD): {benchmark_profile['baseline_qdd']:.1f}/5.0
- Dominant MBTI: {benchmark_profile['baseline_mbti']}
- Dominant DISC: {benchmark_profile['baseline_disc']}
"""
    except KeyError:
        profile_details = "Benchmark profile details could not be loaded."
    except Exception as e:
        profile_details = f"An error occurred formatting benchmark details: {e}"


    # --- PART 2: THE CONTEXT & PROMPT ---
    # This Hybrid Prompt instructs the AI to use BOTH data and context
    prompt = f"""
You are an expert HR strategist. Your goal is to combine hard data with specific business context to create a world-class job profile.

---
### PART 1: THE DATA (Source of Truth)
This is the data-driven profile of our ideal candidate, based on our top performers:
{profile_details}
---
### PART 2: THE CONTEXT (Business Need)
We are hiring for this specific role:
Role: {role_name}
Level: {job_level}
Purpose: {role_purpose}
---

### YOUR TASK:
You are an HR Strategy Advisor specializing in talent intelligence and succession planning.
Using both **data from benchmark performers** and **business purpose**, your task is to formulate a 
**strategic and future-oriented ideal job profile**.

## Job Description 
- Write a **full and descriptive** paragraph. **Do not** use generic phrases like 'We are seeking...'.
- Instead, **elaborate** on what the ideal candidate profile (from **Part 1 Data**) looks like in practice.
- You **must** connect this profile with the **business context (Part 2 Purpose)** to create a compelling narrative about the role's impact.

## Key Requirements
- Create a **single, comprehensive bullet-point list** of qualifications.
- **1. (Data-Driven):** Start by **translating** the key attributes from **Part 1 (Data)** into natural, professional requirements.
    - (Example: 'Dominant ESTP MBTI type' should become 'A personality profile aligning with ESTP, indicating a decisive and action-oriented leader.')
    - (Example: 'Average Tenure: 63 months' should become 'Demonstrated stability with an average tenure of ~63 months in related roles.')
- **2. (Inferred):** Then, **add 3 logical, well-described requirements** that you infer are necessary based on **Part 2 (Context)**.
- ***Do not use sub-headings***. Ensure the entire list flows as one.

## Key Competencies
- Create a **single, comprehensive bullet-point list** of competencies.
- **1. Data-Driven Insights:** From the competency data provided in Part 1 (only include the competencies with a perfect score of 5.0/5.0), clearly mention each competency by name and score. Explain how each of these competencies contributes to success in this role, focusing on how top performers demonstrate these in real execution and decision-making.
- **2. Strategic Relevance:** From the listed competencies, highlight the ones that are most critical for achieving the stated business purpose and aligned with the role's organizational level (e.g., for Internal Audit Staff: risk awareness, integrity, analytical depth, process governance).
- **3. Future-Fit Perspective:** Additionally, infer and include 3 complementary competencies or behavioral strengths that are logically required for this role in the near future (e.g., adaptability, digital literacy, stakeholder influence).
- Do **not** use any sub-headings within the bullet list. Ensure the final list reads as a fluent and cohesive narrative rather than separated sections.


"""
    
    try:
        client = openai.OpenAI(base_url="https://openrouter.ai/api/v1", api_key=api_key)
        response = client.chat.completions.create(
            model="meta-llama/llama-3.3-70b-instruct:free", 
            messages=[
                {"role": "system", "content": "You are an expert HR strategist specializing in data-driven job profile creation."},
                {"role": "user", "content": prompt}
            ],
            max_tokens=1400, 
            temperature=0.6 
        )
        return response.choices[0].message.content.strip()
    except Exception as e:
        st.error(f"Error generating AI profile: {e}")
        return "Failed to generate AI profile."

# --- MAIN STREAMLIT UI ---
st.title("Talent Match Intelligence System 🧠✨")
st.markdown("Use the sidebar to define your new role and select benchmark employees to generate ranked matches.")

# --- SIDEBAR FOR INPUTS ---
with st.sidebar:
    st.header("Vacancy & Benchmark Settings")
    
    # --- Section 1: Define New Role (Inputs for AI) ---
    st.subheader("1. Define New Role")
    role_name_input = st.text_input("New Role Name", "Data Analyst") 
    job_level_input = st.selectbox("New Job Level", ["Staff", "Supervisor", "Manager", "Senior Manager"], index=1)
    
    # --- RE-INTRODUCED ROLE PURPOSE ---
    role_purpose_input = st.text_area(
        "Role Purpose", 
        "Describe the main business objective for this new role. (e.g., 'To build a new data science team from scratch for our marketing department')", 
        height=100
    )

    employee_list_df = get_employee_list()

    # Create lists for the filter dropdowns
    all_roles = sorted(employee_list_df['role'].unique())
    all_grades = sorted(employee_list_df['grade'].unique())
    all_ratings = ['5'] # Manually define rating options
    
    # --- Section 2: Find Benchmarks (Optional Filters) ---
    st.subheader("2. Find Benchmarks (Optional Filters)")
    filter_role = st.selectbox(
        "Filter by Role (Position):",
        options=["All"] + all_roles,
        index=0 
    )
    
    filter_grade = st.selectbox(
        "Filter by Grade:",
        options=["All"] + all_grades,
        index=0 
    )
    
    filter_rating = st.selectbox(
        "Filter by Rating (2025):",
        options=["All"] + all_ratings, # This list is just ['5']
        index=0 
    )

    # Filter the employee DataFrame based on ALL dropdown selections
    filtered_df = employee_list_df.copy() 
    if filter_role != "All":
        filtered_df = filtered_df[filtered_df['role'] == filter_role]
    if filter_grade != "All":
        filtered_df = filtered_df[filtered_df['grade'] == filter_grade]
    if filter_rating == '5': 
        # Correctly filters for 5.0 (float) using '5' (str)
        filtered_df = filtered_df[filtered_df['rating'] == 5.0]

    # --- Section 3: Select Benchmark Employees (Input for SQL) ---
    st.subheader("3. Select Benchmark Employees")
    
    # Find the 'display' names for the default IDs, *if* they exist in the filtered list
    default_ids = ['EMP100012','EMP100524','EMP100548']
    default_options = filtered_df[filtered_df['employee_id'].isin(default_ids)]['display'].tolist()
    
    selected_benchmarks = st.multiselect(
        "Select up to 3 benchmarks from filtered list:",
        options=filtered_df['display'], # Use the filtered DataFrame
        max_selections=3,
        default=default_options 
    )

    # Extract IDs from the selected display strings
    selected_benchmark_ids = [display_str.split('(')[-1].replace(')', '') for display_str in selected_benchmarks]

    generate_button = st.button("✨ Generate Profile & Matches")

# --- EXECUTE SQL QUERY ---
if generate_button:
    if not selected_benchmark_ids:
        st.sidebar.error("Please select at least one benchmark employee.")
    else:
        # Create the SQL array string from the selected IDs
        sql_array_string = "ARRAY[" + ",".join([f"'{eid}'" for eid in selected_benchmark_ids]) + "]::text[]"
        
        try:
            # 1. Define the marker to find the end of the benchmark_baseline CTE
            benchmark_cte_end_marker = "ON benchmark_ids.employee_id = c.employee_id\n)"
            
            # Find the index to split the query
            benchmark_query_index = base_sql_query.index(benchmark_cte_end_marker) + len(benchmark_cte_end_marker)
            
            # 2. Create the Benchmark-Only Query (to get data for the AI)
            benchmark_query_string = base_sql_query[:benchmark_query_index] + "\nSELECT * FROM benchmark_baseline;"
            
            # 3. Parameterize both queries
            parameterized_benchmark_query = benchmark_query_string.replace("ARRAY['EMP100012','EMP100524','EMP100548']::text[]", sql_array_string)
            parameterized_full_query = base_sql_query.replace("ARRAY['EMP100012','EMP100524','EMP100548']::text[]", sql_array_string)

            with st.spinner("Analyzing talent data... ⏳"):
                with engine.connect() as connection:
                    # 4. Execute Benchmark Query First
                    df_benchmark = pd.read_sql(text(parameterized_benchmark_query), connection)
                    # 5. Execute Full Ranking Query
                    df_sql_results = pd.read_sql(text(parameterized_full_query), connection)

                # 6. Store all results in session state
                st.session_state.sql_results = df_sql_results
                st.session_state.benchmark_profile = df_benchmark.iloc[0] # Store the 1-row profile
                
                # --- ADD 'purpose' TO SESSION STATE ---
                st.session_state.inputs = {
                    'role': role_name_input, 
                    'level': job_level_input, 
                    'purpose': role_purpose_input, # <-- ADDED
                    'benchmarks': selected_benchmark_ids
                }
                
                st.success("Analysis complete! Results below. 👇")
        
        except Exception as e:
            st.error(f"Database query failed: {e}")
            if 'sql_results' in st.session_state: del st.session_state.sql_results
            if 'benchmark_profile' in st.session_state: del st.session_state.benchmark_profile

# --- DISPLAY RESULTS ---
if 'sql_results' in st.session_state:
    # Retrieve all data from session state
    df = st.session_state.sql_results
    inputs = st.session_state.inputs
    benchmark_profile = st.session_state.benchmark_profile
    
    employee_list_df = get_employee_list() 

    try:
        # --- Display AI Generated Job Profile ---
        st.write("---") 
        st.subheader("🤖 Data-Driven Job Profile") 
        
        # --- PASS 'purpose' TO THE AI FUNCTION ---
        ai_profile = generate_job_profile(
            inputs['role'], 
            inputs['level'], 
            inputs['purpose'], # <-- ADDED
            benchmark_profile
        )
        st.markdown(ai_profile)

        # --- Display Ranked Talent List ---
        st.write("---") 
        st.subheader("📊 Ranked Talent List")

        # --- Calculate Top TGV (Domain) for each employee ---
        df_top_tgv = pd.DataFrame() 
        if not df.empty and 'tgv_match_rate' in df.columns and 'tgv_name' in df.columns and 'employee_id' in df.columns:
            df_unique_tgv = df[['employee_id', 'tgv_name', 'tgv_match_rate']].drop_duplicates()
            idx = df_unique_tgv.loc[df_unique_tgv.groupby('employee_id')['tgv_match_rate'].idxmax()]
            df_top_tgv = idx[['employee_id', 'tgv_name']].copy()
            df_top_tgv.rename(columns={'tgv_name': 'top_tgv'}, inplace=True)
        else:
            st.warning("Could not calculate Top TGV due to missing data in SQL results.")
            df_top_tgv = pd.DataFrame(columns=['employee_id', 'top_tgv'])
        # ----------------------------------------------------

        # Create the base ranked DataFrame
        df_ranked = df[['employee_id', 'role', 'grade', 'directorate', 'final_match_rate', 'is_benchmark']].drop_duplicates('employee_id').copy()
        
        # Merge with the full employee list to get 'fullname'
        df_ranked = pd.merge(df_ranked, employee_list_df[['employee_id', 'fullname']], on='employee_id', how='left')

        # --- Merge the calculated Top TGV information ---
        if not df_top_tgv.empty:
            df_ranked = pd.merge(df_ranked, df_top_tgv, on='employee_id', how='left')
            df_ranked['top_tgv'] = df_ranked['top_tgv'].fillna('N/A')
        else:
            df_ranked['top_tgv'] = 'N/A'
        # -------------------------------------------------

        # Filter out benchmarks for the final ranked list
        df_ranked_candidates = df_ranked[df_ranked['is_benchmark'] == False].copy()
        df_ranked_candidates = df_ranked_candidates.sort_values('final_match_rate', ascending=False).reset_index(drop=True)
        df_ranked_candidates.insert(0, 'Rank', range(1, len(df_ranked_candidates) + 1))

        # Display the ranked list
        st.dataframe(
            df_ranked_candidates[['Rank', 'employee_id', 'fullname', 'role', 'grade', 'directorate', 'top_tgv', 'final_match_rate']],
            column_config={
                "final_match_rate": st.column_config.ProgressColumn(
                    "Match Rate",
                    format="%.1f%%", 
                    min_value=0,
                    max_value=100
                ),
                "top_tgv": st.column_config.TextColumn("TOP TGV")
            },
            hide_index=True, 
            use_container_width=True # As requested
        )

        # --- Dashboard Visualizations ---
        st.write("---") 
        st.subheader("📈 Dashboard Visualizations")
        col1, col2 = st.columns(2)

        # Histogram of Final Match Rates
        with col1:
            st.markdown("**Final Match Rate Distribution (Candidates)**")
            if not df_ranked_candidates.empty:
                fig_hist = px.histogram(df_ranked_candidates, x="final_match_rate", nbins=20,
                                        labels={'final_match_rate': 'Final Match Rate (%)'})
                fig_hist.update_layout(yaxis_title="Number of Candidates", bargap=0.1, xaxis_range=[0,100])
                st.plotly_chart(fig_hist, use_container_width=True) # As requested
            else:
                st.warning("No candidate data available for histogram.")

        # Bar Chart of Average TGV Match Rate
        with col2:
            st.markdown("**Average Match Rate per TGV (All Employees)**")
            if not df.empty and 'tgv_match_rate' in df.columns:
                df_tgv_unique = df[['employee_id', 'tgv_name', 'tgv_match_rate']].drop_duplicates()
                avg_tgv = df_tgv_unique.groupby('tgv_name')['tgv_match_rate'].mean().reset_index()
                avg_tgv = avg_tgv.sort_values('tgv_match_rate', ascending=True)  
                fig_tgv = px.bar(avg_tgv, x='tgv_match_rate', y='tgv_name', orientation='h',
                               text_auto='.1f', 
                               labels={'tgv_match_rate': 'Average Match Rate (%)', 'tgv_name': 'Talent Group Variable'})
                fig_tgv.update_layout(xaxis_range=[0,100]) 
                st.plotly_chart(fig_tgv, use_container_width=True) # As requested
            else:
                st.warning("No TGV data available for bar chart.")

        # --- Benchmark vs. Candidate Comparison ---
        st.write("---") 
        st.subheader("🔍 Benchmark vs. Candidate Comparison")

        if not df_ranked_candidates.empty:
            # Create candidate selection dropdown
            candidate_options = df_ranked_candidates['employee_id'] + " - " + df_ranked_candidates['fullname']
            selected_candidate_display = st.selectbox("Select Candidate:", options=candidate_options)
            selected_candidate_id = selected_candidate_display.split(" - ")[0]

            # Filter data for the selected candidate and benchmarks
            benchmark_data = df[df['is_benchmark']]
            candidate_data = df[df['employee_id'] == selected_candidate_id]

            # Calculate average TGV scores for both groups
            bench_tgv_avg = benchmark_data[['employee_id', 'tgv_name', 'tgv_match_rate']].drop_duplicates().groupby('tgv_name')['tgv_match_rate'].mean()
            cand_tgv_avg = candidate_data[['employee_id', 'tgv_name', 'tgv_match_rate']].drop_duplicates().groupby('tgv_name')['tgv_match_rate'].mean()

            # Define the axes for the radar chart
            default_tgvs = [
                'Competency',
                'Psychometric (Cognitive)',
                'Psychometric (Personality)',
                'Behavioral (Strengths)',
                'Contextual (Background)',
            ]
            # Create the DataFrame for the radar chart
            radar_df = pd.DataFrame({'tgv_name': default_tgvs})
            radar_df['Benchmark Avg'] = radar_df['tgv_name'].map(bench_tgv_avg).fillna(0)
            radar_df['Candidate'] = radar_df['tgv_name'].map(cand_tgv_avg).fillna(0)

            # Create the Radar Chart
            fig_radar = go.Figure()
            fig_radar.add_trace(go.Scatterpolar(
                r=radar_df['Benchmark Avg'],      
                theta=radar_df['tgv_name'],      
                fill='toself',                  
                name='Benchmark Average',        
                line_color='lightcoral'         
            ))
            fig_radar.add_trace(go.Scatterpolar(
                r=radar_df['Candidate'],        
                theta=radar_df['tgv_name'],      
                fill='toself',                  
                name=f'Candidate ({selected_candidate_id})', 
                line_color='skyblue'            
            ))
            fig_radar.update_layout(
                polar=dict(radialaxis=dict(visible=True, range=[0, 100])), 
                showlegend=True, 
                title=f"TGV Comparison: Benchmark Average vs {selected_candidate_id}" 
            )
            st.plotly_chart(fig_radar, use_container_width=True) # As requested

            # --- Display Summary Insights ---
            st.markdown("**Summary Insights:**")
            diffs = radar_df['Candidate'] - radar_df['Benchmark Avg']
            if diffs.notna().any():
                idx_max_diff = diffs.idxmax()
                idx_min_diff = diffs.idxmin()
                # Strongest Area
                st.success(
                    f"**Candidate's Strongest Area (vs Benchmark):** {radar_df.loc[idx_max_diff, 'tgv_name']} "
                    f"({radar_df.loc[idx_max_diff, 'Candidate']:.1f}% vs {radar_df.loc[idx_max_diff, 'Benchmark Avg']:.1f}%)"
                )
                # Largest Gap
                st.warning(
                    f"**Candidate's Largest Gap (vs Benchmark):** {radar_df.loc[idx_min_diff, 'tgv_name']} "
                    f"({radar_df.loc[idx_min_diff, 'Candidate']:.1f}% vs {radar_df.loc[idx_min_diff, 'Benchmark Avg']:.1f}%)"
                )
            else:
                st.info("Could not determine detailed comparison insights.")

        else:
            st.info("No candidates found matching the criteria for comparison after excluding benchmarks.")

    except Exception as e:
        st.error(f"An error occurred while processing and displaying results: {e}") 
        st.exception(e) # Print the full traceback for debugging