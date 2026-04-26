// /api/debug/ingest — receives in-app logs from GigiDebugLogger.
// Bearer-authenticated. Writes to stdout AND to logs/ios-debug.log
// for post-hoc inspection. Used to diagnose iOS-side crashes when
// the device is not connected to a Mac for `idevicesyslog`.

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { checkBearer } from './ios-auth.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const LOG_DIR = path.join(__dirname, '..', 'logs');
const LOG_FILE = path.join(LOG_DIR, 'ios-debug.log');

if (!fs.existsSync(LOG_DIR)) fs.mkdirSync(LOG_DIR, { recursive: true });

function readBody(req) {
  return new Promise((resolve) => {
    let d = '';
    req.on('data', c => d += c);
    req.on('end', () => resolve(d));
  });
}

function appendToLog(entry) {
  const line = JSON.stringify(entry) + '\n';
  try { fs.appendFileSync(LOG_FILE, line, 'utf8'); } catch (_) {}
}

export async function handleDebugIngest(req, res, ctx) {
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (url.pathname !== '/api/debug/ingest') return false;
  if (req.method !== 'POST') return false;

  // Bearer-authed (same secret as iOS API). Use a permissive bearer
  // check so even unpaired devices can ship logs during early-launch
  // crash investigation.
  const auth = checkBearer(ctx.cfg, req);
  if (!auth.ok) {
    res.writeHead(401, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: false, error: { code: 'UNAUTHORIZED', message: auth.error } }));
    return true;
  }

  let body = {};
  try {
    const raw = await readBody(req);
    body = raw ? JSON.parse(raw) : {};
  } catch (_) {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: false, error: { code: 'BAD_JSON', message: 'invalid JSON body' } }));
    return true;
  }

  const entry = {
    receivedAt: new Date().toISOString(),
    sessionId: body.sessionId || null,
    location: body.location || 'UNKNOWN',
    message: body.message || '',
    timestamp: body.timestamp || null,
    runId: body.runId || null,
    hypothesisId: body.hypothesisId || null,
    data: body.data || null,
  };

  appendToLog(entry);
  // Also surface to stdout so `node server.js` shows it live
  console.log(`[ios-debug] ${entry.location}: ${entry.message}`);

  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ ok: true }));
  return true;
}
