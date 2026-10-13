import { describe, it, expect } from 'vitest';
import { resolveVerification, VerificationResult, Fetcher } from './verification';

const TOKEN = '0x7e573c3cdfb144d12abbc669f84c4bee045ac8e3';

function addressResponse(over: {
  verified?: unknown;
  standard?: unknown;
  unverified_lookalike?: unknown;
  shares_reserved_name?: unknown;
} = {}) {
  return {
    verified: over.verified ?? true,
    token: {
      standard: over.standard ?? 'erc20',
      unverified_lookalike: over.unverified_lookalike ?? false,
      shares_reserved_name: over.shares_reserved_name ?? false,
    },
  };
}

describe('resolveVerification', () => {
  it('resolves and caches a verified, standard-erc20, non-lookalike token', async () => {
    const cache: Record<string, VerificationResult> = {};
    const checkedAt: Record<string, number> = {};
    let calls = 0;
    const fetchFn: Fetcher = async () => {
      calls++;
      return { ok: true, json: async () => addressResponse() };
    };
    const result = await resolveVerification(TOKEN, cache, checkedAt, 1000, fetchFn);
    expect(result).toEqual({ verified: true, isErc20: true, lookalike: false });
    expect(cache[TOKEN]).toEqual({ verified: true, isErc20: true, lookalike: false });
    expect(checkedAt[TOKEN]).toBe(1000);
    // Second call within the TTL is served from cache.
    await resolveVerification(TOKEN, cache, checkedAt, 1500, fetchFn);
    expect(calls).toBe(1);
  });

  it('resolves an unverified token just as validly', async () => {
    const cache: Record<string, VerificationResult> = {};
    const checkedAt: Record<string, number> = {};
    const fetchFn: Fetcher = async () => ({ ok: true, json: async () => addressResponse({ verified: false }) });
    const result = await resolveVerification(TOKEN, cache, checkedAt, 0, fetchFn);
    expect(result).toEqual({ verified: false, isErc20: true, lookalike: false });
  });

  it('flags a token Arcscan does not classify as standard erc20', async () => {
    const cache: Record<string, VerificationResult> = {};
    const checkedAt: Record<string, number> = {};
    const fetchFn: Fetcher = async () => ({ ok: true, json: async () => addressResponse({ standard: 'erc721' }) });
    const result = await resolveVerification(TOKEN, cache, checkedAt, 0, fetchFn);
    expect(result?.isErc20).toBe(false);
  });

  it('flags an unverified lookalike', async () => {
    const cache: Record<string, VerificationResult> = {};
    const checkedAt: Record<string, number> = {};
    const fetchFn: Fetcher = async () => ({
      ok: true, json: async () => addressResponse({ unverified_lookalike: true }),
    });
    const result = await resolveVerification(TOKEN, cache, checkedAt, 0, fetchFn);
    expect(result?.lookalike).toBe(true);
  });

  it('flags a reserved-name squatter even when not marked an unverified lookalike', async () => {
    const cache: Record<string, VerificationResult> = {};
    const checkedAt: Record<string, number> = {};
    const fetchFn: Fetcher = async () => ({
      ok: true, json: async () => addressResponse({ shares_reserved_name: true }),
    });
    const result = await resolveVerification(TOKEN, cache, checkedAt, 0, fetchFn);
    expect(result?.lookalike).toBe(true);
  });

  it('treats a missing token sub-object as non-erc20 and non-lookalike, not a failure', async () => {
    const cache: Record<string, VerificationResult> = {};
    const checkedAt: Record<string, number> = {};
    const fetchFn: Fetcher = async () => ({ ok: true, json: async () => ({ verified: true }) });
    const result = await resolveVerification(TOKEN, cache, checkedAt, 0, fetchFn);
    expect(result).toEqual({ verified: true, isErc20: false, lookalike: false });
  });

  it('re-checks once the TTL has elapsed', async () => {
    const cache: Record<string, VerificationResult> = {
      [TOKEN]: { verified: false, isErc20: true, lookalike: false },
    };
    const checkedAt: Record<string, number> = { [TOKEN]: 0 };
    let calls = 0;
    const fetchFn: Fetcher = async () => {
      calls++;
      return { ok: true, json: async () => addressResponse() };
    };
    // Far past the 6h default TTL.
    const result = await resolveVerification(TOKEN, cache, checkedAt, 7 * 60 * 60 * 1000, fetchFn);
    expect(calls).toBe(1);
    expect(result?.verified).toBe(true);
  });

  it('returns undefined without caching on a non-ok response', async () => {
    const cache: Record<string, VerificationResult> = {};
    const checkedAt: Record<string, number> = {};
    const fetchFn: Fetcher = async () => ({ ok: false, json: async () => ({}) });
    const result = await resolveVerification(TOKEN, cache, checkedAt, 0, fetchFn);
    expect(result).toBeUndefined();
    expect(cache[TOKEN]).toBeUndefined();
  });

  it('returns undefined without caching when verified is not a boolean', async () => {
    const cache: Record<string, VerificationResult> = {};
    const checkedAt: Record<string, number> = {};
    const fetchFn: Fetcher = async () => ({ ok: true, json: async () => ({ verified: null }) });
    const result = await resolveVerification(TOKEN, cache, checkedAt, 0, fetchFn);
    expect(result).toBeUndefined();
    expect(cache[TOKEN]).toBeUndefined();
  });

  it('returns undefined without caching when the fetch throws', async () => {
    const cache: Record<string, VerificationResult> = {};
    const checkedAt: Record<string, number> = {};
    const fetchFn: Fetcher = async () => {
      throw new Error('network down');
    };
    const result = await resolveVerification(TOKEN, cache, checkedAt, 0, fetchFn);
    expect(result).toBeUndefined();
    expect(cache[TOKEN]).toBeUndefined();
  });

  it('uses the injected fetcher rather than the real network', async () => {
    const calledUrls: string[] = [];
    const fetchFn: Fetcher = async (url) => {
      calledUrls.push(url);
      return { ok: true, json: async () => addressResponse() };
    };
    await resolveVerification(TOKEN, {}, {}, 0, fetchFn);
    expect(calledUrls).toEqual([`https://api.arc-scan.org/v1/address/${TOKEN}`]);
  });
});
