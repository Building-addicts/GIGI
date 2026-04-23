// RPC loopback server: espone mutazioni watcher al panel (porta 127.0.0.1:7778).
// Il panel gira in un processo separato; senza questo, ogni "fire"/"toggle" via panel
// spawnava claude nel processo panel bypassando il guard anti-overlap del bridge.
import http from 'node:http';
import * as watchers from './watchers.js';

const PORT = 7778;
const HOST = '127.0.0.1';

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

export function startRpc(cfg, log) {
  const server = http.createServer(async (req, res) => {
    // Hardening minimo: solo loopback (listen è già bindato a 127.0.0.1, ma double-check)
    const ra = req.socket.remoteAddress || '';
    if (!ra.includes('127.0.0.1') && !ra.includes('::1')) {
      return json(res, 403, { error: 'loopback only' });
    }

    const url = new URL(req.url, `http://${req.headers.host}`);
    const p = url.pathname;

    if (p === '/health' && req.method === 'GET') {
      return json(res, 200, { ok: true, pid: process.pid });
    }

    // POST /watchers/:id/fire
    let m = p.match(/^\/watchers\/([^/]+)\/fire$/);
    if (m && req.method === 'POST') {
      const id = decodeURIComponent(m[1]);
      try {
        watchers.fireNow(id, cfg).catch(e => log('rpc fire error:', e.message));
        return json(res, 200, { ok: true, id });
      } catch (e) { return json(res, 500, { error: e.message }); }
    }

    // POST /watchers/:id/toggle
    m = p.match(/^\/watchers\/([^/]+)\/toggle$/);
    if (m && req.method === 'POST') {
      const id = decodeURIComponent(m[1]);
      try {
        const body = await readBody(req);
        const { enabled } = body ? JSON.parse(body) : {};
        const cur = watchers.loadWatchers();
        const arr = cur.watchers || [];
        const i = arr.findIndex(x => x.id === id);
        if (i < 0) return json(res, 404, { error: 'not found' });
        arr[i].enabled = typeof enabled === 'boolean' ? enabled : !arr[i].enabled;
        watchers.saveWatchers({ watchers: arr });
        return json(res, 200, { ok: true, id, enabled: arr[i].enabled });
      } catch (e) { return json(res, 500, { error: e.message }); }
    }

    // POST /watchers/:id/budget  body: { max: number|null }
    m = p.match(/^\/watchers\/([^/]+)\/budget$/);
    if (m && req.method === 'POST') {
      const id = decodeURIComponent(m[1]);
      try {
        const body = await readBody(req);
        const { max } = body ? JSON.parse(body) : {};
        const ok = watchers.setBudget(id, max);
        return json(res, ok ? 200 : 400, { ok });
      } catch (e) { return json(res, 500, { error: e.message }); }
    }

    // POST /watchers/:id/reset_budget
    m = p.match(/^\/watchers\/([^/]+)\/reset_budget$/);
    if (m && req.method === 'POST') {
      const id = decodeURIComponent(m[1]);
      try {
        const ok = watchers.resetBudget(id);
        return json(res, ok ? 200 : 404, { ok });
      } catch (e) { return json(res, 500, { error: e.message }); }
    }

    // POST /watchers  upsert definizione (stesso flusso del panel)
    if (p === '/watchers' && req.method === 'POST') {
      try {
        const body = JSON.parse(await readBody(req) || '{}');
        if (!body.id) return json(res, 400, { error: 'missing id' });
        const cur = watchers.loadWatchers();
        const arr = cur.watchers || [];
        const i = arr.findIndex(x => x.id === body.id);
        if (i >= 0) arr[i] = { ...arr[i], ...body }; else arr.push(body);
        watchers.saveWatchers({ watchers: arr });
        return json(res, 200, { ok: true });
      } catch (e) { return json(res, 400, { error: e.message }); }
    }

    return json(res, 404, { error: 'not found' });
  });

  server.on('error', (e) => {
    if (e.code === 'EADDRINUSE') log(`rpc: porta ${PORT} già in uso — skip avvio server RPC`);
    else log('rpc server error:', e.message);
  });

  server.listen(PORT, HOST, () => {
    log(`rpc: server loopback su http://${HOST}:${PORT}`);
  });

  return server;
}
