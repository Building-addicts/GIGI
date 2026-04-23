// APNS provider API via HTTP/2 + JWT ES256 (no deps, solo node:crypto + node:http2).
// Config (da env o cfg.apns):
//   APNS_KEY_PATH   → path .p8
//   APNS_KEY_ID     → Key ID 10 char
//   APNS_TEAM_ID    → Team ID 10 char
//   APNS_BUNDLE_ID  → com.leonardocorte.gigi
//   APNS_PRODUCTION → "true" per production endpoint
import fs from 'node:fs';
import http2 from 'node:http2';
import crypto from 'node:crypto';
import { log } from '../server/logger.js';
import { loadTokens } from '../server/api/ios-push-register.js';

let cachedJwt = null;
let cachedJwtAt = 0;
const JWT_TTL_MS = 50 * 60 * 1000; // APNS richiede < 60 min

function b64url(buf) {
  return Buffer.from(buf).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
}

function getCfg(cfg) {
  const apns = cfg?.apns || {};
  return {
    keyPath: process.env.APNS_KEY_PATH || apns.key_path,
    keyId: process.env.APNS_KEY_ID || apns.key_id,
    teamId: process.env.APNS_TEAM_ID || apns.team_id,
    bundleId: process.env.APNS_BUNDLE_ID || apns.bundle_id,
    production: (process.env.APNS_PRODUCTION === 'true') || !!apns.production
  };
}

function makeJwt({ keyPath, keyId, teamId }) {
  if (cachedJwt && Date.now() - cachedJwtAt < JWT_TTL_MS) return cachedJwt;
  if (!keyPath || !fs.existsSync(keyPath)) throw new Error(`APNS key non trovata: ${keyPath}`);
  const privateKey = fs.readFileSync(keyPath, 'utf8');
  const header = { alg: 'ES256', kid: keyId, typ: 'JWT' };
  const payload = { iss: teamId, iat: Math.floor(Date.now() / 1000) };
  const signingInput = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
  const signer = crypto.createSign('SHA256');
  signer.update(signingInput);
  signer.end();
  const derSig = signer.sign({ key: privateKey, dsaEncoding: 'ieee-p1363' });
  cachedJwt = `${signingInput}.${b64url(derSig)}`;
  cachedJwtAt = Date.now();
  return cachedJwt;
}

export async function sendPush({ deviceToken, payload, cfg, pushType = 'alert', priority = 10, topicSuffix = null }) {
  const c = getCfg(cfg);
  if (!c.keyPath || !c.keyId || !c.teamId || !c.bundleId) {
    return { ok: false, error: 'APNS non configurato (key_path/key_id/team_id/bundle_id mancanti)' };
  }
  let jwt;
  try { jwt = makeJwt(c); }
  catch (e) { return { ok: false, error: e.message }; }
  const host = c.production ? 'api.push.apple.com' : 'api.sandbox.push.apple.com';
  const topic = topicSuffix ? `${c.bundleId}.${topicSuffix}` : c.bundleId;

  return new Promise((resolve) => {
    const client = http2.connect(`https://${host}:443`);
    client.on('error', (e) => resolve({ ok: false, error: `h2 connect: ${e.message}` }));
    const req = client.request({
      ':method': 'POST',
      ':path': `/3/device/${deviceToken}`,
      'authorization': `bearer ${jwt}`,
      'apns-topic': topic,
      'apns-push-type': pushType,
      'apns-priority': String(priority),
      'content-type': 'application/json'
    });
    req.setEncoding('utf8');
    let status = 0;
    let body = '';
    req.on('response', (headers) => { status = headers[':status']; });
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      client.close();
      if (status === 200) resolve({ ok: true, status });
      else resolve({ ok: false, status, body });
    });
    req.on('error', (e) => { client.close(); resolve({ ok: false, error: e.message }); });
    req.end(JSON.stringify(payload));
  });
}

export async function sendToDevice(deviceId, payload, cfg, opts = {}) {
  const tokens = loadTokens();
  const entry = tokens[deviceId];
  if (!entry?.token) return { ok: false, error: `no APNS token per deviceId ${deviceId}` };
  const r = await sendPush({ deviceToken: entry.token, payload, cfg, ...opts });
  log(`apns: ${deviceId} → ${r.ok ? 'OK' : 'FAIL ' + (r.error || r.status)}`);
  return r;
}

export async function broadcastToAll(payload, cfg, opts = {}) {
  const tokens = loadTokens();
  const results = [];
  for (const [deviceId, entry] of Object.entries(tokens)) {
    if (!entry?.token) continue;
    const r = await sendPush({ deviceToken: entry.token, payload, cfg, ...opts });
    results.push({ deviceId, ...r });
  }
  return results;
}

export function buildAlertPayload({ title, body, badge, sound = 'default', category, data = {} }) {
  const aps = { alert: { title, body } };
  if (typeof badge === 'number') aps.badge = badge;
  if (sound) aps.sound = sound;
  if (category) aps.category = category;
  return { aps, ...data };
}

export function buildSilentPayload(data = {}) {
  return { aps: { 'content-available': 1 }, ...data };
}
