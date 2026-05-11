// Router principale /api/ios/*. Chiamato dal server HTTP iOS in server.js.
// Auth Bearer applicato qui; se fallisce, chiude la risposta senza delegare.
import { checkBearer, checkDevice } from './ios-auth.js';
import * as agent from './ios-agent.js';
import * as computerUse from './ios-computer-use.js';
import * as memory from './ios-memory.js';
import * as push from './ios-push-register.js';
import { handlePushTest } from './ios-push-test.js';
import { handleStatus, recordRequest } from './ios-status.js';
import * as localLLM from './ios-local-llm.js';
import * as claudeAgent from './ios-claude-agent.js';

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

  const auth = checkBearer(ctx.cfg, req);
  if (!auth.ok) { json(res, auth.code, { ok: false, error: { code: 'UNAUTHORIZED', message: auth.error } }); return true; }

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

  // computer-use
  if (p === '/api/ios/computer-use' && m === 'POST') { await computerUse.handleStart(req, res, deps); return true; }
  if (/^\/api\/ios\/computer-use\/[^/]+\/confirm$/.test(p) && m === 'POST') { await computerUse.handleConfirm(req, res, deps); return true; }
  if (/^\/api\/ios\/computer-use\/[^/]+$/.test(p) && m === 'GET') { await computerUse.handleStatus(req, res, deps); return true; }

  // push
  if (p === '/api/ios/push/register' && m === 'POST')   { await push.handleRegister(req, res, deps); return true; }
  if (p === '/api/ios/push/unregister' && m === 'POST') { await push.handleUnregister(req, res, deps); return true; }
  if (p === '/api/ios/push/test' && m === 'POST')       { await handlePushTest(req, res, deps); return true; }

  // Phase 2 — Path 3 Ollama (GATE 4)
  if (p === '/api/ios/local-llm/generate' && m === 'POST') { await localLLM.handleGenerate(req, res, deps); return true; }
  if (p === '/api/ios/local-llm/status'   && m === 'GET')  { await localLLM.handleStatus(req, res, deps); return true; }
  if (p === '/api/ios/local-llm/cancel'   && m === 'POST') { await localLLM.handleCancel(req, res, deps); return true; }

  // Phase 2 — Path 4 Claude Code subprocess + MCP (GATE 5, scaffold)
  if (p === '/api/ios/agent/claude'   && m === 'POST') { await claudeAgent.handleClaude(req, res, deps); return true; }
  if (p === '/api/ios/agent/confirm'  && m === 'POST') { await claudeAgent.handleConfirm(req, res, deps); return true; }
  if (p === '/api/ios/agent/cancel'   && m === 'POST' && req.headers['x-cancel-target'] === 'claude') {
    await claudeAgent.handleCancel(req, res, deps); return true;
  }

  // health
  if (p === '/api/ios/health' && m === 'GET') { json(res, 200, { ok: true, data: { pid: process.pid, uptime_s: Math.floor(process.uptime()) } }); return true; }

  // status (rich Settings card — Phase 6C)
  if (p === '/api/ios/status' && m === 'GET') { await handleStatus(req, res, deps); return true; }

  json(res, 404, { ok: false, error: { code: 'NOT_FOUND', message: `${m} ${p} non esiste` } });
  return true;
}
