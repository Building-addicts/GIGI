// POST /api/ios/agent/run — entry point LLM cloud per app iOS.
// Body: { deviceId, text, stream?: boolean }
// - enqueue serializzato per deviceId (usa queue.enqueue)
// - runClaude con resume sessione
// - se stream=true, i delta Claude vanno su WebSocket room(deviceId)
// - ritorno HTTP finale: { ok, data:{ result, session_id, session_new, usage } }
import { randomUUID } from 'node:crypto';
import { log } from '../logger.js';
import { enqueue, incDepth, decDepth, trackChild, untrackChild, consumeCancelled, markCancelled } from '../queue.js';
import { isBlocked } from '../rate-limit.js';
import { broadcast } from './ios-stream.js';

export async function handleAgentRun(req, res, deps) {
  const { readBody, sendJson, cfg, gigiServer } = deps;
  let body;
  try { body = JSON.parse(await readBody(req) || '{}'); }
  catch { return sendJson(res, 400, { ok: false, error: { code: 'BAD_JSON', message: 'body non JSON' } }); }

  const deviceId = String(body.deviceId || '').trim();
  const text = String(body.text || '').trim();
  const wantStream = !!body.stream;
  const domain = String(body.domain || '').trim() || null;
  const schema = String(body.schema || '').trim() || null;
  if (!deviceId) return sendJson(res, 400, { ok: false, error: { code: 'MISSING_DEVICE', message: 'deviceId mancante' } });
  if (!text) return sendJson(res, 400, { ok: false, error: { code: 'MISSING_TEXT', message: 'text mancante' } });

  if (isBlocked()) {
    return sendJson(res, 429, { ok: false, error: { code: 'RATE_LIMITED', message: 'Claude rate limit attivo — riprova più tardi' } });
  }

  const runId = randomUUID();
  incDepth(deviceId);
  gigiServer.state.requests = (gigiServer.state.requests || 0) + 1;
  gigiServer.state.last_request = { time: Date.now(), text: text.slice(0, 200), deviceId };

  const onEvent = wantStream
    ? (ev) => { broadcast(deviceId, { type: 'claude_event', runId, event: ev }); }
    : null;

  const onSpawn = (child) => { trackChild(deviceId, child, runId); };

  try {
    const result = await enqueue(deviceId, async () => {
      if (consumeCancelled(deviceId, runId)) {
        broadcast(deviceId, { type: 'cancelled', runId });
        return { error: 'CANCELLED' };
      }
      try {
        return await gigiServer.runClaude(cfg, text, deviceId, onEvent, onSpawn, { domain, schema });
      } finally {
        untrackChild(deviceId);
      }
    });

    if (result?.error === 'RATE_LIMIT') {
      gigiServer.state.errors = (gigiServer.state.errors || 0) + 1;
      gigiServer.state.last_error = { time: Date.now(), text: 'RATE_LIMIT', deviceId };
      return sendJson(res, 429, { ok: false, error: { code: 'RATE_LIMITED', message: 'rate limit Claude' } });
    }
    if (result?.error === 'CANCELLED') {
      return sendJson(res, 200, { ok: false, error: { code: 'CANCELLED', message: 'task cancellato' } });
    }
    if (result?.error) {
      gigiServer.state.errors = (gigiServer.state.errors || 0) + 1;
      gigiServer.state.last_error = { time: Date.now(), text: String(result.error).slice(0, 200), deviceId };
      return sendJson(res, 500, { ok: false, error: { code: 'CLAUDE_ERROR', message: String(result.error) } });
    }

    if (wantStream) broadcast(deviceId, { type: 'done', runId, session_id: result.session_id });
    return sendJson(res, 200, {
      ok: true,
      data: {
        result: result.result,
        session_id: result.session_id,
        session_new: !!result.session_new,
        usage: result.usage || null,
        runId
      }
    });
  } catch (e) {
    log('ios-agent error:', e.message);
    gigiServer.state.errors = (gigiServer.state.errors || 0) + 1;
    return sendJson(res, 500, { ok: false, error: { code: 'INTERNAL', message: e.message } });
  } finally {
    decDepth(deviceId);
  }
}

export async function handleAgentCancel(req, res, deps) {
  const { readBody, sendJson } = deps;
  let body;
  try { body = JSON.parse(await readBody(req) || '{}'); }
  catch { return sendJson(res, 400, { ok: false, error: { code: 'BAD_JSON', message: 'body non JSON' } }); }
  const deviceId = String(body.deviceId || '').trim();
  const runId = String(body.runId || '').trim();
  if (!deviceId || !runId) return sendJson(res, 400, { ok: false, error: { code: 'MISSING', message: 'deviceId/runId mancanti' } });
  markCancelled(deviceId, runId);
  return sendJson(res, 200, { ok: true, data: { cancelled: true, deviceId, runId } });
}

export async function handleSession(req, res, deps) {
  const { sendJson, gigiServer } = deps;
  const url = new URL(req.url, `http://${req.headers.host}`);
  const deviceId = url.searchParams.get('deviceId') || '';
  if (!deviceId) return sendJson(res, 400, { ok: false, error: { code: 'MISSING_DEVICE', message: 'deviceId mancante' } });
  const sessions = gigiServer.loadSessions();
  const s = sessions[deviceId];
  if (!s) return sendJson(res, 200, { ok: true, data: { active: false } });
  return sendJson(res, 200, {
    ok: true,
    data: {
      active: true,
      session_id: typeof s === 'string' ? s : s.session_id,
      last_active_at: typeof s === 'string' ? null : s.last_active_at,
      started_at: typeof s === 'string' ? null : s.started_at
    }
  });
}

export async function handleSessionReset(req, res, deps) {
  const { readBody, sendJson, gigiServer } = deps;
  let body;
  try { body = JSON.parse(await readBody(req) || '{}'); }
  catch { return sendJson(res, 400, { ok: false, error: { code: 'BAD_JSON', message: 'body non JSON' } }); }
  const deviceId = String(body.deviceId || '').trim();
  if (!deviceId) return sendJson(res, 400, { ok: false, error: { code: 'MISSING_DEVICE', message: 'deviceId mancante' } });
  const sessions = gigiServer.loadSessions();
  delete sessions[deviceId];
  gigiServer.saveSessions(sessions);
  return sendJson(res, 200, { ok: true, data: { reset: true, deviceId } });
}

export async function handleMemo(req, res, deps) {
  const { readBody, sendJson, cfg, gigiServer } = deps;
  let body;
  try { body = JSON.parse(await readBody(req) || '{}'); }
  catch { return sendJson(res, 400, { ok: false, error: { code: 'BAD_JSON', message: 'body non JSON' } }); }
  const deviceId = String(body.deviceId || '').trim();
  if (!deviceId) return sendJson(res, 400, { ok: false, error: { code: 'MISSING_DEVICE', message: 'deviceId mancante' } });
  try {
    const r = await gigiServer.saveMemorySnapshot(cfg, deviceId, null, body.reason || 'manual');
    return sendJson(res, 200, { ok: !!r.ok, data: r });
  } catch (e) {
    return sendJson(res, 500, { ok: false, error: { code: 'MEMO_ERROR', message: e.message } });
  }
}
