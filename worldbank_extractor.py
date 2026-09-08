import time
import pandas as pd
import requests
from sqlalchemy import create_engine, text

def extract_world_bank_indicator(indicator_code, column_name, start_year=1995, end_year=2014):
    """
    Extracts historical indicator data from the World Bank API for all countries.
    Includes extended timeout and retry mechanism for unstable network responses.
    """
    print(f"[INFO] Initiating bulk extraction for indicator: {indicator_code} ({column_name})")
    
    records = []
    page = 1
    total_pages = 1
    
    while page <= total_pages:
        url = f"http://api.worldbank.org/v2/country/all/indicator/{indicator_code}?format=json&date={start_year}:{end_year}&per_page=1000&page={page}"
        
        retries = 3
        success = False
        
        while retries > 0 and not success:
            try:
                response = requests.get(url, timeout=30)
                response.raise_for_status()
                data = response.json()
                success = True
            except Exception as e:
                retries -= 1
                print(f"[WARN] Request failed for page {page} ({indicator_code}). Retries left: {retries}. Error: {e}")
   	        time.sleep(20)
        
        if not success:
            print(f"[ERROR] Failed permanently on page {page} for {indicator_code}.")
            break
            
        try:
            metadata = data[0]
            payload = data[1]
            total_pages = metadata.get('pages', 1)
            
            if payload:
                for item in payload:
                    country_code = item.get('countryiso3code')
                    year_val = item.get('date')
                    
                    if country_code and year_val:
                        records.append({
                            'country_code': country_code,
                            'record_year': f"{year_val}-01-01",
                            column_name: item.get('value')
                        })
            
            print(f"       -> Processed page {page} of {total_pages}")
            page += 1
            time.sleep(0.5) 
            
        except Exception as e:
            print(f"[ERROR] Failed to parse data on page {page} for {indicator_code}. Details: {e}")
            break
            
    df = pd.DataFrame(records)
    print(f"[SUCCESS] Extracted {len(df)} records for {column_name}.\n")
    return df

def merge_context_data(df_density, df_poverty, df_gdp):
    """
    Merges independent indicator DataFrames on spatial and temporal keys using outer joins.
    """
    print("[INFO] Merging independent indicator datasets on 'country_code' and 'record_year'...")
    
    df_merged = pd.merge(df_density, df_poverty, on=['country_code', 'record_year'], how='outer')
    df_merged = pd.merge(df_merged, df_gdp, on=['country_code', 'record_year'], how='outer')
    
    # Drop rows where all three critical context metrics are completely null
    df_merged.dropna(subset=['population_density', 'poverty_headcount_ratio', 'gdp_per_capita_usd'], how='all', inplace=True)
    
    print(f"[SUCCESS] Datasets merged successfully. Final baseline matrix dimensions: {df_merged.shape}\n")
    return df_merged

def load_to_database(df_final, connection):
    """
    Loads the transformed baseline matrix into the target relational schema safely,
    handling composite primary key conflicts (country_code, record_year) via ON CONFLICT.
    """
    print("[INFO] Staging dimensional data into 'country_context' table...")
    if not df_final.empty:
        # Convert pandas NaN values to Python None for proper SQL NULL insertion
        df_final = df_final.where(pd.notnull(df_final), None)
        
        insert_query = text("""
            INSERT INTO country_context (country_code, record_year, population_density, poverty_headcount_ratio, gdp_per_capita_usd)
            VALUES (:country_code, :record_year, :population_density, :poverty_headcount_ratio, :gdp_per_capita_usd)
            ON CONFLICT (country_code, record_year) 
            DO UPDATE SET 
                population_density = EXCLUDED.population_density,
                poverty_headcount_ratio = EXCLUDED.poverty_headcount_ratio,
                gdp_per_capita_usd = EXCLUDED.gdp_per_capita_usd;
        """)
        
        for _, row in df_final.iterrows():
            connection.execute(insert_query, row.to_dict())
            
        print(f"[SUCCESS] Ingested and synchronized {len(df_final)} rows into 'country_context'.")
    else:
        print("[WARN] DataFrame is empty. Pipeline load aborted.")

if __name__ == "__main__":
    db_name = input("Enter PSQl Database Name: ")
    db_user = input("Enter username: ")
    db_host = input("Host: ")
    db_port = input("port: ")
    db_password = input("Password: ")
    DB_URI = f"postgresql://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}" 
    engine = create_engine(DB_URI)
    
    INDICATORS = {
        'EN.POP.DNST': 'population_density',
        'SI.POV.DDAY': 'poverty_headcount_ratio',
        'NY.GDP.PCAP.CD': 'gdp_per_capita_usd'
    }
    
    dataframes = []
    
    for code, col in INDICATORS.items():
        df_indicator = extract_world_bank_indicator(indicator_code=code, column_name=col)
        dataframes.append(df_indicator)
        
    if all(not df.empty for df in dataframes):
        df_final_matrix = merge_context_data(dataframes[0], dataframes[1], dataframes[2])
        
        try:
            engine = create_engine(DB_URI)
            with engine.connect() as conn:
                trans = conn.begin()
                try:
                    load_to_database(df_final_matrix, conn)
                    trans.commit()
                    print("[INFO] Database transaction committed securely.")
                except Exception as e:
                    trans.rollback()
                    print(f"[CRITICAL] Database load failed. Transaction rolled back. Trace: {e}")
        except Exception as e:
            print(f"[CRITICAL] Engine initialization failed. Check DB_URI credentials. Trace: {e}")
    else:
        print("[CRITICAL] One or more indicator extractions returned empty datasets. Pipeline aborted.")
