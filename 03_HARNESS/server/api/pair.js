// GET /api/pair — pairing payload + optional QR SVG for the iOS app.
//
// Security model:
//   - Loopback-only (127.0.0.1 / ::1). Returns 403 for any other remote
//     address. The pair endpoint hands out the shared secret in cleartext,
//     so it MUST NOT be reachable from Tailscale peers or the LAN.
//   - The expected flow: user opens the Panel in the PC browser
//     (localhost:7777/pair) which in turn fetches this endpoint via a
//     loopback request and renders the QR. The iPhone never talks to
//     this endpoint directly.
//
// Response shapes:
//   - Default (JSON):  { url, secret, deviceName, createdAt }
//   - ?format=svg:     image/svg+xml   (QR code of the JSON payload above)
//
// The `url` field is auto-detected from the PC's network interfaces,
// preferring a Tailscale-assigned IPv4 (100.x.y.z). Falls back to the
// configured host if no Tailscale interface is present.
import os from 'node:os';
import QRCode from 'qrcode';

function pickHostIp(cfg) {
  // Tailscale assigns IPv4 in 100.64.0.0/10 (CGNAT range, which Tailscale
  // reserves). Any interface address that starts with "100." and is NOT
  // also private/internal is very likely the Tailscale one.
  const interfaces = os.networkInterfaces();
  for (const [, addrs] of Object.entries(interfaces)) {
    if (!addrs) continue;
    for (const a of addrs) {
      if (a.family === 'IPv4' && !a.internal && /^100\./.test(a.address)) {
        return a.address;
      }
    }
  }
  // No Tailscale interface — fall back to the first non-loopback IPv4
  // so the QR is still usable on LAN-only setups during dev.
  for (const [, addrs] of Object.entries(interfaces)) {
    if (!addrs) continue;
    for (const a of addrs) {
      if (a.family === 'IPv4' && !a.internal && !/^169\.254\./.test(a.address)) {
        return a.address;
      }
    }
  }
  // Last resort: the configured host from config.json (usually 0.0.0.0
  // which is bad for the iPhone, but better than nothing).
  return cfg?.server?.host || '127.0.0.1';
}

function isLoopback(req) {
  const remote = req.socket?.remoteAddress || '';
  return remote === '127.0.0.1'
      || remote === '::1'
      || remote === '::ffff:127.0.0.1';
}

function buildPayload(cfg) {
  const port = cfg?.server?.port || 7779;
  const host = pickHostIp(cfg);
  const secret = cfg?.ios?.shared_secret || '';
  return {
    url:        `http://${host}:${port}`,
    secret,
    deviceName: os.hostname(),
    createdAt:  new Date().toISOString()
  };
}

function sendJson(res, code, obj) {
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    // Panel on 7777 fetches us via client-side JS — allow.
    'Access-Control-Allow-Origin': 'http://localhost:7777',
    'Access-Control-Allow-Methods': 'GET',
    'Cache-Control': 'no-store'
  });
  res.end(JSON.stringify(obj));
}

/**
 * Returns true if the request was handled (route matched),
 * false if the caller should continue dispatching.
 */
export async function handlePair(req, res, { cfg }) {
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (url.pathname !== '/api/pair') return false;
  if (req.method !== 'GET') {
    sendJson(res, 405, { ok: false, error: { code: 'METHOD_NOT_ALLOWED', message: 'Only GET is supported' } });
    return true;
  }
  if (!isLoopback(req)) {
    sendJson(res, 403, { ok: false, error: { code: 'LOOPBACK_ONLY', message: '/api/pair is only reachable from localhost' } });
    return true;
  }

  const payload = buildPayload(cfg);
  const format  = url.searchParams.get('format');

  if (format === 'svg') {
    try {
      const svg = await QRCode.toString(JSON.stringify(payload), {
        type: 'svg',
        errorCorrectionLevel: 'H',
        margin: 1,
        width: 320,
        color: { dark: '#000000', light: '#FFFFFF' }
      });
      res.writeHead(200, {
        'Content-Type': 'image/svg+xml; charset=utf-8',
        'Access-Control-Allow-Origin': 'http://localhost:7777',
        'Cache-Control': 'no-store'
      });
      res.end(svg);
    } catch (e) {
      sendJson(res, 500, { ok: false, error: { code: 'QR_FAIL', message: e.message } });
    }
    return true;
  }

  sendJson(res, 200, { ok: true, data: payload });
  return true;
}
