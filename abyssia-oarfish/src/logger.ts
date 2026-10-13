import pino from 'pino';

// Defense-in-depth: even though the LP flow never logs a key on purpose, censor
// these field names (and one level of nesting) so a stray `{ ...obj }` log can't
// leak a private key / master secret to any sink. See PRE-LAUNCH-GATE (M4).
export const REDACT_PATHS = [
  'privateKey', 'pk', 'masterKey', 'mnemonic', 'secret',
  '*.privateKey', '*.pk', '*.masterKey', '*.mnemonic', '*.secret',
];

export const logger = pino({
  level: process.env.LOG_LEVEL ?? 'info',
  redact: { paths: REDACT_PATHS, censor: '[REDACTED]' },
});
