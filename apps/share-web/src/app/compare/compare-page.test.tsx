// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import ComparePage, { generateMetadata } from './[token]/page';
import type { ComparePayload } from '@/lib/api';

const PAYLOAD: ComparePayload = {
  season_id: 'season-001',
  status: 'accepted',
  divergence: {
    vignette_id: 'vignette-009',
    inviter_choice: 'choice-a',
    invitee_choice: 'choice-b',
  },
  inviter_png_url: 'https://api.echo.test/compare/tok-aaa/portrait?side=inviter',
  invitee_png_url: 'https://api.echo.test/compare/tok-aaa/portrait?side=invitee',
};

vi.mock('@/lib/api', () => ({
  fetchCompare: vi.fn(),
  apiBaseURL: () => 'https://api.echo.test',
}));

import { fetchCompare } from '@/lib/api';
const mockedFetchCompare = vi.mocked(fetchCompare);

vi.mock('next/navigation', () => ({
  notFound: () => {
    throw new Error('NEXT_NOT_FOUND');
  },
}));

beforeEach(() => {
  mockedFetchCompare.mockReset();
});

async function renderPage() {
  const ui = await ComparePage({ params: { token: 'tok-aaa' } });
  render(ui as React.ReactElement);
}

describe('ComparePage', () => {
  it('renders two portraits and divergence details', async () => {
    mockedFetchCompare.mockResolvedValueOnce({ kind: 'ok', payload: PAYLOAD });
    await renderPage();

    expect(screen.getByText(/friend comparison/i)).toBeInTheDocument();
    const imgs = screen.getAllByRole('img');
    expect(imgs.length).toBe(2);
    expect(screen.getByText(/divergence moment/i)).toBeInTheDocument();
    expect(screen.getByText(/vignette-009/i)).toBeInTheDocument();
  });

  it('renders unavailable message when revoked', async () => {
    mockedFetchCompare.mockResolvedValueOnce({ kind: 'revoked' });
    await renderPage();
    expect(screen.getByText(/comparison link is unavailable/i)).toBeInTheDocument();
  });

  it('throws NEXT_NOT_FOUND on not_found', async () => {
    mockedFetchCompare.mockResolvedValueOnce({ kind: 'not_found' });
    await expect(ComparePage({ params: { token: 'missing' } })).rejects.toThrow(
      /NEXT_NOT_FOUND/,
    );
  });
});

describe('ComparePage metadata', () => {
  it('returns noindex metadata on revoked outcome', async () => {
    mockedFetchCompare.mockResolvedValueOnce({ kind: 'revoked' });
    const meta = await generateMetadata({ params: { token: 'tok-aaa' } });
    expect(meta.robots).toEqual({ index: false, follow: false });
  });
});

