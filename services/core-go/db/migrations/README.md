# Migrations

Schema migrations for the Echo core monolith. Managed via
[`goose`](https://github.com/pressly/goose).

## Rules

Per `AGENTS.md` §"Safety rails — hard rules":

- **Migrations must be backwards-compatible** (additive, never destructive in a
  single deploy).
- **Drop columns/tables only after observability confirms no traffic.**
- **Never amend a migration after it has been merged.** Add a new one.
- **`Down` migrations are intentionally minimal** — they exist for local-dev
  convenience, not production rollback. Production rollbacks happen by rolling
  forward.

## Convention

```
YYYYMMDDHHMMSS_<short_snake_case_description>.sql
```

Use UTC timestamps. The leading number is what `goose` orders by.

## Local

```bash
docker compose up -d postgres
make migrate
make migrate-status
```
