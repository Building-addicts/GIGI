// POST /api/setup/autofix — Bearer-authed batch fixer.
//
// Body shape:
//   { checkIds: string[] }   — explicit list of check ids to fix, OR
//   { checkIds: ["all"] }    — every fixer registered in auto_fixers.js
//
// Response shape: { ok: true, data: { results, summary } }
//   results: [{ id, fixed, detail?, needsUser?, needsRepair?, error? }, ...]
//   summary: { fixedCount, needsUserCount, errorCount, total, elapsed_ms }
//
// Runs in series so the iOS UI can render per-step progress (Q4b
// decision). After this call returns, the iOS view triggers a fresh
// /api/setup/diagnostics call to confirm what's actually green.
//
// Auth: same Bearer secret as the rest of the iOS API. Critically:
// if the batch includes `config_secret_strength`, the secret in the
// request was the OLD one; the server will rotate it AFTER returning,
// so the response body still shows the success report. The next call
// from the iPhone with the old secret will get 401 — this is intended,
// the iOS app handles it via the needsRepair signal.
import { runBatch } from '../preflight/auto_fixers.js';
import { checkBearer } from './ios-auth.js';
import { cloudflared } from '../tunnel/cloudflared-manager.js';

function jsonResponse(res, code, obj) {
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store'
  });
  res.end(JSON.stringify(obj));
}

async function readBody(req) {
  return new Promise((resolve) => {
    let d = '';
    req.on('data', c => { d += c; });
    req.on('end', () => resolve(d));
  });
}

/**
 * Returns true if the request was handled.
 */
export async function handleAutofix(req, res, { cfg, cfgPath }) {
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (url.pathname !== '/api/setup/autofix') return false;

  if (req.method !== 'POST') {
    jsonResponse(res, 405, { ok: false, error: { code: 'METHOD_NOT_ALLOWED', message: 'POST only' } });
    return true;
  }

  const auth = checkBearer(cfg, req);
  if (!auth.ok) {
    jsonResponse(res, auth.code, { ok: false, error: { code: 'UNAUTHORIZED', message: auth.error } });
    return true;
  }

  let body;
  try {
    body = JSON.parse(await readBody(req) || '{}');
  } catch {
    jsonResponse(res, 400, { ok: false, error: { code: 'BAD_JSON', message: 'body is not JSON' } });
    return true;
  }

  const checkIds = Array.isArray(body.checkIds) ? body.checkIds.filter(Boolean) : [];
  if (checkIds.length === 0) {
    jsonResponse(res, 400, { ok: false, error: { code: 'EMPTY_CHECK_IDS', message: 'checkIds must be a non-empty array' } });
    return true;
  }

  try {
    const report = await runBatch(checkIds, { cfg, cfgPath, cloudflared });
    jsonResponse(res, 200, { ok: true, data: report });
  } catch (e) {
    jsonResponse(res, 500, { ok: false, error: { code: 'AUTOFIX_FAILED', message: e.message } });
  }
  return true;
}
