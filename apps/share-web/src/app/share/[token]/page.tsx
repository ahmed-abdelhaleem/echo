import type { Metadata } from "next";
import { notFound } from "next/navigation";
import Link from "next/link";
import { fetchShare } from "@/lib/api";

type Params = { token: string };

/**
 * generateMetadata is the SEO surface — og:image / twitter:image /
 * canonical URL — that determines what Slack, iMessage, Twitter, and
 * other social previews render. The image points at the public
 * portrait endpoint on core-go (no auth required).
 */
export async function generateMetadata({
  params,
}: {
  params: Params;
}): Promise<Metadata> {
  const outcome = await fetchShare(params.token);
  if (outcome.kind !== "ok") {
    return {
      title: outcome.kind === "revoked" ? "Echo — share revoked" : "Echo",
      robots: { index: false, follow: false },
    };
  }
  const { payload } = outcome;
  return {
    title: "Echo — A mirror, not a label.",
    description: payload.reflection.text,
    openGraph: {
      title: "Echo — A mirror, not a label.",
      description: payload.reflection.text,
      url: payload.share_url,
      type: "article",
      images: [{ url: payload.portrait_png_url, width: 1080, height: 1080 }],
    },
    twitter: {
      card: "summary_large_image",
      title: "Echo — A mirror, not a label.",
      description: payload.reflection.text,
      images: [payload.portrait_png_url],
    },
    alternates: { canonical: payload.share_url },
  };
}

export default async function SharePage({ params }: { params: Params }) {
  const outcome = await fetchShare(params.token);

  if (outcome.kind === "not_found") {
    // Next's notFound() returns a 404 status — the right semantic for
    // a token that never existed.
    notFound();
  }
  if (outcome.kind === "revoked") {
    return (
      <main>
        <section className="error-page">
          <h1>This Portrait was taken down.</h1>
          <p className="muted">
            The person who shared it revoked the link. Portraits are
            opt-in and revocable at any time.
          </p>
          <p>
            <Link className="cta" href="https://echo.app">
              Download Echo
            </Link>
          </p>
        </section>
      </main>
    );
  }
  if (outcome.kind === "error") {
    return (
      <main>
        <section className="error-page">
          <h1>Something went wrong.</h1>
          <p className="muted">
            We couldn&rsquo;t load this Portrait right now. Try again in
            a moment.
          </p>
        </section>
      </main>
    );
  }

  const { payload } = outcome;
  return (
    <main>
      <article className="portrait-card">
        <picture>
          <source srcSet={payload.portrait_webp_url} type="image/webp" />
          <img
            src={payload.portrait_png_url}
            alt="Animated Portrait generated from this player's trait vector."
            width={1080}
            height={1080}
          />
        </picture>
        <p className="reflection">{payload.reflection.text}</p>
        <Link className="cta" href="https://echo.app">
          Download Echo
        </Link>
        <p className="muted">
          Echo is a 20-minute story-driven game that reflects who you
          tend to be back at you.
        </p>
      </article>
    </main>
  );
}
