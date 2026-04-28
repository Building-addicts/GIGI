import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
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
const PASSPORT_FILE = path.join(LOGS_DIR, 'browser-passport.json');
const PASSPORT_INSTANCE = 'passport';
const PUBLIC_DIR = path.join(__dirname, 'public');
try { fs.mkdirSync(LOGS_DIR, { recursive: true }); } catch {}
const TASK_NAME = 'GigiHarnessServer';
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
const LOGIN_SITES = [
  { id: 'google',   domain: 'google.com' },
  { id: 'ubereats', domain: 'ubereats.com' },
  { id: 'doordash', domain: 'doordash.com' },
  { id: 'amazon',   domain: 'amazon.com' },
  { id: 'booking',  domain: 'booking.com' },
  { id: 'airbnb',   domain: 'airbnb.com' },
];

const PASSPORT_DEFAULTS = {
  version: 1,
  domains: {},
  events: [],
  guardrails: {
    confirmation_required_for: [
      'pay / buy / place or confirm order / confirm payment / use card, PayPal, or Apple Pay',
      'accept subscriptions, free trials, renewals, or recurring billing',
      'modify or delete important files, accounts, data, reservations, bookings, or services'
    ],
    never_do: [
      'bypass CAPTCHA',
      'bypass MFA/2FA',
      'steal, extract, or store passwords'
    ]
  }
};

const PASSPORT_CREDENTIAL_POLICY = {
  ok: true,
  mode: 'browser_os_managed_credentials',
  summary: 'GIGI usa il profilo Chrome Passport persistente e delega credenziali, autofill, passkey e password manager al browser/OS.',
  allowed: [
    'riusare cookie/sessioni salvate nel profilo Chrome Passport dedicato',
    'lasciare che Chrome, il sistema operativo o un password manager compilino credenziali/passkey',
    'richiedere takeover umano per CAPTCHA, MFA/2FA, OTP e security challenge',
    'stimare lo stato login da segnali non sensibili come URL, testo pagina e presenza/nomi cookie'
  ],
  never_do: [
    'bypass CAPTCHA, reCAPTCHA o hCaptcha',
    'bypass MFA/2FA, OTP o security challenge',
    'leggere, estrarre, intercettare, loggare o salvare password/passkey/segreti',
    'chiedere a GIGI di custodire password o token utente'
  ],
  user_action: 'Completa manualmente login/CAPTCHA/2FA nella finestra Chrome Passport; salva password/passkey solo nel browser/OS o nel tuo password manager.'
};

const AUTH_COOKIE_RE = /(session|sess|auth|token|sid|sso|login|logged|secure|remember|account|user|idp|oauth)/i;
const LOGIN_TEXT_RE = /(sign in|log in|login|accedi|connexion|anmelden|password|passcode|email address|continue with google|forgot password)/i;
const LOGGED_IN_TEXT_RE = /(sign out|log out|logout|account|profile|your orders|my trips|dashboard|settings|il tuo account|esci)/i;
const EXPIRED_TEXT_RE = /(session expired|sessione scaduta|please sign in again|for your security|reauthenticate|login required)/i;
const TAKEOVER_TEXT_RE = /(captcha|recaptcha|hcaptcha|two-factor|two factor|2fa|mfa|verification code|codice di verifica|one-time code|otp|security check|challenge|verify it's you|verifica che sia tu)/i;

const GUARDRAIL_RULES = [
  { id: 'payment_or_purchase', re: /(pay|payment|checkout|buy now|place order|confirm order|submit order|purchase|paga|pagamento|compra|acquista|ordine|carta|credit card|debit card|paypal|apple pay)/i, description: 'pagare/comprare/inviare ordine/confermare pagamento/usare carta-PayPal-Apple Pay' },
  { id: 'subscription_trial_renewal', re: /(subscribe|subscription|free trial|trial|renew|renewal|abbonamento|prova gratuita|rinnovo|recurring|billing)/i, description: 'accettare abbonamenti/prove gratuite/rinnovi' },
  { id: 'important_change_or_delete', re: /(delete|remove|cancel|modify|change|erase|close account|terminate|cancella|elimina|annulla|modifica|prenotazione|reservation|booking|account|file|data|servizio|service)/i, description: 'modificare/cancellare file/account/dati importanti/prenotazioni/servizi' }
];

function canonicalUrl(raw) {
  if (!raw || typeof raw !== 'string') return null;
  const trimmed = raw.trim();
  if (!trimmed) return null;
  try { return new URL(trimmed.includes('://') ? trimmed : `https://${trimmed}`); }
  catch { return null; }
}

function hostnameForUrl(raw) {
  const u = canonicalUrl(raw);
  return u ? u.hostname.replace(/^www\./, '').toLowerCase() : null;
}

function cookieMatchesDomain(cookie, host) {
  if (!host || !cookie?.domain) return false;
  const d = cookie.domain.replace(/^\./, '').toLowerCase();
  return host === d || host.endsWith(`.${d}`) || d.endsWith(`.${host}`);
}

function passportProfileDir() {
  return path.join(dirnameSafe(), '..', 'browser-passport-profile');
}

function dirnameSafe() { return __dirname; }

function loadPassport() {
  try {
    const parsed = JSON.parse(fs.readFileSync(PASSPORT_FILE, 'utf8'));
    return { ...PASSPORT_DEFAULTS, ...parsed, domains: parsed.domains || {}, events: parsed.events || [] };
  } catch {
    return structuredClone(PASSPORT_DEFAULTS);
  }
}

function savePassport(state) {
  const compact = { ...state, events: (state.events || []).slice(-200) };
  fs.writeFileSync(PASSPORT_FILE, JSON.stringify(compact, null, 2));
  return compact;
}

function rememberPassportDomain(host, patch = {}) {
  if (!host) return null;
  const state = loadPassport();
  const now = new Date().toISOString();
  const cur = state.domains[host] || { domain: host, first_seen_at: now, visits: 0, urls: [] };
  const next = { ...cur, ...patch, domain: host, last_seen_at: now, visits: (cur.visits || 0) + (patch.countVisit === false ? 0 : 1) };
  delete next.countVisit;
  if (patch.url) next.urls = Array.from(new Set([patch.url, ...(cur.urls || [])])).slice(0, 10);
  state.domains[host] = next;
  state.events = [...(state.events || []), { at: now, domain: host, state: next.state || patch.state || 'unknown', url: patch.url || null }].slice(-200);
  savePassport(state);
  return next;
}

function checkPassportGuardrails(input = '') {
  const text = typeof input === 'string' ? input : JSON.stringify(input || {});
  const hits = GUARDRAIL_RULES.filter(rule => rule.re.test(text)).map(rule => ({ id: rule.id, description: rule.description }));
  return {
    ok: true,
    requires_confirmation: hits.length > 0,
    reasons: hits,
    policy: PASSPORT_DEFAULTS.guardrails,
    note: hits.length ? 'Serve conferma esplicita dell’utente prima di procedere.' : 'Nessuna conferma speciale rilevata dalle guardrail testuali.'
  };
}

function getPassportCredentialPolicy() {
  return PASSPORT_CREDENTIAL_POLICY;
}

// Pool di istanze Chrome: name -> { proc, startedAt, manuallyStopped }
const chromeProcs = new Map();
// Crash counter per Chrome: name -> [timestamp, ...] (ultimi crash)
const chromeCrashLog = new Map();
const CHROME_MAX_CRASHES = 5;
const CHROME_CRASH_WINDOW_MS = 2 * 60 * 1000;
let termProc = null;

function getInstances(cfg) {
  const br = cfg.browser || {};
  const base = Array.isArray(br.instances) && br.instances.length ? br.instances : [{
    name: 'main',
    profile_dir: br.profile_dir,
    cdp_port: br.cdp_port || 9224,
    autostart: true
  }];
  if (base.some(i => i.name === PASSPORT_INSTANCE)) return base;
  const usedPorts = new Set(base.map(i => Number(i.cdp_port)).filter(Boolean));
  let passportPort = Number(br.passport_cdp_port || 9234);
  while (usedPorts.has(passportPort)) passportPort += 1;
  return [
    ...base,
    {
      name: PASSPORT_INSTANCE,
      profile_dir: br.passport_profile_dir || passportProfileDir(),
      cdp_port: passportPort,
      autostart: br.passport_autostart !== false
    }
  ];
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

async function waitForChromeReady(name = 'main', timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await chromeAlive(name)) return true;
    await new Promise(r => setTimeout(r, 250));
  }
  return false;
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

async function navigateInstance(name, url) {
  const cfg = loadConfig();
  const inst = findInstance(cfg, name);
  if (!inst) return { ok: false, error: 'instance not found' };
  try {
    const b = await getPpBrowser(name, inst.cdp_port);
    const pages = await b.pages();
    const page = pages.find(p => !p.url().startsWith('devtools://')) || await b.newPage();
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 15000 });
    return { ok: true, url: page.url() };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

async function getPassportStatus(name = PASSPORT_INSTANCE, rawUrl = null) {
  const cfg = loadConfig();
  const inst = findInstance(cfg, name);
  if (!inst) return { ok: false, error: 'instance not found', state: 'unknown' };
  const target = rawUrl ? canonicalUrl(rawUrl) : null;
  const targetHost = target ? target.hostname.replace(/^www\./, '').toLowerCase() : null;

  try {
    const b = await getPpBrowser(name, inst.cdp_port);
    const pages = await b.pages();
    const page = pages.find(p => !p.url().startsWith('devtools://')) || pages[0] || await b.newPage();
    const currentUrl = page.url();
    const currentHost = hostnameForUrl(currentUrl);
    const host = targetHost || currentHost;

    const client = await page.createCDPSession();
    const { cookies } = await client.send('Network.getAllCookies');
    await client.detach().catch(() => {});
    const domainCookies = cookies.filter(c => cookieMatchesDomain(c, host));
    const authCookies = domainCookies.filter(c => AUTH_COOKIE_RE.test(c.name));

    let pageSignals = { title: '', text: '', url: currentUrl };
    if (!targetHost || targetHost === currentHost) {
      pageSignals = await page.evaluate(() => ({
        title: document.title || '',
        text: (document.body?.innerText || '').slice(0, 12000),
        url: location.href
      })).catch(() => pageSignals);
    }

    const signalText = `${pageSignals.title}\n${pageSignals.text}`;
    const loginLikeUrl = /(login|signin|sign-in|auth|account\/login|session)/i.test(pageSignals.url || '');
    const takeoverRequired = TAKEOVER_TEXT_RE.test(signalText);
    const expired = EXPIRED_TEXT_RE.test(signalText);
    const loginPrompt = LOGIN_TEXT_RE.test(signalText) || loginLikeUrl;
    const loggedInText = LOGGED_IN_TEXT_RE.test(signalText);

    let state = 'unknown';
    let confidence = 'low';
    const evidence = {
      domain_cookies: domainCookies.length,
      auth_cookie_names: authCookies.map(c => c.name).slice(0, 12),
      login_prompt: loginPrompt,
      logged_in_text: loggedInText,
      expired,
      takeover_required: takeoverRequired,
      current_url: currentUrl
    };

    if (takeoverRequired) { state = 'needs_login'; confidence = 'high'; }
    else if (expired) { state = 'expired'; confidence = 'high'; }
    else if (authCookies.length && !loginPrompt) { state = 'logged_in'; confidence = loggedInText ? 'high' : 'medium'; }
    else if (domainCookies.length >= 3 && loggedInText && !loginPrompt) { state = 'logged_in'; confidence = 'medium'; }
    else if (loginPrompt && !authCookies.length) { state = 'needs_login'; confidence = 'medium'; }
    else if (loginPrompt && authCookies.length) { state = 'expired'; confidence = 'medium'; }

    if (host) rememberPassportDomain(host, {
      url: target ? target.href : currentUrl,
      state,
      confidence,
      takeover_required: takeoverRequired,
      last_checked_at: new Date().toISOString(),
      cookie_count: domainCookies.length,
      auth_cookie_count: authCookies.length
    });

    return {
      ok: true,
      instance: name,
      domain: host,
      url: target ? target.href : currentUrl,
      current_url: currentUrl,
      state,
      confidence,
      takeover_required: takeoverRequired,
      user_takeover: takeoverRequired || state === 'needs_login' || state === 'expired',
      evidence
    };
  } catch (e) {
    return { ok: false, error: e.message, state: 'unknown' };
  }
}

async function navigatePassport(name = PASSPORT_INSTANCE, rawUrl) {
  const target = canonicalUrl(rawUrl);
  if (!target) return { ok: false, error: 'valid url required' };
  const started = await chromeAlive(name) ? { ok: true, already_running: true } : startChrome(name);
  if (started.ok === false && !/già in esecuzione/i.test(started.msg || '')) return started;
  if (!started.already_running) {
    const ready = await waitForChromeReady(name);
    if (!ready) return { ok: false, error: `Chrome "${name}" non pronto sul CDP dopo l'avvio` };
  }
  const result = await navigateInstance(name, target.href);
  if (!result.ok) return result;
  const host = target.hostname.replace(/^www\./, '').toLowerCase();
  rememberPassportDomain(host, { url: result.url || target.href, state: 'unknown' });
  const status = await getPassportStatus(name, result.url || target.href);
  return { ...result, passport: status };
}

async function getLoginStatus(name) {
  const cfg = loadConfig();
  const inst = findInstance(cfg, name);
  if (!inst) return {};
  try {
    const b = await getPpBrowser(name, inst.cdp_port);
    const pages = await b.pages();
    if (!pages.length) return {};
    const client = await pages[0].createCDPSession();
    const { cookies } = await client.send('Network.getAllCookies');
    await client.detach().catch(() => {});
    const result = {};
    for (const site of LOGIN_SITES) {
      result[site.id] = cookies.some(c =>
        (c.domain === `.${site.domain}` || c.domain === site.domain || c.domain.endsWith(`.${site.domain}`)) &&
        c.httpOnly === true
      );
    }
    return result;
  } catch { return {}; }
}

function startBridge() {
  if (bridge) return { ok: false, msg: 'già attivo' };
  bridge = spawn(process.execPath, [path.join(__dirname, 'server.js')], {
    cwd: __dirname,
    windowsHide: true,
    detached: false,
    stdio: ['ignore', 'pipe', 'pipe']
  });
  bridge.stdout.on('data', (d) => process.stdout.write(`[bridge] ${d}`));
  bridge.stderr.on('data', (d) => process.stderr.write(`[bridge:err] ${d}`));
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
  navigateInstance, getLoginStatus, getPassportStatus, navigatePassport, loadPassport, checkPassportGuardrails, getPassportCredentialPolicy, rememberPassportDomain,
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
const port = cfg.panel?.port || cfg.ui?.port || 7777;
server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`Porta ${port} già in uso — un'altra istanza del panel è già attiva. Uscita.`);
    process.exit(0);
  } else {
    console.error('Server error:', err.message);
  }
});

function getLanIP() {
  for (const iface of Object.values(os.networkInterfaces()).flat()) {
    if (iface?.family === 'IPv4' && !iface.internal) return iface.address;
  }
  return '127.0.0.1';
}

// Decide the boot label based on the *actual* URL, not the configured mode.
// Prevents the "URL: 192.168.x.x [quick tunnel]" inconsistency seen when the
// cloudflared subprocess hadn't spawned yet but mode=quick in the config.
function tunnelLabelForUrl(urlStr) {
  if (!urlStr) return ' [LAN only]';
  try {
    const u = new URL(urlStr);
    const host = u.hostname;
    if (/\.trycloudflare\.com$/i.test(host)) return ' [quick tunnel]';
    // IPv4 literal or localhost → LAN.
    if (host === 'localhost' || /^\d{1,3}(\.\d{1,3}){3}$/.test(host)) return ' [LAN only]';
    // Any other FQDN over HTTPS → named tunnel (or other public CNAME).
    if (u.protocol === 'https:') return ' [named tunnel]';
    return ' [LAN only]';
  } catch {
    return ' [LAN only]';
  }
}

async function printPairingQR() {
  // Wait for both the bridge AND the tunnel (when mode=quick|named) to be
  // ready before printing the QR. /api/pair returns 503 with code
  // TUNNEL_NOT_READY while cloudflared is still spawning — we must not fall
  // through to the LAN fallback in that window or the QR will encode a LAN
  // URL that the iPhone can't reach when off-WiFi (issue #113).
  const iosCfgPort = cfg.server?.port || 7779;
  const tunnelMode = cfg?.tunnel?.mode || 'manual';
  const requiresTunnel = (tunnelMode === 'quick' || tunnelMode === 'named');

  let payload = null;
  // Up to 20s polling at 500ms — covers cloudflared cold start (~4-5s typ.)
  // plus margin for slow links / DNS warmup.
  for (let i = 0; i < 40; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${iosCfgPort}/api/pair`, { signal: AbortSignal.timeout(500) });
      if (r.status === 200) {
        const j = await r.json().catch(() => null);
        if (j && (j.data || j.url)) {
          payload = j.data || j;
          break;
        }
      }
      // 503 TUNNEL_NOT_READY → keep polling. Other non-200 → keep polling too.
    } catch {}
    await new Promise(r => setTimeout(r, 500));
  }

  try {
    const { createRequire } = await import('node:module');
    const require = createRequire(import.meta.url);
    const qrcode = require('qrcode-terminal');

    // If the tunnel never came up and we are in quick|named mode, do NOT
    // fall back to a LAN-only QR — that would encode an unreachable URL for
    // off-WiFi clients. Print a clear warning instead.
    if (!payload && requiresTunnel) {
      console.warn('[pair] Tunnel non pronto dopo 20s — QR non stampato.');
      console.warn('[pair] Apri http://localhost:7777/pair quando il tunnel è ready.');
      return;
    }

    // Fallback: only valid for manual / lan modes — encode LAN IP directly.
    if (!payload) {
      const iosCfg = cfg.ios || {};
      const secret = process.env.HARNESS_SHARED_SECRET || iosCfg.shared_secret || '';
      const url = `http://${getLanIP()}:${iosCfgPort}`;
      payload = { url, secret, deviceName: os.hostname(), mode: tunnelMode, createdAt: new Date().toISOString() };
    }

    const qrString = JSON.stringify(payload);
    const tunnelNote = tunnelLabelForUrl(payload.url);
    console.log('\n── GIGI Pairing QR — scan from iPhone: Settings → Harness → Pair ──');
    qrcode.generate(qrString, { small: true });
    console.log(`URL: ${payload.url}${tunnelNote}`);
    console.log(`Mode: ${payload.mode || 'manual'} · Device: ${payload.deviceName}`);
    console.log('To regenerate: open http://localhost:7777/pair in browser');
    console.log('────────────────────────────────────────────────────────────────\n');
  } catch {
    // qrcode-terminal not installed — run: npm install
    console.log('[pair] Install qrcode-terminal (npm install) to see the QR in terminal.');
    console.log(`[pair] Or open http://localhost:7777/pair in browser to get the QR.`);
  }
}

server.listen(port, '127.0.0.1', () => {
  console.log(`Control Panel: http://localhost:${port}`);
  startBridge();
  printPairingQR();
  if (cfg.browser?.enabled) {
    const insts = getInstances(cfg);
    insts.forEach((inst, i) => {
      if (inst.autostart !== false) {
        setTimeout(() => startChrome(inst.name), 300 + i * 500);
      }
    });
  }
});
