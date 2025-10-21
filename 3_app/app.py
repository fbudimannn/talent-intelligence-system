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

# --- PAGE CONFIGURATION ---
# Set page layout to wide and define the title shown in the browser tab
st.set_page_config(layout="wide", page_title="Talent Match App")

# --- DATABASE CONNECTION ---
# Cache the database engine resource to avoid reconnecting on every script rerun
@st.cache_resource
def get_db_engine():
    """Establishes a connection pool to the PostgreSQL database using credentials from .env."""
    # Construct the path to the .env file (assuming it's one directory up)
    dotenv_path = os.path.join(os.path.dirname(__file__), '..', '.env')
    load_dotenv(dotenv_path=dotenv_path) # Load environment variables

    # Retrieve database connection details from environment variables
    db_host = os.getenv('DB_HOST')
    db_port = os.getenv('DB_PORT')
    db_name = os.getenv('DB_NAME')
    db_user = os.getenv('DB_USER')
    db_password = os.getenv('DB_PASSWORD')

    # Create the database connection string
    connection_string = f"postgresql://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}"
    # Return a SQLAlchemy engine object
    return create_engine(connection_string)

# Initialize the database engine
engine = get_db_engine()

# --- LOAD BASE SQL QUERY ---
# Cache the base SQL query data to avoid rereading the file on every script rerun
@st.cache_data
def load_base_query():
    """Loads the main talent matching SQL query from an external file."""
    # Construct the path to the SQL query file
    sql_file_path = os.path.join(os.path.dirname(__file__), '..', '2_sql_logic', 'talent_matching_query.sql')
    # Read the content of the SQL file
    with open(sql_file_path, 'r') as file:
        return file.read()

# Store the loaded base SQL query
base_sql_query = load_base_query()

# --- FETCH EMPLOYEE LIST ---
# Cache the employee list data
@st.cache_data
def get_employee_list():
    """Fetches employee IDs and full names from the database for selection widgets."""
    with engine.connect() as connection:
        # Query the employees table
        df = pd.read_sql("SELECT employee_id, fullname FROM employees ORDER BY fullname;", connection)
    # Create a display column combining name and ID for user-friendliness in widgets
    df['display'] = df['fullname'] + " (" + df['employee_id'] + ")"
    return df

# --- GENERATE AI JOB PROFILE ---
# Cache the generated job profile based on inputs
@st.cache_data
def generate_job_profile(role_name, job_level, role_purpose):
    """Generates a job profile using an AI model via OpenRouter API."""
    # Retrieve the API key from environment variables
    api_key = os.getenv("OPENROUTER_API_KEY")
    if not api_key:
        return "Error: Missing OpenRouter API key. Please set it in your .env file."

    # Define the prompt for the AI model
    prompt = f"""
    Generate a concise job profile for the following role:
    Role: {role_name}
    Level: {job_level}
    Purpose: {role_purpose}

    Structure the output using markdown with these sections:
    ## Job Requirements
    - Provide 5 to 7 key requirements as bullet points.
    ## Job Description
    - Write a brief paragraph summarizing the role's responsibilities.
    ## Key Competencies
    - List 5 essential competencies as bullet points.
    """
    try:
        # Initialize the OpenAI client configured for OpenRouter
        client = openai.OpenAI(base_url="https://openrouter.ai/api/v1", api_key=api_key)
        # Make the API call to generate the job profile
        response = client.chat.completions.create(
            model="meta-llama/llama-3.3-8b-instruct:free", # Using a capable free model
            messages=[
                {"role": "system", "content": "You are an expert HR assistant specializing in job profile creation."},
                {"role": "user", "content": prompt}
            ],
            max_tokens=400, # Limit the response length
            temperature=0.6 # Control the creativity of the response
        )
        # Extract and return the generated text
        return response.choices[0].message.content.strip()
    except Exception as e:
        # Handle potential API errors gracefully
        st.error(f"Error generating AI profile: {e}")
        return "Failed to generate AI profile."

# --- MAIN STREAMLIT UI ---
st.title("Talent Match Intelligence System 🧠✨")
st.markdown("Use the sidebar to input vacancy details and select benchmark employees to generate ranked matches.")

# --- SIDEBAR FOR INPUTS ---
with st.sidebar:
    st.header("Vacancy & Benchmark Settings")
    # Input fields for vacancy details
    role_name_input = st.text_input("Role Name", "Data Analyst") # Default role name
    job_level_input = st.selectbox("Job Level", ["Staff", "Supervisor", "Manager", "Senior Manager"], index=1) # Default to Supervisor
    role_purpose_input = st.text_area("Role Purpose", "Analyze complex datasets to extract meaningful insights and support data-driven decision-making across the organization.", height=100)

    # Fetch employee list for the multiselect widget
    employee_list_df = get_employee_list()
    # Multiselect widget for choosing benchmark employees
    selected_benchmarks = st.multiselect(
        "Select up to 3 benchmark employees:",
        options=employee_list_df['display'], # Show "Fullname (ID)"
        max_selections=3,
        # Set default selections based on predefined IDs
        default=[emp['display'] for _, emp in employee_list_df.iterrows() if emp['employee_id'] in ['EMP100012', 'EMP100524', 'EMP100548']][:3]
    )
    # Extract only the employee IDs from the selected display strings
    selected_benchmark_ids = [display_str.split('(')[-1].replace(')', '') for display_str in selected_benchmarks]

    # Button to trigger the query execution and profile generation
    generate_button = st.button("✨ Generate Profile & Matches")

# --- EXECUTE SQL QUERY ---
# This block runs only when the 'Generate' button is clicked
if generate_button:
    # Check if benchmark employees are selected
    if not selected_benchmark_ids:
        st.sidebar.error("Please select at least one benchmark employee.")
    else:
        # Format the selected employee IDs into a PostgreSQL array string for the SQL query
        sql_array_string = "ARRAY[" + ",".join([f"'{eid}'" for eid in selected_benchmark_ids]) + "]::text[]"
        # Replace the placeholder array in the base SQL query with the selected IDs
        parameterized_query = base_sql_query.replace("ARRAY['EMP100012','EMP100524','EMP100548']::text[]", sql_array_string)

        # Show a spinner while the query is running
        with st.spinner("Analyzing talent data... ⏳"):
            try:
                # Execute the parameterized SQL query
                with engine.connect() as connection:
                    df_sql_results = pd.read_sql(text(parameterized_query), connection)
                # Store the results and inputs in Streamlit's session state
                st.session_state.sql_results = df_sql_results
                st.session_state.inputs = {'role': role_name_input, 'level': job_level_input, 'purpose': role_purpose_input, 'benchmarks': selected_benchmark_ids}
                st.success("Analysis complete! Results below. 👇")
            except Exception as e:
                # Display database errors clearly
                st.error(f"Database query failed: {e}")
                # Clear potentially stale results if query fails
                if 'sql_results' in st.session_state: del st.session_state.sql_results

# --- DISPLAY RESULTS ---
# This block runs if results are available in the session state
if 'sql_results' in st.session_state:
    # Retrieve the DataFrame and inputs from session state
    df = st.session_state.sql_results
    inputs = st.session_state.inputs
    # Ensure employee_list_df is available (it should be due to caching)
    employee_list_df = get_employee_list()

    # Wrap the main result processing in a try-except block for robustness
    try:
        # --- Display AI Generated Job Profile ---
        st.write("---") # Visual separator
        st.subheader("🤖 Job Profile")
        # Generate and display the profile (uses cached result if inputs haven't changed)
        ai_profile = generate_job_profile(inputs['role'], inputs['level'], inputs['purpose'])
        st.markdown(ai_profile)

        # --- Display Ranked Talent List ---
        st.write("---") # Visual separator
        st.subheader("📊 Ranked Talent List")

        # --- Calculate Top TGV (Domain) for each employee ---
        df_top_tgv = pd.DataFrame() # Initialize an empty DataFrame
        # Check if necessary columns exist in the SQL output
        if not df.empty and 'tgv_match_rate' in df.columns and 'tgv_name' in df.columns and 'employee_id' in df.columns:
            # First, get the unique TGV rate per employee/TGV combination, as TGV rate repeats for each TV row
            df_unique_tgv = df[['employee_id', 'tgv_name', 'tgv_match_rate']].drop_duplicates()
            # Then, find the index of the row with the maximum tgv_match_rate for each employee_id
            # Note: idxmax() finds the *first* occurrence in case of ties
            idx = df_unique_tgv.loc[df_unique_tgv.groupby('employee_id')['tgv_match_rate'].idxmax()]
            # Select only employee_id and the corresponding tgv_name (the top TGV)
            df_top_tgv = idx[['employee_id', 'tgv_name']].copy()
            # Rename the 'tgv_name' column to 'top_tgv' for clarity before merging
            df_top_tgv.rename(columns={'tgv_name': 'top_tgv'}, inplace=True)
        else:
            # If data is missing, create an empty DataFrame with the expected columns
            st.warning("Could not calculate Top TGV due to missing data in SQL results.")
            df_top_tgv = pd.DataFrame(columns=['employee_id', 'top_tgv'])
        # ----------------------------------------------------

        # Create the base ranked DataFrame (one row per employee)
        # Select necessary columns and remove duplicate employee rows
        df_ranked = df[['employee_id', 'role', 'grade', 'directorate', 'final_match_rate', 'is_benchmark']].drop_duplicates('employee_id').copy()

        # Merge with the employee list DataFrame to add the 'fullname' column
        df_ranked = pd.merge(df_ranked, employee_list_df[['employee_id', 'fullname']], on='employee_id', how='left')

        # --- Merge the calculated Top TGV information ---
        if not df_top_tgv.empty:
            df_ranked = pd.merge(df_ranked, df_top_tgv, on='employee_id', how='left')
            # Fill any potential missing values with 'N/A' (e.g., if an employee had no TGV scores)
            df_ranked['top_tgv'] = df_ranked['top_tgv'].fillna('N/A')
        else:
            # If df_top_tgv couldn't be calculated, add an 'N/A' column to df_ranked
             df_ranked['top_tgv'] = 'N/A'
        # -------------------------------------------------

        # Filter out benchmark employees for the final ranked list display
        df_ranked_candidates = df_ranked[df_ranked['is_benchmark'] == False].copy()

        # Sort candidates by final match rate in descending order
        df_ranked_candidates = df_ranked_candidates.sort_values('final_match_rate', ascending=False).reset_index(drop=True)

        # Add a 'Rank' column based on the sorted order
        df_ranked_candidates.insert(0, 'Rank', range(1, len(df_ranked_candidates) + 1))

        # Display the ranked list using Streamlit's DataFrame component
        st.dataframe(
            # Select and order columns for display, including the new 'top_tgv'
            df_ranked_candidates[['Rank', 'employee_id', 'fullname', 'role', 'grade', 'directorate', 'top_tgv', 'final_match_rate']],
            column_config={
                # Configure the 'final_match_rate' column as a progress bar
                "final_match_rate": st.column_config.ProgressColumn(
                    "Match Rate",
                    format="%.1f%%", # Format as percentage with one decimal place
                    min_value=0,
                    max_value=100
                ),
                # Configure the new 'top_tgv' column with the desired title
                "top_tgv": st.column_config.TextColumn("TOP TGV")
            },
            hide_index=True, # Don't show the default DataFrame index
            use_container_width=True # Make the table expand to the container width
        )

        # --- Dashboard Visualizations ---
        st.write("---") # Visual separator
        st.subheader("📈 Dashboard Visualizations")
        # Create two columns for side-by-side charts
        col1, col2 = st.columns(2)

        # Histogram of Final Match Rates for Candidates
        with col1:
            st.markdown("**Final Match Rate Distribution (Candidates)**")
            if not df_ranked_candidates.empty:
                fig_hist = px.histogram(df_ranked_candidates, x="final_match_rate", nbins=20,
                                        labels={'final_match_rate': 'Final Match Rate (%)'})
                fig_hist.update_layout(yaxis_title="Number of Candidates", bargap=0.1, xaxis_range=[0,100])
                st.plotly_chart(fig_hist, use_container_width=True)
            else:
                st.warning("No candidate data available for histogram.")

        # Bar Chart of Average TGV Match Rate (across ALL employees in the initial SQL result)
        with col2:
            st.markdown("**Average Match Rate per TGV (All Employees)**")
            if not df.empty and 'tgv_match_rate' in df.columns:
                # Drop duplicates first because tgv_match_rate is repeated for each TV within a TGV per employee
                df_tgv_unique = df[['employee_id', 'tgv_name', 'tgv_match_rate']].drop_duplicates()
                # Calculate the average match rate for each TGV
                avg_tgv = df_tgv_unique.groupby('tgv_name')['tgv_match_rate'].mean().reset_index()
                #Sort values
                avg_tgv = avg_tgv.sort_values('tgv_match_rate', ascending=True) 
                # Create the horizontal bar chart
                fig_tgv = px.bar(avg_tgv, x='tgv_match_rate', y='tgv_name', orientation='h',
                                 text_auto='.1f', # Display values on bars
                                 labels={'tgv_match_rate': 'Average Match Rate (%)', 'tgv_name': 'Talent Group Variable'})
                fig_tgv.update_layout(xaxis_range=[0,100]) # Ensure x-axis goes up to 100
                st.plotly_chart(fig_tgv, use_container_width=True)
            else:
                st.warning("No TGV data available for bar chart.")

        # --- Benchmark vs. Candidate Comparison ---
        st.write("---") # Visual separator
        st.subheader("🔍 Benchmark vs. Candidate Comparison")

        # Check if there are candidates to select from for comparison
        if not df_ranked_candidates.empty:
            # Create options for the candidate selection dropdown (ID - Fullname)
            candidate_options = df_ranked_candidates['employee_id'] + " - " + df_ranked_candidates['fullname']
            # Selectbox widget to choose a candidate
            selected_candidate_display = st.selectbox("Select Candidate:", options=candidate_options)
            # Extract the employee ID from the selected display string
            selected_candidate_id = selected_candidate_display.split(" - ")[0]

            # Filter the main DataFrame 'df' for benchmark employees and the selected candidate
            benchmark_data = df[df['is_benchmark']]
            candidate_data = df[df['employee_id'] == selected_candidate_id]

            # Calculate the average TGV match rate for benchmarks and the selected candidate
            # Important: Drop duplicates first as TGV rate is repeated per TV row within the same TGV/employee
            bench_tgv_avg = benchmark_data[['employee_id', 'tgv_name', 'tgv_match_rate']].drop_duplicates().groupby('tgv_name')['tgv_match_rate'].mean()
            cand_tgv_avg = candidate_data[['employee_id', 'tgv_name', 'tgv_match_rate']].drop_duplicates().groupby('tgv_name')['tgv_match_rate'].mean()

            # --- Ensure all standard TGVs are present for the radar chart axes ---
            default_tgvs = [
                'Competency',
                'Psychometric (Cognitive)',
                'Psychometric (Personality)',
                'Behavioral (Strengths)',
                'Contextual (Background)',
            ]
            # Create a base DataFrame with standard TGV names
            radar_df = pd.DataFrame({'tgv_name': default_tgvs})
            # Map the calculated average scores onto this base, filling missing TGVs with 0
            radar_df['Benchmark Avg'] = radar_df['tgv_name'].map(bench_tgv_avg).fillna(0)
            radar_df['Candidate'] = radar_df['tgv_name'].map(cand_tgv_avg).fillna(0)

            # --- Create Radar Chart using Plotly Graph Objects ---
            fig_radar = go.Figure()
            # Add trace for Benchmark Average scores
            fig_radar.add_trace(go.Scatterpolar(
                r=radar_df['Benchmark Avg'],      # Radial values (scores)
                theta=radar_df['tgv_name'],     # Angular values (TGV names)
                fill='toself',                  # Fill the area under the line
                name='Benchmark Average',       # Legend name
                line_color='lightcoral'         # Line color
            ))
            # Add trace for the Selected Candidate's scores
            fig_radar.add_trace(go.Scatterpolar(
                r=radar_df['Candidate'],        # Radial values (scores)
                theta=radar_df['tgv_name'],     # Angular values (TGV names)
                fill='toself',                  # Fill the area under the line
                name=f'Candidate ({selected_candidate_id})', # Legend name
                line_color='skyblue'            # Line color
            ))
            # Configure layout properties for the radar chart
            fig_radar.update_layout(
                polar=dict(radialaxis=dict(visible=True, range=[0, 100])), # Set radial axis range 0-100
                showlegend=True, # Display the legend
                title=f"TGV Comparison: Benchmark Average vs {selected_candidate_id}" # Chart title
            )
            # Display the radar chart in Streamlit
            st.plotly_chart(fig_radar, use_container_width=True)

            # --- Display Summary Insights: Strongest Area and Largest Gap ---
            st.markdown("**Summary Insights:**")
            # Calculate the difference between candidate and benchmark average scores for each TGV
            diffs = radar_df['Candidate'] - radar_df['Benchmark Avg']
            # Check if there are valid differences to analyze
            if diffs.notna().any():
                # Find the index (and thus TGV name) of the maximum difference (candidate's strength)
                idx_max_diff = diffs.idxmax()
                # Find the index (and thus TGV name) of the minimum difference (candidate's largest gap)
                idx_min_diff = diffs.idxmin()
                # Display the strongest TGV using st.success for positive emphasis
                st.success(
                    f"**Candidate's Strongest Area (vs Benchmark):** {radar_df.loc[idx_max_diff, 'tgv_name']} "
                    f"({radar_df.loc[idx_max_diff, 'Candidate']:.1f}% vs {radar_df.loc[idx_max_diff, 'Benchmark Avg']:.1f}%)"
                )
                # Display the largest gap using st.warning for cautionary emphasis
                st.warning(
                    f"**Candidate's Largest Gap (vs Benchmark):** {radar_df.loc[idx_min_diff, 'tgv_name']} "
                    f"({radar_df.loc[idx_min_diff, 'Candidate']:.1f}% vs {radar_df.loc[idx_min_diff, 'Benchmark Avg']:.1f}%)"
                )
            else:
                # Handle cases where differences couldn't be calculated (e.g., all NaNs)
                st.info("Could not determine detailed comparison insights.")

        else:
            # Handle case where there are no candidates (df_ranked_candidates is empty)
            st.info("No candidates found matching the criteria for comparison after excluding benchmarks.")

    # General error catching for the results display section
    except Exception as e:
        st.error(f"An error occurred while processing and displaying results: {e}") 
        st.exception(e) # Optionally print the full traceback for debugging

