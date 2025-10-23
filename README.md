# Talent Match Intelligence System 🧠✨

This repository contains the code for the **"Talent Match Intelligence System,"** an end-to-end analytical web application built to transform the internal talent sourcing process.

This application shifts from subjective recruiting to data-driven matching. It dynamically ranks all employees against an "ideal" profile generated in real-time from 1-3 manager-selected benchmark employees. At its core is a weighted **"Success Formula"** derived from Exploratory Data Analysis (EDA) to prioritize candidates based on proven drivers of success (like `Competency`) and de-prioritize statistically insignificant factors (like `Cognitive Scores`).

##  Key Features

* **🤖 AI-Powered Job Profiles:** Integrates with OpenRouter (using Llama 3) to dynamically generate Job Descriptions, Requirements, and Key Competencies from a simple 'Role Purpose' input.
* **⚡ Dynamic Benchmarking:** Ranks *all* employees against an "ideal" profile built in real-time from 1-3 user-selected benchmark employees.
* **📊 Weighted 'Success Formula':** Utilizes a sophisticated 300+ line SQL query to score candidates based on an EDA-validated weighted formula (e.g., Competency: 67.5%, Contextual: 17.5%).
* **📈 Ranked Talent List:** Displays a clear, sortable list of top talent, showing their `final_match_rate` and their "Top TGV" (strongest area).
* **🔍 Candidate Drill-Down:** Allows managers to select any candidate and visualize their TGV profile (Competency, Contextual, etc.) on a radar chart against the benchmark average.
* **💡 Actionable Gap Analysis:** Automatically highlights a candidate's "Strongest Area" and "Largest Gap" to provide a clear starting point for development conversations.

##  Tech Stack

* **Frontend:** Streamlit
* **Backend & Analysis:** Python
* **Database:** PostgreSQL via Supabase
* **DB Connection:** SQLAlchemy
* **Visualization:** Plotly, Plotly Express, Matplotlib, Seaborn
* **AI (LLM):** OpenRouter (API), OpenAI Library
* **Environment Management:** `python-dotenv`


## 📁 Repository Structure

```bash
├── 1_analysis/
│   └── data_exploration.ipynb # Jupyter Notebook for initial data exploration and analysis
├── 2_sql_logic/
│   └── talent_matching_query.sql # Main 300+ line SQL “Engine” for talent matching logic
├── 3_app/
│   └── app.py # Streamlit web app for user interaction and result visualization    
├── README.md # Project documentation
├── .env.example # Template for environment variables
├── requirements.txt # List of required Python libraries
└── .gitignore # Ignores secret and unnecessary files (e.g., .env)
```


## ⚙️ Setup & Installation

### 1. Prerequisites
* Python 
* VSCode with the Jupyter Notebook extension (recommended for running the `.ipynb` file)
* PostgreSQL (a running database server, e.g., Supabase)
* An OpenRouter Account (to get an API Key)

### 2. Installation Instructions

1.  **Clone this repository:**
    ```bash
    git clone [https://github.com/fbudimannn/talent-intelligence-system.git](https://github.com/fbudimannn/talent-intelligence-system.git)
    cd talent-intelligence-system
    ```

2.  **Create and activate a virtual environment:**
    *(This uses the name `.talentint` as seen in the project)*
    ```bash
    # For MacOS/Linux
    python3 -m venv .talentint
    source .talentint/bin/activate
    
    # For Windows
    python -m venv .talentint
    .\.talentint\Scripts\activate
    ```

3.  **Install Libraries & Link Kernel:**
    ```bash
    # Install all required libraries
    pip install -r requirements.txt
    
    # Link this new environment to Jupyter/VSCode
    # This allows you to select ".talentint" as the kernel in your notebook
    python -m ipykernel install --user --name=.talentint --display-name "Python (.talentint)"
    ```

4.  **Database Setup:**
    This project requires your PostgreSQL server to be running and populated with the data (schema and data are not included in this repo).

5.  **Set Up Environment Variables:**
    Copy the `.env.example` template to create your secret `.env` file.
    ```bash
    cp .env.example .env
    ```
    Open the new `.env` file and fill in your credentials:
    ```
    # Example for a local database or cloud DB
    DB_HOST=
    DB_PORT=
    DB_NAME=
    DB_USER=
    DB_PASSWORD=
    OPENROUTER_API_KEY=
    ```

6.  **Run the Streamlit App:**
    ```bash
    python -m streamlit run 3_app/app.py
    ```

7.  Open `http://localhost:8501` in your browser.



## 🚀 How to Use the App

1.  In the left sidebar, fill in the **Vacancy Details** (Role Name, Job Level, Role Purpose).
2.  From the **"Select up to 3 benchmark employees"** dropdown, pick 1-3 employees who represent your "ideal" profile.
3.  Click the **"✨ Generate Profile & Matches"** button.
4.  Wait a moment for the SQL query and AI call to complete. ** Please click Generate again within the app if there are some errors when click it for the first time**
5.  Analyze the results:
    * Review the AI-generated **Job Profile**.
    * Examine the **Ranked Talent List** to see the top fits.
    * View the **Dashboard Visualizations** for a macro overview of the talent pool.
    * In the **"Benchmark vs. Candidate Comparison"** section, select a candidate to see their drill-down radar chart and gap analysis.

## 📸 Application Screenshots

*(As requested for the review process, here are screenshots of the running application)*

| Main View (Ranking & Aggregates) | Drill-Down View (Gap Analysis) | AI Job Profile View |
| :---: | :---: | :---: |
| ![Main Dashboard View](https://github.com/user-attachments/assets/e53f6853-e7c8-439a-a518-826a2d18be8e) | ![Candidate Drill-Down View](https://github.com/user-attachments/assets/ec68d3af-8c1a-46b4-9084-ced3f28f80aa) | ![AI Job Profile View](https://github.com/user-attachments/assets/698f748b-2c6c-4e71-a1f7-99dd02666063) |

##  Core Logic: The SQL "Engine"

The heart of this project is `talent_matching_query.sql`. It is not a simple query, but a 6-phase algorithm that runs as a single script:

* **Phase 1: Data Cleaning & Imputation:** Cleans dirty data (e.g., 'inftj', 'nan') and imputes missing values (e.g., `Competency`, `IQ`, `PAPI`) using group-specific medians/modes.
* **Phase 2: Dynamic Benchmark Generation:** Dynamically calculates the "ideal" profile using `MEDIAN` (for numerics) and `MODE` (for categoricals) from the user-selected benchmark employees.
* **Phase 3: Unpivot All Employees:** Transforms the "wide" data for all employees into a "long" format (`employee_id`, `tv_name`, `user_score`) using `UNION ALL`.
* **Phase 4: Scoring:** Compares every employee against the benchmark and creates a `match_score` (0-100) for *every single variable*.
* **Phase 5: Weighting (Success Formula):** Multiplies each variable's `match_score` by its predetermined weight from the "Success Formula".
* **Phase 6: Aggregation & Ranking:** Sums all weighted scores to produce the `final_match_rate` and presents it in a visualization-ready format.