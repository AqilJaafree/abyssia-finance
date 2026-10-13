import { describe, it, expect, vi } from 'vitest';

const ctor = vi.fn();
const sendMessageMock = vi.fn().mockResolvedValue({ message_id: 1 });

vi.mock('node-telegram-bot-api', () => ({
  default: class {
    constructor(token: string, options?: unknown) {
      ctor(token, options);
    }
    startPolling = vi.fn();
    setMyCommands = vi.fn().mockResolvedValue(undefined);
    onText = vi.fn();
    on = vi.fn();
    sendMessage = sendMessageMock;
  },
}));

async function loadSender() {
  ctor.mockClear();
  sendMessageMock.mockClear();
  vi.resetModules();
  process.env.TELEGRAM_BOT_TOKEN = 'test-token';
  process.env.TELEGRAM_CHAT_ID = '-100';
  process.env.V3_MOVERS_TOPIC_ID = '10';
  process.env.V4_MOVERS_TOPIC_ID = '20';
  process.env.DANGER_ZONE_TOPIC_ID = '30';
  return import('./sender');
}

describe('bot construction', () => {
  it('does not start polling merely by being imported', async () => {
    await loadSender();
    const [, options] = ctor.mock.calls[0] as [string, { polling?: { autoStart?: boolean } }];
    expect(options?.polling?.autoStart).toBe(false);
  });
});

describe('sendMoversBoard / sendMoversBoardV4', () => {
  it('posts to the v3 topic', async () => {
    const { sendMoversBoard } = await loadSender();
    await sendMoversBoard({ rows: [], block: 1, fromBlock: 1 });
    const [, , options] = sendMessageMock.mock.calls[0];
    expect(options.message_thread_id).toBe(10);
  });

  it('posts to the v4 topic', async () => {
    const { sendMoversBoardV4 } = await loadSender();
    await sendMoversBoardV4({ rows: [], block: 1, fromBlock: 1 });
    const [, , options] = sendMessageMock.mock.calls[0];
    expect(options.message_thread_id).toBe(20);
  });
});

describe('postDangerZoneBoard', () => {
  it('posts to the shared danger zone topic', async () => {
    const { postDangerZoneBoard } = await loadSender();
    await postDangerZoneBoard({ rows: [], block: 1, fromBlock: 1, variant: 'danger', label: 'Uniswap v3' });
    const [, , options] = sendMessageMock.mock.calls[0];
    expect(options.message_thread_id).toBe(30);
  });

  it('swallows a send failure rather than throwing', async () => {
    sendMessageMock.mockRejectedValueOnce(new Error('network down'));
    const { postDangerZoneBoard } = await loadSender();
    await expect(
      postDangerZoneBoard({ rows: [], block: 1, fromBlock: 1, variant: 'danger', label: 'Uniswap v4' })
    ).resolves.toBeUndefined();
  });
});
