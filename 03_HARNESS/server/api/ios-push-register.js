// POST /api/ios/push/register — salva device token APNS.
// Body: { deviceId, apnsToken, platform? ("ios"|"macos"), bundleId? }
// Storage: apns/tokens.json { deviceId: {token, platform, bundleId, updated_at} }
import fs from 'node:fs';
import path from 'node:path';
import { SERVER_DIR } from '../paths.js';

const APNS_DIR = path.join(SERVER_DIR, '..', 'apns');
const TOKENS_FILE = path.join(APNS_DIR, 'tokens.json');

try { fs.mkdirSync(APNS_DIR, { recursive: true }); } catch {}

export function loadTokens() {
  try { return JSON.parse(fs.readFileSync(TOKENS_FILE, 'utf8')); } catch { return {}; }
}

export function saveTokens(t) {
  try { fs.writeFileSync(TOKENS_FILE, JSON.stringify(t, null, 2)); } catch {}
}

export function getToken(deviceId) {
  const all = loadTokens();
  return all[deviceId] || null;
}

export async function handleRegister(req, res, deps) {
  const { readBody, sendJson } = deps;
  let body;
  try { body = JSON.parse(await readBody(req) || '{}'); }
  catch { return sendJson(res, 400, { ok: false, error: { code: 'BAD_JSON', message: 'body non JSON' } }); }
  const deviceId = String(body.deviceId || '').trim();
  const apnsToken = String(body.apnsToken || '').trim();
  if (!deviceId) return sendJson(res, 400, { ok: false, error: { code: 'MISSING_DEVICE', message: 'deviceId mancante' } });
  if (!apnsToken) return sendJson(res, 400, { ok: false, error: { code: 'MISSING_TOKEN', message: 'apnsToken mancante' } });

  const all = loadTokens();
  all[deviceId] = {
    token: apnsToken,
    platform: body.platform || 'ios',
    bundle_id: body.bundleId || null,
    updated_at: Date.now()
  };
  saveTokens(all);
  return sendJson(res, 200, { ok: true, data: { registered: true, deviceId } });
}

export async function handleUnregister(req, res, deps) {
  const { readBody, sendJson } = deps;
  let body;
  try { body = JSON.parse(await readBody(req) || '{}'); }
  catch { return sendJson(res, 400, { ok: false, error: { code: 'BAD_JSON', message: 'body non JSON' } }); }
  const deviceId = String(body.deviceId || '').trim();
  if (!deviceId) return sendJson(res, 400, { ok: false, error: { code: 'MISSING_DEVICE', message: 'deviceId mancante' } });
  const all = loadTokens();
  const existed = !!all[deviceId];
  delete all[deviceId];
  saveTokens(all);
  return sendJson(res, 200, { ok: true, data: { unregistered: existed, deviceId } });
}
