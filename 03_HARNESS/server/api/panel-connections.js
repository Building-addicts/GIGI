// MARK: - panel-connections.js (Phase 6B / B4 + B5)
//
// Aggregator + action router for the Panel "Connections" tab.
// Exposes loopback-only endpoints under /api/panel/* :
//
//   GET  /api/panel/connections                 → tunnel + ws + devices + requests
//   POST /api/panel/tunnel/stop
//   POST /api/panel/tunnel/restart
//   POST /api/panel/ws/:deviceId/close
//   POST /api/panel/device/:deviceId/revoke
//   POST /api/panel/device/:deviceId/reset-session
//
// Security: caller must already be loopback (panel.js binds 127.0.0.1 only),
// so no Bearer auth here. The dispatcher additionally verifies remoteAddress.

import fs from 'node:fs';
import { cloudflared } from '../tunnel/cloudflared-manager.js';
import { activeClients, closeForDevice } from './ios-stream.js';
import { recentRequests } from '../request-log.js';
import { SESSIONS_FILE } from '../paths.js';
import { loadTokens } from './ios-push-register.js';

function json(res, code, obj) {
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    // Panel UI runs on :7777 and fetches us at :7779; both loopback.
    // Allow only loopback origins.
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  });
  res.end(JSON.stringify(obj));
}

function isLoopback(req) {
  const addr = req.socket?.remoteAddress || '';
  return addr === '127.0.0.1' || addr === '::1' || addr === '::ffff:127.0.0.1';
}

function readSessions() {
  try { return JSON.parse(fs.readFileSync(SESSIONS_FILE, 'utf8')); } catch { return {}; }
}

function writeSessions(obj) {
  try { fs.writeFileSync(SESSIONS_FILE, JSON.stringify(obj, null, 2)); } catch {}
}

function writeCfg(cfgPath, cfg) {
  try { fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2)); } catch {}
}

// MARK: - Aggregators

function tunnelSnapshot(cfg) {
  const cf = cloudflared.status();
  return {
    mode:         cfg?.tunnel?.mode || 'manual',
    publicUrl:    cf.publicUrl || null,
    running:      cf.running,
    pid:          cf.pid,
    uptime_s:     cf.uptime_s || 0,
    restartCount: cf.restartCount || 0,
    lastError:    cf.lastError || null,
  };
}

function knownDevices(cfg) {
  const sessions = readSessions();
  const tokens = (() => { try { return loadTokens(); } catch { return {}; } })();
  const allowed = Array.isArray(cfg?.ios?.allowed_device_ids) ? cfg.ios.allowed_device_ids : [];
  const blocked = Array.isArray(cfg?.ios?.blocked_device_ids) ? cfg.ios.blocked_device_ids : [];
  const live = activeClients();
  const liveByDevice = new Set(live.map(c => c.deviceId));

  const ids = new Set([
    ...Object.keys(sessions),
    ...Object.keys(tokens),
    ...allowed,
    ...blocked,
  ]);

  const out = [];
  for (const id of ids) {
    const sess = sessions[id] || null;
    out.push({
      deviceId: id,
      lastActiveAt: sess?.last_active_at || null,
      hasSession: !!sess?.session_id,
      apnsRegistered: !!tokens[id],
      wsConnected: liveByDevice.has(id),
      blocked: blocked.includes(id),
      allowed: allowed.length === 0 ? true : allowed.includes(id),
    });
  }
  // Sort: connected first, then by lastActiveAt desc, then by id
  out.sort((a, b) => {
    if (a.wsConnected !== b.wsConnected) return a.wsConnected ? -1 : 1;
    if (a.lastActiveAt !== b.lastActiveAt) {
      return (b.lastActiveAt || 0) - (a.lastActiveAt || 0);
    }
    return a.deviceId.localeCompare(b.deviceId);
  });
  return out;
}

// MARK: - Action handlers

async function actionTunnelStop(req, res, { cfg, cfgPath }) {
  await cloudflared.stop();
  if (cfg?.tunnel) cfg.tunnel.mode = 'manual';
  writeCfg(cfgPath, cfg);
  json(res, 200, { ok: true, data: { tunnel: tunnelSnapshot(cfg) } });
}

async function actionTunnelRestart(req, res, { cfg, cfgPath }) {
  const mode = cfg?.tunnel?.mode || 'manual';
  await cloudflared.stop();
  if (mode === 'quick') {
    await cloudflared.startQuick({ localPort: cfg?.server?.ios_port || 7779 });
  } else if (mode === 'named') {
    const named = cfg?.tunnel?.named || {};
    if (!named.tunnelName) {
      json(res, 400, { ok: false, error: { code: 'MISSING_NAMED_TUNNEL', message: 'Configure a named tunnel via /setup first' } });
      return;
    }
    await cloudflared.startNamed({ tunnelName: named.tunnelName, configPath: named.configPath, localPort: cfg?.server?.ios_port || 7779 });
  } else {
    json(res, 400, { ok: false, error: { code: 'NO_TUNNEL_MODE', message: 'tunnel.mode is "manual"; nothing to restart' } });
    return;
  }
  json(res, 200, { ok: true, data: { tunnel: tunnelSnapshot(cfg) } });
}

function actionWsClose(req, res, deviceId) {
  const closed = closeForDevice(deviceId);
  json(res, 200, { ok: true, data: { closed } });
}

function actionDeviceRevoke(req, res, { cfg, cfgPath }, deviceId) {
  cfg.ios = cfg.ios || {};
  cfg.ios.blocked_device_ids = Array.isArray(cfg.ios.blocked_device_ids) ? cfg.ios.blocked_device_ids : [];
  if (!cfg.ios.blocked_device_ids.includes(deviceId)) {
    cfg.ios.blocked_device_ids.push(deviceId);
  }
  writeCfg(cfgPath, cfg);
  // Drop the active session and tear down WS so the change is felt now.
  const sessions = readSessions();
  delete sessions[deviceId];
  writeSessions(sessions);
  const closed = closeForDevice(deviceId);
  json(res, 200, { ok: true, data: { revoked: true, wsClosed: closed } });
}

function actionDeviceResetSession(req, res, deviceId) {
  const sessions = readSessions();
  delete sessions[deviceId];
  writeSessions(sessions);
  const closed = closeForDevice(deviceId);
  json(res, 200, { ok: true, data: { reset: true, wsClosed: closed } });
}

// MARK: - Dispatcher

export async function handlePanelRequest(req, res, ctx) {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const p = url.pathname;
  const m = req.method;
  if (!p.startsWith('/api/panel/')) return false;

  if (m === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': 'Content-Type',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    });
    res.end();
    return true;
  }

  if (!isLoopback(req)) {
    json(res, 403, { ok: false, error: { code: 'LOOPBACK_ONLY', message: 'Panel API è loopback-only' } });
    return true;
  }

  if (p === '/api/panel/connections' && m === 'GET') {
    const data = {
      tunnel:   tunnelSnapshot(ctx.cfg),
      ws:       activeClients(),
      devices:  knownDevices(ctx.cfg),
      requests: recentRequests(50),
    };
    json(res, 200, { ok: true, data });
    return true;
  }

  if (p === '/api/panel/tunnel/stop' && m === 'POST') {
    await actionTunnelStop(req, res, ctx);
    return true;
  }
  if (p === '/api/panel/tunnel/restart' && m === 'POST') {
    await actionTunnelRestart(req, res, ctx);
    return true;
  }

  let mWs = /^\/api\/panel\/ws\/([^/]+)\/close$/.exec(p);
  if (mWs && m === 'POST') {
    actionWsClose(req, res, decodeURIComponent(mWs[1]));
    return true;
  }

  let mRev = /^\/api\/panel\/device\/([^/]+)\/revoke$/.exec(p);
  if (mRev && m === 'POST') {
    actionDeviceRevoke(req, res, ctx, decodeURIComponent(mRev[1]));
    return true;
  }

  let mReset = /^\/api\/panel\/device\/([^/]+)\/reset-session$/.exec(p);
  if (mReset && m === 'POST') {
    actionDeviceResetSession(req, res, decodeURIComponent(mReset[1]));
    return true;
  }

  json(res, 404, { ok: false, error: { code: 'NOT_FOUND', message: `${m} ${p} non esiste` } });
  return true;
}
