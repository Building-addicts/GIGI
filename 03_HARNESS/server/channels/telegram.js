// channels/telegram.js
// Telegram channel adapter.
// Handles webhook receipt, OGG voice download, STT, agent routing, text/voice reply.
//
// Setup:
//   1. Set cfg.telegram.bot_token in config.json
//   2. Register webhook: POST https://api.telegram.org/bot<TOKEN>/setWebhook?url=<HTTPS_URL>/api/channels/telegram
//   3. Requires ffmpeg on PATH for audio normalization.

import { createHmac } from 'node:crypto';

const TELEGRAM_API = 'https://api.telegram.org';

// MARK: - Webhook handler

export const name = 'telegram';

/**
 * POST /api/channels/telegram
 */
export async function handleWebhook(req, res, deps) {
  const { readBody, sendJson, cfg, gigiServer, stt, tts, userMapper, log } = deps;

  // Acknowledge immediately — Telegram retries on timeout
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end('{"ok":true}');

  let body;
  try { body = JSON.parse(await readBody(req) || '{}'); }
  catch { return log('[telegram] bad JSON'); }

  const token = cfg.telegram?.bot_token;
  if (!token) return log('[telegram] bot_token not configured');

  // Handle inbound message
  const message = body.message || body.edited_message;
  const callbackQuery = body.callback_query;

  if (callbackQuery) {
    await handleCallbackQuery(callbackQuery, { token, cfg, gigiServer, stt, tts, userMapper, log });
    return;
  }

  if (!message) return;

  const chatId = String(message.chat?.id || '');
  const fromId = String(message.from?.id || '');
  if (!chatId || !fromId) return;

  const { deviceId } = userMapper.getOrCreateUser('telegram', fromId);

  if (message.voice) {
    await handleVoiceMessage(message, { chatId, deviceId, token, cfg, gigiServer, stt, tts, log });
  } else if (message.text) {
    await handleTextMessage(message, { chatId, deviceId, token, cfg, gigiServer, log });
  }
}

// MARK: - Voice message

async function handleVoiceMessage(message, { chatId, deviceId, token, cfg, gigiServer, stt, tts, log }) {
  const fileId = message.voice.file_id;

  let audioBuffer;
  try {
    audioBuffer = await downloadFile(fileId, token);
  } catch (e) {
    log(`[telegram] voice download failed: ${e.message}`);
    await sendText(chatId, "Sorry, I couldn't download that voice note. Try again.", token);
    return;
  }

  let transcript;
  try {
    const groqApiKey = cfg.groq?.api_key || cfg.groq?.key;
    const openaiKey  = cfg.openai?.api_key;
    const result = await stt.transcribe(audioBuffer, 'audio/ogg', { groqApiKey, apiKey: openaiKey });
    transcript = result.transcript;
    log(`[telegram] STT: "${transcript.slice(0, 100)}"`);
  } catch (e) {
    log(`[telegram] STT failed: ${e.message}`);
    await sendText(chatId, "I couldn't transcribe that. Could you try again or type your message?", token);
    return;
  }

  if (!transcript) {
    await sendText(chatId, "I didn't catch any speech. Could you try again?", token);
    return;
  }

  await runAgentAndReply(transcript, { chatId, deviceId, token, cfg, gigiServer, tts, log, withVoice: true });
}

// MARK: - Text message

async function handleTextMessage(message, { chatId, deviceId, token, cfg, gigiServer, log }) {
  const text = (message.text || '').trim();
  if (!text || text.startsWith('/')) return;   // ignore commands

  await runAgentAndReply(text, { chatId, deviceId, token, cfg, gigiServer, tts: null, log, withVoice: false });
}

// MARK: - Agent + reply

async function runAgentAndReply(text, { chatId, deviceId, token, cfg, gigiServer, tts, log, withVoice }) {
  let result;
  try {
    result = await gigiServer.runClaude(cfg, text, deviceId, null, null, { domain: null, schema: null });
  } catch (e) {
    log(`[telegram] agent error: ${e.message}`);
    await sendText(chatId, "Something went wrong on my end. Try again in a moment.", token);
    return;
  }

  const reply = result?.result || result?.text || 'Done.';

  // Check if agent returned a confirmation request
  if (reply.startsWith('CONFIRM_REQUIRED:')) {
    const summary = reply.replace('CONFIRM_REQUIRED:', '').trim();
    await sendConfirmRequest(chatId, summary, token);
    return;
  }

  await sendText(chatId, reply, token);

  // Optionally send voice reply for voice input
  if (withVoice && tts && cfg.openai?.api_key) {
    try {
      const audio = await tts.synthesize(reply, { apiKey: cfg.openai.api_key, format: 'ogg_opus' });
      await sendVoice(chatId, audio, token);
    } catch (e) {
      log(`[telegram] TTS failed (text sent ok): ${e.message}`);
    }
  }
}

// MARK: - Confirmation (inline keyboard)

async function handleCallbackQuery(query, { token, cfg, gigiServer, stt, tts, userMapper, log }) {
  const chatId = String(query.message?.chat?.id || '');
  const fromId = String(query.from?.id || '');
  const data = query.data || '';

  await fetch(`${TELEGRAM_API}/bot${token}/answerCallbackQuery`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ callback_query_id: query.id }),
  }).catch(() => {});

  if (!chatId || !fromId) return;

  if (data === 'confirm_yes') {
    const { deviceId } = userMapper.getOrCreateUser('telegram', fromId);
    await runAgentAndReply('yes, confirmed', { chatId, deviceId, token, cfg, gigiServer, tts, log, withVoice: false });
  } else if (data === 'confirm_no') {
    await sendText(chatId, 'Cancelled.', token);
  }
}

async function sendConfirmRequest(chatId, summary, token) {
  await fetch(`${TELEGRAM_API}/bot${token}/sendMessage`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      chat_id: chatId,
      text: `⚠️ ${summary}\n\nProceed?`,
      reply_markup: {
        inline_keyboard: [[
          { text: '✅ Yes', callback_data: 'confirm_yes' },
          { text: '❌ No',  callback_data: 'confirm_no'  },
        ]],
      },
    }),
  }).catch((e) => console.error('[telegram] sendConfirmRequest failed:', e.message));
}

// MARK: - Telegram API helpers

async function downloadFile(fileId, token) {
  const infoResp = await fetch(`${TELEGRAM_API}/bot${token}/getFile?file_id=${fileId}`);
  if (!infoResp.ok) throw new Error(`getFile ${infoResp.status}`);
  const info = await infoResp.json();
  const filePath = info.result?.file_path;
  if (!filePath) throw new Error('getFile: no file_path');

  const fileResp = await fetch(`${TELEGRAM_API}/file/bot${token}/${filePath}`);
  if (!fileResp.ok) throw new Error(`file download ${fileResp.status}`);
  return Buffer.from(await fileResp.arrayBuffer());
}

async function sendText(chatId, text, token) {
  await fetch(`${TELEGRAM_API}/bot${token}/sendMessage`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: chatId, text }),
  }).catch((e) => console.error('[telegram] sendText failed:', e.message));
}

async function sendVoice(chatId, audioBuffer, token) {
  const form = new FormData();
  form.append('chat_id', String(chatId));
  form.append('voice', new Blob([audioBuffer], { type: 'audio/ogg' }), 'reply.ogg');
  await fetch(`${TELEGRAM_API}/bot${token}/sendVoice`, {
    method: 'POST',
    body: form,
  }).catch((e) => console.error('[telegram] sendVoice failed:', e.message));
}
