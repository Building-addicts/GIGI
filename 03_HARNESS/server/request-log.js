// MARK: - request-log.js (Phase 6B / B1)
//
// In-memory ring buffer of the last N iOS requests, used by the Panel
// "Connections" tab to show recent activity. The buffer is intentionally
// not persisted: it is UI-live state. For persistent audit, see
// `logs/bridge.log` and `logs/state.json`.

const BUFFER_SIZE = 100;
const _buffer = []; // newest at the END

/**
 * Push one request into the ring buffer.
 * @param {Object} entry - { ts, deviceId, method, path, status, latencyMs, errorCode? }
 */
export function logRequest(entry) {
  const ts = entry.ts || Date.now();
  _buffer.push({
    ts,
    deviceId: entry.deviceId || null,
    method: entry.method || 'GET',
    path: entry.path || '/',
    status: typeof entry.status === 'number' ? entry.status : 0,
    latencyMs: typeof entry.latencyMs === 'number' ? entry.latencyMs : 0,
    errorCode: entry.errorCode || null,
  });
  while (_buffer.length > BUFFER_SIZE) _buffer.shift();
}

/**
 * Snapshot of the buffer, newest first.
 * Used by `/api/panel/connections` aggregator.
 * @param {number} limit - cap returned entries (default = full buffer)
 */
export function recentRequests(limit = BUFFER_SIZE) {
  const out = [];
  for (let i = _buffer.length - 1; i >= 0 && out.length < limit; i--) {
    out.push(_buffer[i]);
  }
  return out;
}

/**
 * Wraps a Node http handler `(req, res, ctx) -> Promise<bool>` so every
 * call is timed and logged. Best-effort deviceId extraction:
 *  - URL query `deviceId`
 *  - `X-Device-Id` header
 *  - JSON body `deviceId` (parsed by the handler downstream — not here)
 *
 * The wrapper does NOT consume the request body; it only inspects URL+headers
 * to avoid breaking handlers that read `req` themselves.
 */
export function wrapRequestHandler(handler) {
  return async function wrapped(req, res, ctx) {
    const start = Date.now();
    let result;
    let err;
    try {
      result = await handler(req, res, ctx);
    } catch (e) {
      err = e;
    }
    // Only log handled requests (those that wrote a response).
    // Status code on res may be 200 by default if handler never wrote anything;
    // we still log so silent successes show up.
    const status = res.statusCode || 0;
    const latencyMs = Date.now() - start;
    let deviceId = null;
    try {
      const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
      deviceId = url.searchParams.get('deviceId');
    } catch {}
    if (!deviceId && req.headers['x-device-id']) {
      deviceId = String(req.headers['x-device-id']);
    }
    logRequest({
      ts: start,
      deviceId,
      method: req.method,
      path: (req.url || '/').split('?')[0],
      status,
      latencyMs,
      errorCode: err ? String(err.code || err.name || 'ERR') : null,
    });
    if (err) throw err;
    return result;
  };
}
