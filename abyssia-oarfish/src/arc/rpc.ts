import { ARC_RPC_URL, ARC_RPC_URL_FALLBACK, ARC_RPC_TIMEOUT_MS } from './config';
import { RawLog } from './decode';

let idCounter = 1;

export function isRetryableHttp(status: number): boolean {
  return status === 429 || status === 503;
}

export function isSplittableError(message: string): boolean {
  // Range/result-size errors vary by provider: geth's "query returned more than
  // N results", "range too large", timeouts, response-size caps. Match broadly
  // so the adaptive split (the sole mitigation for the unfiltered sweep) engages.
  return /timed out|exceed|too many|more than|response size|results|block range|range is too large|limit of/i.test(
    message
  );
}

class RpcError extends Error {
  constructor(message: string, readonly rpcCode?: number) {
    super(message);
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

async function rpcCall<T>(
  url: string, method: string, params: unknown[], tries = 6
): Promise<T> {
  for (let attempt = 0; ; attempt++) {
    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: idCounter++, method, params }),
        // Fresh signal PER ATTEMPT — hoisting this out of the loop would carry an
        // already-aborted signal into every retry.
        signal: AbortSignal.timeout(ARC_RPC_TIMEOUT_MS),
      });
      if (isRetryableHttp(res.status)) {
        if (attempt >= tries - 1) throw new RpcError(`${method}: HTTP ${res.status}`);
        await sleep(500 * 2 ** attempt + Math.floor(Math.random() * 250));
        continue;
      }
      const json = (await res.json()) as { result?: T; error?: { message: string; code: number } };
      if (json.error) throw new RpcError(`${method}: ${json.error.message}`, json.error.code);
      return json.result as T;
    } catch (err) {
      if (err instanceof RpcError || attempt >= tries - 1) throw err;
      await sleep(500 * 2 ** attempt + Math.floor(Math.random() * 250));
    }
  }
}

async function blockNumberAt(url: string): Promise<number> {
  return Number(BigInt(await rpcCall<string>(url, 'eth_blockNumber', [])));
}

export interface LogFilter {
  address?: string[];
  topics: (string | null)[];
  fromBlock: number;
  toBlock: number;
}

async function getLogsAt(url: string, params: LogFilter): Promise<RawLog[]> {
  const filter: Record<string, unknown> = {
    topics: params.topics,
    fromBlock: '0x' + params.fromBlock.toString(16),
    toBlock: '0x' + params.toBlock.toString(16),
  };
  if (params.address) filter.address = params.address;
  try {
    return await rpcCall<RawLog[]>(url, 'eth_getLogs', [filter]);
  } catch (err) {
    if (
      err instanceof Error &&
      isSplittableError(err.message) &&
      params.toBlock > params.fromBlock
    ) {
      const mid = Math.floor((params.fromBlock + params.toBlock) / 2);
      const left = await getLogsAt(url, { ...params, toBlock: mid });
      const right = await getLogsAt(url, { ...params, fromBlock: mid + 1 });
      return left.concat(right);
    }
    throw err;
  }
}

async function callAt(url: string, to: string, data: string, from?: string): Promise<string> {
  return rpcCall<string>(url, 'eth_call', [from ? { to, data, from } : { to, data }, 'latest']);
}

// Every endpoint configured, in priority order. A blank ARC_RPC_URL_FALLBACK
// (unset, the common case) drops out here rather than being tried as "".
function rpcUrls(): string[] {
  return [ARC_RPC_URL, ARC_RPC_URL_FALLBACK].filter((u) => u.length > 0);
}

// Tries each configured endpoint in order, returning the first success. Each
// endpoint still gets its own full retry budget inside rpcCall/getLogsAt — this
// only steps to the next URL once the current one is truly exhausted, so a
// working primary never pays the fallback's latency. Not a smarter router
// between providers with different limits (see ARC_RPC_URL_FALLBACK's
// comment in config.ts) — just redundancy against one endpoint being down.
async function withFailover<T>(fn: (url: string) => Promise<T>): Promise<T> {
  const urls = rpcUrls();
  if (urls.length === 0) throw new Error('no ARC RPC endpoint configured');
  let lastErr: unknown;
  for (const url of urls) {
    try {
      return await fn(url);
    } catch (err) {
      lastErr = err;
    }
  }
  throw lastErr;
}

export async function blockNumber(): Promise<number> {
  return withFailover((url) => blockNumberAt(url));
}

export async function getLogs(params: LogFilter): Promise<RawLog[]> {
  return withFailover((url) => getLogsAt(url, params));
}

export async function call(to: string, data: string, from?: string): Promise<string> {
  return withFailover((url) => callAt(url, to, data, from));
}
