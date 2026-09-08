import time
import pandas as pd
import requests
from sqlalchemy import create_engine, text

def extract_propublica_data(search_term):
    """Extracts organization and financial filing data from the ProPublica
    Nonprofit Explorer API based on a given search term.
    """
    orgs_data = []
    filings_data = []

    print(f"[INFO] Initiating API extraction for search term: '{search_term}'")
    search_url = f"https://projects.propublica.org/nonprofits/api/v2/search.json?q={search_term}"

    try:
        response = requests.get(search_url, timeout=15).json()
    except Exception as e:
        print(f"[ERROR] Failed to fetch search results for '{search_term}': {e}")
        return pd.DataFrame(), pd.DataFrame()

    organizations = response.get("organizations", [])

    for org in organizations:
        ein = str(org.get("ein"))
        org_name = org.get("name")

        if not ein.isdigit():
            continue

        # Collect organization baseline info using EIN as org_id
        orgs_data.append({
            "org_id": int(ein),
            "org_name": org_name,
            "headquarters_country": "US",
            "registration_number": int(ein),
        })

        print(f"[INFO] Fetching financial filings for EIN: {ein}")
        time.sleep(0.5)

        org_url = f"https://projects.propublica.org/nonprofits/api/v2/organizations/{ein}.json"
        try:
            org_res = requests.get(org_url, timeout=15).json()
            filings = org_res.get("filings_with_data", [])

            for filing in filings:
                tax_year = filing.get("tax_prd_yr")
                if not tax_year:
                    continue

                formatted_date = f"{tax_year}-01-01"

                # Collect annual financial metrics per organization
                filings_data.append({
                    "org_id": int(ein),
                    "filing_id": f"{ein}_{tax_year}",
                    "tax_year": formatted_date,
                    "total_revenue": int(filing.get("totrevenue", 0) or 0),
                    "total_functional_expenses": int(filing.get("totfuncexpns", 0) or 0),
                    "executive_compensation": int(filing.get("compnsatncurrofcr", 0) or 0),
                })
        except Exception as e:
            print(f"[WARN] Failed to fetch or parse filings for EIN {ein}: {e}")

    df_orgs = pd.DataFrame(orgs_data).drop_duplicates(subset=["org_id"]) if orgs_data else pd.DataFrame()
    df_filings = pd.DataFrame(filings_data).drop_duplicates(subset=["filing_id"]) if filings_data else pd.DataFrame()

    return df_orgs, df_filings

def load_to_database(df_orgs, df_filings, connection):
    """Loads extracted organizations and financial filings into PostgreSQL,
    ignoring duplicate primary keys using ON CONFLICT DO NOTHING.
    """
    if not df_orgs.empty:
        for _, row in df_orgs.iterrows():
            # Insert organization safely using EIN as org_id, skipping duplicates
            insert_org_query = text("""
                INSERT INTO organizations (org_id, org_name, headquarters_country, registration_number)
                VALUES (:org_id, :org_name, :headquarters_country, :registration_number)
                ON CONFLICT (org_id) DO NOTHING;
            """)
            connection.execute(insert_org_query, row.to_dict())

    if not df_filings.empty:
        for _, row in df_filings.iterrows():
            # Insert financial filing safely, bypassing duplicate filing keys (same org and year)
            insert_filing_query = text("""
                INSERT INTO financial_filings (filing_id, org_id, tax_year, total_revenue, total_functional_expenses, executive_compensation)
                VALUES (:filing_id, :org_id, :tax_year, :total_revenue, :total_functional_expenses, :executive_compensation)
                ON CONFLICT (filing_id) DO NOTHING;
            """)
            connection.execute(insert_filing_query, row.to_dict())

    print("[INFO] Successfully processed and loaded records into database tables.")

if __name__ == "__main__":
    db_name = input("Enter PSQl Database Name: ")
    db_user = input("Enter username: ")
    db_host = input("Host: ")
    db_port = input("port: ")
    db_password = input("Password: ")
    DB_URI = f"postgresql://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}" 
    engine = create_engine(DB_URI)

    search_terms = [
        "relief", "humanitarian", "aid", "development", "charity", 
        "global", "international", "emergency", "disaster", "poverty", 
        "hunger", "health", "medical", "education", "water", 
        "sanitation", "shelter", "refugee", "children", "women", 
        "empowerment", "crisis", "response", "rescue", "action"
    ]

    for term in search_terms:
        with engine.connect() as conn:
            trans = conn.begin()
            try:
                df_orgs, df_filings = extract_propublica_data(term)

                if not df_orgs.empty or not df_filings.empty:
                    load_to_database(df_orgs, df_filings, conn)
                    trans.commit()
                    print(f"[SUCCESS] Transaction committed for search term: '{term}'\n")
                else:
                    print(f"[INFO] No data extracted for search term: '{term}'. Skipping.\n")
                    trans.rollback()

            except Exception as e:
                trans.rollback()
                print(f"[CRITICAL ERROR] Transaction rolled back for '{term}': {e}\n")
