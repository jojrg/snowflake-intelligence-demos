# The Energy Trading Company

## Overview

This use case demonstrates a complete data pipeline for ingesting and analyzing European energy market data from the Energy-Charts API, with AI-powered semantic search and natural language query capabilities.

### Features

- External Access Integration for Energy-Charts API
- Raw JSON ingestion tables with change data capture streams
- Transformation procedures for incremental processing
- LLM-generated metadata and documentation
- Cortex Search services for semantic discovery
- AI Agent with Cortex Analyst for natural language queries

## Use Case Deployment

To create and deploy the use case assets and services, execute the following SQL scripts in order:

### Step 1: Setup

Run the setup script to create the required database objects, tables, views, stored procedures, and services:

[setup/1_setup.sql](setup/1_setup.sql)

### Step 2: Start Pipeline

Run the pipeline script to ingest initial data and start the scheduled data pipeline tasks:

[setup/2_start_pipeline.sql](setup/2_start_pipeline.sql)
