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
st.set_page_config(layout="wide", page_title="Talent Match App")

# --- DATABASE CONNECTION ---
@st.cache_resource
def get_db_engine():
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

# --- LOAD SQL QUERY ---
@st.cache_data
def load_base_query():
    sql_file_path = os.path.join(os.path.dirname(__file__), '..', '2_sql_logic', 'talent_matching_query.sql')
    with open(sql_file_path, 'r') as file:
        return file.read()

base_sql_query = load_base_query()

# --- EMPLOYEE LIST ---
@st.cache_data
def get_employee_list():
    with engine.connect() as connection:
        df = pd.read_sql("SELECT employee_id, fullname FROM employees ORDER BY fullname;", connection)
    df['display'] = df['fullname'] + " (" + df['employee_id'] + ")"
    return df

# --- AI JOB PROFILE ---
@st.cache_data
def generate_job_profile(role_name, job_level, role_purpose):
    api_key = os.getenv("OPENROUTER_API_KEY")
    if not api_key:
        return "Error: Missing OpenRouter API key."
    prompt = f"""
    Generate a concise job profile for:
    Role: {role_name}
    Level: {job_level}
    Purpose: {role_purpose}

    Format:
    ## Job Requirements
    - 5–7 bullet points
    ## Job Description
    (1 paragraph)
    ## Key Competencies
    - 5 bullet points
    """
    client = openai.OpenAI(base_url="https://openrouter.ai/api/v1", api_key=api_key)
    response = client.chat.completions.create(
        model="meta-llama/llama-3.3-8b-instruct:free",
        messages=[
            {"role": "system", "content": "You are an expert HR assistant."},
            {"role": "user", "content": prompt}
        ],
        max_tokens=400,
        temperature=0.6
    )
    return response.choices[0].message.content.strip()

# --- MAIN UI ---
st.title("Talent Match Intelligence System 🧠✨")
st.markdown("Use the sidebar to input vacancy details and select benchmark employees to generate ranked matches.")

with st.sidebar:
    st.header("Vacancy & Benchmark Settings")
    role_name_input = st.text_input("Role Name", "Data Analyst")
    job_level_input = st.selectbox("Job Level", ["Staff", "Supervisor", "Manager", "Senior Manager"], index=1)
    role_purpose_input = st.text_area("Role Purpose", "Analyze data to identify business opportunities...", height=100)

    employee_list_df = get_employee_list()
    selected_benchmarks = st.multiselect(
        "Select up to 3 benchmark employees:",
        options=employee_list_df['display'],
        max_selections=3,
        default=[emp['display'] for _, emp in employee_list_df.iterrows() if emp['employee_id'] in ['EMP100024', 'EMP100075', 'EMP100319']][:3]
    )
    selected_benchmark_ids = [d.split('(')[-1].replace(')', '') for d in selected_benchmarks]
    generate_button = st.button("✨ Generate Profile & Matches")

# --- EXECUTE SQL ---
if generate_button:
    sql_array_string = "ARRAY[" + ",".join([f"'{eid}'" for eid in selected_benchmark_ids]) + "]::text[]"
    parameterized_query = base_sql_query.replace("ARRAY['EMP100024', 'EMP100075', 'EMP100319']::text[]", sql_array_string)
    with st.spinner("Running SQL query..."):
        with engine.connect() as connection:
            df_sql_results = pd.read_sql(text(parameterized_query), connection)
    st.session_state.sql_results = df_sql_results
    st.session_state.inputs = {'role': role_name_input, 'level': job_level_input, 'benchmarks': selected_benchmark_ids}

# --- DISPLAY RESULTS ---
if 'sql_results' in st.session_state:
    df = st.session_state.sql_results
    inputs = st.session_state.inputs

    st.write("---")
    st.subheader("🤖 AI-Generated Job Profile")
    ai_profile = generate_job_profile(inputs['role'], inputs['level'], role_purpose_input)
    st.markdown(ai_profile)

    st.write("---")
    st.subheader("📊 Ranked Talent List")

    df_ranked = df[['employee_id', 'role', 'grade', 'directorate', 'final_match_rate', 'is_benchmark']].drop_duplicates('employee_id')
    df_ranked = pd.merge(df_ranked, employee_list_df[['employee_id', 'fullname']], on='employee_id', how='left')
    df_ranked = df_ranked[df_ranked['is_benchmark'] == False].copy()
    df_ranked = df_ranked.sort_values('final_match_rate', ascending=False).reset_index(drop=True)
    df_ranked.insert(0, 'Rank', range(1, len(df_ranked) + 1))
    st.caption("ℹ️ Benchmark employees are excluded from this ranked list.")
    st.dataframe(
        df_ranked[['Rank', 'employee_id', 'fullname', 'role', 'grade', 'directorate', 'final_match_rate']],
        column_config={
            "final_match_rate": st.column_config.ProgressColumn("Match Rate", format="%.1f%%", min_value=0, max_value=100)
        },
        hide_index=True, use_container_width=True
    )

    # --- ADD VISUALIZATIONS (back) ---
    st.write("---")
    st.subheader("📈 Dashboard Visualizations")
    col1, col2 = st.columns(2)

    with col1:
        st.markdown("**Final Match Rate Distribution**")
        fig_hist = px.histogram(df_ranked, x="final_match_rate", nbins=20, labels={'final_match_rate': 'Final Match Rate (%)'})
        fig_hist.update_layout(yaxis_title="Number of Candidates", bargap=0.1)
        st.plotly_chart(fig_hist, use_container_width=True)

    with col2:
        st.markdown("**Average Match Rate per TGV**")
        df_tgv = df[['employee_id', 'tgv_name', 'tgv_match_rate']].drop_duplicates()
        avg_tgv = df_tgv.groupby('tgv_name')['tgv_match_rate'].mean().reset_index()
        fig_tgv = px.bar(avg_tgv, x='tgv_match_rate', y='tgv_name', orientation='h', text_auto='.1f')
        st.plotly_chart(fig_tgv, use_container_width=True)

    # --- BENCHMARK COMPARISON ---
    st.write("---")
    st.subheader("🔍 Benchmark vs. Candidate Comparison")

    candidate_options = df_ranked['employee_id'] + " - " + df_ranked['fullname']
    selected_candidate_display = st.selectbox("Select Candidate:", options=candidate_options)
    selected_candidate_id = selected_candidate_display.split(" - ")[0]

    benchmark_data = df[df['is_benchmark']]
    candidate_data = df[df['employee_id'] == selected_candidate_id]
    bench_tgv = benchmark_data.groupby('tgv_name')['tgv_match_rate'].mean()
    cand_tgv = candidate_data.groupby('tgv_name')['tgv_match_rate'].mean()

    # --- Ensure all TGVs exist ---
    default_tgvs = [
        'Competency',
        'Psychometric (Cognitive)',
        'Psychometric (Personality)',
        'Behavioral (Strengths)',
        'Contextual (Background)',
    ]
    radar_df = pd.DataFrame({'tgv_name': default_tgvs})
    radar_df['Benchmark Avg'] = radar_df['tgv_name'].map(bench_tgv).fillna(0)
    radar_df['Candidate'] = radar_df['tgv_name'].map(cand_tgv).fillna(0)

    # --- Radar chart ---
    fig_radar = go.Figure()
    fig_radar.add_trace(go.Scatterpolar(r=radar_df['Benchmark Avg'], theta=radar_df['tgv_name'],
                                        fill='toself', name='Benchmark Average', line_color='lightcoral'))
    fig_radar.add_trace(go.Scatterpolar(r=radar_df['Candidate'], theta=radar_df['tgv_name'],
                                        fill='toself', name=f'Candidate ({selected_candidate_id})', line_color='skyblue'))
    fig_radar.update_layout(polar=dict(radialaxis=dict(visible=True, range=[0, 100])),
                            showlegend=True, title=f"TGV Comparison: Benchmark vs {selected_candidate_id}")
    st.plotly_chart(fig_radar, use_container_width=True)

    # --- Summary Insights ---
    st.markdown("**Summary Insights:**")
    diffs = radar_df['Candidate'] - radar_df['Benchmark Avg']
    if diffs.notna().any():
        idx_max = diffs.idxmax()
        idx_min = diffs.idxmin()
        st.success(f"**Strongest TGV:** {radar_df.loc[idx_max, 'tgv_name']} "
                   f"({radar_df.loc[idx_max, 'Candidate']:.1f}% vs {radar_df.loc[idx_max, 'Benchmark Avg']:.1f}%)")
        st.warning(f"**Largest Gap:** {radar_df.loc[idx_min, 'tgv_name']} "
                   f"({radar_df.loc[idx_min, 'Candidate']:.1f}% vs {radar_df.loc[idx_min, 'Benchmark Avg']:.1f}%)")
    else:
        st.warning("Could not determine strongest/weakest TGV.")
