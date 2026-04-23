// Route handler del panel, separato da panel.js per permettere hot-reload via
// cache-busted import. panel.js mantiene lo stato del processo (bridge child,
// chromeProcs, autostart) e lo passa qui come `deps`. Modifiche a questo file
// si applicano con POST /api/panel/reload — niente restart di panel/bridge.
import fs from 'node:fs';
import path from 'node:path';

export async function handleRequest(req, res, deps) {
  const {
    loadConfig, saveConfig, getState,
    getBridge, getBridgeStartedAt,
    startBridgeManual, stopBridge,
    chromeProcs, getInstances, findInstance,
    chromeAliveByPort, chromeStatusAll,
    startChrome, stopChrome, captureInstanceScreenshot,
    startTerminal, stopTerminal,
    autostartEnabled, enableAutostart, disableAutostart,
    LOG_FILE, PUBLIC_DIR, dirname,
    MIME, sendJson, readBody
  } = deps;

  const url = new URL(req.url, `http://${req.headers.host}`);
  const p = url.pathname;

  if (p === '/api/status') {
    const st = getState();
    const bridge = getBridge();
    const startedAt = getBridgeStartedAt();
    return sendJson(res, 200, {
      running: !!bridge,
      pid: bridge?.pid || null,
      started_at: startedAt,
      uptime_s: startedAt ? Math.floor((Date.now() - startedAt) / 1000) : 0,
      requests: st.requests || 0,
      errors: st.errors || 0,
      last_request: st.last_request,
      last_error: st.last_error
    });
  }
  if (p === '/api/config' && req.method === 'GET') {
    return sendJson(res, 200, loadConfig());
  }
  if (p === '/api/config' && req.method === 'POST') {
    try {
      const body = await readBody(req);
      const cfg = JSON.parse(body);
      saveConfig(cfg);
      return sendJson(res, 200, { ok: true });
    } catch (e) { return sendJson(res, 400, { ok: false, error: e.message }); }
  }
  if (p === '/api/bridge/start' && req.method === 'POST') return sendJson(res, 200, startBridgeManual());
  if (p === '/api/bridge/stop' && req.method === 'POST') return sendJson(res, 200, stopBridge());
  if (p === '/api/bridge/restart' && req.method === 'POST') {
    stopBridge();
    setTimeout(() => startBridgeManual(), 500);
    return sendJson(res, 200, { ok: true });
  }
  if (p === '/api/browser/status' && req.method === 'GET') {
    const name = url.searchParams.get('instance') || 'main';
    const cfg = loadConfig();
    const inst = findInstance(cfg, name);
    const rec = chromeProcs.get(name);
    const alive = inst ? await chromeAliveByPort(inst.cdp_port) : false;
    return sendJson(res, 200, {
      name,
      running: !!rec,
      alive,
      pid: rec?.proc?.pid || null,
      uptime_s: rec?.startedAt ? Math.floor((Date.now() - rec.startedAt) / 1000) : 0,
      cdp_port: inst?.cdp_port || null
    });
  }
  if (p === '/api/browser/instances' && req.method === 'GET') {
    return sendJson(res, 200, await chromeStatusAll());
  }
  if (p === '/api/browser/screenshot' && req.method === 'GET') {
    const name = url.searchParams.get('instance') || 'main';
    const cfg = loadConfig();
    const inst = findInstance(cfg, name);
    if (!inst) { res.writeHead(404); return res.end('instance not found'); }
    try {
      const buf = await captureInstanceScreenshot(name, inst.cdp_port);
      res.writeHead(200, { 'Content-Type': 'image/jpeg', 'Cache-Control': 'no-store' });
      return res.end(buf);
    } catch (e) {
      res.writeHead(500, { 'Content-Type': 'text/plain' });
      return res.end('screenshot error: ' + e.message);
    }
  }
  if (p === '/api/browser/leases' && req.method === 'GET') {
    try {
      const leasePath = path.join(dirname, 'logs', 'browser_leases.json');
      const data = fs.existsSync(leasePath) ? JSON.parse(fs.readFileSync(leasePath, 'utf8')) : { leases: [] };
      const enriched = (data.leases || []).map(l => ({
        ...l,
        age_ms: Date.now() - (l.at || 0),
        pid_alive: (() => { try { process.kill(l.pid, 0); return true; } catch (e) { return e.code === 'EPERM'; } })()
      }));
      return sendJson(res, 200, { leases: enriched });
    } catch (e) { return sendJson(res, 500, { error: e.message }); }
  }
  if (p === '/api/telegram/queue' && req.method === 'GET') {
    try {
      const sessPath = path.join(dirname, 'logs', 'sessions.json');
      const sessions = fs.existsSync(sessPath) ? JSON.parse(fs.readFileSync(sessPath, 'utf8')) : {};
      const list = Object.entries(sessions).map(([chatId, s]) => ({
        chat_id: chatId,
        session_id: s.session_id,
        last_active_at: s.last_active_at,
        last_active_ago_s: s.last_active_at ? Math.floor((Date.now() - s.last_active_at) / 1000) : null,
        started_at: s.started_at
      }));
      return sendJson(res, 200, { sessions: list });
    } catch (e) { return sendJson(res, 500, { error: e.message }); }
  }
  if (p === '/api/browser/start' && req.method === 'POST') {
    const name = url.searchParams.get('instance') || 'main';
    return sendJson(res, 200, startChrome(name));
  }
  if (p === '/api/browser/stop' && req.method === 'POST') {
    const name = url.searchParams.get('instance') || 'main';
    return sendJson(res, 200, stopChrome(name));
  }
  if (p === '/api/browser/restart' && req.method === 'POST') {
    const name = url.searchParams.get('instance') || 'main';
    stopChrome(name);
    setTimeout(() => startChrome(name), 1000);
    return sendJson(res, 200, { ok: true, name });
  }
  if (p === '/api/watchers' && req.method === 'GET') {
    try {
      const mod = await import('./watchers.js');
      return sendJson(res, 200, mod.getStatus());
    } catch (e) { return sendJson(res, 500, { error: e.message }); }
  }
  if (p === '/api/watchers' && req.method === 'POST') {
    try {
      const body = JSON.parse(await readBody(req));
      const mod = await import('./watchers.js');
      const cur = mod.loadWatchers();
      const arr = cur.watchers || [];
      const i = arr.findIndex(x => x.id === body.id);
      if (i >= 0) arr[i] = { ...arr[i], ...body }; else arr.push(body);
      mod.saveWatchers({ watchers: arr });
      return sendJson(res, 200, { ok: true, note: 'salvato. Riavvia bridge per applicare.' });
    } catch (e) { return sendJson(res, 400, { error: e.message }); }
  }
  if (p.startsWith('/api/watchers/') && p.endsWith('/fire') && req.method === 'POST') {
    const id = decodeURIComponent(p.slice('/api/watchers/'.length, -'/fire'.length));
    try {
      const r = await fetch(`http://127.0.0.1:7778/watchers/${encodeURIComponent(id)}/fire`, { method: 'POST' });
      const body = await r.json().catch(() => ({}));
      return sendJson(res, r.status, body);
    } catch (e) {
      if (e.cause?.code === 'ECONNREFUSED' || e.code === 'ECONNREFUSED') {
        try {
          const mod = await import('./watchers.js');
          const cfg = loadConfig();
          mod.fireNow(id, cfg).catch(err => console.error('fire error:', err.message));
          return sendJson(res, 200, { ok: true, id, note: 'triggered (bridge down, fired locally)' });
        } catch (e2) { return sendJson(res, 500, { error: e2.message }); }
      }
      return sendJson(res, 502, { error: `rpc failed: ${e.message}` });
    }
  }
  if (p.startsWith('/api/watchers/') && p.endsWith('/toggle') && req.method === 'POST') {
    const id = decodeURIComponent(p.slice('/api/watchers/'.length, -'/toggle'.length));
    const body = await readBody(req);
    try {
      const r = await fetch(`http://127.0.0.1:7778/watchers/${encodeURIComponent(id)}/toggle`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: body || '{}'
      });
      const j = await r.json().catch(() => ({}));
      return sendJson(res, r.status, j);
    } catch (e) {
      if (e.cause?.code === 'ECONNREFUSED' || e.code === 'ECONNREFUSED') {
        try {
          const desiredEnabled = body ? !!JSON.parse(body).enabled : null;
          const mod = await import('./watchers.js');
          const cur = mod.loadWatchers();
          const arr = cur.watchers || [];
          const i = arr.findIndex(x => x.id === id);
          if (i < 0) return sendJson(res, 404, { error: 'not found' });
          arr[i].enabled = desiredEnabled === null ? !arr[i].enabled : desiredEnabled;
          mod.saveWatchers({ watchers: arr });
          return sendJson(res, 200, { ok: true, id, enabled: arr[i].enabled, note: 'bridge down, saved locally' });
        } catch (e2) { return sendJson(res, 500, { error: e2.message }); }
      }
      return sendJson(res, 502, { error: `rpc failed: ${e.message}` });
    }
  }
  if (p.startsWith('/api/watchers/') && p.endsWith('/budget') && req.method === 'POST') {
    const id = decodeURIComponent(p.slice('/api/watchers/'.length, -'/budget'.length));
    const body = await readBody(req);
    try {
      const parsed = JSON.parse(body || '{}');
      const val = (parsed.max_responses === null || parsed.max_responses === undefined || parsed.max_responses === '') ? null : parsed.max_responses;
      const r = await fetch(`http://127.0.0.1:7778/watchers/${encodeURIComponent(id)}/budget`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ max: val })
      });
      const j = await r.json().catch(() => ({}));
      if (r.ok) return sendJson(res, 200, { ok: true, id, max_responses: val, ...j });
      return sendJson(res, r.status, j);
    } catch (e) {
      if (e.cause?.code === 'ECONNREFUSED' || e.code === 'ECONNREFUSED') {
        try {
          const parsed = JSON.parse(body || '{}');
          const val = (parsed.max_responses === null || parsed.max_responses === undefined || parsed.max_responses === '') ? null : parsed.max_responses;
          const mod = await import('./watchers.js');
          const ok = mod.setBudget(id, val);
          if (!ok) return sendJson(res, 400, { error: 'invalid budget value or watcher not found' });
          return sendJson(res, 200, { ok: true, id, max_responses: val, note: 'bridge down, saved locally' });
        } catch (e2) { return sendJson(res, 500, { error: e2.message }); }
      }
      return sendJson(res, 502, { error: `rpc failed: ${e.message}` });
    }
  }
  if (p.startsWith('/api/watchers/') && p.endsWith('/reset_budget') && req.method === 'POST') {
    const id = decodeURIComponent(p.slice('/api/watchers/'.length, -'/reset_budget'.length));
    try {
      const r = await fetch(`http://127.0.0.1:7778/watchers/${encodeURIComponent(id)}/reset_budget`, { method: 'POST' });
      const j = await r.json().catch(() => ({}));
      return sendJson(res, r.status, j);
    } catch (e) {
      if (e.cause?.code === 'ECONNREFUSED' || e.code === 'ECONNREFUSED') {
        try {
          const mod = await import('./watchers.js');
          const ok = mod.resetBudget(id);
          return sendJson(res, ok ? 200 : 404, ok ? { ok: true, id, note: 'bridge down, saved locally' } : { error: 'no state for watcher' });
        } catch (e2) { return sendJson(res, 500, { error: e2.message }); }
      }
      return sendJson(res, 502, { error: `rpc failed: ${e.message}` });
    }
  }
  if (p === '/api/watchers/log') {
    const n = parseInt(url.searchParams.get('lines') || '200', 10);
    try {
      const logPath = path.join(dirname, 'logs', 'watchers.log');
      const content = fs.existsSync(logPath) ? fs.readFileSync(logPath, 'utf8').split('\n').filter(Boolean) : [];
      const tail = content.slice(-n).join('\n');
      res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
      return res.end(tail);
    } catch (e) { return sendJson(res, 500, { error: e.message }); }
  }
  if (p === '/api/terminal/open' && req.method === 'POST') return sendJson(res, 200, startTerminal());
  if (p === '/api/terminal/close' && req.method === 'POST') return sendJson(res, 200, stopTerminal());
  if (p === '/api/autostart' && req.method === 'GET') {
    return sendJson(res, 200, { enabled: autostartEnabled() });
  }
  if (p === '/api/autostart' && req.method === 'POST') {
    try {
      const body = JSON.parse(await readBody(req));
      if (body.enabled) enableAutostart(); else disableAutostart();
      return sendJson(res, 200, { ok: true, enabled: autostartEnabled() });
    } catch (e) { return sendJson(res, 500, { ok: false, error: e.message }); }
  }
  if (p === '/api/logs') {
    const n = parseInt(url.searchParams.get('lines') || '200', 10);
    try {
      const content = fs.readFileSync(LOG_FILE, 'utf8').split('\n').filter(Boolean);
      const tail = content.slice(-n).join('\n');
      res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
      return res.end(tail);
    } catch (e) { return sendJson(res, 500, { error: e.message }); }
  }
  if (p === '/api/logs/clear' && req.method === 'POST') {
    try { fs.writeFileSync(LOG_FILE, ''); return sendJson(res, 200, { ok: true }); }
    catch (e) { return sendJson(res, 500, { error: e.message }); }
  }
  if (p === '/api/test-message' && req.method === 'POST') {
    try {
      const body = JSON.parse(await readBody(req));
      const cfg = loadConfig();
      const r = await fetch(`https://api.telegram.org/bot${cfg.telegram.bot_token}/sendMessage`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ chat_id: cfg.telegram.allowed_chat_ids[0], text: body.text || 'Test dal panel' })
      });
      return sendJson(res, 200, await r.json());
    } catch (e) { return sendJson(res, 500, { error: e.message }); }
  }

  let filePath = p === '/' ? '/index.html' : p;
  filePath = path.join(PUBLIC_DIR, filePath);
  if (!filePath.startsWith(PUBLIC_DIR)) { res.writeHead(403); return res.end(); }
  fs.readFile(filePath, (err, data) => {
    if (err) { res.writeHead(404); return res.end('Not found'); }
    const ext = path.extname(filePath);
    res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
    res.end(data);
  });
}
