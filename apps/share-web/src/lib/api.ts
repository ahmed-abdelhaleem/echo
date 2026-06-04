// Client of the core-go sharing API.
//
// share-web is a thin SSR layer; the canonical contract is JSON served
// by core-go at GET /share/{token}. This module is the single place
// that knows the wire shape and the canonical base URL.

/**
 * SharePayload is the JSON contract served by core-go's
 * GET /share/{token}. Kept structurally aligned with
 * services/core-go/http/sharing.go::sharePayload.
 */
export type SharePayload = {
  token: string;
  playthrough_id: string;
  share_url: string;
  portrait_png_url: string;
  portrait_webp_url: string;
  reflection: {
    text: string;
    template_id: string;
  };
  created_at: string;
};

export type ComparePayload = {
  season_id: string;
  status: string;
  divergence: {
    vignette_id: string;
    inviter_choice: string;
    invitee_choice: string;
  };
  inviter_png_url: string;
  invitee_png_url: string;
};

export type FetchOutcome =
  | { kind: "ok"; payload: SharePayload }
  | { kind: "not_found" }
  | { kind: "revoked" }
  | { kind: "error"; message: string };

/**
 * apiBaseURL returns the configured core-go origin. NEXT_PUBLIC_ here
 * because some renderers (Suspense streaming, hydrate) read it on the
 * client too — though most of share-web is SSR. Falls back to
 * localhost:8080 in dev.
 */
export function apiBaseURL(): string {
  const v = process.env.NEXT_PUBLIC_API_BASE_URL;
  if (v && v.trim().length > 0) {
    return v.replace(/\/$/, "");
  }
  return "http://localhost:8080";
}

/**
 * fetchShare reaches into core-go for the JSON payload that the share
 * page renders. It deliberately runs server-side only — no caching,
 * no client-side credentials, no cookies. Failures map to discrete
 * outcomes so the page can render appropriate UI (404 for missing,
 * 410 for revoked, generic error otherwise) without leaking server
 * errors to the visitor.
 */
export async function fetchShare(token: string): Promise<FetchOutcome> {
  if (!token || token.trim().length === 0) {
    return { kind: "not_found" };
  }
  const url = `${apiBaseURL()}/share/${encodeURIComponent(token)}`;
  let res: Response;
  try {
    res = await fetch(url, {
      // Share pages are public + cacheable; we let Next's fetch cache
      // own the freshness. revalidate=30s balances "preview embeds get
      // fresh data" against "viral link doesn't hammer core-go".
      next: { revalidate: 30 },
      headers: { Accept: "application/json" },
    });
  } catch (err) {
    return { kind: "error", message: errMessage(err) };
  }

  if (res.status === 404) return { kind: "not_found" };
  if (res.status === 410) return { kind: "revoked" };
  if (!res.ok) {
    return { kind: "error", message: `core-go returned ${res.status}` };
  }
  try {
    const payload = (await res.json()) as SharePayload;
    return { kind: "ok", payload };
  } catch (err) {
    return { kind: "error", message: errMessage(err) };
  }
}

export type CompareFetchOutcome =
  | { kind: "ok"; payload: ComparePayload }
  | { kind: "not_found" }
  | { kind: "revoked" }
  | { kind: "error"; message: string };

/**
 * fetchCompare resolves GET /compare/{token} for side-by-side public
 * comparison pages.
 */
export async function fetchCompare(
  token: string,
): Promise<CompareFetchOutcome> {
  if (!token || token.trim().length === 0) {
    return { kind: "not_found" };
  }
  const url = `${apiBaseURL()}/compare/${encodeURIComponent(token)}`;
  let res: Response;
  try {
    res = await fetch(url, {
      next: { revalidate: 30 },
      headers: { Accept: "application/json" },
    });
  } catch (err) {
    return { kind: "error", message: errMessage(err) };
  }

  if (res.status === 404) return { kind: "not_found" };
  if (res.status === 410) return { kind: "revoked" };
  if (!res.ok) {
    return { kind: "error", message: `core-go returned ${res.status}` };
  }
  try {
    const payload = (await res.json()) as ComparePayload;
    return { kind: "ok", payload };
  } catch (err) {
    return { kind: "error", message: errMessage(err) };
  }
}

function errMessage(err: unknown): string {
  if (err instanceof Error) return err.message;
  return String(err);
}
