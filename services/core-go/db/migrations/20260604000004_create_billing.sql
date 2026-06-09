-- 20260604000004_create_billing.sql
--
-- Subscription billing tables (T-MONEY-001 / F-MONEY-001).
--
-- Tracks Echo+ subscription state per user regardless of payment provider
-- (Stripe for desktop, Apple IAP for iOS/macOS, Google Play for Android).
-- Webhook handlers upsert into this table; the application reads it to
-- gate Echo+ features.
--
-- Intentionally additive — no columns dropped or renamed.

-- +goose Up
-- +goose StatementBegin

CREATE SCHEMA IF NOT EXISTS billing;

CREATE TABLE IF NOT EXISTS billing.subscriptions (
    id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id               UUID        NOT NULL UNIQUE,
    tier                  TEXT        NOT NULL DEFAULT 'free',
    status                TEXT        NOT NULL DEFAULT 'active',
    store                 TEXT        NOT NULL DEFAULT 'none',
    store_customer_id     TEXT        NOT NULL DEFAULT '',
    store_subscription_id TEXT        NOT NULL DEFAULT '',
    current_period_end    TIMESTAMPTZ,
    canceled_at           TIMESTAMPTZ,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT billing_subscriptions_tier_chk CHECK (
        tier IN ('free', 'echo_plus')
    ),
    CONSTRAINT billing_subscriptions_status_chk CHECK (
        status IN ('active', 'trialing', 'past_due', 'canceled', 'expired')
    ),
    CONSTRAINT billing_subscriptions_store_chk CHECK (
        store IN ('none', 'stripe', 'apple', 'google')
    )
);

-- Index for webhook lookups (find subscription by provider subscription id).
CREATE INDEX IF NOT EXISTS billing_subscriptions_store_sub_idx
    ON billing.subscriptions (store, store_subscription_id)
    WHERE store_subscription_id <> '';

-- Index for webhook lookups by store customer id (Stripe).
CREATE INDEX IF NOT EXISTS billing_subscriptions_store_cust_idx
    ON billing.subscriptions (store, store_customer_id)
    WHERE store_customer_id <> '';

-- Append-only event log for all inbound billing webhook payloads.
-- This is the audit trail; the subscriptions row is the derived state.
CREATE TABLE IF NOT EXISTS billing.subscription_events (
    id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    store        TEXT        NOT NULL,
    event_type   TEXT        NOT NULL,
    payload      JSONB       NOT NULL DEFAULT '{}',
    processed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS billing_sub_events_store_idx
    ON billing.subscription_events (store, processed_at);

-- +goose StatementEnd

-- +goose Down
-- Per AGENTS.md §"Safety rails": Down migrations never drop tables.
-- Removal happens in a separate migration after observability confirms
-- zero traffic to these tables.
SELECT 1;

