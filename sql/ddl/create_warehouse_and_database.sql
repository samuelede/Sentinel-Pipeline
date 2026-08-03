-- Creates the warehouse, database, and default schema that
-- create_tables.sql and create_stage.sql assume already exist. Run this
-- FIRST, before create_tables.sql or create_stage.sql.

CREATE WAREHOUSE IF NOT EXISTS SENTINEL_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE;

CREATE DATABASE IF NOT EXISTS SENTINEL_DB;

CREATE SCHEMA IF NOT EXISTS SENTINEL_DB.ANALYTICS;

USE WAREHOUSE SENTINEL_WH;
USE DATABASE SENTINEL_DB;
USE SCHEMA ANALYTICS;
