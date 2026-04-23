// POST /api/ios/push/test → manda push APNS di test (auth watcher o iOS client).
// Body: { deviceId, title?, body?, silent? }
// Usato per verificare: token registrato, APNS config, connettività.
import { sendToDevice, buildAlertPayload, buildSilentPayload } from '../../apns/send.js';

export async function handlePushTest(req, res, deps) {
  const { readBody, sendJson, cfg } = deps;
  let body;
  try { body = JSON.parse(await readBody(req) || '{}'); }
  catch { return sendJson(res, 400, { ok: false, error: { code: 'BAD_JSON', message: 'body non JSON' } }); }
  const deviceId = String(body.deviceId || '').trim();
  if (!deviceId) return sendJson(res, 400, { ok: false, error: { code: 'MISSING_DEVICE', message: 'deviceId mancante' } });
  const payload = body.silent
    ? buildSilentPayload({ test: true, at: Date.now() })
    : buildAlertPayload({ title: body.title || 'GIGI', body: body.body || 'Push di test', data: body.data || {} });
  const r = await sendToDevice(deviceId, payload, cfg, {
    pushType: body.silent ? 'background' : 'alert',
    priority: body.silent ? 5 : 10
  });
  return sendJson(res, r.ok ? 200 : 502, { ok: r.ok, data: r });
}
