USE ROLE ACCOUNTADMIN;

-- Create a warehouse
CREATE WAREHOUSE IF NOT EXISTS AI_WH WITH WAREHOUSE_SIZE='X-SMALL';

-- Create a fresh Database
CREATE OR REPLACE DATABASE AI_DEVELOPMENT;

-- Create the API integration with Github

/**
CREATE OR REPLACE API INTEGRATION GITHUB_INTEGRATION_SNOWFLAKE_INTELLIGENCE_DEMOS
    api_provider = git_https_api
    api_allowed_prefixes = ('https://github.com/michaelgorkow/')
    enabled = true
    comment='Git integration for Github Repository from Michael Gorkow.';


-- Create the integration with the Github demo repository
CREATE GIT REPOSITORY GITHUB_REPO_SNOWFLAKE_INTELLIGENCE_DEMOS
	ORIGIN = 'https://github.com/michaelgorkow/snowflake-intelligence-demos' 
	API_INTEGRATION = 'GITHUB_INTEGRATION_SNOWFLAKE_INTELLIGENCE_DEMOS' 
	COMMENT = 'Github Repository from Michael Gorkow with demos for Cortex Agents.';
**/

-- Create the integration with the Github demo repository
CREATE GIT REPOSITORY GITHUB_REPO_SNOWFLAKE_INTELLIGENCE_DEMOS_JOJRG
	ORIGIN = 'https://github.com/jojrg/snowflake-intelligence-demos' 
	API_INTEGRATION = 'GITHUB_OAUTH_JOJRG' 
	COMMENT = 'Github Repository from Jochen Joerg with demos for Cortex Agents.';



-- Run the installation of the Demo
EXECUTE IMMEDIATE FROM @AI_DEVELOPMENT.PUBLIC.GITHUB_REPO_SNOWFLAKE_INTELLIGENCE_DEMOS_JOJRG/branches/energy_company_enhancements/setup/setup.sql;


-- Deploy the Use cases
EXECUTE IMMEDIATE FROM @AI_DEVELOPMENT.PUBLIC.GITHUB_REPO_SNOWFLAKE_INTELLIGENCE_DEMOS_JOJRG/branches/energy_company_enhancements/use_cases/The_Bottling_Company/setup/setup.sql
  USING (BRANCH => 'energy_company_enhancements', EXECUTE_NOTEBOOKS => TRUE) DRY_RUN = FALSE;

// energy use case
EXECUTE IMMEDIATE FROM @AI_DEVELOPMENT.PUBLIC.GITHUB_REPO_SNOWFLAKE_INTELLIGENCE_DEMOS_JOJRG/branches/energy_company_enhancements/use_cases/The_Energy_Company/setup/setup.sql
  USING (BRANCH => 'energy_company_enhancements', EXECUTE_NOTEBOOKS => TRUE) DRY_RUN = FALSE;


-- Add ons required 
-- For syncing execution github repo stage object in snowflake with latest code changes
-- To find your repo name first
SHOW GIT REPOSITORIES;

-- Fetch latest from your Git repo
ALTER GIT REPOSITORY AI_DEVELOPMENT.PUBLIC.GITHUB_REPO_SNOWFLAKE_INTELLIGENCE_DEMOS_JOJRG FETCH;


--