// channel-router.js
// Mounts all external channel webhook endpoints.
// Registered in server.js alongside ios-router.js.
//
// Routes:
//   POST /api/channels/telegram   → telegram adapter
//   GET  /api/channels/whatsapp   → WhatsApp webhook verification
//   POST /api/channels/whatsapp   → WhatsApp message handler

import * as telegram  from '../channels/telegram.js';
import * as whatsapp  from '../channels/whatsapp.js';
import * as sttMod    from '../audio/stt.js';
import * as ttsMod    from '../audio/tts.js';
import * as userMapper from '../identity/user-mapper.js';

export function init(logsDir) {
  userMapper.init(logsDir);
}

/**
 * Attempt to handle the request as a channel webhook.
 * Returns true if handled, false if the route didn't match.
 */
export async function handle(req, res, deps) {
  const url = req.url?.split('?')[0] || '';
  const method = req.method?.toUpperCase() || '';

  const channelDeps = {
    ...deps,
    stt: sttMod,
    tts: ttsMod,
    userMapper,
  };

  if (url === '/api/channels/telegram' && method === 'POST') {
    await telegram.handleWebhook(req, res, channelDeps);
    return true;
  }

  if (url === '/api/channels/whatsapp') {
    if (method === 'GET') {
      await whatsapp.handleVerification(req, res, channelDeps);
      return true;
    }
    if (method === 'POST') {
      await whatsapp.handleWebhook(req, res, channelDeps);
      return true;
    }
  }

  return false;
}
