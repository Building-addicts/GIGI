// MARK: - ios-status.js (Phase 6C — rich settings card)
//
// Endpoint GET /api/ios/status that returns a snapshot suitable for the iOS
// Settings screen: tunnel mode, redacted public URL, last request timestamp,
// requests in the last hour, server uptime.
//
// In-memory ring buffer of recent request timestamps (kept lightweight; max
// 1000 entries). Each iOS Bearer-authed request bumps the buffer via
// `recordRequest()` called from the router.

const _requestTimes = []; // ms epochs, sorted ascending
const MAX_TIMES = 1000;
const ONE_HOUR_MS = 60 * 60 * 1000;

export function recordRequest() {
  const now = Date.now();
  _requestTimes.push(now);
  // Trim head (drop entries older than 1h OR exceeding MAX_TIMES)
  const cutoff = now - ONE_HOUR_MS;
  while (_requestTimes.length > 0 && _requestTimes[0] < cutoff) {
    _requestTimes.shift();
  }
  if (_requestTimes.length > MAX_TIMES) {
    _requestTimes.splice(0, _requestTimes.length - MAX_TIMES);
  }
}

function lastRequestAt() {
  if (_requestTimes.length === 0) return null;
  return new Date(_requestTimes[_requestTimes.length - 1]).toISOString();
}

function requestsLastHour() {
  const cutoff = Date.now() - ONE_HOUR_MS;
  let count = 0;
  for (let i = _requestTimes.length - 1; i >= 0; i--) {
    if (_requestTimes[i] >= cutoff) count++;
    else break;
  }
  return count;
}

// Redact the middle of the public URL so the card shows e.g.
// "https://abc...xyz.trycloudflare.com" — keep enough on each end to
// recognize the host. Returns null if no URL.
function redactUrl(url) {
  if (!url || typeof url !== 'string') return null;
  try {
    const u = new URL(url);
    const host = u.host;
    const dot = host.indexOf('.');
    let label = dot >= 0 ? host.slice(0, dot) : host;
    const tld = dot >= 0 ? host.slice(dot) : '';
    if (label.length <= 8) {
      return `${u.protocol}//${host}`;
    }
    const head = label.slice(0, 3);
    const tail = label.slice(-3);
    return `${u.protocol}//${head}...${tail}${tld}`;
  } catch {
    return url;
  }
}

function inferTunnelMode(cfg) {
  return cfg?.tunnel?.mode || 'manual';
}

function inferPublicUrl(cfg) {
  // Prefer explicit named/quick URL, fall back to manual base URL.
  const t = cfg?.tunnel || {};
  return (
    t.named?.publicUrl ||
    t.quick?.publicUrl ||
    t.lan?.advertisedUrl ||
    cfg?.ios?.public_url ||
    null
  );
}

export async function handleStatus(req, res, deps) {
  const { cfg, sendJson } = deps;
  const payload = {
    tunnelMode: inferTunnelMode(cfg),
    publicUrlRedacted: redactUrl(inferPublicUrl(cfg)),
    lastRequestAt: lastRequestAt(),
    requestsLastHour: requestsLastHour(),
    uptimeSeconds: Math.floor(process.uptime()),
  };
  sendJson(res, 200, { ok: true, data: payload });
}
