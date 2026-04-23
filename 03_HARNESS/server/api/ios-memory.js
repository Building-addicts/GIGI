// POST /api/ios/memory/put    { deviceId, text, tags? }
// POST /api/ios/memory/query  { deviceId, q, limit? }
// DELETE /api/ios/memory/:id   (+ deviceId in query string)
// GET  /api/ios/memory/all?deviceId=...
// Storage: memory/store.js (backend swappabile, default JSON file).
import { getStore } from '../../memory/store.js';

export async function handlePut(req, res, deps) {
  const { readBody, sendJson } = deps;
  let body;
  try { body = JSON.parse(await readBody(req) || '{}'); }
  catch { return sendJson(res, 400, { ok: false, error: { code: 'BAD_JSON', message: 'body non JSON' } }); }
  const deviceId = String(body.deviceId || '').trim();
  const text = String(body.text || '').trim();
  if (!deviceId) return sendJson(res, 400, { ok: false, error: { code: 'MISSING_DEVICE', message: 'deviceId mancante' } });
  if (!text) return sendJson(res, 400, { ok: false, error: { code: 'MISSING_TEXT', message: 'text mancante' } });
  const store = await getStore();
  const entry = await store.put({ userId: deviceId, text, tags: Array.isArray(body.tags) ? body.tags : [] });
  return sendJson(res, 200, { ok: true, data: entry });
}

export async function handleQuery(req, res, deps) {
  const { readBody, sendJson } = deps;
  let body;
  try { body = JSON.parse(await readBody(req) || '{}'); }
  catch { return sendJson(res, 400, { ok: false, error: { code: 'BAD_JSON', message: 'body non JSON' } }); }
  const deviceId = String(body.deviceId || '').trim();
  const q = String(body.q || body.query || '').trim();
  if (!deviceId) return sendJson(res, 400, { ok: false, error: { code: 'MISSING_DEVICE', message: 'deviceId mancante' } });
  const store = await getStore();
  const results = await store.query(q, { userId: deviceId, limit: body.limit || 10 });
  return sendJson(res, 200, { ok: true, data: { results } });
}

export async function handleDelete(req, res, deps) {
  const { sendJson } = deps;
  const url = new URL(req.url, `http://${req.headers.host}`);
  const id = url.pathname.split('/').pop();
  const deviceId = url.searchParams.get('deviceId') || '';
  if (!id) return sendJson(res, 400, { ok: false, error: { code: 'MISSING_ID', message: 'id mancante' } });
  if (!deviceId) return sendJson(res, 400, { ok: false, error: { code: 'MISSING_DEVICE', message: 'deviceId mancante' } });
  const store = await getStore();
  const removed = await store.delete(id, { userId: deviceId });
  return sendJson(res, 200, { ok: true, data: { removed, id } });
}

export async function handleAll(req, res, deps) {
  const { sendJson } = deps;
  const url = new URL(req.url, `http://${req.headers.host}`);
  const deviceId = url.searchParams.get('deviceId') || '';
  if (!deviceId) return sendJson(res, 400, { ok: false, error: { code: 'MISSING_DEVICE', message: 'deviceId mancante' } });
  const store = await getStore();
  const all = await store.all(deviceId);
  return sendJson(res, 200, { ok: true, data: { entries: all } });
}
