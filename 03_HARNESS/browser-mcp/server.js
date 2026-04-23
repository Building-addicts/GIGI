#!/usr/bin/env node
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import puppeteer from 'puppeteer-core';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const CONFIG_PATH = process.env.HARNESS_CONFIG || path.join(__dirname, '..', 'telegram-bridge', 'config.json');

function loadInstances() {
  // Ritorna mappa name -> { name, cdp_url }
  const result = new Map();
  try {
    const cfg = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
    const br = cfg.browser || {};
    const list = Array.isArray(br.instances) && br.instances.length
      ? br.instances
      : [{ name: 'main', cdp_port: br.cdp_port || 9224 }];
    for (const inst of list) {
      result.set(inst.name, { name: inst.name, cdp_url: `http://127.0.0.1:${inst.cdp_port}` });
    }
  } catch {
    // Fallback all'env legacy
    const port = process.env.HARNESS_CDP_URL?.match(/:(\d+)/)?.[1] || 9224;
    result.set('main', { name: 'main', cdp_url: `http://127.0.0.1:${port}` });
  }
  return result;
}

const INSTANCES = loadInstances();
const LEGACY_URL = process.env.HARNESS_CDP_URL;
if (LEGACY_URL && !INSTANCES.has('main')) {
  INSTANCES.set('main', { name: 'main', cdp_url: LEGACY_URL });
}

// Connessioni lazy per istanza
const browsers = new Map(); // name -> puppeteer.Browser

// ═══════════════════════════════════════════════════════════════════
// Shared lease store (cross-process, lockfile-backed).
// I processi Claude sono spawnati in parallelo dal bridge e ciascuno lancia
// il proprio MCP server. Senza stato condiviso, due MCP diversi crederebbero
// entrambi che "main" è libera → collisione sul Chrome.
// Qui il pool è su file, protetto da un lockfile sentinella.
// ═══════════════════════════════════════════════════════════════════

const LEASES_DIR = path.join(__dirname, '..', 'telegram-bridge', 'logs');
const LEASES_FILE = path.join(LEASES_DIR, 'browser_leases.json');
const LOCK_FILE = LEASES_FILE + '.lock';
const LEASE_TTL_MS = 10 * 60 * 1000;   // 10 min max per lease
const LOCK_STALE_MS = 10 * 1000;       // lockfile più vecchio di 10s = probabilmente owner morto
const LOCK_TIMEOUT_MS = 8000;          // max attesa per acquisire il lock
const WAIT_POLL_MS = 400;              // polling per wait-for-free

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
      // Stale lock detection
      try {
        const st = fs.statSync(LOCK_FILE);
        if (Date.now() - st.mtimeMs > LOCK_STALE_MS) {
          try { fs.unlinkSync(LOCK_FILE); } catch {}
          continue;
        }
      } catch {}
      if (Date.now() - start > LOCK_TIMEOUT_MS) throw new Error(`lease lock timeout (>${LOCK_TIMEOUT_MS}ms)`);
      await sleep(30 + Math.floor(Math.random() * 60));
    }
  }
  try { return await fn(); }
  finally { try { fs.unlinkSync(LOCK_FILE); } catch {} }
}

function readLeasesFile() {
  try { return JSON.parse(fs.readFileSync(LEASES_FILE, 'utf8')); }
  catch { return { leases: [] }; }
}

function writeLeasesFile(state) {
  const tmp = LEASES_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2));
  fs.renameSync(tmp, LEASES_FILE); // atomico su NTFS
}

function cleanupStale(state) {
  const now = Date.now();
  const kept = [];
  for (const l of state.leases || []) {
    if (!l.instance) continue;
    if (l.at && now - l.at > LEASE_TTL_MS) continue;
    if (l.pid && !isPidAlive(l.pid)) continue;
    kept.push(l);
  }
  state.leases = kept;
  return state;
}

function occupiedSetFromState(state) {
  const s = new Set();
  for (const l of state.leases || []) s.add(l.instance);
  return s;
}

function pickFree(state, preferMain = true) {
  const occ = occupiedSetFromState(state);
  const names = [...INSTANCES.keys()];
  if (preferMain && names.includes('main') && !occ.has('main')) return 'main';
  for (const n of names) if (!occ.has(n)) return n;
  return null;
}

// Acquisizione lease cross-process con wait-for-free
async function acquireLease({ app, task_id, prefer_main = true, wait_ms = 20000, skip_if_busy = false }) {
  const deadline = Date.now() + Math.max(0, wait_ms);
  while (true) {
    const outcome = await withFileLock(async () => {
      const state = cleanupStale(readLeasesFile());

      // Se il task_id ha già lease → rinfresca e ritorna
      const existing = state.leases.find(l => l.task_id === task_id);
      if (existing) {
        existing.at = Date.now();
        existing.pid = process.pid;
        writeLeasesFile(state);
        return { instance: existing.instance, app: existing.app, queued: false, reused: true };
      }

      const chosen = pickFree(state, prefer_main);
      if (chosen) {
        state.leases.push({ task_id, instance: chosen, app, at: Date.now(), pid: process.pid });
        writeLeasesFile(state);
        return { instance: chosen, app, queued: false, reused: false };
      }
      return null; // tutto pieno
    });

    if (outcome) return outcome;
    if (skip_if_busy) {
      return { instance: null, app, queued: false, skipped: true, note: 'Tutte le istanze occupate. skip_if_busy=true → esci senza prenotare.' };
    }
    if (Date.now() >= deadline) {
      // Fallback: prenota main con flag queued così il caller sa che è concomitante
      return await withFileLock(async () => {
        const state = cleanupStale(readLeasesFile());
        state.leases.push({ task_id, instance: 'main', app, at: Date.now(), pid: process.pid, queued: true });
        writeLeasesFile(state);
        return { instance: 'main', app, queued: true, reused: false, note: 'Timeout wait-for-free, uso main concomitante (rischio conflitto)' };
      });
    }
    await sleep(WAIT_POLL_MS);
  }
}

async function releaseLease(task_id) {
  return await withFileLock(async () => {
    const state = readLeasesFile();
    const before = (state.leases || []).length;
    state.leases = (state.leases || []).filter(l => l.task_id !== task_id);
    writeLeasesFile(state);
    return { released: state.leases.length < before, task_id };
  });
}

// Best-effort release dei lease di questo pid quando il processo esce
function releaseOwnLeasesSync() {
  try {
    // Acquisizione lock "best effort" sync senza retry elaborati
    try { fs.writeFileSync(LOCK_FILE, `${process.pid}:${Date.now()}`, { flag: 'wx' }); }
    catch { /* se lock occupato, rinuncia */ return; }
    try {
      const state = readLeasesFile();
      const before = (state.leases || []).length;
      state.leases = (state.leases || []).filter(l => l.pid !== process.pid);
      if (state.leases.length < before) writeLeasesFile(state);
    } finally {
      try { fs.unlinkSync(LOCK_FILE); } catch {}
    }
  } catch {}
}
process.on('exit', releaseOwnLeasesSync);
process.on('SIGTERM', () => { releaseOwnLeasesSync(); process.exit(0); });
process.on('SIGINT', () => { releaseOwnLeasesSync(); process.exit(0); });

const PANEL_URL = process.env.HARNESS_PANEL_URL || 'http://127.0.0.1:7777';

async function tryAutostartInstance(name) {
  try {
    const ac = new AbortController();
    const t = setTimeout(() => ac.abort(), 3000);
    const r = await fetch(`${PANEL_URL}/api/browser/start?instance=${encodeURIComponent(name)}`, { method: 'POST', signal: ac.signal });
    clearTimeout(t);
    if (!r.ok) return false;
  } catch { return false; }
  for (let i = 0; i < 20; i++) {
    await new Promise(r => setTimeout(r, 500));
    try {
      const ac = new AbortController();
      const t = setTimeout(() => ac.abort(), 1500);
      const r = await fetch(`${PANEL_URL}/api/browser/status?instance=${encodeURIComponent(name)}`, { signal: ac.signal });
      clearTimeout(t);
      if (r.ok) {
        const j = await r.json();
        if (j && j.alive) return true;
      }
    } catch {}
  }
  return false;
}

async function getBrowser(instanceName) {
  const name = instanceName || 'main';
  if (!INSTANCES.has(name)) throw new Error(`Istanza browser "${name}" non configurata. Disponibili: ${[...INSTANCES.keys()].join(', ')}`);
  const existing = browsers.get(name);
  if (existing && existing.connected) return existing;
  const cdp = INSTANCES.get(name).cdp_url;
  try {
    const b = await puppeteer.connect({ browserURL: cdp, defaultViewport: null });
    browsers.set(name, b);
    b.on('disconnected', () => browsers.delete(name));
    return b;
  } catch (e) {
    const started = await tryAutostartInstance(name);
    if (started) {
      try {
        const b = await puppeteer.connect({ browserURL: cdp, defaultViewport: null });
        browsers.set(name, b);
        b.on('disconnected', () => browsers.delete(name));
        return b;
      } catch (e2) {
        throw new Error(`Autostarted "${name}" but still cannot connect at ${cdp}: ${e2.message}`);
      }
    }
    throw new Error(`Cannot connect to Harness browser "${name}" at ${cdp}. Autostart via panel failed. Original error: ${e.message}`);
  }
}

async function activePage(instanceName) {
  const b = await getBrowser(instanceName);
  const pages = await b.pages();
  const visible = pages.find(p => !p.url().startsWith('devtools://') && !p.url().startsWith('chrome://'));
  return visible || pages[0] || await b.newPage();
}

// Descrizione comune dell'istanza per i tool
const INSTANCE_PROP = {
  instance: {
    type: 'string',
    description: 'Nome istanza browser (main, slot1, slot2, ...). Default "main". Usa browser_lease per ottenere un\'istanza dedicata quando servono azioni parallele sulla stessa app.'
  }
};

const tools = [
  {
    name: 'browser_lease',
    description: 'Prenota un\'istanza browser dedicata per un task. Pool CONDIVISO cross-process (file-locked): due Claude paralleli non otterranno mai la stessa istanza. Se tutte occupate, aspetta fino a wait_ms che una si liberi; poi fallback a "main" con queued=true, oppure se skip_if_busy=true ritorna instance=null. Rilascia SEMPRE con browser_release a fine task.',
    inputSchema: {
      type: 'object',
      properties: {
        app: { type: 'string', description: 'App target (whatsapp, telegram, gmail, tradingview, ...). Solo tag diagnostico.' },
        task_id: { type: 'string', description: 'ID arbitrario del task. Usalo per rilasciare poi.' },
        prefer_main: { type: 'boolean', description: 'Default true: preferisce "main" se libera.' },
        wait_ms: { type: 'number', description: 'Timeout di attesa (default 20000ms) per avere un\'istanza libera. Dopo fallback a main con queued=true.' },
        skip_if_busy: { type: 'boolean', description: 'Default false. Se true e il pool è esaurito, invece di aspettare/fallback ritorna instance=null skipped=true. Utile per watcher che preferiscono saltare il fire.' }
      },
      required: ['app', 'task_id']
    }
  },
  {
    name: 'browser_release',
    description: 'Rilascia il lease precedentemente ottenuto con browser_lease.',
    inputSchema: {
      type: 'object',
      properties: { task_id: { type: 'string' } },
      required: ['task_id']
    }
  },
  {
    name: 'browser_instances',
    description: 'Elenca le istanze browser configurate e il loro stato di lease corrente.',
    inputSchema: { type: 'object' }
  },
  { name: 'browser_navigate', description: 'Navigate the active tab to a URL. Browser persistente con cookies/login salvati (WhatsApp Web, LinkedIn, ecc.).', inputSchema: { type: 'object', properties: { url: { type: 'string' }, ...INSTANCE_PROP }, required: ['url'] } },
  { name: 'browser_screenshot', description: 'Screenshot della pagina attiva (base64 PNG).', inputSchema: { type: 'object', properties: { full_page: { type: 'boolean' }, selector: { type: 'string' }, ...INSTANCE_PROP } } },
  { name: 'browser_click', description: 'Click su un elemento per CSS selector.', inputSchema: { type: 'object', properties: { selector: { type: 'string' }, ...INSTANCE_PROP }, required: ['selector'] } },
  { name: 'browser_fill', description: 'Fill an input field (clears first).', inputSchema: { type: 'object', properties: { selector: { type: 'string' }, value: { type: 'string' }, ...INSTANCE_PROP }, required: ['selector', 'value'] } },
  { name: 'browser_type', description: 'Type text in the currently focused element.', inputSchema: { type: 'object', properties: { text: { type: 'string' }, ...INSTANCE_PROP }, required: ['text'] } },
  { name: 'browser_press', description: 'Press a keyboard key (es. Enter, Escape, Tab).', inputSchema: { type: 'object', properties: { key: { type: 'string' }, ...INSTANCE_PROP }, required: ['key'] } },
  { name: 'browser_evaluate', description: 'Execute JavaScript in page context and return the result.', inputSchema: { type: 'object', properties: { script: { type: 'string' }, ...INSTANCE_PROP }, required: ['script'] } },
  { name: 'browser_text', description: 'innerText del body o di un selector.', inputSchema: { type: 'object', properties: { selector: { type: 'string' }, ...INSTANCE_PROP } } },
  { name: 'browser_wait', description: 'Sleep for N milliseconds.', inputSchema: { type: 'object', properties: { ms: { type: 'number' } }, required: ['ms'] } },
  { name: 'browser_wait_selector', description: 'Wait until a selector appears (default timeout 10000ms).', inputSchema: { type: 'object', properties: { selector: { type: 'string' }, timeout: { type: 'number' }, ...INSTANCE_PROP }, required: ['selector'] } },
  { name: 'browser_url', description: 'URL e title del tab attivo.', inputSchema: { type: 'object', properties: { ...INSTANCE_PROP } } },
  { name: 'browser_pages', description: 'Elenca i tab aperti.', inputSchema: { type: 'object', properties: { ...INSTANCE_PROP } } },
  { name: 'browser_new_tab', description: 'Apre un nuovo tab (eventualmente su URL).', inputSchema: { type: 'object', properties: { url: { type: 'string' }, ...INSTANCE_PROP } } },
  { name: 'browser_close_tab', description: 'Chiude il tab attivo.', inputSchema: { type: 'object', properties: { ...INSTANCE_PROP } } },
  { name: 'browser_switch_tab', description: 'Switcha tab per indice (vedi browser_pages).', inputSchema: { type: 'object', properties: { index: { type: 'number' }, ...INSTANCE_PROP }, required: ['index'] } },
];

const handlers = {
  async browser_lease({ app, task_id, prefer_main = true, wait_ms = 20000, skip_if_busy = false }) {
    const result = await acquireLease({ app, task_id, prefer_main, wait_ms, skip_if_busy });
    return { content: [{ type: 'text', text: JSON.stringify(result) }] };
  },
  async browser_release({ task_id }) {
    const result = await releaseLease(task_id);
    return { content: [{ type: 'text', text: JSON.stringify(result) }] };
  },
  async browser_instances() {
    const state = await withFileLock(async () => {
      const s = cleanupStale(readLeasesFile());
      writeLeasesFile(s);
      return s;
    });
    const out = [];
    for (const [name, meta] of INSTANCES.entries()) {
      const tasks = (state.leases || []).filter(l => l.instance === name).map(l => ({
        task_id: l.task_id,
        app: l.app,
        pid: l.pid,
        age_ms: Date.now() - (l.at || 0),
        queued: !!l.queued
      }));
      out.push({ name, cdp_url: meta.cdp_url, occupied: tasks.length > 0, tasks });
    }
    return { content: [{ type: 'text', text: JSON.stringify(out, null, 2) }] };
  },
  async browser_navigate({ url, instance }) {
    const p = await activePage(instance);
    await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 45000 });
    return { content: [{ type: 'text', text: `Navigated to ${url} [${instance || 'main'}]` }] };
  },
  async browser_screenshot({ full_page, selector, instance }) {
    const p = await activePage(instance);
    let buf;
    if (selector) {
      const el = await p.$(selector);
      if (!el) throw new Error(`Element not found: ${selector}`);
      buf = await el.screenshot();
    } else {
      buf = await p.screenshot({ fullPage: !!full_page });
    }
    return { content: [{ type: 'image', data: buf.toString('base64'), mimeType: 'image/png' }] };
  },
  async browser_click({ selector, instance }) {
    const p = await activePage(instance);
    await p.click(selector);
    return { content: [{ type: 'text', text: `Clicked ${selector} [${instance || 'main'}]` }] };
  },
  async browser_fill({ selector, value, instance }) {
    const p = await activePage(instance);
    await p.focus(selector);
    await p.evaluate(s => { const e = document.querySelector(s); if (e) { e.value = ''; e.innerText = ''; } }, selector);
    await p.type(selector, value);
    return { content: [{ type: 'text', text: `Filled ${selector} [${instance || 'main'}]` }] };
  },
  async browser_type({ text, instance }) {
    const p = await activePage(instance);
    await p.keyboard.type(text);
    return { content: [{ type: 'text', text: `Typed ${text.length} chars [${instance || 'main'}]` }] };
  },
  async browser_press({ key, instance }) {
    const p = await activePage(instance);
    await p.keyboard.press(key);
    return { content: [{ type: 'text', text: `Pressed ${key} [${instance || 'main'}]` }] };
  },
  async browser_evaluate({ script, instance }) {
    const p = await activePage(instance);
    const wrapped = `(async () => { ${script.includes('return') ? script : 'return ' + script} })()`;
    const result = await p.evaluate(wrapped);
    const out = typeof result === 'string' ? result : JSON.stringify(result, null, 2);
    return { content: [{ type: 'text', text: out?.slice(0, 20000) || 'undefined' }] };
  },
  async browser_text({ selector, instance }) {
    const p = await activePage(instance);
    const text = await p.evaluate((s) => {
      const el = s ? document.querySelector(s) : document.body;
      return el ? el.innerText : null;
    }, selector || null);
    return { content: [{ type: 'text', text: (text || '').slice(0, 20000) || '(no text)' }] };
  },
  async browser_wait({ ms }) {
    await new Promise(r => setTimeout(r, Math.min(60000, Math.max(0, ms))));
    return { content: [{ type: 'text', text: `waited ${ms}ms` }] };
  },
  async browser_wait_selector({ selector, timeout, instance }) {
    const p = await activePage(instance);
    await p.waitForSelector(selector, { timeout: timeout || 10000 });
    return { content: [{ type: 'text', text: `${selector} appeared [${instance || 'main'}]` }] };
  },
  async browser_url({ instance }) {
    const p = await activePage(instance);
    return { content: [{ type: 'text', text: `${p.url()}\n${await p.title()}` }] };
  },
  async browser_pages({ instance }) {
    const b = await getBrowser(instance);
    const pages = await b.pages();
    const list = await Promise.all(pages.map(async (p, i) => `${i}: ${p.url()} — ${await p.title()}`));
    return { content: [{ type: 'text', text: list.join('\n') }] };
  },
  async browser_new_tab({ url, instance }) {
    const b = await getBrowser(instance);
    const p = await b.newPage();
    if (url) await p.goto(url, { waitUntil: 'domcontentloaded' });
    return { content: [{ type: 'text', text: `Opened new tab [${instance || 'main'}]${url ? ' → ' + url : ''}` }] };
  },
  async browser_close_tab({ instance }) {
    const p = await activePage(instance);
    await p.close();
    return { content: [{ type: 'text', text: `Tab closed [${instance || 'main'}]` }] };
  },
  async browser_switch_tab({ index, instance }) {
    const b = await getBrowser(instance);
    const pages = await b.pages();
    if (index < 0 || index >= pages.length) throw new Error(`Invalid tab index ${index}`);
    await pages[index].bringToFront();
    return { content: [{ type: 'text', text: `Switched to tab ${index}: ${pages[index].url()} [${instance || 'main'}]` }] };
  },
};

const server = new Server({ name: 'harness-browser', version: '2.0.0' }, { capabilities: { tools: {} } });
server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools }));
server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const h = handlers[req.params.name];
  if (!h) return { content: [{ type: 'text', text: `Unknown tool: ${req.params.name}` }], isError: true };
  try {
    return await h(req.params.arguments || {});
  } catch (e) {
    return { content: [{ type: 'text', text: `ERROR: ${e.message}` }], isError: true };
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
