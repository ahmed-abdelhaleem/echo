# share-web

Public Portrait sharing page. Renders a server-side, SEO-friendly page
from a share token issued by `services/core-go`.

This is the **public** surface that lives at `https://share.echo.app/share/{token}`
and is what someone clicks when their friend sends them a Portrait.
The page is unauthenticated — it pulls all the data it needs from a
single `GET /share/{token}` request to `core-go` (which gates on the
opt-in share token).

Tasks landed: `T-WEB-001` (apps/share-web Portrait page) per
`docs/07_AI_Agent_Implementation_Guide.md`.

## Routes

- `/` — landing/explainer page, links to `https://echo.app` to download.
- `/share/[token]` — the actual share page. SSR fetches `GET /share/{token}`
  on the configured `core-go` origin, renders the Portrait (PNG + WebP
  fallback), the reflection prose, and a "Download Echo" CTA.
- `/share/[token]` (revoked) — 200 OK with a "this Portrait was taken down"
  page. The underlying `core-go` returns `410 Gone`; share-web maps
  that to a noindex render (we don't want crawlers to keep the page
  cached).
- `/share/[token]` (not found) — 404. share-web renders a small
  explainer linking to `https://echo.app`.

## SEO

- `og:image` and `twitter:image` point at the public portrait endpoint
  served by core-go (`/share/{token}/portrait`). No auth needed.
- `og:title` / `twitter:title` is the brand tag line.
- `og:description` / `twitter:description` is the reflection text
  itself — that's the most evocative copy and the most likely to
  generate a click.
- Revoked + errored pages set `robots: noindex,nofollow`.

## Configuration

Environment variables (read at build/SSR time):

- `NEXT_PUBLIC_API_BASE_URL` — origin of `core-go`'s public sharing API
  (defaults to `http://localhost:8080` for local dev).

## Local development

```bash
pnpm install
pnpm --filter @echo/share-web dev
```

Then visit `http://localhost:3001/share/<token>` (mint a token first
via `POST /playthroughs/{id}/share` on `core-go`).

## Testing

```bash
pnpm --filter @echo/share-web test
```

Vitest runs the SSR fetch unit tests and the page-render tests under
jsdom. The page tests exercise the three render branches (ok,
revoked, error) and the metadata helper (`generateMetadata`).
