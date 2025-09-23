-- =================================================================================
-- TABLE & COLUMN DESCRIPTIONS
-- =================================================================================

-- Table Descriptions
COMMENT ON TABLE DIM_CUSTOMERS IS 'Dimension table containing static attributes for each Energy Company customer. It serves as the master table for all customer-related information.';
COMMENT ON TABLE FACT_CONTRACTS IS 'Fact table that links customers to their specific service contracts, detailing the type of service, tariff plan, and contract duration.';
COMMENT ON TABLE FACT_SMART_METER_READINGS IS 'Fact table containing all time-series smart meter readings. This is the central repository for granular energy consumption and generation data.';
COMMENT ON TABLE FACT_BILLINGS IS 'Fact table that stores all customer billing and invoicing information, including amounts due, payment status, and the relevant consumption periods.';
COMMENT ON TABLE FACT_SUPPORT_CASES IS 'Fact table that logs all customer service interactions and support tickets, providing insights into customer issues and satisfaction.';

---

-- Column Descriptions for DIM_CUSTOMERS
COMMENT ON COLUMN DIM_CUSTOMERS.CUSTOMER_ID IS 'The primary key and unique string identifier for each customer (e.g., CID_001001).';
COMMENT ON COLUMN DIM_CUSTOMERS.CUSTOMER_NAME IS 'The name of the customer.';
COMMENT ON COLUMN DIM_CUSTOMERS.EMAIL IS 'The customer''s email address for communication and billing.';
COMMENT ON COLUMN DIM_CUSTOMERS.ADDRESS IS 'The full street address of the customer''s service location.';
COMMENT ON COLUMN DIM_CUSTOMERS.CITY IS 'The city of the customer''s service location.';
COMMENT ON COLUMN DIM_CUSTOMERS.POSTAL_CODE IS 'The postal code for the customer''s address.';
COMMENT ON COLUMN DIM_CUSTOMERS.CUSTOMER_TYPE IS 'Categorizes the customer as either ''residential'' or ''commercial''.';
COMMENT ON COLUMN DIM_CUSTOMERS.ACCOUNT_STATUS IS 'The current status of the customer''s account (e.g., ''active'', ''suspended'').';
COMMENT ON COLUMN DIM_CUSTOMERS.JOIN_DATE IS 'The date when the customer first signed up for service with Energy Compance.';

---

-- Column Descriptions for FACT_CONTRACTS
COMMENT ON COLUMN FACT_CONTRACTS.CONTRACT_ID IS 'The primary key and unique string identifier for each service contract (e.g., CON_0005001).';
COMMENT ON COLUMN FACT_CONTRACTS.CUSTOMER_ID IS 'Foreign key linking to DIM_CUSTOMERS, specifying which customer holds the contract.';
COMMENT ON COLUMN FACT_CONTRACTS.SERVICE_TYPE IS 'The type of energy service provided under the contract (e.g., ''electricity'', ''gas'', ''solar panel lease'').';
COMMENT ON COLUMN FACT_CONTRACTS.TARIFF_PLAN IS 'The specific pricing plan associated with the contract.';
COMMENT ON COLUMN FACT_CONTRACTS.START_DATE IS 'The date on which the service contract became effective.';
COMMENT ON COLUMN FACT_CONTRACTS.END_DATE IS 'The date on which the service contract is set to expire. NULL indicates an ongoing contract.';
COMMENT ON COLUMN FACT_CONTRACTS.STATUS IS 'The current status of the contract (e.g., ''active'', ''pending renewal'').';

---

-- Column Descriptions for FACT_SMART_METER_READINGS
COMMENT ON COLUMN FACT_SMART_METER_READINGS.READING_ID IS 'The primary key and unique string identifier for each individual meter reading (e.g., RID_00100001).';
COMMENT ON COLUMN FACT_SMART_METER_READINGS.CUSTOMER_ID IS 'Foreign key linking to DIM_CUSTOMERS, identifying the customer associated with the meter reading.';
COMMENT ON COLUMN FACT_SMART_METER_READINGS.METER_ID IS 'The unique identifier for the physical smart meter installed at the customer''s location.';
COMMENT ON COLUMN FACT_SMART_METER_READINGS.TIMESTAMP IS 'The exact date and time when the meter reading was recorded.';
COMMENT ON COLUMN FACT_SMART_METER_READINGS.KWH_CONSUMPTION IS 'The total energy consumed in kilowatt-hours (kWh) during the interval leading up to the timestamp.';
COMMENT ON COLUMN FACT_SMART_METER_READINGS.KW_GENERATION IS 'The total energy generated in kilowatts (kW) for customers with solar panels.';

---

-- Column Descriptions for FACT_BILLINGS
COMMENT ON COLUMN FACT_BILLINGS.INVOICE_ID IS 'The primary key and unique string identifier for each invoice (e.g., INV_0080001).';
COMMENT ON COLUMN FACT_BILLINGS.CUSTOMER_ID IS 'Foreign key linking to DIM_CUSTOMERS, identifying the customer who received the invoice.';
COMMENT ON COLUMN FACT_BILLINGS.INVOICE_DATE IS 'The date the invoice was generated and issued to the customer.';
COMMENT ON COLUMN FACT_BILLINGS.DUE_DATE IS 'The date by which the payment for the invoice is due.';
COMMENT ON COLUMN FACT_BILLINGS.AMOUNT_DUE IS 'The total amount payable in EUR for the billing period.';
COMMENT ON COLUMN FACT_BILLINGS.PAYMENT_STATUS IS 'The current status of the invoice payment (e.g., ''paid'', ''overdue'', ''pending'').';
COMMENT ON COLUMN FACT_BILLINGS.CONSUMPTION_PERIOD_START IS 'The start date of the billing period for which consumption is being charged.';
COMMENT ON COLUMN FACT_BILLINGS.CONSUMPTION_PERIOD_END IS 'The end date of the billing period for which consumption is being charged.';

---

-- Column Descriptions for FACT_SUPPORT_CASES
COMMENT ON COLUMN FACT_SUPPORT_CASES.CASE_ID IS 'The primary key and unique string identifier for each customer support case (e.g., CAS_000101).';
COMMENT ON COLUMN FACT_SUPPORT_CASES.CUSTOMER_ID IS 'Foreign key linking to DIM_CUSTOMERS, identifying the customer who initiated the support case.';
COMMENT ON COLUMN FACT_SUPPORT_CASES.CASE_DATE IS 'The date the support case was created.';
COMMENT ON COLUMN FACT_SUPPORT_CASES.ISSUE_TYPE IS 'A category describing the nature of the customer''s issue (e.g., ''billing inquiry'', ''service outage'').';
COMMENT ON COLUMN FACT_SUPPORT_CASES.RESOLUTION_STATUS IS 'The current status of the support case (e.g., ''open'', ''closed'', ''escalated'').';
COMMENT ON COLUMN FACT_SUPPORT_CASES.DESCRIPTION IS 'A brief summary of the customer''s issue or inquiry.';


-- =================================================================================
-- PRIMARY / FOREIGN KEYS
-- =================================================================================

-- DIM_CUSTOMERS Primary Key
ALTER TABLE DIM_CUSTOMERS ADD CONSTRAINT PK_DIM_CUSTOMERS PRIMARY KEY (CUSTOMER_ID);

---

-- FACT_CONTRACTS Keys
ALTER TABLE FACT_CONTRACTS ADD CONSTRAINT PK_FACT_CONTRACTS PRIMARY KEY (CONTRACT_ID);
ALTER TABLE FACT_CONTRACTS
ADD CONSTRAINT FK_CONTRACTS_CUSTOMER FOREIGN KEY (CUSTOMER_ID)
REFERENCES DIM_CUSTOMERS(CUSTOMER_ID);

---

-- FACT_SMART_METER_READINGS Keys
ALTER TABLE FACT_SMART_METER_READINGS ADD CONSTRAINT PK_FACT_SMART_METER_READINGS PRIMARY KEY (READING_ID);
ALTER TABLE FACT_SMART_METER_READINGS
ADD CONSTRAINT FK_READINGS_CUSTOMER FOREIGN KEY (CUSTOMER_ID)
REFERENCES DIM_CUSTOMERS(CUSTOMER_ID);

---

-- FACT_BILLINGS Keys
ALTER TABLE FACT_BILLINGS ADD CONSTRAINT PK_FACT_BILLINGS PRIMARY KEY (INVOICE_ID);
ALTER TABLE FACT_BILLINGS
ADD CONSTRAINT FK_BILLINGS_CUSTOMER FOREIGN KEY (CUSTOMER_ID)
REFERENCES DIM_CUSTOMERS(CUSTOMER_ID);

---

-- FACT_SUPPORT_CASES Keys
ALTER TABLE FACT_SUPPORT_CASES ADD CONSTRAINT PK_FACT_SUPPORT_CASES PRIMARY KEY (CASE_ID);
ALTER TABLE FACT_SUPPORT_CASES
ADD CONSTRAINT FK_CASES_CUSTOMER FOREIGN KEY (CUSTOMER_ID)
REFERENCES DIM_CUSTOMERS(CUSTOMER_ID);