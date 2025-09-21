## Use Case Deployment
Execute this SQL Query to create and run the notebook in your account which will generate data and required services.
```sql
EXECUTE IMMEDIATE FROM @AI_DEVELOPMENT.PUBLIC.GITHUB_REPO_SNOWFLAKE_INTELLIGENCE_DEMOS/branches/main/use_cases/Clinical_Trial/setup/setup.sql
  USING (BRANCH => 'main', EXECUTE_NOTEBOOKS => TRUE) DRY_RUN = FALSE;
```