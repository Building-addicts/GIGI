// channel-router.js
// Legacy external channel webhook endpoints.
// Registered in server.js alongside ios-router.js.
//
// Product decision: GIGI is iPhone-only. Telegram/WhatsApp stay disabled
// by default and are only loaded if config.channels.<name>.enabled === true.
//
// Legacy routes:
//   POST /api/channels/telegram   → telegram adapter
//   GET  /api/channels/whatsapp   → WhatsApp webhook verification
//   POST /api/channels/whatsapp   → WhatsApp message handler

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

  const isTelegram = url === '/api/channels/telegram' && method === 'POST';
  const isWhatsApp = url === '/api/channels/whatsapp' && (method === 'GET' || method === 'POST');
  if (!isTelegram && !isWhatsApp) return false;

  const cfg = deps?.cfg || {};
  const telegramEnabled = cfg.channels?.telegram?.enabled === true;
  const whatsappEnabled = cfg.channels?.whatsapp?.enabled === true;

  if ((isTelegram && !telegramEnabled) || (isWhatsApp && !whatsappEnabled)) {
    res.writeHead(410, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({
      ok: false,
      error: {
        code: 'CHANNEL_DISABLED',
        message: 'GIGI is configured as iPhone-only; legacy Telegram/WhatsApp channels are disabled.'
      }
    }));
    return true;
  }

  const [sttMod, ttsMod] = await Promise.all([
    import('../audio/stt.js'),
    import('../audio/tts.js')
  ]);

  const channelDeps = { ...deps, stt: sttMod, tts: ttsMod, userMapper };

  if (isTelegram) {
    const telegram = await import('../channels/telegram.js');
    await telegram.handleWebhook(req, res, channelDeps);
    return true;
  }

  if (isWhatsApp) {
    const whatsapp = await import('../channels/whatsapp.js');
    if (method === 'GET') {
      await whatsapp.handleVerification(req, res, channelDeps);
      return true;
    }
    if (method === 'POST') {
      await whatsapp.handleWebhook(req, res, channelDeps);
      return true;
    }
  }

  return true;
}
