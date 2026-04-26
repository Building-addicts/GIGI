// channels/whatsapp.js
// WhatsApp Business Cloud API adapter.
// Handles webhook verification, media download, STT, agent routing, text/audio reply.
//
// Setup:
//   1. Configure Meta Business: app_id, phone_number_id, access_token, verify_token
//   2. Set cfg.whatsapp.* in config.json
//   3. Register webhook in Meta Developer Console pointing to <HTTPS_URL>/api/channels/whatsapp
//   4. Subscribe to 'messages' webhook field

import { createHmac } from 'node:crypto';

const GRAPH_API = 'https://graph.facebook.com/v19.0';

export const name = 'whatsapp';

// MARK: - Webhook verification (GET)

export async function handleVerification(req, res, deps) {
  const { cfg } = deps;
  const urlObj = new URL(req.url, `http://${req.headers.host}`);
  const mode      = urlObj.searchParams.get('hub.mode');
  const token     = urlObj.searchParams.get('hub.verify_token');
  const challenge = urlObj.searchParams.get('hub.challenge');

  if (mode === 'subscribe' && token === cfg.whatsapp?.verify_token) {
    res.writeHead(200); res.end(challenge);
  } else {
    res.writeHead(403); res.end('Forbidden');
  }
}

// MARK: - Webhook handler (POST)

export async function handleWebhook(req, res, deps) {
  const { readBody, cfg, gigiServer, stt, tts, userMapper, log } = deps;

  // Acknowledge immediately — Meta retries on non-200
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end('{"ok":true}');

  let rawBody;
  try { rawBody = await readBody(req); }
  catch { return; }

  // Verify signature
  const sig = req.headers['x-hub-signature-256'] || '';
  if (cfg.whatsapp?.app_secret && !verifySignature(rawBody, cfg.whatsapp.app_secret, sig)) {
    log('[whatsapp] signature mismatch — ignoring');
    return;
  }

  let body;
  try { body = JSON.parse(rawBody || '{}'); }
  catch { return; }

  // Parse messages
  const entries = body.entry || [];
  for (const entry of entries) {
    for (const change of entry.changes || []) {
      const value = change.value || {};
      for (const message of value.messages || []) {
        await handleMessage(message, value.metadata, { cfg, gigiServer, stt, tts, userMapper, log });
      }
    }
  }
}

// MARK: - Message dispatch

async function handleMessage(message, metadata, { cfg, gigiServer, stt, tts, userMapper, log }) {
  const from = message.from;  // E.164 phone number
  const token = cfg.whatsapp?.access_token;
  const phoneNumberId = metadata?.phone_number_id || cfg.whatsapp?.phone_number_id;

  if (!from || !token || !phoneNumberId) return;

  const { deviceId } = userMapper.getOrCreateUser('whatsapp', from);

  if (message.type === 'audio') {
    await handleAudio(message, { from, deviceId, token, phoneNumberId, cfg, gigiServer, stt, tts, log });
  } else if (message.type === 'text') {
    const text = message.text?.body?.trim() || '';
    if (text) await runAgentAndReply(text, { from, deviceId, token, phoneNumberId, cfg, gigiServer, tts, log, withAudio: false });
  } else if (message.type === 'interactive') {
    // Reply button response (confirmation)
    const reply = message.interactive?.button_reply;
    if (reply?.id === 'confirm_yes') {
      await runAgentAndReply('yes, confirmed', { from, deviceId, token, phoneNumberId, cfg, gigiServer, tts, log, withAudio: false });
    } else if (reply?.id === 'confirm_no') {
      await sendTextReply(from, 'Cancelled.', phoneNumberId, token);
    }
  }
}

// MARK: - Audio handling

async function handleAudio(message, { from, deviceId, token, phoneNumberId, cfg, gigiServer, stt, tts, log }) {
  const mediaId = message.audio?.id;
  if (!mediaId) return;

  let audioBuffer;
  try {
    audioBuffer = await downloadMedia(mediaId, token);
  } catch (e) {
    log(`[whatsapp] media download failed: ${e.message}`);
    await sendTextReply(from, "Sorry, I couldn't download that audio. Try again.", phoneNumberId, token);
    return;
  }

  let transcript;
  try {
    const groqApiKey = cfg.groq?.api_key || cfg.groq?.key;
    const openaiKey  = cfg.openai?.api_key;
    const result = await stt.transcribe(audioBuffer, 'audio/ogg', { groqApiKey, apiKey: openaiKey });
    transcript = result.transcript;
    log(`[whatsapp] STT: "${transcript.slice(0, 100)}"`);
  } catch (e) {
    log(`[whatsapp] STT failed: ${e.message}`);
    await sendTextReply(from, "I couldn't transcribe that audio. Please try typing your message.", phoneNumberId, token);
    return;
  }

  if (!transcript) {
    await sendTextReply(from, "I didn't catch any speech. Could you try again?", phoneNumberId, token);
    return;
  }

  await runAgentAndReply(transcript, { from, deviceId, token, phoneNumberId, cfg, gigiServer, tts, log, withAudio: true });
}

// MARK: - Agent + reply

async function runAgentAndReply(text, { from, deviceId, token, phoneNumberId, cfg, gigiServer, tts, log, withAudio }) {
  let result;
  try {
    result = await gigiServer.runClaude(cfg, text, deviceId, null, null, { domain: null, schema: null });
  } catch (e) {
    log(`[whatsapp] agent error: ${e.message}`);
    await sendTextReply(from, 'Something went wrong. Try again in a moment.', phoneNumberId, token);
    return;
  }

  const reply = result?.result || result?.text || 'Done.';

  if (reply.startsWith('CONFIRM_REQUIRED:')) {
    const summary = reply.replace('CONFIRM_REQUIRED:', '').trim();
    await sendConfirmButtons(from, summary, phoneNumberId, token);
    return;
  }

  await sendTextReply(from, reply, phoneNumberId, token);

  if (withAudio && tts && cfg.openai?.api_key) {
    try {
      const audioBuffer = await tts.synthesize(reply, { apiKey: cfg.openai.api_key, format: 'mp3' });
      await sendAudioReply(from, audioBuffer, phoneNumberId, token);
    } catch (e) {
      log(`[whatsapp] TTS failed (text sent ok): ${e.message}`);
    }
  }
}

// MARK: - WhatsApp API helpers

function verifySignature(rawBody, appSecret, sigHeader) {
  const expected = 'sha256=' + createHmac('sha256', appSecret).update(rawBody).digest('hex');
  return sigHeader === expected;
}

async function downloadMedia(mediaId, token) {
  // Step 1: get media URL
  const infoResp = await fetch(`${GRAPH_API}/${mediaId}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!infoResp.ok) throw new Error(`media info ${infoResp.status}`);
  const info = await infoResp.json();
  const mediaUrl = info.url;
  if (!mediaUrl) throw new Error('no media URL');

  // Step 2: download media (expires in ~5 min — must be immediate)
  const mediaResp = await fetch(mediaUrl, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!mediaResp.ok) throw new Error(`media download ${mediaResp.status}`);
  return Buffer.from(await mediaResp.arrayBuffer());
}

async function sendTextReply(to, text, phoneNumberId, token) {
  await fetch(`${GRAPH_API}/${phoneNumberId}/messages`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      messaging_product: 'whatsapp',
      to,
      type: 'text',
      text: { body: text },
    }),
  }).catch((e) => console.error('[whatsapp] sendText failed:', e.message));
}

async function sendConfirmButtons(to, summary, phoneNumberId, token) {
  await fetch(`${GRAPH_API}/${phoneNumberId}/messages`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      messaging_product: 'whatsapp',
      to,
      type: 'interactive',
      interactive: {
        type: 'button',
        body: { text: `⚠️ ${summary}\n\nProceed?` },
        action: {
          buttons: [
            { type: 'reply', reply: { id: 'confirm_yes', title: '✅ Yes' } },
            { type: 'reply', reply: { id: 'confirm_no',  title: '❌ No'  } },
          ],
        },
      },
    }),
  }).catch((e) => console.error('[whatsapp] sendConfirm failed:', e.message));
}

async function sendAudioReply(to, audioBuffer, phoneNumberId, token) {
  // Step 1: upload media
  const form = new FormData();
  form.append('messaging_product', 'whatsapp');
  form.append('file', new Blob([audioBuffer], { type: 'audio/mpeg' }), 'reply.mp3');
  form.append('type', 'audio/mpeg');

  const uploadResp = await fetch(`${GRAPH_API}/${phoneNumberId}/media`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}` },
    body: form,
  }).catch((e) => { console.error('[whatsapp] media upload failed:', e.message); return null; });

  if (!uploadResp?.ok) return;
  const uploadJson = await uploadResp.json().catch(() => ({}));
  const mediaId = uploadJson.id;
  if (!mediaId) return;

  // Step 2: send audio message
  await fetch(`${GRAPH_API}/${phoneNumberId}/messages`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      messaging_product: 'whatsapp',
      to,
      type: 'audio',
      audio: { id: mediaId },
    }),
  }).catch((e) => console.error('[whatsapp] sendAudio failed:', e.message));
}
