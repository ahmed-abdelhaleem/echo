import Link from "next/link";

/**
 * Landing page. share-web is primarily resolved as /share/[token];
 * the root path explains what the site is and links to echo.app for
 * the download CTA.
 */
export default function Home() {
  return (
    <main>
      <section className="error-page">
        <h1>Echo</h1>
        <p className="muted">A mirror, not a label.</p>
        <p>
          Echo shows you who you tend to be, through play. If you landed
          here looking for someone&rsquo;s Portrait, you need the full
          share link — it&rsquo;ll look something like{" "}
          <code>/share/&lt;token&gt;</code>.
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
