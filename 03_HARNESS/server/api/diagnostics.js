// GET /api/setup/diagnostics — Bearer-authed diagnostics report consumed by
// both the iOS app (SetupDiagnosticView, polling 5s) and the Panel
// Connections tab Card 0 (Phase 6B).
//
// Response: 200 with the DiagnosticsReport produced by runner.runDiagnostics().
//
// Caching: results are cached for 5 seconds in memory to absorb the iOS
// polling traffic — the heavy probe (claude_cli_authenticated) makes a
// real Claude API call, we don't want to fire it 12x/min. Cache key has
// no per-device variation.
import { runDiagnostics } from '../preflight/runner.js';
import { checkBearer } from './ios-auth.js';
import { cloudflared } from '../tunnel/cloudflared-manager.js';

const CACHE_TTL_MS = 5_000;
let cached = null; // { ts, report }

function jsonResponse(res, code, obj) {
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store'
  });
  res.end(JSON.stringify(obj));
}

/**
 * Returns true if the request was handled.
 */
export async function handleDiagnostics(req, res, { cfg, gigiServer }) {
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (url.pathname !== '/api/setup/diagnostics') return false;

  if (req.method !== 'GET') {
    jsonResponse(res, 405, { ok: false, error: { code: 'METHOD_NOT_ALLOWED', message: 'GET only' } });
    return true;
  }

  // Bearer auth — same shared secret as the rest of the iOS API. Diagnostics
  // is sensitive (it leaks PC config details) so we don't make it public.
  const auth = checkBearer(cfg, req);
  if (!auth.ok) {
    jsonResponse(res, auth.code, { ok: false, error: { code: 'UNAUTHORIZED', message: auth.error } });
    return true;
  }

  // Cache hit?
  const refresh = url.searchParams.get('refresh') === '1';
  const now = Date.now();
  if (!refresh && cached && (now - cached.ts) < CACHE_TTL_MS) {
    jsonResponse(res, 200, { ok: true, data: cached.report, cached: true, age_ms: now - cached.ts });
    return true;
  }

  try {
    const report = await runDiagnostics({
      cfg,
      cloudflared,
      gigiServer
    });
    cached = { ts: now, report };
    jsonResponse(res, 200, { ok: true, data: report, cached: false, age_ms: 0 });
  } catch (e) {
    jsonResponse(res, 500, { ok: false, error: { code: 'DIAGNOSTICS_FAILED', message: e.message } });
  }
  return true;
}
