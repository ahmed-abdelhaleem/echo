import type { Metadata } from 'next';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { fetchCompare } from '@/lib/api';

type Params = { token: string };

export async function generateMetadata({
  params,
}: {
  params: Params;
}): Promise<Metadata> {
  const outcome = await fetchCompare(params.token);
  if (outcome.kind !== 'ok') {
    return {
      title: outcome.kind === 'revoked' ? 'Echo — comparison unavailable' : 'Echo',
      robots: { index: false, follow: false },
    };
  }

  const { payload } = outcome;
  const title = 'Echo — Friend comparison';
  const description =
    'Two portraits, one divergence moment. A side-by-side mirror of your choices.';

  return {
    title,
    description,
    openGraph: {
      title,
      description,
      type: 'article',
      images: [{ url: payload.inviter_png_url, width: 1080, height: 1080 }],
    },
    twitter: {
      card: 'summary_large_image',
      title,
      description,
      images: [payload.inviter_png_url],
    },
  };
}

export default async function ComparePage({ params }: { params: Params }) {
  const outcome = await fetchCompare(params.token);

  if (outcome.kind === 'not_found') {
    notFound();
  }

  if (outcome.kind === 'revoked') {
    return (
      <main>
        <section className='error-page'>
          <h1>This comparison link is unavailable.</h1>
          <p className='muted'>
            The link was revoked or has expired. Comparison sharing is always opt-in
            and revocable.
          </p>
          <p>
            <Link className='cta' href='https://echo.app'>
              Download Echo
            </Link>
          </p>
        </section>
      </main>
    );
  }

  if (outcome.kind === 'error') {
    return (
      <main>
        <section className='error-page'>
          <h1>Something went wrong.</h1>
          <p className='muted'>
            We couldn&apos;t load this comparison right now. Try again shortly.
          </p>
        </section>
      </main>
    );
  }

  const { payload } = outcome;
  return (
    <main>
      <article className='portrait-card'>
        <h1>Friend comparison</h1>
        <section className='compare-grid'>
          <figure>
            <img src={payload.inviter_png_url} alt='Inviter portrait.' width={1080} height={1080} />
            <figcaption className='muted'>Inviter</figcaption>
          </figure>
          <figure>
            <img src={payload.invitee_png_url} alt='Invitee portrait.' width={1080} height={1080} />
            <figcaption className='muted'>Invitee</figcaption>
          </figure>
        </section>

        <section className='reflection'>
          <strong>Divergence moment:</strong>{' '}
          <span>{payload.divergence.vignette_id}</span>
          <br />
          <span>Inviter choice: {payload.divergence.inviter_choice}</span>
          <br />
          <span>Invitee choice: {payload.divergence.invitee_choice}</span>
        </section>

        <Link className='cta' href='https://echo.app'>
          Download Echo
        </Link>
      </article>
    </main>
  );
}

