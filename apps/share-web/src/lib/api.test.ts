// @vitest-environment node
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { apiBaseURL, fetchShare, type SharePayload } from "./api";

const VALID_PAYLOAD: SharePayload = {
  token: "tok-aaa",
  playthrough_id: "11111111-1111-1111-1111-111111111111",
  share_url: "https://share.echo.test/share/tok-aaa",
  portrait_png_url: "https://api.echo.test/share/tok-aaa/portrait",
  portrait_webp_url: "https://api.echo.test/share/tok-aaa/portrait?format=webp",
  reflection: { text: "You hesitate, then choose anyway.", template_id: "x" },
  created_at: "2026-05-21T12:00:00Z",
};

describe("apiBaseURL", () => {
  const original = process.env.NEXT_PUBLIC_API_BASE_URL;
  afterEach(() => {
    if (original === undefined) {
      delete process.env.NEXT_PUBLIC_API_BASE_URL;
    } else {
      process.env.NEXT_PUBLIC_API_BASE_URL = original;
    }
  });

  it("returns the configured env value", () => {
    process.env.NEXT_PUBLIC_API_BASE_URL = "https://api.echo.app";
    expect(apiBaseURL()).toBe("https://api.echo.app");
  });

  it("strips a trailing slash", () => {
    process.env.NEXT_PUBLIC_API_BASE_URL = "https://api.echo.app/";
    expect(apiBaseURL()).toBe("https://api.echo.app");
  });

  it("falls back to localhost when unset", () => {
    delete process.env.NEXT_PUBLIC_API_BASE_URL;
    expect(apiBaseURL()).toBe("http://localhost:8080");
  });
});

describe("fetchShare", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    process.env.NEXT_PUBLIC_API_BASE_URL = "https://api.echo.test";
  });

  it("returns ok payload on 200", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(JSON.stringify(VALID_PAYLOAD), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
      ),
    );
    const out = await fetchShare("tok-aaa");
    expect(out).toEqual({ kind: "ok", payload: VALID_PAYLOAD });
  });

  it("returns not_found on 404", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("", { status: 404 })));
    const out = await fetchShare("missing");
    expect(out).toEqual({ kind: "not_found" });
  });

  it("returns revoked on 410", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("", { status: 410 })));
    const out = await fetchShare("revoked");
    expect(out).toEqual({ kind: "revoked" });
  });

  it("returns error on 5xx", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("", { status: 500 })));
    const out = await fetchShare("boom");
    expect(out.kind).toBe("error");
  });

  it("returns not_found on empty token without making an HTTP call", async () => {
    const fn = vi.fn();
    vi.stubGlobal("fetch", fn);
    const out = await fetchShare("");
    expect(out).toEqual({ kind: "not_found" });
    expect(fn).not.toHaveBeenCalled();
  });

  it("encodes the token into the URL", async () => {
    const fn = vi.fn(async () =>
      new Response(JSON.stringify(VALID_PAYLOAD), { status: 200 }),
    );
    vi.stubGlobal("fetch", fn);
    await fetchShare("tok with spaces");
    const url = fn.mock.calls[0][0] as string;
    expect(url).toBe("https://api.echo.test/share/tok%20with%20spaces");
  });

  it("returns error when fetch throws", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        throw new Error("network down");
      }),
    );
    const out = await fetchShare("tok");
    expect(out.kind).toBe("error");
    if (out.kind === "error") {
      expect(out.message).toContain("network down");
    }
  });
});
