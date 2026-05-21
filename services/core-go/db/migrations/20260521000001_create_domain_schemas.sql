-- +goose Up
-- Create the five domain schemas per docs/05_Technical_Architecture.md
-- §"Logical schema separation by domain". Tables for each schema are added in
-- subsequent migrations as the corresponding feature lands.
--
-- Auth is the responsibility of Ory Kratos for identity; this schema holds the
-- application-side user record that maps to a Kratos identity.

CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS playthrough;
CREATE SCHEMA IF NOT EXISTS events;
CREATE SCHEMA IF NOT EXISTS sharing;
CREATE SCHEMA IF NOT EXISTS org;

-- +goose Down
-- Drops are not allowed in a single migration per AGENTS.md §"Safety rails".
-- This Down is intentionally empty so accidental rollbacks cannot destroy
-- production schemas. Schema removal happens via a separate explicit migration
-- after observability confirms no traffic.
SELECT 1;
