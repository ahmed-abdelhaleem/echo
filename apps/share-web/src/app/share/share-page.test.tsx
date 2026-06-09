// @vitest-environment jsdom
import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen } from "@testing-library/react";
import SharePage, { generateMetadata } from "./[token]/page";
import type { SharePayload } from "@/lib/api";

const PAYLOAD: SharePayload = {
  token: "tok-aaa",
  playthrough_id: "11111111-1111-1111-1111-111111111111",
  share_url: "https://share.echo.test/share/tok-aaa",
  portrait_png_url: "https://api.echo.test/share/tok-aaa/portrait",
  portrait_webp_url: "https://api.echo.test/share/tok-aaa/portrait?format=webp",
  reflection: {
    text: "You hesitate at first, then choose anyway.",
    template_id: "openness-high",
  },
  created_at: "2026-05-21T12:00:00Z",
};

// The page calls fetchShare from @/lib/api. Mock it so tests don't
// actually reach over the network and can drive the three render
// branches (ok, revoked, error) independently.
vi.mock("@/lib/api", () => ({
  fetchShare: vi.fn(),
  apiBaseURL: () => "https://api.echo.test",
}));

import { fetchShare } from "@/lib/api";
const mockedFetch = vi.mocked(fetchShare);

// next/navigation's notFound() throws a special "NEXT_NOT_FOUND"
// error in production; replicate that in-test.
vi.mock("next/navigation", () => ({
  notFound: () => {
    throw new Error("NEXT_NOT_FOUND");
  },
}));

beforeEach(() => {
  mockedFetch.mockReset();
});

async function renderPage() {
  const ui = await SharePage({ params: { token: "tok-aaa" } });
  render(ui as React.ReactElement);
}

describe("SharePage render branches", () => {
  it("renders portrait, reflection, and CTA on ok", async () => {
    mockedFetch.mockResolvedValueOnce({ kind: "ok", payload: PAYLOAD });
    await renderPage();
    expect(screen.getByRole("img")).toHaveAttribute(
      "src",
      PAYLOAD.portrait_png_url,
    );
    expect(screen.getByText(PAYLOAD.reflection.text)).toBeInTheDocument();
    const cta = screen.getByRole("link", { name: /download echo/i });
    expect(cta).toHaveAttribute("href", "https://echo.app");
  });

  it("renders the revoked page on revoked outcome", async () => {
    mockedFetch.mockResolvedValueOnce({ kind: "revoked" });
    await renderPage();
    expect(screen.getByText(/taken down/i)).toBeInTheDocument();
    // CTA still present so visitors have a path forward.
    expect(
      screen.getByRole("link", { name: /download echo/i }),
    ).toBeInTheDocument();
  });

  it("renders the error page on error outcome", async () => {
    mockedFetch.mockResolvedValueOnce({ kind: "error", message: "boom" });
    await renderPage();
    expect(screen.getByText(/something went wrong/i)).toBeInTheDocument();
  });

  it("throws NEXT_NOT_FOUND on not_found outcome", async () => {
    mockedFetch.mockResolvedValueOnce({ kind: "not_found" });
    await expect(
      SharePage({ params: { token: "missing" } }),
    ).rejects.toThrow(/NEXT_NOT_FOUND/);
  });
});

describe("generateMetadata", () => {
  it("populates og:image / twitter:image from the payload on ok", async () => {
    mockedFetch.mockResolvedValueOnce({ kind: "ok", payload: PAYLOAD });
    const meta = await generateMetadata({ params: { token: "tok-aaa" } });
    expect(meta.title).toContain("Echo");
    expect(meta.description).toBe(PAYLOAD.reflection.text);
    expect(meta.alternates?.canonical).toBe(PAYLOAD.share_url);
    expect(meta.openGraph?.images).toBeDefined();
    const ogImages = meta.openGraph?.images as
      | Array<{ url: string; width?: number; height?: number }>
      | undefined;
    expect(ogImages?.[0]?.url).toBe(PAYLOAD.portrait_png_url);
    expect(ogImages?.[0]?.width).toBe(1080);
    const twImages = meta.twitter?.images as string[] | undefined;
    expect(twImages?.[0]).toBe(PAYLOAD.portrait_png_url);
  });

  it("returns noindex metadata when the share is revoked", async () => {
    mockedFetch.mockResolvedValueOnce({ kind: "revoked" });
    const meta = await generateMetadata({ params: { token: "tok-aaa" } });
    expect(meta.robots).toEqual({ index: false, follow: false });
    expect(meta.title).toMatch(/revoked/i);
  });

  it("returns noindex metadata on error", async () => {
    mockedFetch.mockResolvedValueOnce({ kind: "error", message: "boom" });
    const meta = await generateMetadata({ params: { token: "tok-aaa" } });
    expect(meta.robots).toEqual({ index: false, follow: false });
  });
});
