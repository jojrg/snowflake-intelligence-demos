import pandas as pd
import numpy as np
from datetime import datetime, timedelta
import random
from faker import Faker

def generate_energy_provider_data(session, num_customers: int, start_date: datetime, end_date: datetime):
    """
    Generates a synthetic dataset for a fictional energy provider.

    This function creates five pandas DataFrames:
    1. customers: Details about each customer.
    2. contracts: Service contracts associated with customers.
    3. readings: Simulated smart meter readings.
    4. billing: Invoices for each customer.
    5. support_cases: Customer support tickets.

    Args:
        num_customers (int): The total number of customers to generate.
        start_date (datetime): The start date for generating time-series data (readings, bills).
        end_date (datetime): The end date for generating time-series data.

    Returns:
        dict: A dictionary where keys are table names (e.g., 'customers')
              and values are the corresponding pandas DataFrames.
    """
    # --- Configuration ---
    TARIFF_RATE_KWH = 0.35  # EUR per kWh
    BASE_MONTHLY_FEE = 5.50  # EUR

    # Initialize Faker for German data
    fake = Faker('de_DE')

    # --- 1. CUSTOMERS Table ---
    customers_data = []
    customer_ids = [f"CID_{1001 + i:06}" for i in range(num_customers)]

    for i, customer_id in enumerate(customer_ids):
        first_name = fake.first_name()
        last_name = fake.last_name()
        customers_data.append({
            'CUSTOMER_ID': customer_id,
            'CUSTOMER_NAME': f'{first_name} {last_name}',
            'EMAIL': f"{first_name.lower()}.{last_name.lower()}@{fake.free_email_domain()}",
            'ADDRESS': fake.street_address(),
            'CITY': fake.city(),
            'POSTAL_CODE': fake.postcode(),
            'CUSTOMER_TYPE': random.choices(['residential', 'commercial'], weights=[0.95, 0.05], k=1)[0],
            'ACCOUNT_STATUS': random.choices(['active', 'suspended', 'canceled'], weights=[0.96, 0.03, 0.01], k=1)[0],
            'JOIN_DATE': fake.date_between(start_date='-8y', end_date='-1y')
        })

    customers_df = pd.DataFrame(customers_data)
    customers_df['JOIN_DATE'] = pd.to_datetime(customers_df['JOIN_DATE']).dt.date
    print(f"✅ Generated {len(customers_df)} records for CUSTOMERS.")

    # --- 2. SERVICE_CONTRACTS Table ---
    contracts_data = []
    contract_id_counter = 5001

    for customer_id in customers_df['CUSTOMER_ID']:
        num_contracts = random.choices([1, 2], weights=[0.8, 0.2], k=1)[0]
        services = set()
        for _ in range(num_contracts):
            service_type = random.choice(['electricity', 'gas', 'solar panel lease'])
            if service_type in services: continue
            services.add(service_type)

            contract_start_date = fake.date_between(start_date='-4y', end_date='-6m')
            contracts_data.append({
                'CONTRACT_ID': f"CON_{contract_id_counter:07}",
                'CUSTOMER_ID': customer_id,
                'SERVICE_TYPE': service_type,
                'TARIFF_PLAN': random.choice(['Green Fix', 'Energy Plus Variable', 'Basic Home']),
                'START_DATE': contract_start_date,
                'END_DATE': random.choices([None, fake.date_between(start_date='+1y', end_date='+3y')], weights=[0.7, 0.3], k=1)[0],
                'STATUS': random.choices(['active', 'pending renewal', 'expired'], weights=[0.9, 0.08, 0.02], k=1)[0]
            })
            contract_id_counter += 1

    contracts_df = pd.DataFrame(contracts_data)
    contracts_df['START_DATE'] = pd.to_datetime(contracts_df['START_DATE']).dt.date
    contracts_df['END_DATE'] = pd.to_datetime(contracts_df['END_DATE']).dt.date
    print(f"✅ Generated {len(contracts_df)} records for SERVICE_CONTRACTS.")

    # --- 3. SMART_METER_READINGS Table ---
    readings_data = []
    reading_id_counter = 100001
    solar_customers = set(contracts_df[contracts_df['SERVICE_TYPE'] == 'solar panel lease']['CUSTOMER_ID'])
    all_residential_ids = list(customers_df[customers_df['CUSTOMER_TYPE'] == 'residential']['CUSTOMER_ID'])
    anomaly_customers = set(random.sample(all_residential_ids, k=min(15, len(all_residential_ids))))
    anomaly_spike_date = datetime(2025, 8, 15)
    customer_types = customers_df.set_index('CUSTOMER_ID')['CUSTOMER_TYPE'].to_dict()
    date_range = pd.date_range(start=start_date, end=end_date, freq='D')

    for customer_id in customers_df['CUSTOMER_ID']:
        customer_numeric_id = int(customer_id.split('_')[1])
        meter_id = f"MTR-{customer_numeric_id + 12345}"
        cust_type = customer_types[customer_id]

        for day in date_range:
            base_consumption = np.random.normal(loc=75, scale=10) if cust_type == 'commercial' else np.random.normal(loc=10, scale=3)
            if customer_id in anomaly_customers and (anomaly_spike_date - timedelta(days=2) <= day <= anomaly_spike_date + timedelta(days=2)):
                kwh_consumption = base_consumption * random.uniform(5, 8)
            else:
                kwh_consumption = base_consumption
            kw_generation = np.random.uniform(1.0, 5.5) if customer_id in solar_customers and day.month in [6, 7, 8] else 0.0
            readings_data.append({
                'READING_ID': f"RID_{reading_id_counter:08}",
                'CUSTOMER_ID': customer_id,
                'METER_ID': meter_id,
                'TIMESTAMP': day.replace(hour=random.randint(0, 23), minute=random.randint(0, 59)),
                'KWH_CONSUMPTION': round(max(0, kwh_consumption), 2),
                'KW_GENERATION': round(max(0, kw_generation), 2)
            })
            reading_id_counter += 1

    readings_df = pd.DataFrame(readings_data)
    print(f"✅ Generated {len(readings_df)} records for SMART_METER_READINGS.")

    # --- 4. BILLING Table ---
    billing_data = []
    invoice_id_counter = 80001
    overdue_customers = set(list(anomaly_customers)[:7])

    for customer_id in customers_df['CUSTOMER_ID']:
        # Calculate the number of months to generate bills for
        num_months = (end_date.year - start_date.year) * 12 + (end_date.month - start_date.month) + 1
        for month_offset in range(num_months):
            period_start = start_date + pd.DateOffset(months=month_offset)
            # Ensure period_start doesn't go past the simulation end date
            if period_start > end_date:
                continue
            period_start = period_start.replace(day=1) # Start of the month
            period_end = period_start + pd.DateOffset(months=1) - pd.DateOffset(days=1)
            # Ensure period_end doesn't exceed the simulation end_date
            period_end = min(period_end, end_date)

            monthly_consumption = readings_df[
                (readings_df['CUSTOMER_ID'] == customer_id) &
                (readings_df['TIMESTAMP'] >= period_start) &
                (readings_df['TIMESTAMP'] <= period_end)
            ]['KWH_CONSUMPTION'].sum()

            amount = round(monthly_consumption * TARIFF_RATE_KWH + BASE_MONTHLY_FEE, 2)
            invoice_date = (period_end + timedelta(days=5)).date()

            if period_start.month == end_date.month and period_start.year == end_date.year:
                status = 'pending'
            elif customer_id in overdue_customers and period_start.month == 8:
                status = 'overdue'
            else:
                status = 'paid'

            billing_data.append({
                'INVOICE_ID': f"INV_{invoice_id_counter:07}",
                'CUSTOMER_ID': customer_id,
                'INVOICE_DATE': invoice_date,
                'DUE_DATE': invoice_date + timedelta(days=14),
                'AMOUNT_DUE': amount,
                'PAYMENT_STATUS': status,
                'CONSUMPTION_PERIOD_START': period_start.date(),
                'CONSUMPTION_PERIOD_END': period_end.date()
            })
            invoice_id_counter += 1

    billing_df = pd.DataFrame(billing_data)
    for col in ['INVOICE_DATE', 'DUE_DATE', 'CONSUMPTION_PERIOD_START', 'CONSUMPTION_PERIOD_END']:
        billing_df[col] = pd.to_datetime(billing_df[col]).dt.date
    print(f"✅ Generated {len(billing_df)} records for BILLING.")

    # --- 5. CUSTOMER_SUPPORT_CASES Table ---
    cases_data = []
    case_id_counter = 101
    customers_for_cases = set(random.sample(customer_ids, k=int(num_customers * 0.2)))
    customers_for_cases.update(anomaly_customers)
    customers_for_cases.update(overdue_customers)

    for customer_id in customers_for_cases:
        num_cases = random.randint(1, 2)
        for _ in range(num_cases):
            case_date_obj = fake.date_time_between(start_date=start_date, end_date=end_date).date()
            if customer_id in anomaly_customers:
                issue_type = 'billing inquiry'
                description = "Customer inquired about unexpectedly high bill for August."
                case_date_obj = (anomaly_spike_date + timedelta(days=15 + random.randint(1, 5))).date()
            elif customer_id in overdue_customers:
                issue_type = 'billing inquiry'
                description = "Follow-up call regarding overdue payment for August invoice."
                case_date_obj = (anomaly_spike_date + timedelta(days=30 + random.randint(1, 5))).date()
            else:
                issue_type = random.choice(['service outage', 'meter reading issue', 'tariff plan query'])
                description = "Customer called with a general query about their service."

            cases_data.append({
                'CASE_ID': f"CAS_{case_id_counter:06}",
                'CUSTOMER_ID': customer_id,
                'CASE_DATE': case_date_obj,
                'ISSUE_TYPE': issue_type,
                'RESOLUTION_STATUS': random.choices(['closed', 'open', 'escalated'], weights=[0.8, 0.15, 0.05], k=1)[0],
                'DESCRIPTION': description
            })
            case_id_counter += 1

    support_cases_df = pd.DataFrame(cases_data)
    support_cases_df['CASE_DATE'] = pd.to_datetime(support_cases_df['CASE_DATE']).dt.date
    print(f"✅ Generated {len(support_cases_df)} records for CUSTOMER_SUPPORT_CASES.")

    customers_sdf = session.write_pandas(customers_df, table_name='DIM_CUSTOMERS', overwrite=True, use_logical_type=True, auto_create_table=True)
    
    contracts_sdf = session.write_pandas(contracts_df, table_name='FACT_CONTRACTS', overwrite=True, use_logical_type=True, auto_create_table=True)
    
    readings_sdf = session.write_pandas(readings_df, table_name='FACT_SMART_METER_READINGS', overwrite=True, use_logical_type=True, auto_create_table=True)
    
    billing_sdf = session.write_pandas(billing_df, table_name='FACT_BILLINGS', overwrite=True, use_logical_type=True, auto_create_table=True)
    
    support_cases_sdf = session.write_pandas(support_cases_df, table_name='FACT_SUPPORT_CASES', overwrite=True, use_logical_type=True, auto_create_table=True)
    print("\n--- Data Generation Complete ---")