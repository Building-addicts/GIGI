// Watcher worker: task ricorrenti indipendenti dalle sessioni Claude via Telegram.
// Ogni watcher fa partire periodicamente una breve invocazione di Claude con un prompt fissato.
// Memoria: per default stateless (si appoggia a file JSON); opzionalmente usa session-resume.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const WATCHERS_FILE = path.join(__dirname, 'watchers.json');
const STATE_FILE = path.join(__dirname, 'logs', 'watchers_state.json');
const RUNTIME_FILE = path.join(__dirname, 'logs', 'watchers_runtime.json');
const LOG_FILE = path.join(__dirname, 'logs', 'watchers.log');

const timers = new Map();     // id -> NodeJS.Timeout
const running = new Map();    // id -> true se fire in corso
let extLog = () => {};
let stateListener = null;
let lastCfg = null;           // memorizza cfg per hot-reload su edit manuale
let fileWatcher = null;       // fs.watchFile handle
let reloadDebounce = null;    // timer debounce reload

export function onStateChange(fn) { stateListener = typeof fn === 'function' ? fn : null; }

function emitStateChange(kind, id) {
  if (!stateListener) return;
  try { stateListener({ kind, id, at: Date.now() }); } catch (e) { wlog('stateListener error:', e.message); }
}

function wlog(...args) {
  const line = `[${new Date().toISOString()}] ${args.map(a => typeof a === 'string' ? a : JSON.stringify(a)).join(' ')}`;
  try { fs.appendFileSync(LOG_FILE, line + '\n'); } catch {}
  try { extLog('[watcher]', ...args); } catch {}
}

export function loadWatchers() {
  try { return JSON.parse(fs.readFileSync(WATCHERS_FILE, 'utf8')); }
  catch { return { watchers: [] }; }
}

export function saveWatchers(obj) {
  fs.writeFileSync(WATCHERS_FILE, JSON.stringify(obj, null, 2));
}

function loadState() {
  try { return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')); }
  catch { return {}; }
}

function saveState(s) {
  try { fs.writeFileSync(STATE_FILE, JSON.stringify(s, null, 2)); } catch {}
}

// Runtime file: tiene traccia dei fire in volo e sopravvive a restart del bridge.
// Schema: { running: { <watcherId>: { pid, started_at, timeout_at } } }
function loadRuntime() {
  try { return JSON.parse(fs.readFileSync(RUNTIME_FILE, 'utf8')); }
  catch { return { running: {} }; }
}

function saveRuntime(r) {
  try { fs.writeFileSync(RUNTIME_FILE, JSON.stringify(r, null, 2)); } catch {}
}

function isPidAlive(pid) {
  if (!pid) return false;
  try { process.kill(pid, 0); return true; }
  catch (e) { return e.code === 'EPERM'; }
}

function runtimeAcquireLock(id, timeoutMs) {
  const r = loadRuntime();
  if (!r.running) r.running = {};
  const existing = r.running[id];
  if (existing) {
    const alive = isPidAlive(existing.pid);
    const expired = Date.now() > (existing.timeout_at || 0);
    if (alive && !expired) return { acquired: false, existing };
    // Stale: processo morto o timeout superato → pulisci e procedi
    wlog(`[${id}] lock stale (pid=${existing.pid} alive=${alive} expired=${expired}) — clearing`);
  }
  const now = Date.now();
  r.running[id] = { pid: null, started_at: now, timeout_at: now + timeoutMs + 10000 };
  saveRuntime(r);
  return { acquired: true };
}

function runtimeSetPid(id, pid) {
  const r = loadRuntime();
  if (r.running?.[id]) {
    r.running[id].pid = pid;
    saveRuntime(r);
  }
}

function runtimeReleaseLock(id) {
  const r = loadRuntime();
  if (r.running?.[id]) {
    delete r.running[id];
    saveRuntime(r);
  }
}

function nextMidnightRome() {
  // Calcola il prossimo mezzanotte in Europe/Rome come timestamp UTC
  const now = new Date();
  const romeStr = now.toLocaleString('en-CA', { timeZone: 'Europe/Rome', hour12: false });
  // romeStr: "YYYY-MM-DD, HH:MM:SS" → prendi la data e aggiungi 1 giorno
  const [datePart] = romeStr.split(', ');
  const midnight = new Date(`${datePart}T00:00:00`);
  // converti mezzanotte Rome → UTC (offset approssimativo; usiamo trick Intl)
  const romeOffset = -new Date().toLocaleString('en-US', { timeZone: 'Europe/Rome', timeZoneName: 'shortOffset' })
    .match(/GMT([+-]\d+(?::\d+)?)/)?.[1]?.split(':').reduce((h, m) => h * 60 + +m, 0) * 60000 || 0;
  const midnightUTC = midnight.getTime() + 24 * 3600 * 1000 - romeOffset;
  return midnightUTC > Date.now() ? midnightUTC : midnightUTC + 24 * 3600 * 1000;
}

async function fireWatcher(w, cfg) {
  if (running.get(w.id)) {
    wlog(`[${w.id}] skip — fire precedente ancora in corso (in-memory guard)`);
    return;
  }

  // Controlla pausa globale per rate limit
  const stCheck = loadState();
  const pausedUntil = stCheck._rate_limit_paused_until || 0;
  if (pausedUntil > Date.now()) {
    const resumeAt = new Date(pausedUntil).toLocaleTimeString('it-IT', { timeZone: 'Europe/Rome' });
    wlog(`[${w.id}] skip — rate limit globale, riprendo alle ${resumeAt} (Europe/Rome)`);
    return;
  }

  // Lock persistente su disco: sopravvive a restart/hot-reload del bridge.
  // Evita doppio spawn quando start() viene chiamato mentre un claude child è ancora in volo.
  const lockTimeoutMs = w.timeout_ms || cfg?.claude?.timeout_ms || 180000;
  const lock = runtimeAcquireLock(w.id, lockTimeoutMs);
  if (!lock.acquired) {
    const ageSec = Math.floor((Date.now() - (lock.existing?.started_at || 0)) / 1000);
    wlog(`[${w.id}] skip — lock persistente attivo (pid=${lock.existing?.pid} age=${ageSec}s)`);
    return;
  }

  running.set(w.id, true);
  emitStateChange('fire_start', w.id);
  const started = Date.now();
  const state = loadState();
  if (!state[w.id]) state[w.id] = {};

  // Istruzioni one-shot iniettate via /watcher <id> say <testo>.
  // File append-only: accumula più istruzioni fino al prossimo fire, poi viene cancellato.
  const instructionsFile = path.join(__dirname, 'logs', `${w.id}-instructions.md`);
  let injectedPrompt = w.prompt || '';
  try {
    if (fs.existsSync(instructionsFile)) {
      const injected = fs.readFileSync(instructionsFile, 'utf8').trim();
      if (injected) {
        injectedPrompt = `[ISTRUZIONE PRIORITARIA UTENTE — applicala subito, precede le regole del prompt]\n${injected}\n[FINE ISTRUZIONE]\n\n${injectedPrompt}`;
        wlog(`[${w.id}] injected ${injected.length} chars di istruzioni one-shot`);
      }
      fs.unlinkSync(instructionsFile);
    }
  } catch (e) {
    wlog(`[${w.id}] injection read/delete error: ${e.message}`);
  }

  const args = [
    '-p', injectedPrompt,
    '--output-format', 'json',
    '--permission-mode', cfg?.claude?.permission_mode || 'bypassPermissions'
  ];

  const useSession = !!w.use_session;
  let sessionId = state[w.id].session_id || null;
  if (useSession) {
    if (!sessionId) {
      sessionId = randomUUID();
      args.push('--session-id', sessionId);
      if (cfg?.claude?.system_prompt) args.push('--append-system-prompt', cfg.claude.system_prompt);
    } else {
      args.push('--resume', sessionId);
    }
  } else if (cfg?.claude?.system_prompt) {
    args.push('--append-system-prompt', cfg.claude.system_prompt);
  }

  const bin = cfg?.claude?.bin || 'claude';
  const timeout = w.timeout_ms || cfg?.claude?.timeout_ms || 180000;
  wlog(`[${w.id}] fire session=${useSession ? (sessionId || '').slice(0,8) : 'stateless'} timeout=${timeout}ms`);

  // stdio: stdin 'ignore' per chiudere subito (evita il warning "no stdin data received in 3s"
  // e garantisce che Claude non aspetti input interattivo bloccandosi).
  const child = spawn(bin, args, {
    shell: false,
    windowsHide: true,
    timeout,
    stdio: ['ignore', 'pipe', 'pipe']
  });
  runtimeSetPid(w.id, child.pid);
  let stdout = '', stderr = '';
  child.stdout.on('data', d => stdout += d.toString());
  child.stderr.on('data', d => stderr += d.toString());
  // Safeguard: se spawn timeout non killa per qualche motivo, forza un SIGKILL + cleanup dopo timeout+10s
  const hardKill = setTimeout(() => {
    try { child.kill('SIGKILL'); } catch {}
    wlog(`[${w.id}] hard-kill after ${timeout + 10000}ms (spawn timeout didn't terminate)`);
  }, timeout + 10000);
  const exitCode = await new Promise(resolve => {
    child.on('error', err => { wlog(`[${w.id}] spawn error: ${err.message}`); resolve(-1); });
    child.on('close', code => resolve(code));
  });
  clearTimeout(hardKill);

  const dur = Date.now() - started;
  let resultText = '';
  let apiErrorStatus = null;
  // Parsing unificato: prima tenta JSON singolo, poi stream line-by-line
  try {
    const j = JSON.parse(stdout.trim());
    resultText = j.result || j.message || '';
    apiErrorStatus = j.api_error_status ?? null;
  } catch {
    const lines = stdout.trim().split('\n');
    for (let i = lines.length - 1; i >= 0; i--) {
      try {
        const o = JSON.parse(lines[i]);
        if (o.type === 'result') {
          if (typeof o.result === 'string') resultText = o.result;
          apiErrorStatus = o.api_error_status ?? null;
          break;
        }
      } catch {}
    }
  }

  const summary = (resultText || stderr || '').replace(/\s+/g, ' ').slice(0, 300);
  wlog(`[${w.id}] done code=${exitCode} ${dur}ms — ${summary}`);

  // Budget tracking: incrementa responses_count quando l'output dichiara action=sent.
  // Si auto-disabilita il watcher quando raggiunge max_responses.
  let budgetReached = false;
  if (typeof w.max_responses === 'number' && w.max_responses > 0) {
    const actionSent = /action\s*=\s*sent\b/i.test(resultText || '');
    if (actionSent) {
      const stB = loadState();
      if (!stB[w.id]) stB[w.id] = {};
      stB[w.id].responses_count = (stB[w.id].responses_count || 0) + 1;
      saveState(stB);
      wlog(`[${w.id}] budget ${stB[w.id].responses_count}/${w.max_responses}`);
      if (stB[w.id].responses_count >= w.max_responses) {
        budgetReached = true;
        const cur = loadWatchers();
        const arr = cur.watchers || [];
        const idx = arr.findIndex(x => x.id === w.id);
        if (idx >= 0 && arr[idx].enabled) {
          arr[idx].enabled = false;
          saveWatchers({ watchers: arr });
          const initT = timers.get(w.id + ':init');
          const intT = timers.get(w.id + ':interval');
          if (initT) { try { clearTimeout(initT); } catch {} timers.delete(w.id + ':init'); }
          if (intT) { try { clearInterval(intT); } catch {} timers.delete(w.id + ':interval'); }
          wlog(`[${w.id}] budget raggiunto (${w.max_responses}) — watcher auto-disabilitato`);
          try { extLog(`🎯 Watcher "${w.id}" disabilitato — budget raggiunto (${stB[w.id].responses_count}/${w.max_responses}).`); } catch {}
          emitStateChange('reload', null);
        }
      }
    }
  }

  // Rate limit 429: pausa globale di tutti i worker fino a mezzanotte
  if (apiErrorStatus === 429 || (resultText && resultText.includes("hit your limit"))) {
    const resumeAt = nextMidnightRome();
    const st0 = loadState();
    st0._rate_limit_paused_until = resumeAt;
    saveState(st0);
    wlog(`[GLOBAL] rate limit 429 rilevato — tutti i worker in pausa fino a ${new Date(resumeAt).toISOString()}`);
    try { extLog(`⚠️ Rate limit Claude raggiunto. Worker in pausa fino a mezzanotte (${new Date(resumeAt).toLocaleTimeString('it-IT', { timeZone: 'Europe/Rome' })} Rome).`); } catch {}
  }

  // Debug log per-fire: se il fire è andato male (exitCode non 0 o empty), dump completo su file separato
  if (exitCode !== 0 || !resultText) {
    try {
      const dbgPath = path.join(__dirname, 'logs', `watcher-${w.id}-debug.log`);
      const block = `\n\n═══ ${new Date().toISOString()} code=${exitCode} dur=${dur}ms ═══\n--- STDOUT (${stdout.length} bytes) ---\n${stdout.slice(0, 4000)}\n--- STDERR (${stderr.length} bytes) ---\n${stderr.slice(0, 4000)}\n`;
      fs.appendFileSync(dbgPath, block);
    } catch {}
  }

  const st = loadState();
  st[w.id] = {
    ...(st[w.id] || {}),
    last_fire_at: started,
    last_duration_ms: dur,
    last_exit_code: exitCode,
    last_summary: summary,
    session_id: sessionId
  };
  saveState(st);
  running.delete(w.id);
  runtimeReleaseLock(w.id);
  emitStateChange('fire_end', w.id);
}

// Hot-reload: osserva WATCHERS_FILE e ri-avvia i timer quando cambia su disco
// (edit manuale, panel, script esterni). Idempotente — setup una sola volta.
function watchWatchersFile() {
  if (fileWatcher) return;
  try {
    fileWatcher = fs.watch(WATCHERS_FILE, { persistent: false }, () => {
      if (reloadDebounce) clearTimeout(reloadDebounce);
      reloadDebounce = setTimeout(() => {
        reloadDebounce = null;
        try {
          // Sanity check: parse deve riuscire (evita reload su scrittura parziale)
          loadWatchers();
          wlog('watchers.json modificato — hot-reload timers');
          start(lastCfg, extLog);
        } catch (e) {
          wlog('hot-reload skip — parse failed:', e.message);
        }
      }, 500);
    });
    fileWatcher.on('error', (e) => { wlog('fs.watch error:', e.message); });
  } catch (e) {
    wlog('watchWatchersFile setup failed:', e.message);
  }
}

export function start(cfg, log) {
  extLog = log || (() => {});
  lastCfg = cfg;
  stop();
  watchWatchersFile();
  const { watchers = [] } = loadWatchers();
  let active = 0;
  const STAGGER_MS = 30000; // 30s di offset tra watcher per evitare collisioni sul browser
  for (const w of watchers) {
    if (!w.enabled) continue;
    const myIndex = active;
    active++;
    const intervalMs = Math.max(5, w.interval_sec || 60) * 1000;
    const offsetMs = myIndex * STAGGER_MS;
    const initialDelay = 8000 + offsetMs;
    wlog(`[${w.id}] start — ogni ${intervalMs/1000}s, offset iniziale +${offsetMs/1000}s`);
    // Primo fire e interval sfasati: evitano che due watcher partano allo stesso millisecondo
    const initTimer = setTimeout(() => {
      fireWatcher(w, cfg).catch(e => wlog(`[${w.id}] initial fire error: ${e.message}`));
      const intervalTimer = setInterval(() => {
        fireWatcher(w, cfg).catch(e => wlog(`[${w.id}] fire error: ${e.message}`));
      }, intervalMs);
      timers.set(w.id + ':interval', intervalTimer);
    }, initialDelay);
    timers.set(w.id + ':init', initTimer);
  }
  wlog(`worker started — ${active} watcher attivi su ${watchers.length}`);
  emitStateChange('reload', null);
  return active;
}

export function stop() {
  for (const t of timers.values()) { try { clearTimeout(t); } catch {} try { clearInterval(t); } catch {} }
  timers.clear();
  running.clear();
}

export function getStatus() {
  const { watchers = [] } = loadWatchers();
  const state = loadState();
  const runtime = loadRuntime();
  const rtRunning = runtime.running || {};
  const rateLimitPausedUntil = state._rate_limit_paused_until || null;
  return {
    rate_limit_paused_until: rateLimitPausedUntil,
    rate_limit_active: rateLimitPausedUntil ? rateLimitPausedUntil > Date.now() : false,
    watchers: watchers.map(w => {
      // running_now: in-memory guard (processo bridge) OPPURE lock su disco con PID vivo (cross-process).
      const rt = rtRunning[w.id];
      const rtAlive = rt && isPidAlive(rt.pid) && Date.now() < (rt.timeout_at || 0);
      return {
        id: w.id,
        name: w.name,
        enabled: !!w.enabled,
        interval_sec: w.interval_sec,
        use_session: !!w.use_session,
        running_now: running.has(w.id) || !!rtAlive,
        fire_started_at: rtAlive ? rt.started_at : null,
        last_fire_at: state[w.id]?.last_fire_at || null,
        last_duration_ms: state[w.id]?.last_duration_ms || null,
        last_exit_code: state[w.id]?.last_exit_code ?? null,
        last_summary: state[w.id]?.last_summary || null,
        session_id: state[w.id]?.session_id || null,
        max_responses: typeof w.max_responses === 'number' ? w.max_responses : null,
        responses_count: state[w.id]?.responses_count || 0
      };
    })
  };
}

export function resetBudget(id) {
  const st = loadState();
  if (st[id]) {
    st[id].responses_count = 0;
    saveState(st);
    wlog(`[${id}] budget counter reset`);
    emitStateChange('budget_reset', id);
    return true;
  }
  return false;
}

export function setBudget(id, max) {
  const cur = loadWatchers();
  const arr = cur.watchers || [];
  const i = arr.findIndex(x => x.id === id);
  if (i < 0) return false;
  if (max === null || max === undefined) {
    delete arr[i].max_responses;
  } else {
    const n = Number(max);
    if (!Number.isFinite(n) || n <= 0) return false;
    arr[i].max_responses = Math.floor(n);
  }
  saveWatchers({ watchers: arr });
  wlog(`[${id}] budget set to ${arr[i].max_responses ?? 'off'}`);
  emitStateChange('budget_set', id);
  return true;
}

export function clearRateLimit() {
  const st = loadState();
  delete st._rate_limit_paused_until;
  saveState(st);
  wlog('[GLOBAL] rate limit pausa rimossa manualmente');
}

export async function fireNow(id, cfg) {
  const { watchers = [] } = loadWatchers();
  const w = watchers.find(x => x.id === id);
  if (!w) throw new Error(`watcher "${id}" non trovato`);
  await fireWatcher(w, cfg);
}
