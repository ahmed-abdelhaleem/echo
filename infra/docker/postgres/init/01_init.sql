-- Local development Postgres init.
-- Creates the application database and a separate database for the Ory Kratos
-- service (used in M2+; created up front so we don't need to re-init then).
--
-- This file is mounted into the Postgres entrypoint by docker-compose.yml.

CREATE DATABASE echo_test;
CREATE DATABASE kratos;
GRANT ALL PRIVILEGES ON DATABASE echo_test TO echo;
GRANT ALL PRIVILEGES ON DATABASE kratos TO echo;
