\set ON_ERROR_STOP on

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'orchard_owner') THEN
    CREATE ROLE orchard_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'orchard_controller') THEN
    CREATE ROLE orchard_controller LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'orchard_migrator') THEN
    CREATE ROLE orchard_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'orchard_backup') THEN
    CREATE ROLE orchard_backup LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
  END IF;
END
$$;

GRANT orchard_owner TO orchard_migrator;
GRANT pg_read_all_data, pg_read_all_settings TO orchard_backup;
SELECT 'CREATE DATABASE orchard OWNER orchard_owner'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'orchard')\gexec
REVOKE CONNECT ON DATABASE orchard FROM PUBLIC;
GRANT CONNECT ON DATABASE orchard TO orchard_controller, orchard_migrator, orchard_backup;
GRANT TEMPORARY ON DATABASE orchard TO orchard_controller;
\connect orchard
GRANT USAGE ON SCHEMA public TO orchard_controller, orchard_backup;
ALTER DEFAULT PRIVILEGES FOR ROLE orchard_owner IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO orchard_controller;
ALTER DEFAULT PRIVILEGES FOR ROLE orchard_owner IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO orchard_controller;
