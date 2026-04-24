// Setup wizard API routes (localhost Panel on 7777 and iOS HTTP on 7779).
// Mode switching + status readout. The wizard HTML lives at
// server/public/setup.html and hits these endpoints client-side.
//
// Mode matrix (Phase 5 MVP):
//   "manual"  — legacy flow: user pastes URL+secret in iOS Settings (Phase 4)
//   "quick"   — cloudflared --url http://localhost:7779 → trycloudflare.com
//   "lan"     — mDNS advertise _gigi._tcp.local only (no internet exposure)
//   "named"   — OAuth-driven Cloudflare Named Tunnel with user domain (PHASE 5.2)
//
// Named mode endpoints are stubbed and return 501 NOT_IMPLEMENTED — they
// require a Cloudflare OAuth app registration which is follow-up work.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { cloudflared } from '../tunnel/cloudflared-manager.js';
import { startAdvertise, stopAdvertise } from '../tunnel/mdns.js';

function json(res, code, obj) {
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': 'http://localhost:7777',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Cache-Control': 'no-store'
  });
  res.end(JSON.stringify(obj));
}

function isLoopback(req) {
  const remote = req.socket?.remoteAddress || '';
  return remote === '127.0.0.1' || remote === '::1' || remote === '::ffff:127.0.0.1';
}

async function readBody(req) {
  return new Promise((resolve) => {
    let d = ''; req.on('data', c => { d += c; }); req.on('end', () => resolve(d));
  });
}

function saveConfigMode(cfgPath, mode, patch = {}) {
  try {
    const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
    cfg.tunnel = cfg.tunnel || { mode: 'manual', named: {}, quick: {}, lan: {} };
    cfg.tunnel.mode = mode;
    if (patch.quick)  Object.assign(cfg.tunnel.quick  = cfg.tunnel.quick  || {}, patch.quick);
    if (patch.lan)    Object.assign(cfg.tunnel.lan    = cfg.tunnel.lan    || {}, patch.lan);
    if (patch.named)  Object.assign(cfg.tunnel.named  = cfg.tunnel.named  || {}, patch.named);
    fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2), 'utf8');
  } catch (e) {
    console.error('setup: config write failed:', e.message);
  }
}

let mdnsHandle = null;

/**
 * Returns true if the request matched a /api/setup/* route.
 */
export async function handleSetup(req, res, { cfg, cfgPath }) {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const p = url.pathname;
  if (!p.startsWith('/api/setup/') && p !== '/api/setup') return false;

  // CORS preflight
  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': 'http://localhost:7777',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type'
    });
    res.end();
    return true;
  }

  // All setup endpoints are loopback-only because they manipulate
  // sensitive configuration / start child processes.
  if (!isLoopback(req)) {
    json(res, 403, { ok: false, error: { code: 'LOOPBACK_ONLY', message: '/api/setup/* reachable only from localhost' } });
    return true;
  }

  // ---- status ----
  if (p === '/api/setup/status' && req.method === 'GET') {
    return json(res, 200, {
      ok: true,
      data: {
        mode:         cfg?.tunnel?.mode || 'manual',
        cloudflared:  cloudflared.status(),
        lan:          { advertising: !!mdnsHandle, serviceName: cfg?.tunnel?.lan?.service_name || null },
        supported:    ['manual', 'quick', 'lan', 'named'],
        namedReady:   false                   // flip to true when OAuth wizard ships in P5.2
      }
    }), true;
  }

  // ---- quick tunnel ----
  if (p === '/api/setup/quick/start' && req.method === 'POST') {
    try {
      await cloudflared.startQuick({ localPort: cfg?.server?.port || 7779 });
      // Poll up to 15s for the URL to appear in cloudflared stdout
      let url = null;
      for (let i = 0; i < 30; i++) {
        url = cloudflared.status().publicUrl;
        if (url) break;
        await new Promise(r => setTimeout(r, 500));
      }
      saveConfigMode(cfgPath, 'quick', { quick: { last_url: url, last_started: Date.now() } });
      return json(res, 200, { ok: true, data: { url, status: cloudflared.status() } }), true;
    } catch (e) {
      return json(res, 500, { ok: false, error: { code: 'QUICK_START_FAIL', message: e.message } }), true;
    }
  }

  if (p === '/api/setup/quick/stop' && req.method === 'POST') {
    await cloudflared.stop();
    return json(res, 200, { ok: true, data: cloudflared.status() }), true;
  }

  // ---- LAN / mDNS ----
  if (p === '/api/setup/lan/start' && req.method === 'POST') {
    try {
      if (mdnsHandle) { mdnsHandle.stop(); mdnsHandle = null; }
      mdnsHandle = startAdvertise({
        port:        cfg?.server?.port || 7779,
        deviceName:  process.env.COMPUTERNAME || process.env.HOSTNAME || 'gigi-harness',
        version:     '1.0'
      });
      saveConfigMode(cfgPath, 'lan', { lan: { service_name: process.env.COMPUTERNAME || 'gigi-harness' } });
      return json(res, 200, { ok: true, data: { advertising: true } }), true;
    } catch (e) {
      return json(res, 500, { ok: false, error: { code: 'LAN_START_FAIL', message: e.message } }), true;
    }
  }

  if (p === '/api/setup/lan/stop' && req.method === 'POST') {
    if (mdnsHandle) { mdnsHandle.stop(); mdnsHandle = null; }
    return json(res, 200, { ok: true, data: { advertising: false } }), true;
  }

  // ---- manual mode switch back ----
  if (p === '/api/setup/manual' && req.method === 'POST') {
    if (mdnsHandle) { mdnsHandle.stop(); mdnsHandle = null; }
    await cloudflared.stop();
    saveConfigMode(cfgPath, 'manual');
    return json(res, 200, { ok: true, data: { mode: 'manual' } }), true;
  }

  // ---- Named tunnel (Cloudflare login + named hostname) — Phase 5.2 ----
  // Flow: (1) POST /named/login spawns `cloudflared tunnel login` which
  // opens the user's browser; we poll ~/.cloudflared/cert.pem and resolve
  // when it's written. (2) POST /named/configure takes {hostname, tunnelName?}
  // and does `cloudflared tunnel create` + `cloudflared tunnel route dns`
  // + writes a config.yml with ingress rule + starts `cloudflared tunnel run`.
  if (p === '/api/setup/named/login' && req.method === 'POST') {
    try {
      const r = await cloudflared.login({ timeoutMs: 5 * 60_000 });
      return json(res, 200, { ok: true, data: { certPath: r.certPath } }), true;
    } catch (e) {
      return json(res, 500, { ok: false, error: { code: 'LOGIN_FAIL', message: e.message } }), true;
    }
  }

  if (p === '/api/setup/named/cert-status' && req.method === 'GET') {
    const cp = path.join(os.homedir(), '.cloudflared', 'cert.pem');
    const present = fs.existsSync(cp);
    return json(res, 200, { ok: true, data: { present, path: present ? cp : null } }), true;
  }

  if (p === '/api/setup/named/configure' && req.method === 'POST') {
    try {
      const body = JSON.parse(await readBody(req) || '{}');
      const hostname = String(body.hostname || '').trim().toLowerCase();
      if (!hostname || !hostname.includes('.')) {
        return json(res, 400, { ok: false, error: { code: 'BAD_HOSTNAME', message: 'hostname non valido' } }), true;
      }
      const tunnelName = String(body.tunnelName || `gigi-${Date.now().toString(36)}`).trim();
      const localPort = cfg?.server?.port || 7779;

      // 1) create named tunnel
      const created = await cloudflared.createNamedTunnel({ name: tunnelName });

      // 2) route DNS CNAME hostname → <uuid>.cfargotunnel.com
      await cloudflared.routeDns({ uuid: created.uuid, hostname });

      // 3) write a local cloudflared config.yml with the ingress rule
      const cfgYml = path.join(os.homedir(), '.gigi', `cloudflared-${created.uuid}.yml`);
      const credFile = path.join(os.homedir(), '.cloudflared', `${created.uuid}.json`);
      fs.mkdirSync(path.dirname(cfgYml), { recursive: true });
      fs.writeFileSync(cfgYml, [
        `tunnel: ${created.uuid}`,
        `credentials-file: ${credFile.replace(/\\/g, '/')}`,
        `ingress:`,
        `  - hostname: ${hostname}`,
        `    service: http://localhost:${localPort}`,
        `  - service: http_status:404`,
        ``
      ].join('\n'), 'utf8');

      // 4) start cloudflared as named
      await cloudflared.startNamed({ tunnelName: created.uuid, configPath: cfgYml, localPort });

      // 5) persist
      saveConfigMode(cfgPath, 'named', {
        named: {
          tunnel_uuid: created.uuid,
          tunnel_name: tunnelName,
          hostname,
          cert_path:   path.join(os.homedir(), '.cloudflared', 'cert.pem'),
          config_path: cfgYml
        }
      });

      return json(res, 200, {
        ok: true,
        data: {
          hostname,
          tunnel: created,
          publicUrl: `https://${hostname}`,
          status: cloudflared.status()
        }
      }), true;
    } catch (e) {
      return json(res, 500, { ok: false, error: { code: 'NAMED_CONFIGURE_FAIL', message: e.message } }), true;
    }
  }

  if (p === '/api/setup/named/stop' && req.method === 'POST') {
    await cloudflared.stop();
    return json(res, 200, { ok: true, data: cloudflared.status() }), true;
  }

  return json(res, 404, { ok: false, error: { code: 'NOT_FOUND', message: p } }), true;
}
