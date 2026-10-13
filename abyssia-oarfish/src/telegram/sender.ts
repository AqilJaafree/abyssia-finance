import TelegramBot from 'node-telegram-bot-api';
import { MoversBoard } from '../types';
import {
  formatMoversBoard, formatMoversBoardV4, formatDangerZoneBoard, formatHelpMessage,
} from './format';
import { logger } from '../logger';

// Must be sent explicitly on every getUpdates — Telegram remembers the last
// allowed_updates set for a bot token and reuses it when the field is omitted.
// This bot only ever needs plain messages (for /help), never callback_query.
export const ALLOWED_UPDATES = ['message'] as const;

const bot = new TelegramBot(process.env.TELEGRAM_BOT_TOKEN!, {
  polling: {
    autoStart: false,
    params: {
      allowed_updates: JSON.stringify(ALLOWED_UPDATES) as unknown as string[],
    },
  },
});
const chatId = process.env.TELEGRAM_CHAT_ID!;
const v3TopicId = process.env.V3_MOVERS_TOPIC_ID;
const v4TopicId = process.env.V4_MOVERS_TOPIC_ID;
const dangerZoneTopicId = process.env.DANGER_ZONE_TOPIC_ID;

let commandResponderStarted = false;

export function startCommandResponder(): void {
  if (commandResponderStarted) return;
  if (!process.env.TELEGRAM_BOT_TOKEN) {
    logger.warn('telegram: no bot token, /help responder not started');
    return;
  }
  commandResponderStarted = true;
  bot.startPolling();
  bot
    .setMyCommands([{ command: 'help', description: 'How to read the Top Movers boards' }])
    .catch((err) => logger.warn({ err }, 'telegram: setMyCommands failed'));
  bot.onText(/^\/help(@\w+)?\s*$/, (msg) => {
    const options: TelegramBot.SendMessageOptions = {
      parse_mode: 'HTML',
      disable_web_page_preview: true,
    };
    if (msg.message_thread_id) options.message_thread_id = msg.message_thread_id;
    bot
      .sendMessage(msg.chat.id, formatHelpMessage(), options)
      .then(() => logger.info({ chat: msg.chat.id }, 'telegram: /help replied'))
      .catch((err) => logger.error({ err }, 'telegram: /help reply failed'));
  });
  bot.on('polling_error', (err) => logger.warn({ err: err.message }, 'telegram: polling error'));
  logger.info('telegram: /help command responder started');
}

export async function sendMoversBoard(board: MoversBoard): Promise<void> {
  const message = formatMoversBoard(board);
  const options: TelegramBot.SendMessageOptions = {
    parse_mode: 'HTML',
    disable_web_page_preview: true,
  };
  if (v3TopicId) options.message_thread_id = Number(v3TopicId);
  try {
    await bot.sendMessage(chatId, message, options);
    logger.info({ rows: board.rows.length, block: board.block }, 'telegram: v3 board sent');
  } catch (err) {
    logger.error({ err }, 'telegram: v3 board send failed');
    throw err;
  }
}

export async function sendMoversBoardV4(board: MoversBoard): Promise<void> {
  const message = formatMoversBoardV4(board);
  const options: TelegramBot.SendMessageOptions = {
    parse_mode: 'HTML',
    disable_web_page_preview: true,
  };
  if (v4TopicId) options.message_thread_id = Number(v4TopicId);
  try {
    await bot.sendMessage(chatId, message, options);
    logger.info({ rows: board.rows.length, block: board.block }, 'telegram: v4 board sent');
  } catch (err) {
    logger.error({ err }, 'telegram: v4 board send failed');
    throw err;
  }
}

async function sendDangerZoneBoard(board: MoversBoard): Promise<void> {
  const message = formatDangerZoneBoard(board);
  const options: TelegramBot.SendMessageOptions = {
    parse_mode: 'HTML',
    disable_web_page_preview: true,
  };
  if (dangerZoneTopicId) options.message_thread_id = Number(dangerZoneTopicId);
  try {
    await bot.sendMessage(chatId, message, options);
    logger.info(
      { rows: board.rows.length, block: board.block, label: board.label },
      'telegram: danger-zone board sent'
    );
  } catch (err) {
    logger.error({ err, label: board.label }, 'telegram: danger-zone send failed');
    throw err;
  }
}

// Swallows any send failure — the Danger Zone topic is shared by both board
// loops, and a caller's cursor advance must not be blocked by this failing:
// the main board has already posted by the time this runs, and leaving the
// cursor put would re-sweep the window next cycle and post the main board a
// SECOND time. Ported from nautilus's postDangerZoneBoard, same rationale.
export async function postDangerZoneBoard(board: MoversBoard): Promise<void> {
  try {
    await sendDangerZoneBoard(board);
  } catch {
    /* already logged by the sender */
  }
}
