// Driver Playwright diretto per computer-use iOS (no MCP).
// Si connette via CDP alle istanze Chrome running (profili loggati).
// Espone lease/release file-backed (stessa logica MCP server) + primitive azione.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { chromium } from 'playwright-core';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const CONFIG_PATH = process.env.HARNESS_CONFIG || path.join(__dirname, '..', 'server', 'config.json');
const LEASES_DIR = process.env.HARNESS_LOGS_DIR || path.join(__dirname, '..', 'server', 'logs');
const LEASES_FILE = path.join(LEASES_DIR, 'browser_leases.json');
const LOCK_FILE = LEASES_FILE + '.lock';
const PASSPORT_INSTANCE = 'passport';
const PANEL_URL = process.env.HARNESS_PANEL_URL || 'http://127.0.0.1:7777';
const LEASE_TTL_MS = 10 * 60 * 1000;
const LOCK_STALE_MS = 10 * 1000;

try { fs.mkdirSync(LEASES_DIR, { recursive: true }); } catch {}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

function isPidAlive(pid) {
  if (!pid) return false;
  try { process.kill(pid, 0); return true; }
  catch (e) { return e.code === 'EPERM'; }
}

async function withFileLock(fn) {
  const start = Date.now();
  while (true) {
    try {
      fs.writeFileSync(LOCK_FILE, `${process.pid}:${Date.now()}`, { flag: 'wx' });
      break;
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
      try {
        const st = fs.statSync(LOCK_FILE);
        if (Date.now() - st.mtimeMs > LOCK_STALE_MS) {
          try { fs.unlinkSync(LOCK_FILE); } catch {}
          continue;
        }
      } catch {}
      if (Date.now() - start > 8000) throw new Error('lease lock timeout');
      await sleep(200);
    }
  }
  try { return await fn(); }
  finally { try { fs.unlinkSync(LOCK_FILE); } catch {} }
}

function readLeases() {
  try { return JSON.parse(fs.readFileSync(LEASES_FILE, 'utf8')); } catch { return { leases: [] }; }
}

function writeLeases(data) {
  fs.writeFileSync(LEASES_FILE, JSON.stringify(data, null, 2));
}

function pruneLeases(data) {
  const now = Date.now();
  data.leases = (data.leases || []).filter(l =>
    isPidAlive(l.pid) && (now - (l.at || 0) < LEASE_TTL_MS)
  );
  return data;
}

function loadInstances() {
  try {
    const cfg = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
    const br = cfg.browser || {};
    const list = Array.isArray(br.instances) && br.instances.length
      ? br.instances
      : [{ name: 'main', cdp_port: br.cdp_port || 9224 }];
    const out = list.map(i => ({ name: i.name, cdp_url: `http://127.0.0.1:${i.cdp_port}` }));
    if (!out.some(i => i.name === PASSPORT_INSTANCE)) {
      const usedPorts = new Set(list.map(i => Number(i.cdp_port)).filter(Boolean));
      let passportPort = Number(br.passport_cdp_port || 9234);
      while (usedPorts.has(passportPort)) passportPort += 1;
      out.unshift({ name: PASSPORT_INSTANCE, cdp_url: `http://127.0.0.1:${passportPort}` });
    }
    return out;
  } catch {
    return [{ name: 'main', cdp_url: 'http://127.0.0.1:9224' }];
  }
}

export async function lease({ app = 'ios-computer-use', taskId, preferred }) {
  return withFileLock(async () => {
    const data = pruneLeases(readLeases());
    const instances = loadInstances();
    const busy = new Set(data.leases.map(l => l.instance));

    let chosen = null;
    if (preferred && !busy.has(preferred)) {
      chosen = instances.find(i => i.name === preferred) || null;
    }
    if (!chosen) {
      chosen = instances.find(i => !busy.has(i.name)) || null;
    }
    if (!chosen) throw new Error('tutte le istanze browser occupate');

    const lease = {
      instance: chosen.name,
      cdp_url: chosen.cdp_url,
      task_id: taskId || randomUUID(),
      app, pid: process.pid, at: Date.now()
    };
    data.leases.push(lease);
    writeLeases(data);
    return lease;
  });
}

export async function release(taskId) {
  return withFileLock(async () => {
    const data = readLeases();
    const before = data.leases.length;
    data.leases = (data.leases || []).filter(l => l.task_id !== taskId);
    writeLeases(data);
    return before - data.leases.length;
  });
}

// ─────────────────────────────────────────────────────────────
// Session wrapper: Playwright connectOverCDP + ContextPage + primitives.
// ─────────────────────────────────────────────────────────────

async function tryAutostartInstance(name) {
  if (!name) return false;
  try {
    const ac = new AbortController();
    const t = setTimeout(() => ac.abort(), 3000);
    const r = await fetch(`${PANEL_URL}/api/browser/start?instance=${encodeURIComponent(name)}`, { method: 'POST', signal: ac.signal });
    clearTimeout(t);
    if (!r.ok) return false;
  } catch { return false; }
  for (let i = 0; i < 20; i++) {
    await sleep(500);
    try {
      const ac = new AbortController();
      const t = setTimeout(() => ac.abort(), 1500);
      const r = await fetch(`${PANEL_URL}/api/browser/status?instance=${encodeURIComponent(name)}`, { signal: ac.signal });
      clearTimeout(t);
      if (r.ok) {
        const j = await r.json();
        if (j?.alive) return true;
      }
    } catch {}
  }
  return false;
}

export async function openSession(cdpUrl, instanceName = null) {
  let browser;
  try {
    browser = await chromium.connectOverCDP(cdpUrl);
  } catch (e) {
    const started = await tryAutostartInstance(instanceName);
    if (!started) throw e;
    browser = await chromium.connectOverCDP(cdpUrl);
  }
  const ctx = browser.contexts()[0] || await browser.newContext();
  const pages = ctx.pages();
  const page = pages.find(p => !p.url().startsWith('devtools://')) || await ctx.newPage();
  return {
    browser,
    ctx,
    page,
    async close() { try { await browser.close(); } catch {} },
    async navigate(url) { await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 }); return { url: page.url() }; },
    async screenshot({ fullPage = false, quality = 70, maxWidth = 1280 } = {}) {
      // viewport resize
      await page.setViewportSize({ width: maxWidth, height: 800 }).catch(() => {});
      const buf = await page.screenshot({ type: 'jpeg', quality, fullPage });
      return { buffer: buf, mimeType: 'image/jpeg' };
    },
    async click(x, y) { await page.mouse.click(x, y); },
    async doubleClick(x, y) { await page.mouse.dblclick(x, y); },
    async rightClick(x, y) { await page.mouse.click(x, y, { button: 'right' }); },
    async moveMouse(x, y) { await page.mouse.move(x, y); },
    async type(text) { await page.keyboard.type(text, { delay: 15 }); },
    async key(combo) {
      // Mapping tipo "Return", "ctrl+a", "cmd+l"
      const mapped = String(combo)
        .replace(/\bReturn\b/i, 'Enter')
        .replace(/\bKP_Enter\b/i, 'Enter')
        .replace(/\bctrl\b/gi, 'Control')
        .replace(/\bcmd\b/gi, 'Meta')
        .replace(/\bsuper\b/gi, 'Meta')
        .replace(/\+/g, '+');
      await page.keyboard.press(mapped);
    },
    async scroll(direction, amount = 500) {
      const dx = direction === 'left' ? -amount : direction === 'right' ? amount : 0;
      const dy = direction === 'up' ? -amount : direction === 'down' ? amount : 0;
      await page.mouse.wheel(dx, dy);
    },
    async url() { return page.url(); },
    async text() { return await page.evaluate(() => document.body.innerText).catch(() => ''); }
  };
}
