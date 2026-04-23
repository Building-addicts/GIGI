import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { spawn, execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import puppeteer from 'puppeteer-core';
const pExecFile = promisify(execFile);

// Pool di connessioni puppeteer per screenshot live (una per istanza)
const ppBrowsers = new Map(); // name -> Browser
async function getPpBrowser(name, cdpPort) {
  const existing = ppBrowsers.get(name);
  if (existing && existing.connected) return existing;
  try {
    const b = await puppeteer.connect({ browserURL: `http://127.0.0.1:${cdpPort}`, defaultViewport: null });
    ppBrowsers.set(name, b);
    b.on('disconnected', () => ppBrowsers.delete(name));
    return b;
  } catch (e) {
    ppBrowsers.delete(name);
    throw e;
  }
}
async function captureInstanceScreenshot(name, cdpPort) {
  const b = await getPpBrowser(name, cdpPort);
  const pages = await b.pages();
  const p = pages.find(x => !x.url().startsWith('devtools://') && !x.url().startsWith('chrome://newtab')) || pages[0] || await b.newPage();
  return await p.screenshot({ type: 'jpeg', quality: 60, fullPage: false });
}

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const LOGS_DIR = process.env.HARNESS_LOGS_DIR || path.join(__dirname, 'logs');
const CONFIG_PATH = process.env.HARNESS_CONFIG || path.join(__dirname, 'config.json');
const LOG_FILE = path.join(LOGS_DIR, 'bridge.log');
const STATE_FILE = path.join(LOGS_DIR, 'state.json');
const PUBLIC_DIR = path.join(__dirname, 'public');
try { fs.mkdirSync(LOGS_DIR, { recursive: true }); } catch {}
const TASK_NAME = 'HarnessTelegramBridge';
const STARTUP_DIR = path.join(process.env.APPDATA || '', 'Microsoft', 'Windows', 'Start Menu', 'Programs', 'Startup');
const STARTUP_FILE = path.join(STARTUP_DIR, 'HarnessBridge.vbs');

function autostartEnabled() {
  return fs.existsSync(STARTUP_FILE);
}

function enableAutostart() {
  const panelJs = path.join(__dirname, 'panel.js').replace(/\\/g, '\\\\');
  const logFile = path.join(LOGS_DIR, 'panel.log').replace(/\\/g, '\\\\');
  const workDir = __dirname.replace(/\\/g, '\\\\');
  const vbs = `Set WshShell = CreateObject("WScript.Shell")\r\nWshShell.CurrentDirectory = "${workDir}"\r\nWshShell.Run "cmd /c node ""${panelJs}"" >> ""${logFile}"" 2>&1", 0, False\r\n`;
  fs.writeFileSync(STARTUP_FILE, vbs);
}

function disableAutostart() {
  try { fs.unlinkSync(STARTUP_FILE); } catch {}
}

function loadConfig() { return JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8')); }
function saveConfig(cfg) { fs.writeFileSync(CONFIG_PATH, JSON.stringify(cfg, null, 2)); }

let bridge = null;
let bridgeStartedAt = null;
let bridgeManuallyStopped = false;
// Pool di istanze Chrome: name -> { proc, startedAt, manuallyStopped }
const chromeProcs = new Map();
// Crash counter per Chrome: name -> [timestamp, ...] (ultimi crash)
const chromeCrashLog = new Map();
const CHROME_MAX_CRASHES = 5;
const CHROME_CRASH_WINDOW_MS = 2 * 60 * 1000;
let termProc = null;

function getInstances(cfg) {
  const br = cfg.browser || {};
  if (Array.isArray(br.instances) && br.instances.length) return br.instances;
  // Fallback retrocompatibile: un'unica istanza "main" dai campi legacy
  return [{
    name: 'main',
    profile_dir: br.profile_dir,
    cdp_port: br.cdp_port || 9224,
    autostart: true
  }];
}

function findInstance(cfg, name) {
  return getInstances(cfg).find(i => i.name === (name || 'main'));
}

function startTerminal() {
  if (termProc) return { ok: false, msg: 'già aperto' };
  const logPath = path.join(LOGS_DIR, 'bridge.log');
  const psCmd = `$Host.UI.RawUI.WindowTitle='Harness — Live Bridge Log'; Write-Host 'Tail di bridge.log. Chiudi questa finestra per fermare il terminale live.' -ForegroundColor Cyan; Get-Content -Path '${logPath}' -Wait -Tail 30`;
  termProc = spawn('cmd.exe', ['/c', 'start', 'Harness Live Log', 'powershell.exe', '-NoProfile', '-NoExit', '-Command', psCmd], {
    detached: true, windowsHide: false, stdio: 'ignore'
  });
  termProc.unref();
  termProc.on('exit', () => { termProc = null; });
  return { ok: true };
}

function stopTerminal() {
  try {
    execFile('taskkill', ['/F', '/FI', 'WINDOWTITLE eq Harness — Live Bridge Log*'], () => {});
    execFile('taskkill', ['/F', '/FI', 'WINDOWTITLE eq Harness Live Log*'], () => {});
  } catch {}
  termProc = null;
  return { ok: true };
}

async function chromeAliveByPort(port) {
  try {
    const r = await fetch(`http://127.0.0.1:${port}/json/version`, { signal: AbortSignal.timeout(1000) });
    return r.ok;
  } catch { return false; }
}

async function chromeAlive(name = 'main') {
  const cfg = loadConfig();
  const inst = findInstance(cfg, name);
  if (!inst) return false;
  return chromeAliveByPort(inst.cdp_port);
}

function startChrome(name = 'main') {
  const entry = chromeProcs.get(name);
  if (entry && entry.proc) return { ok: false, msg: 'già in esecuzione', name };
  const cfg = loadConfig();
  const br = cfg.browser || {};
  const inst = findInstance(cfg, name);
  if (!inst) return { ok: false, msg: `istanza "${name}" non trovata` };
  if (!br.chrome_path || !fs.existsSync(br.chrome_path)) {
    return { ok: false, msg: 'Chrome path non valido: ' + br.chrome_path };
  }
  if (!inst.profile_dir) return { ok: false, msg: `istanza "${name}" senza profile_dir` };
  try { fs.mkdirSync(inst.profile_dir, { recursive: true }); } catch {}
  const args = [
    `--user-data-dir=${inst.profile_dir}`,
    `--remote-debugging-port=${inst.cdp_port}`,
    '--remote-allow-origins=*',
    ...(br.extra_args || [])
  ];
  const visible = inst.visible ?? br.visible;
  if (visible === false) args.push('--headless=new');
  const proc = spawn(br.chrome_path, args, { detached: false, windowsHide: false, stdio: 'ignore' });
  const rec = { proc, startedAt: Date.now(), manuallyStopped: false };
  chromeProcs.set(name, rec);
  proc.on('exit', () => {
    console.log(`chrome "${name}" exited`);
    const cur = chromeProcs.get(name);
    chromeProcs.delete(name);
    const cfgNow = loadConfig();
    if (cur && !cur.manuallyStopped && cfgNow.browser?.auto_restart !== false && cfgNow.browser?.enabled) {
      // Crash counter: evita loop infiniti
      const now = Date.now();
      const crashes = (chromeCrashLog.get(name) || []).filter(t => now - t < CHROME_CRASH_WINDOW_MS);
      crashes.push(now);
      chromeCrashLog.set(name, crashes);
      if (crashes.length > CHROME_MAX_CRASHES) {
        console.error(`chrome "${name}" ha crashato ${crashes.length} volte in 2 minuti — auto-restart disabilitato.`);
        return;
      }
      console.log(`auto-restart chrome "${name}" in 3s... (crash #${crashes.length})`);
      setTimeout(() => startChrome(name), 3000);
    }
  });
  return { ok: true, pid: proc.pid, name, cdp_port: inst.cdp_port };
}

function stopChrome(name = 'main') {
  const rec = chromeProcs.get(name);
  if (!rec || !rec.proc) return { ok: false, msg: 'non in esecuzione', name };
  rec.manuallyStopped = true;
  try { rec.proc.kill(); } catch {}
  return { ok: true, name };
}

async function chromeStatusAll() {
  const cfg = loadConfig();
  const out = [];
  for (const inst of getInstances(cfg)) {
    const rec = chromeProcs.get(inst.name);
    const alive = await chromeAliveByPort(inst.cdp_port);
    out.push({
      name: inst.name,
      cdp_port: inst.cdp_port,
      profile_dir: inst.profile_dir,
      running: !!rec,
      alive,
      pid: rec?.proc?.pid || null,
      uptime_s: rec?.startedAt ? Math.floor((Date.now() - rec.startedAt) / 1000) : 0,
      autostart: inst.autostart !== false
    });
  }
  return out;
}

function startBridge() {
  if (bridge) return { ok: false, msg: 'già attivo' };
  bridge = spawn(process.execPath, [path.join(__dirname, 'server.js')], {
    cwd: __dirname,
    windowsHide: true,
    detached: false,
    stdio: ['ignore', 'pipe', 'pipe']
  });
  bridge.stdout.on('data', () => {});
  bridge.stderr.on('data', () => {});
  bridge.on('exit', (code) => {
    console.log(`bridge exited code=${code}`);
    bridge = null;
    bridgeStartedAt = null;
    if (!bridgeManuallyStopped) {
      console.log('bridge crashed — auto-restart in 4s...');
      setTimeout(() => startBridge(), 4000);
    }
  });
  bridgeStartedAt = Date.now();
  return { ok: true, pid: bridge.pid };
}

function stopBridge() {
  if (!bridge) return { ok: false, msg: 'già fermo' };
  bridgeManuallyStopped = true;
  bridge.kill();
  return { ok: true };
}

function startBridgeManual() {
  bridgeManuallyStopped = false;
  return startBridge();
}

function getState() {
  try { return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')); }
  catch { return { requests: 0, errors: 0 }; }
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.json': 'application/json; charset=utf-8'
};

function sendJson(res, code, obj) {
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(obj));
}

async function readBody(req) {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', c => data += c);
    req.on('end', () => resolve(data));
  });
}

// Hot-reload del router: panel-routes.js viene ri-importato con cache-bust su
// POST /api/panel/reload. Permette di applicare modifiche ai route handler
// senza killare il panel (che trascinerebbe giù bridge + Chrome pool).
let handleRequest = null;
let lastRoutesReloadAt = null;
async function loadRoutes() {
  const mod = await import(`./panel-routes.js?t=${Date.now()}`);
  handleRequest = mod.handleRequest;
  lastRoutesReloadAt = Date.now();
}
await loadRoutes();

const deps = {
  loadConfig, saveConfig, getState,
  getBridge: () => bridge,
  getBridgeStartedAt: () => bridgeStartedAt,
  startBridgeManual, stopBridge,
  chromeProcs, getInstances, findInstance,
  chromeAliveByPort, chromeStatusAll,
  startChrome, stopChrome, captureInstanceScreenshot,
  startTerminal, stopTerminal,
  autostartEnabled, enableAutostart, disableAutostart,
  LOG_FILE, PUBLIC_DIR, dirname: __dirname,
  MIME, sendJson, readBody
};

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const p = url.pathname;

  // Endpoint di hot-reload gestito qui (non nel modulo routes, altrimenti non
  // potrebbe ri-bindare la reference `handleRequest`).
  if (p === '/api/panel/reload' && req.method === 'POST') {
    try {
      await loadRoutes();
      return sendJson(res, 200, { ok: true, reloaded_at: lastRoutesReloadAt });
    } catch (e) { return sendJson(res, 500, { ok: false, error: e.message }); }
  }
  if (p === '/api/panel/info' && req.method === 'GET') {
    return sendJson(res, 200, { pid: process.pid, routes_reloaded_at: lastRoutesReloadAt });
  }

  try {
    return await handleRequest(req, res, deps);
  } catch (e) {
    console.error('route handler error:', e.message);
    if (!res.headersSent) return sendJson(res, 500, { error: e.message });
  }
});

const cfg = loadConfig();
const port = cfg.ui?.port || 7777;
server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`Porta ${port} già in uso — un'altra istanza del panel è già attiva. Uscita.`);
    process.exit(0);
  } else {
    console.error('Server error:', err.message);
  }
});

server.listen(port, '127.0.0.1', () => {
  console.log(`Control Panel: http://localhost:${port}`);
  startBridge();
  if (cfg.browser?.enabled) {
    const insts = getInstances(cfg);
    insts.forEach((inst, i) => {
      if (inst.autostart !== false) {
        setTimeout(() => startChrome(inst.name), 300 + i * 500);
      }
    });
  }
});
