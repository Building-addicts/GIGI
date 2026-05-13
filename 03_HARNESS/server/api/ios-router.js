// Router principale /api/ios/*. Chiamato dal server HTTP iOS in server.js.
// Auth Bearer applicato qui; se fallisce, chiude la risposta senza delegare.
import { checkBearer, checkDevice } from './ios-auth.js';
import * as agent from './ios-agent.js';
import * as memory from './ios-memory.js';
// Phase 2 GATE 5 (2026-05-12): ios-computer-use.js (Anthropic SDK loop)
// deprecated → see server/examples/ios-computer-use-anthropic-sdk.js.legacy.
// Replaced by Path 4 via ios-claude-agent.js (Claude Code subprocess + MCP).
import * as push from './ios-push-register.js';
import { handlePushTest } from './ios-push-test.js';
import { handleStatus, recordRequest } from './ios-status.js';
import * as localLLM from './ios-local-llm.js';
import * as claudeAgent from './ios-claude-agent.js';
import * as buildShortcut from './ios-build-shortcut.js';
import { log } from '../logger.js';

function json(res, code, obj) {
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(obj));
}

async function readBody(req) {
  return new Promise((resolve) => {
    let d = '';
    req.on('data', c => d += c);
    req.on('end', () => resolve(d));
  });
}

export async function handleIosRequest(req, res, ctx) {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const p = url.pathname;
  const m = req.method;

  // CORS minimal per dev app iOS
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS');
  if (m === 'OPTIONS') { res.writeHead(204); res.end(); return true; }

  if (!p.startsWith('/api/ios/')) return false;

  // Phase 2 — Signed Shortcut file is opened by iOS Safari/Shortcuts.app
  // via UIApplication.open(url), which CANNOT include our Bearer header.
  // Auth model for this endpoint: 16-hex-char unguessable id + 5-min TTL
  // (file is purged on every GET after expiry). Treat it as a one-shot
  // signed URL — same security model as cloud presigned download links.
  const isPublicShortcutDownload =
    m === 'GET' && /^\/api\/ios\/build-shortcut\/[a-f0-9]{8,64}\.shortcut$/.test(p);

  if (!isPublicShortcutDownload) {
    const auth = checkBearer(ctx.cfg, req);
    if (!auth.ok) { json(res, auth.code, { ok: false, error: { code: 'UNAUTHORIZED', message: auth.error } }); return true; }
  }

  // Blocked-device check (Phase 6B revoke action). Best-effort deviceId
  // extraction from URL query or X-Device-Id header. Body-only deviceIds
  // for POST endpoints are revalidated by their handlers via checkDevice.
  const deviceIdFromQuery = url.searchParams.get('deviceId');
  const deviceIdFromHeader = req.headers['x-device-id'] ? String(req.headers['x-device-id']) : null;
  const earlyDeviceId = deviceIdFromQuery || deviceIdFromHeader;
  if (earlyDeviceId) {
    const dev = checkDevice(ctx.cfg, earlyDeviceId);
    if (!dev.ok && dev.error === 'DEVICE_REVOKED') {
      json(res, 403, { ok: false, error: { code: 'DEVICE_REVOKED', message: 'Device revoked by admin' } });
      return true;
    }
  }

  // Record every authenticated iOS request for the rich Settings card (P6C.1).
  recordRequest();

  // 2026-05-12 capillary logging: surface every incoming iOS request in the
  // live monitor (Log tab). Helps diagnose "I said something but nothing happened"
  // — if no line appears here, the request never reached the harness (dead tunnel,
  // unpaired, wrong bearer, etc).
  try {
    const devId = earlyDeviceId || '<no-device-id>';
    const shortDev = devId === '<no-device-id>' ? devId : devId.slice(0, 8) + '…';
    log(`[ios-request] ${m} ${p} · device=${shortDev}`);
  } catch {}

  const deps = { readBody, sendJson: json, cfg: ctx.cfg, gigiServer: ctx.gigiServer };

  // agent
  if (p === '/api/ios/agent/run' && m === 'POST')    { await agent.handleAgentRun(req, res, deps); return true; }
  if (p === '/api/ios/agent/cancel' && m === 'POST') { await agent.handleAgentCancel(req, res, deps); return true; }

  // session
  if (p === '/api/ios/session' && m === 'GET')       { await agent.handleSession(req, res, deps); return true; }
  if (p === '/api/ios/session/reset' && m === 'POST'){ await agent.handleSessionReset(req, res, deps); return true; }
  if (p === '/api/ios/memo' && m === 'POST')         { await agent.handleMemo(req, res, deps); return true; }

  // memory
  if (p === '/api/ios/memory/put' && m === 'POST')   { await memory.handlePut(req, res, deps); return true; }
  if (p === '/api/ios/memory/query' && m === 'POST') { await memory.handleQuery(req, res, deps); return true; }
  if (p === '/api/ios/memory/all' && m === 'GET')    { await memory.handleAll(req, res, deps); return true; }
  if (p.startsWith('/api/ios/memory/') && m === 'DELETE') { await memory.handleDelete(req, res, deps); return true; }

  // computer-use (DEPRECATED — see server/examples/ios-computer-use-anthropic-sdk.js.legacy)
  // Phase 2 GATE 5 (2026-05-12): the old /api/ios/computer-use/* routes are
  // gone. Path 4 lives under /api/ios/agent/claude (mounted below). Legacy
  // clients receive a structured 410 Gone with migration hint.
  if (p.startsWith('/api/ios/computer-use')) {
    json(res, 410, { ok: false, error: { code: 'COMPUTER_USE_DEPRECATED',
      message: 'Use POST /api/ios/agent/claude with mcpServers:["harness-browser"] instead (GATE 5 — Path 4 Claude Code subprocess + MCP).' } });
    return true;
  }

  // push
  if (p === '/api/ios/push/register' && m === 'POST')   { await push.handleRegister(req, res, deps); return true; }
  if (p === '/api/ios/push/unregister' && m === 'POST') { await push.handleUnregister(req, res, deps); return true; }
  if (p === '/api/ios/push/test' && m === 'POST')       { await handlePushTest(req, res, deps); return true; }

  // Phase 2 — Path 3 Ollama (GATE 4) + Fix-Automatically (2026-05-12 batch 4)
  if (p === '/api/ios/local-llm/generate'        && m === 'POST') { await localLLM.handleGenerate(req, res, deps); return true; }
  if (p === '/api/ios/local-llm/status'          && m === 'GET')  { await localLLM.handleStatus(req, res, deps); return true; }
  if (p === '/api/ios/local-llm/cancel'          && m === 'POST') { await localLLM.handleCancel(req, res, deps); return true; }
  if (p === '/api/ios/local-llm/install-status'  && m === 'GET')  { await localLLM.handleInstallStatus(req, res, deps); return true; }
  if (p === '/api/ios/local-llm/install-ollama'  && m === 'POST') { await localLLM.handleInstallOllama(req, res, deps); return true; }
  if (p === '/api/ios/local-llm/pull-model'      && m === 'POST') { await localLLM.handlePullModel(req, res, deps); return true; }

  // Phase 2 — Path 4 Claude Code subprocess + MCP (GATE 5)
  if (p === '/api/ios/agent/claude'        && m === 'POST') { await claudeAgent.handleClaude(req, res, deps); return true; }
  if (p === '/api/ios/agent/claude-status' && m === 'GET')  { await claudeAgent.handleStatus(req, res, deps); return true; }
  if (p === '/api/ios/agent/confirm'       && m === 'POST') { await claudeAgent.handleConfirm(req, res, deps); return true; }
  if (p === '/api/ios/agent/claude/cancel' && m === 'POST') { await claudeAgent.handleCancel(req, res, deps); return true; }

  // Phase 2 — AI-generated Shortcuts via Cherri pipeline
  if (p === '/api/ios/build-shortcut' && m === 'POST') {
    await buildShortcut.handleBuildShortcut(req, res, ctx);
    return true;
  }
  // Phase 2 (option A) — Claude-composed Shortcuts: iOS sends raw user text,
  // harness runs Claude → {title, actions[]} → Cherri DSL → sign → URL.
  // Bypasses Apple FM on-device (which hallucinates apologies under load).
  if (p === '/api/ios/compose-shortcut' && m === 'POST') {
    await buildShortcut.handleComposeShortcut(req, res, ctx);
    return true;
  }
  // Phase 2.1 — async job pattern to dodge cellular/CDN idle-TCP timeouts.
  // POST start returns jobId immediately; client polls GET job/<id>.
  if (p === '/api/ios/compose-shortcut/start' && m === 'POST') {
    await buildShortcut.handleComposeShortcutStart(req, res, ctx);
    return true;
  }
  if (/^\/api\/ios\/compose-shortcut\/job\/[a-f0-9]+$/.test(p) && m === 'GET') {
    await buildShortcut.handleComposeShortcutJob(req, res, ctx);
    return true;
  }
  if (p.startsWith('/api/ios/build-shortcut/') && p.endsWith('.shortcut') && m === 'GET') {
    await buildShortcut.handleShortcutFile(req, res, ctx);
    return true;
  }

  // 2026-05-12 — telemetry endpoint (bug-012 visibility).
  // iOS fires events for native_tool actions (which otherwise don't reach
  // the harness) so the Live Monitor (/live.html) can show a complete
  // picture of what GIGI is doing on-device. Payload is a fire-and-forget
  // JSON event; we just log it and reply 204. No persistence.
  if (p === '/api/ios/telemetry' && m === 'POST') {
    try {
      const raw = await readBody(req);
      const ev = JSON.parse(raw || '{}');
      const type = String(ev.type || 'event');
      const path = String(ev.path || '');
      const action = String(ev.primaryAction || ev.action || '');
      const userText = String(ev.userText || '').slice(0, 80);
      const elapsedMs = Number.isFinite(ev.elapsedMs) ? Math.round(ev.elapsedMs) : null;
      const dev = earlyDeviceId ? earlyDeviceId.slice(0, 8) + '…' : '<no-device-id>';
      const elapsed = elapsedMs != null ? ` · ${elapsedMs}ms` : '';
      log(`[ios-telemetry] ${type} · path=${path}${action ? ' · action=' + action : ''}${userText ? ' · text="' + userText + '"' : ''}${elapsed} · device=${dev}`);
      res.writeHead(204);
      res.end();
    } catch (e) {
      res.writeHead(400);
      res.end();
    }
    return true;
  }

  // health
  if (p === '/api/ios/health' && m === 'GET') { json(res, 200, { ok: true, data: { pid: process.pid, uptime_s: Math.floor(process.uptime()) } }); return true; }

  // status (rich Settings card — Phase 6C)
  if (p === '/api/ios/status' && m === 'GET') { await handleStatus(req, res, deps); return true; }

  json(res, 404, { ok: false, error: { code: 'NOT_FOUND', message: `${m} ${p} non esiste` } });
  return true;
}
