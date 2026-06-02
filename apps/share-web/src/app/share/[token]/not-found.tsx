import Link from "next/link";

/**
 * 404 for /share/[token] when the token doesn't exist. Distinct from
 * the revoked-link page (which lives inline in page.tsx because it
 * carries 200 OK + an explanatory copy).
 */
export default function ShareNotFound() {
  return (
    <main>
      <section className="error-page">
        <h1>This share link doesn&rsquo;t exist.</h1>
        <p className="muted">Double-check the URL.</p>
        <p>
          <Link className="cta" href="https://echo.app">
            Download Echo
          </Link>
        </p>
      </section>
    </main>
  );
}
