# --- IMPORTS ---
import streamlit as st
import pandas as pd
import numpy as np
import os
from dotenv import load_dotenv
from sqlalchemy import create_engine, text
import openai
import plotly.express as px
import plotly.graph_objects as go

# --- PAGE CONFIG ---
# This sets the browser tab title and favicon, and configures the layout to be wide.
st.set_page_config(layout="wide", page_title="Talent Match App")

# --- LOAD ENVIRONMENT VARIABLES & CONNECT TO DB ---
# This section handles loading secret credentials and connecting to the database.
# It is designed to run once at the start of the app.
@st.cache_resource
def get_db_engine():
    """Loads environment variables and creates a SQLAlchemy engine. Cached to prevent re-creation on every rerun."""
    dotenv_path = os.path.join(os.path.dirname(__file__), '..', '.env')
    load_dotenv(dotenv_path=dotenv_path)

    db_host = os.getenv('DB_HOST')
    db_port = os.getenv('DB_PORT')
    db_name = os.getenv('DB_NAME')
    db_user = os.getenv('DB_USER')
    db_password = os.getenv('DB_PASSWORD')
    
    if not all([db_host, db_port, db_name, db_user, db_password]):
        st.error("❌ Database credentials are not fully set in the .env file.")
        st.stop()

    connection_string = f"postgresql://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}"
    try:
        engine = create_engine(connection_string)
        return engine
    except Exception as e:
        st.error(f"❌ Database Connection Failed: {e}")
        st.stop()

engine = get_db_engine()

# --- LOAD THE BASE SQL QUERY FROM FILE ---
# This loads the SQL template from the .sql file. Cached to avoid rereading the file on every interaction.
@st.cache_data
def load_base_query():
    """Loads the main SQL query template from its file."""
    sql_file_path = os.path.join(os.path.dirname(__file__), '..', '2_sql_logic', 'talent_matching_query.sql')
    try:
        with open(sql_file_path, 'r') as file:
            return file.read()
    except Exception as e:
        st.error(f"❌ Error loading SQL query file: {e}")
        st.stop()

base_sql_query = load_base_query()

# --- HELPER FUNCTIONS ---

@st.cache_data # Cache the employee list for performance
def get_employee_list():
    """Fetches the full employee list from the database for the benchmark selection dropdown."""
    try:
        with engine.connect() as connection:
            query = text("SELECT employee_id, fullname FROM employees ORDER BY fullname;")
            df_employees_list = pd.read_sql(query, connection)
            df_employees_list['display'] = df_employees_list['fullname'] + " (" + df_employees_list['employee_id'] + ")"
            return df_employees_list
    except Exception as e:
        st.error(f"Failed to load employee list: {e}")
        return pd.DataFrame({'employee_id': [], 'fullname': [], 'display': []})

@st.cache_data # Cache AI responses for the same inputs
def generate_job_profile(role_name, job_level, role_purpose):
    """Calls an OpenRouter LLM to generate job profile details based on user input."""
    openrouter_api_key = os.getenv('OPENROUTER_API_KEY')
    prompt = f"""
    Generate a concise job profile based on these details:
    Role Name: {role_name}
    Job Level: {job_level}
    Role Purpose: {role_purpose}

    Include the following sections clearly marked with markdown headings:
    1. ## Job Requirements
       (5-7 concise bullet points of essential skills, experience, or qualifications)
    2. ## Job Description
       (1 short paragraph, 3-4 sentences summarizing the role)
    3. ## Key Competencies
       (5 concise bullet points focusing on crucial skills or behaviors needed)
    """
    if not openrouter_api_key:
         return "Error: OpenRouter API Key not found. Please set it in the .env file."
    try:
        client = openai.OpenAI(
            base_url="https://openrouter.ai/api/v1",
            api_key=openrouter_api_key,
        )
        completion = client.chat.completions.create(
            model="meta-llama/llama-3.3-8b-instruct:free", # A reliable free model
            messages=[
                {"role": "system", "content": "You are an expert HR assistant specializing in creating clear, professional job profiles."},
                {"role": "user", "content": prompt}
            ],
            max_tokens=400, temperature=0.6
        )
        return completion.choices[0].message.content.strip()
    except Exception as e:
        return f"Error calling AI: {e}"

# --- MAIN APP LAYOUT ---
st.title("Talent Match Intelligence System 🧠✨")
st.markdown("Use the sidebar on the left to input vacancy details and select benchmark employees to generate a ranked list of candidates.")

# --- SIDEBAR FOR INPUTS ---
with st.sidebar:
    st.header("Vacancy Details & Benchmarking")
    role_name_input = st.sidebar.text_input("Role Name", "e.g., Data Analyst")
    job_level_input = st.sidebar.selectbox("Job Level", ["Staff", "Supervisor", "Manager", "Senior Manager"], index=1)
    role_purpose_input = st.sidebar.text_area("Role Purpose (1-2 sentences)", "e.g., Analyze sales data to identify growth opportunities...", height=100)
    
    st.subheader("Select Benchmarks")
    employee_list_df = get_employee_list()
    selected_benchmarks = st.sidebar.multiselect(
        "Select Benchmark Employees (max 3)",
        options=employee_list_df['display'],
        max_selections=3,
        default=[ emp['display'] for _, emp in employee_list_df.iterrows() if emp['employee_id'] in ['EMP100024', 'EMP100075', 'EMP100319'] ][:3]
    )
    selected_benchmark_ids = [ display_str.split('(')[-1].replace(')', '') for display_str in selected_benchmarks ]
    
    generate_button = st.sidebar.button("✨ Generate Profile & Matches")

# --- MAIN PANEL ---
st.header("Results")

# --- LOGIC WHEN GENERATE BUTTON IS CLICKED ---
if generate_button:
    # --- 3.3.1: Validate Input ---
    if not selected_benchmark_ids:
        st.warning("⚠️ Please select at least one benchmark employee.")
        st.stop()
    
    st.info(f"Processing request for Role: '{role_name_input}', Level: '{job_level_input}' with Benchmarks: {', '.join(selected_benchmark_ids)}")

    # --- 3.3.2: Parameterize SQL ---
    with st.spinner("🔄 Running SQL query to calculate match scores..."):
        try:
            sql_array_string = "ARRAY[" + ",".join([f"'{eid}'" for eid in selected_benchmark_ids]) + "]::text[]"
            placeholder_array = "ARRAY['EMP100024', 'EMP100075', 'EMP100319']::text[]" # MUST MATCH YOUR SQL FILE
            parameterized_query = base_sql_query.replace(placeholder_array, sql_array_string)
        except Exception as e:
            st.error(f"❌ Error parameterizing SQL query: {e}")
            st.stop()

        # --- 3.3.3: Execute SQL ---
        try:
            with engine.connect() as connection:
                df_sql_results = pd.read_sql(text(parameterized_query), connection)
            
            st.session_state.sql_results = df_sql_results
            st.session_state.inputs_processed = {'role': role_name_input, 'level': job_level_input, 'benchmarks': selected_benchmark_ids}
            st.success("✅ SQL Query executed successfully!")
        except Exception as e:
            st.error(f"❌ Error running SQL query: {e}")
            st.stop()

# --- DISPLAY RESULTS (IF THEY EXIST IN SESSION STATE) ---
if 'sql_results' in st.session_state and not st.session_state.sql_results.empty:
    df_sql_results_state = st.session_state.sql_results
    inputs_processed = st.session_state.inputs_processed
    benchmarks_used = inputs_processed['benchmarks']
    
    # --- 3.4: Display AI-Generated Job Profile ---
    st.write("---")
    with st.spinner("🤖 Calling AI to generate job profile..."):
         ai_profile_text = generate_job_profile(inputs_processed['role'], inputs_processed['level'], role_purpose_input)
    
    st.subheader("🤖 AI-Generated Job Profile")
    if "Error:" in ai_profile_text:
        st.error(ai_profile_text)
    else:
        st.markdown(ai_profile_text)
    st.write("---")

    # --- 3.5: Display Ranked Talent List ---
    st.subheader("📊 Ranked Talent List")
    try:
        df_ranked_list = df_sql_results_state[[
            'employee_id', 'role', 'grade', 'directorate', 'final_match_rate'
        ]].drop_duplicates(subset=['employee_id']).copy()

        df_ranked_list = pd.merge(df_ranked_list, employee_list_df[['employee_id', 'fullname']], on='employee_id', how='left')
        df_ranked_list = df_ranked_list.sort_values(by='final_match_rate', ascending=False).reset_index(drop=True)
        df_ranked_list.insert(0, 'Rank', range(1, len(df_ranked_list) + 1))
        
        # Reorder columns for display
        display_cols = ['Rank', 'employee_id', 'fullname', 'role', 'grade', 'directorate', 'final_match_rate']
        st.dataframe(
            df_ranked_list[display_cols],
            column_config={"final_match_rate": st.column_config.ProgressColumn("Match Rate",format="%.1f%%", min_value=0, max_value=100)},
            hide_index=True, use_container_width=True
         )
        st.session_state.ranked_list = df_ranked_list
    except Exception as e:
        st.error(f"Error processing ranked list: {e}")
    st.write("---")

    # --- 3.6 & 3.7: Dashboard Visualizations & Insights ---
    st.subheader("📈 Dashboard Visualizations")
    try:
        df_ranked_list_state = st.session_state.ranked_list
        col1, col2 = st.columns(2)

        with col1:
            st.markdown("**Final Match Rate Distribution**")
            fig_hist = px.histogram(df_ranked_list_state, x="final_match_rate", nbins=20, labels={'final_match_rate': 'Final Match Rate (%)'}, opacity=0.8)
            fig_hist.update_layout(yaxis_title="Number of Candidates", bargap=0.1)
            st.plotly_chart(fig_hist, use_container_width=True)

        with col2:
            st.markdown("**Average Match Rate per Talent Group (TGV)**")
            df_tgv_unique = df_sql_results_state[['employee_id', 'tgv_name', 'tgv_match_rate']].drop_duplicates()
            avg_tgv_rates = df_tgv_unique.groupby('tgv_name')['tgv_match_rate'].mean().reset_index().sort_values('tgv_match_rate')
            fig_tgv = px.bar(avg_tgv_rates, x='tgv_match_rate', y='tgv_name', orientation='h', labels={'tgv_match_rate': 'Avg. Match Rate (%)', 'tgv_name': ''}, text_auto='.1f')
            st.plotly_chart(fig_tgv, use_container_width=True)

        st.write("---")
        st.subheader("🔍 Benchmark vs. Candidate Comparison")
        candidate_options = df_ranked_list_state['employee_id'] + " - " + df_ranked_list_state['fullname']
        selected_candidate_display = st.selectbox("Select Candidate to Compare:", options=candidate_options, key='candidate_selector')
        selected_candidate_id = selected_candidate_display.split(" - ")[0] if selected_candidate_display else None

        if selected_candidate_id:
            candidate_data = df_sql_results_state[df_sql_results_state['employee_id'] == selected_candidate_id][['tgv_name', 'tgv_match_rate']].drop_duplicates().set_index('tgv_name')
            
            # Note: Benchmark scores are calculated from the detailed SQL output, not re-queried
            benchmark_data_detail = df_sql_results_state[df_sql_results_state['employee_id'].isin(benchmarks_used)]
            avg_benchmark_tgv = benchmark_data_detail.groupby('tgv_name')['tgv_match_rate'].mean()

            radar_df = pd.DataFrame({'Benchmark Avg': avg_benchmark_tgv, 'Candidate': candidate_data['tgv_match_rate']}).reset_index()

            fig_radar = go.Figure()
            fig_radar.add_trace(go.Scatterpolar(r=radar_df['Benchmark Avg'], theta=radar_df['tgv_name'], fill='toself', name='Benchmark Average', line_color='lightcoral'))
            fig_radar.add_trace(go.Scatterpolar(r=radar_df['Candidate'], theta=radar_df['tgv_name'], fill='toself', name=f'Candidate ({selected_candidate_id})', line_color='skyblue'))
            fig_radar.update_layout(polar=dict(radialaxis=dict(visible=True, range=[0, 100])), showlegend=True, title=f"TGV Comparison: Benchmark vs {selected_candidate_id}")
            st.plotly_chart(fig_radar, use_container_width=True)

            # Summary Insights
            st.markdown("**Summary Insights:**")
            radar_df['Difference (Candidate - Bench)'] = radar_df['Candidate'] - radar_df['Benchmark Avg']
            valid_diffs = radar_df['Difference (Candidate - Bench)'].notna()
            if valid_diffs.any():
                idx_max = radar_df.loc[valid_diffs, 'Difference (Candidate - Bench)'].idxmax()
                top_strength_tgv = radar_df.loc[idx_max]
                idx_min = radar_df.loc[valid_diffs, 'Difference (Candidate - Bench)'].idxmin()
                top_gap_tgv = radar_df.loc[idx_min]
                st.success(f"**Strongest Relative TGV:** **{top_strength_tgv['tgv_name']}** ({top_strength_tgv['Candidate']:.1f}% vs Benchmark {top_strength_tgv['Benchmark Avg']:.1f}%)")
                st.warning(f"**Largest Relative Gap:** **{top_gap_tgv['tgv_name']}** ({top_gap_tgv['Candidate']:.1f}% vs Benchmark {top_gap_tgv['Benchmark Avg']:.1f}%)")
            else:
                st.warning("Could not determine strongest/weakest TGV due to missing data.")

    except Exception as e:
        st.error(f"Error generating visualizations: {e}")
        import traceback
        st.text(traceback.format_exc())

# Initial message if the app has not been run yet
elif not generate_button and 'sql_results' not in st.session_state:
     st.info("ℹ️ Please fill in the details in the sidebar and click 'Generate Profile & Matches' to begin.")
