import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { isRetryableHttp, isSplittableError } from './rpc';

describe('isRetryableHttp', () => {
  it('treats 429 and 503 as retryable', () => {
    expect(isRetryableHttp(429)).toBe(true);
    expect(isRetryableHttp(503)).toBe(true);
    expect(isRetryableHttp(500)).toBe(false);
    expect(isRetryableHttp(200)).toBe(false);
  });
});

describe('isSplittableError', () => {
  it('matches range/result-size error messages', () => {
    expect(isSplittableError('query returned more than 10000 results')).toBe(true);
    expect(isSplittableError('block range is too large')).toBe(true);
    expect(isSplittableError('request timed out')).toBe(true);
    expect(isSplittableError('logs matched by query exceeds limit of 10000')).toBe(true);
  });
  it('does not match an unrelated error', () => {
    expect(isSplittableError('insufficient funds')).toBe(false);
  });
});

describe('blockNumber / getLogs / call', () => {
  const originalFetch = global.fetch;

  beforeEach(() => {
    process.env.ARC_RPC_URL = 'https://example.invalid/rpc';
    delete process.env.ARC_RPC_URL_FALLBACK;
  });

  afterEach(() => {
    global.fetch = originalFetch;
    delete process.env.ARC_RPC_URL_FALLBACK;
    vi.resetModules();
  });

  it('blockNumber decodes a hex result to a number', async () => {
    global.fetch = vi.fn().mockResolvedValue({
      status: 200,
      json: async () => ({ result: '0x2a' }),
    }) as unknown as typeof fetch;
    vi.resetModules();
    const { blockNumber } = await import('./rpc');
    expect(await blockNumber()).toBe(42);
  });

  it('call posts eth_call with to/data', async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      status: 200,
      json: async () => ({ result: '0xdeadbeef' }),
    });
    global.fetch = fetchMock as unknown as typeof fetch;
    vi.resetModules();
    const { call } = await import('./rpc');
    const result = await call('0xpool', '0x3850c7bd');
    expect(result).toBe('0xdeadbeef');
    const body = JSON.parse((fetchMock.mock.calls[0][1] as RequestInit).body as string);
    expect(body.method).toBe('eth_call');
    expect(body.params[0]).toEqual({ to: '0xpool', data: '0x3850c7bd' });
  });

  it('getLogs splits a range-too-large error into two sub-ranges', async () => {
    let call = 0;
    global.fetch = vi.fn().mockImplementation(async () => {
      call++;
      if (call === 1) {
        return { status: 200, json: async () => ({ error: { message: 'block range is too large', code: -32000 } }) };
      }
      return { status: 200, json: async () => ({ result: [] }) };
    }) as unknown as typeof fetch;
    vi.resetModules();
    const { getLogs } = await import('./rpc');
    const logs = await getLogs({ topics: ['0xtopic'], fromBlock: 1, toBlock: 3 });
    expect(logs).toEqual([]);
    // 1 failed full-range call + 2 successful half-range calls
    expect(call).toBe(3);
  });

  it('falls back to a second endpoint when the primary is exhausted', async () => {
    process.env.ARC_RPC_URL_FALLBACK = 'https://fallback.invalid/rpc';
    global.fetch = vi.fn().mockImplementation(async (url: unknown) => {
      // A JSON-RPC application error (not an HTTP status) throws immediately
      // with no retry inside rpcCall, so the primary "fails" fast here.
      if (url === 'https://example.invalid/rpc') {
        return { status: 200, json: async () => ({ error: { message: 'primary unavailable', code: -32000 } }) };
      }
      return { status: 200, json: async () => ({ result: '0x2a' }) };
    }) as unknown as typeof fetch;
    vi.resetModules();
    const { blockNumber } = await import('./rpc');
    expect(await blockNumber()).toBe(42);
  });

  it('never calls the fallback while the primary is healthy', async () => {
    process.env.ARC_RPC_URL_FALLBACK = 'https://fallback.invalid/rpc';
    const calledUrls: unknown[] = [];
    global.fetch = vi.fn().mockImplementation(async (url: unknown) => {
      calledUrls.push(url);
      return { status: 200, json: async () => ({ result: '0x2a' }) };
    }) as unknown as typeof fetch;
    vi.resetModules();
    const { blockNumber } = await import('./rpc');
    expect(await blockNumber()).toBe(42);
    expect(calledUrls).toEqual(['https://example.invalid/rpc']);
  });

  it('throws when no RPC endpoint is configured at all', async () => {
    delete process.env.ARC_RPC_URL;
    vi.resetModules();
    const { blockNumber } = await import('./rpc');
    await expect(blockNumber()).rejects.toThrow('no ARC RPC endpoint configured');
  });
});
