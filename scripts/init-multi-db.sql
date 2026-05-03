-- GridTokenX Multi-Database Initialization
-- This script runs once during the first container startup

-- Create Noti Service database if it doesn't exist
SELECT 'CREATE DATABASE gridtokenx_noti'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'gridtokenx_noti')\gexec

-- The 'gridtokenx' database is created by the environment variable POSTGRES_DB
-- but we can ensure other necessary databases are here.

-- Grant permissions (if needed, though usually handled by POSTGRES_USER)
-- GRANT ALL PRIVILEGES ON DATABASE gridtokenx_noti TO gridtokenx_user;
