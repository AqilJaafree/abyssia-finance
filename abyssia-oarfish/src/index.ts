import http from 'http';
import fs from 'fs';
import { logger } from './logger';
import { initMovers, moversCycle } from './arc/worker';
import { initMoversV4, moversCycleV4 } from './arc/v4/worker';
import { startCommandResponder } from './telegram/sender';
import { arcV3Enabled, arcV4Enabled } from './flags';
import { ARC_RPC_URL, POLL_SECONDS } from './arc/config';
import { V4_POLL_SECONDS } from './arc/v4/config';
import { loadStrategy } from './strategy';

if (process.argv.includes('--dry-run')) {
  logger.info('dry-run: startup OK');
  process.exit(0);
}

if (!process.env.RAILWAY_ENVIRONMENT) {
  fs.mkdirSync('./tmp', { recursive: true });
}

const dataDir = process.env.RAILWAY_ENVIRONMENT ? '/data' : './tmp';

const port = parseInt(process.env.PORT ?? '3000', 10);
const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200);
    res.end('ok');
  } else {
    res.writeHead(404);
    res.end();
  }
});
server.listen(port, () => logger.info({ port }, 'health server listening'));

// Deployed env only — a single poller per bot token, so local dev never
// hijacks production's updates.
if (process.env.RAILWAY_ENVIRONMENT) startCommandResponder();

// Neither board can do anything useful without a real RPC endpoint — there is
// no public default for Arc (see arc/config.ts). Refuse loudly rather than
// starting a loop that will fail every single cycle.
// The signal strategy has no in-code defaults (see strategy.ts) — same
// refusal. Only the offending key NAMES are logged, never their values.
const strategyResult = loadStrategy();

if (!ARC_RPC_URL) {
  logger.error(
    'ARC_RPC_URL is not set — the v3 and v4 movers boards cannot start. ' +
      'Health check will still respond so the deploy does not flap; set ARC_RPC_URL and redeploy.'
  );
} else if (!strategyResult.ok) {
  logger.error(
    { invalid: strategyResult.invalid },
    'strategy env is missing or invalid — the v3 and v4 movers boards cannot start. ' +
      'Health check will still respond; set the STRATEGY_* vars and redeploy.'
  );
} else {
  const { strategy } = strategyResult;
  if (arcV3Enabled()) {
    const moversFile = `${dataDir}/movers.json`;
    initMovers(moversFile, strategy);
    moversCycle();
    setInterval(moversCycle, POLL_SECONDS * 1000);
  } else {
    logger.info('movers: v3 board disabled by ARC_V3_ENABLED, not starting the loop');
  }

  if (arcV4Enabled()) {
    const moversV4File = `${dataDir}/movers-v4.json`;
    initMoversV4(moversV4File, strategy);
    moversCycleV4();
    setInterval(moversCycleV4, V4_POLL_SECONDS * 1000);
  } else {
    logger.info('movers-v4: v4 board disabled by ARC_V4_ENABLED, not starting the loop');
  }
}
