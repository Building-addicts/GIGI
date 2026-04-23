import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import * as watchers from './watchers.js';
import { startRpc } from './bridge-rpc.js';
import { transcribeTelegramVoice, modelExists as whisperModelExists } from './transcribe.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const LOGS_DIR = process.env.HARNESS_LOGS_DIR || LOGS_DIR;
const CONFIG_PATH = process.env.HARNESS_CONFIG || path.join(__dirname, 'config.json');
const LOG_FILE = path.join(LOGS_DIR, 'bridge.log');
const STATE_FILE = path.join(LOGS_DIR, 'state.json');
const SESSIONS_FILE = path.join(LOGS_DIR, 'sessions.json');
const LOCK_FILE = path.join(LOGS_DIR, 'bridge.lock');

// Assicura LOGS_DIR esista prima del lockfile
try { fs.mkdirSync(LOGS_DIR, { recursive: true }); } catch {}

// Lock file: evita istanze duplicate
(function acquireLock() {
  if (fs.existsSync(LOCK_FILE)) {
    const pid = parseInt(fs.readFileSync(LOCK_FILE, 'utf8').trim(), 10);
    let alive = false;
    try { process.kill(pid, 0); alive = true; } catch {}
    if (alive) {
      console.error(`[bridge] already running (pid ${pid}), exiting.`);
      process.exit(0);
    }
  }
  fs.writeFileSync(LOCK_FILE, String(process.pid));
  process.on('exit', () => { try { fs.unlinkSync(LOCK_FILE); } catch {} });
  process.on('SIGINT', () => process.exit(0));
  process.on('SIGTERM', () => process.exit(0));
})();

function loadSessions() {
  try { return JSON.parse(fs.readFileSync(SESSIONS_FILE, 'utf8')); } catch { return {}; }
}
function saveSessions(s) {
  try { fs.writeFileSync(SESSIONS_FILE, JSON.stringify(s, null, 2)); } catch {}
}

function loadConfig() {
  return JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
}

function log(...args) {
  const line = `[${new Date().toISOString()}] ${args.map(a => typeof a === 'string' ? a : JSON.stringify(a)).join(' ')}`;
  console.log(line);
  try { fs.appendFileSync(LOG_FILE, line + '\n'); } catch {}
}

const state = {
  started_at: Date.now(),
  requests: 0,
  errors: 0,
  last_request: null,
  last_error: null
};
function saveState() {
  try { fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2)); } catch {}
}

async function tg(token, method, body, signal) {
  const r = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
    ...(signal ? { signal } : {})
  });
  return r.json();
}

const BUILTIN_COMMANDS = [
  { command: 'ping', description: 'Test bot (risponde pong)' },
  { command: 'help', description: 'Guida e comandi disponibili' },
  { command: 'cancel', description: 'Annulla richiesta in corso + coda' },
  { command: 'stop', description: 'Alias di /cancel' },
  { command: 'reset', description: 'Nuova conversazione (azzera sessione)' },
  { command: 'live', description: 'Riapri finestra Claude live' },
  { command: 'watchers', description: 'Lista dei worker e loro stato' },
  { command: 'watcher', description: 'Dettaglio watcher: /watcher <id>' },
  { command: 'watcher_fire', description: 'Scatena subito un watcher: /watcher_fire <id>' },
  { command: 'watcher_on', description: 'Attiva un watcher: /watcher_on <id>' },
  { command: 'watcher_off', description: 'Disattiva un watcher: /watcher_off <id>' },
  { command: 'watcher_log', description: 'Ultimi 10 cicli log workers (opzionale <id>)' },
  { command: 'watcher_budget', description: 'Imposta budget risposte: /watcher_budget <id> <n|off>' },
  { command: 'watcher_reset', description: 'Azzera contatore budget: /watcher_reset <id>' },
  { command: 'watcher_say', description: 'Inietta istruzione one-shot nel prossimo fire: /watcher_say <id> <testo>' },
  { command: 'restart', description: 'Riprendi dopo limite Claude (cambia account prima)' },
  { command: 'memo', description: 'Salva riassunto conversazione in memoria persistente' },
  { command: 'memos', description: 'Mostra storia e stato coda /memo' },
  { command: 'parallel', description: 'Lancia un task Claude in parallelo: /parallel <prompt>' },
  { command: 'model', description: 'Cambia modello Claude: /model sonnet | opus | haiku | status' },
  { command: 'reboot', description: 'Riavvia il bridge tramite panel' },
  { command: 'reload_panel', description: 'Hot-reload route handler del panel (no restart)' },
  { command: 'clean', description: 'Cancella la cronologia della chat' }
];

function sanitizeCmd(s) {
  return String(s || '').replace(/^\//, '').toLowerCase().replace(/[^a-z0-9_]/g, '').slice(0, 32);
}

async function registerTelegramCommands(token, cfg) {
  const sc = cfg.shortcuts || {};
  const extras = Object.keys(sc).map(k => {
    const cmd = sanitizeCmd(k);
    if (!cmd) return null;
    const desc = String(sc[k] || '').replace(/\s+/g, ' ').slice(0, 120) || 'Scorciatoia';
    return { command: cmd, description: desc };
  }).filter(Boolean);
  const all = [...BUILTIN_COMMANDS];
  const seen = new Set(BUILTIN_COMMANDS.map(c => c.command));
  for (const e of extras) if (!seen.has(e.command) && all.length < 100) { all.push(e); seen.add(e.command); }
  try {
    const r = await tg(token, 'setMyCommands', { commands: all });
    log('setMyCommands:', r.ok ? `OK (${all.length})` : JSON.stringify(r));
  } catch (e) { log('setMyCommands error:', e.message); }
}

function mdToHtml(text) {
  // Escaping HTML entities prima di tutto
  let s = text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');

  // Blocchi di codice (``` ... ```) → <pre><code>
  s = s.replace(/```(?:\w+)?\n?([\s\S]*?)```/g, (_, code) =>
    `<pre><code>${code.trimEnd()}</code></pre>`);

  // Codice inline → <code>
  s = s.replace(/`([^`\n]+)`/g, '<code>$1</code>');

  // Intestazioni # ## ### → <b>
  s = s.replace(/^#{1,3} +(.+)$/gm, '<b>$1</b>');

  // Grassetto **testo** o __testo__
  s = s.replace(/\*\*(.+?)\*\*/g, '<b>$1</b>');
  s = s.replace(/__(.+?)__/g, '<b>$1</b>');

  // Corsivo *testo* o _testo_ (non confliggere con bold)
  s = s.replace(/\*([^*\n]+)\*/g, '<i>$1</i>');
  s = s.replace(/_([^_\n]+)_/g, '<i>$1</i>');

  // Link [testo](url)
  s = s.replace(/\[([^\]]+)\]\((https?:\/\/[^)]+)\)/g, '<a href="$2">$1</a>');

  // Linee separatorie --- → spazio vuoto
  s = s.replace(/^-{3,}$/gm, '');

  return s;
}

async function sendMessage(token, chatId, text, opts = {}) {
  const MAX = 3800;
  let lastId = null;
  let firstChunk = true;
  const html = mdToHtml(text);
  for (let i = 0; i < html.length; i += MAX) {
    const chunk = html.slice(i, i + MAX);
    const body = { chat_id: chatId, text: chunk, parse_mode: 'HTML' };
    if (firstChunk && opts.replyTo) {
      body.reply_parameters = { message_id: opts.replyTo, allow_sending_without_reply: true };
    }
    firstChunk = false;
    let r = await tg(token, 'sendMessage', body);
    // Fallback a testo semplice se HTML non parsato correttamente
    if (r && r.ok === false) {
      const plainChunk = text.slice(i, i + MAX);
      const fallback = { chat_id: chatId, text: plainChunk };
      if (i === 0 && opts.replyTo) fallback.reply_parameters = body.reply_parameters;
      r = await tg(token, 'sendMessage', fallback);
    }
    lastId = r?.result?.message_id ?? lastId;
    if (lastId) logMsgId(chatId, lastId);
  }
  return lastId;
}

async function editMessage(token, chatId, messageId, text) {
  try {
    const html = mdToHtml(text);
    const signal = AbortSignal.timeout(8000);
    let r = await tg(token, 'editMessageText', { chat_id: chatId, message_id: messageId, text: html, parse_mode: 'HTML' }, signal);
    if (r && r.ok === false) {
      // Fallback plain
      r = await tg(token, 'editMessageText', { chat_id: chatId, message_id: messageId, text }, AbortSignal.timeout(8000));
    }
    if (r && r.ok === false && r.description && !/not modified/i.test(r.description)) {
      log('editMessage fail:', r.error_code, r.description);
    }
    return r;
  } catch (e) { log('editMessage exception:', e.message); return null; }
}

async function deleteMessage(token, chatId, messageId) {
  try { return await tg(token, 'deleteMessage', { chat_id: chatId, message_id: messageId }); } catch { return null; }
}

const INTERRUPTED_FILE = path.join(LOGS_DIR, 'interrupted.json');
const REBOOT_FLAG_FILE = path.join(LOGS_DIR, 'reboot_pending.json');
const CHAT_MESSAGES_FILE = path.join(LOGS_DIR, 'chat_messages.json');
const TRANSCRIPTS_DIR = path.join(LOGS_DIR, 'transcripts');

try { fs.mkdirSync(TRANSCRIPTS_DIR, { recursive: true }); } catch {}

// Claude Code salva i JSONL di sessione in ~/.claude/projects/<cwd-encoded>/<sessionId>.jsonl
// dove <cwd-encoded> è il path assoluto con ':', '\\' e '/' sostituiti da '-'.
function claudeProjectDir(cwd = __dirname) {
  const encoded = cwd.replace(/[\\\/:]/g, '-');
  return path.join(os.homedir(), '.claude', 'projects', encoded);
}
function claudeSessionJsonlPath(sessionId) {
  if (!sessionId) return null;
  return path.join(claudeProjectDir(), `${sessionId}.jsonl`);
}

// Copia (overwrite idempotente) il JSONL della sessione dentro logs/transcripts/<chatId>.jsonl.
// Così lo storico completo viaggia con la cartella del server anche se sposti 03_HARNESS altrove
// o se ~/.claude/ viene ripulita.
function mirrorTranscript(chatId, sessionId) {
  if (!chatId || !sessionId) return;
  const src = claudeSessionJsonlPath(sessionId);
  if (!src || !fs.existsSync(src)) return;
  const dst = path.join(TRANSCRIPTS_DIR, `${chatId}.jsonl`);
  try { fs.copyFileSync(src, dst); } catch (e) { log('mirror transcript error:', e.message); }
}

// Legge la trascrizione completa di una chat. Preferisce il mirror locale (portabile),
// fallback al JSONL originale se il mirror non esiste ancora.
// Ritorna un array di oggetti parsati (una entry per riga). Mai invocata automaticamente:
// è un helper esposto per tool che ne abbiano bisogno esplicito.
function getChatTranscript(chatId) {
  const mirrored = path.join(TRANSCRIPTS_DIR, `${chatId}.jsonl`);
  let source = null;
  if (fs.existsSync(mirrored)) source = mirrored;
  else {
    const sessions = loadSessions();
    const entry = sessions[chatId];
    const sid = typeof entry === 'string' ? entry : entry?.session_id;
    const src = claudeSessionJsonlPath(sid);
    if (src && fs.existsSync(src)) source = src;
  }
  if (!source) return [];
  try {
    return fs.readFileSync(source, 'utf8')
      .split('\n').filter(Boolean)
      .map(l => { try { return JSON.parse(l); } catch { return null; } })
      .filter(Boolean);
  } catch { return []; }
}

function logMsgId(chatId, msgId) {
  if (!msgId) return;
  try {
    let data = {};
    if (fs.existsSync(CHAT_MESSAGES_FILE)) data = JSON.parse(fs.readFileSync(CHAT_MESSAGES_FILE, 'utf8'));
    if (!data[chatId]) data[chatId] = [];
    data[chatId].push({ id: msgId, ts: Date.now() });
    fs.writeFileSync(CHAT_MESSAGES_FILE, JSON.stringify(data));
  } catch {}
}
function loadInterrupted() {
  try { return JSON.parse(fs.readFileSync(INTERRUPTED_FILE, 'utf8')); } catch { return {}; }
}
function saveInterrupted(obj) {
  try { fs.writeFileSync(INTERRUPTED_FILE, JSON.stringify(obj, null, 2)); } catch {}
}
function clearInterrupted() {
  try { fs.writeFileSync(INTERRUPTED_FILE, '{}'); } catch {}
}

const DOCS_MEMORY = path.join(__dirname, '..', 'docs', 'memory');
const MEMORY_FILE = path.join(DOCS_MEMORY, 'memory.md');
const CONTEXT_FILE = path.join(DOCS_MEMORY, 'context.md');
let snapshotInProgress = false;
// Coda tracciata per /memo: evita collisioni ma serializza le richieste
const memoState = {
  queue: [], // Array<{ cfg, chatId, overrideSessionId, reason, resolve, reject, queuedAt }>
  history: [] // Array<{ chatId, reason, startedAt, endedAt, ok, error?, bytes? }>, max 50
};

async function _doMemoSnapshot(cfg, chatId, overrideSessionId) {
  const sessions = loadSessions();
  const entry = overrideSessionId ? { session_id: overrideSessionId } : sessions[chatId];
  if (!entry) return { ok: false, error: 'no session' };
  const summaryPrompt = 'Crea un riassunto strutturato e conciso (max 2000 parole) di TUTTI i punti importanti di questa conversazione: decisioni prese, task completati, preferenze dell\'utente, informazioni chiave, contesti rilevanti. Scrivi solo il riassunto in italiano, senza preamboli.';
  const args = ['-p', summaryPrompt, '--output-format', 'json',
    '--resume', entry.session_id,
    '--permission-mode', cfg.claude.permission_mode || 'bypassPermissions'];
  const res = await spawnClaude(cfg, args, null, null);
  const lines = (res.stdout || '').trim().split('\n').filter(Boolean);
  let summary = '';
  for (let i = lines.length - 1; i >= 0; i--) {
    try { const o = JSON.parse(lines[i]); if (o.type === 'result' && o.result) { summary = o.result; break; } } catch {}
  }
  if (!summary) { try { const j = JSON.parse((res.stdout || '').trim()); summary = j.result || ''; } catch {} }
  if (summary && summary.length > 50) {
    const ts = new Date().toLocaleString('it-IT');
    fs.writeFileSync(MEMORY_FILE, `# Memoria sessione — ${ts}\n\n${summary}\n`, 'utf8');
    log('memory: snapshot saved', summary.length, 'chars');
    return { ok: true, bytes: summary.length };
  }
  return { ok: false, error: 'empty summary' };
}

async function _processMemoQueue() {
  if (snapshotInProgress) return;
  const job = memoState.queue.shift();
  if (!job) return;
  snapshotInProgress = true;
  const startedAt = Date.now();
  let rec = { chatId: job.chatId, reason: job.reason, queuedAt: job.queuedAt, startedAt, endedAt: null, ok: false };
  try {
    const r = await _doMemoSnapshot(job.cfg, job.chatId, job.overrideSessionId);
    rec.ok = !!r.ok;
    if (!r.ok) rec.error = r.error;
    if (r.bytes) rec.bytes = r.bytes;
    job.resolve(r);
  } catch (e) {
    rec.error = e.message;
    log('memory: snapshot error', e.message);
    job.reject(e);
  } finally {
    rec.endedAt = Date.now();
    memoState.history.push(rec);
    if (memoState.history.length > 50) memoState.history.shift();
    snapshotInProgress = false;
    // processa il prossimo in coda (se presente)
    setImmediate(_processMemoQueue);
  }
}

async function saveMemorySnapshot(cfg, chatId, overrideSessionId = null, reason = 'manual') {
  return new Promise((resolve, reject) => {
    memoState.queue.push({ cfg, chatId, overrideSessionId, reason, resolve, reject, queuedAt: Date.now() });
    _processMemoQueue();
  });
}

function isRateLimit(res) {
  if (res.code === 0) return false;
  const haystack = ((res.stderr || '') + ' ' + (res.error || '') + ' ' + (res.stdout || '')).toLowerCase();
  return ['rate limit', 'rate_limit', 'too many requests', 'usage limit', 'overloaded', '529', 'claude ai usage', 'quota exceeded'].some(p => haystack.includes(p));
}

function isSessionNotFound(res) {
  const haystack = ((res.stdout || '') + ' ' + (res.stderr || '')).toLowerCase();
  return haystack.includes('no conversation found with session id');
}

function killAllActive() {
  let count = 0;
  for (const [chatId, child] of runningChildren.entries()) {
    const runId = runningUpdates.get(chatId);
    if (runId != null) markCancelled(chatId, runId);
    try { child.kill('SIGTERM'); } catch {}
    setTimeout(() => { try { child.kill('SIGKILL'); } catch {} }, 2000);
    count++;
  }
  return count;
}

async function notifyRateLimit(cfg) {
  const token = cfg.telegram.bot_token;
  const allowed = (cfg.telegram.allowed_chat_ids || []).map(String);
  const msg = '⛔ Limite Claude raggiunto. Tutti i processi Claude sono stati terminati.\n\nCambia account su Claude sul PC (o attendi il reset dei crediti), poi invia /restart per riprendere.';
  for (const chatId of allowed) {
    try { await sendMessage(token, chatId, msg); } catch {}
  }
}

function fmtTokens({ input = 0, output = 0, cacheRead = 0, cacheCreate = 0 }) {
  const fmt = n => n >= 1000 ? (n / 1000).toFixed(1).replace(/\.0$/, '') + 'k' : String(n);
  const parts = [];
  if (input) parts.push(`in ${fmt(input)}`);
  if (output) parts.push(`out ${fmt(output)}`);
  if (cacheRead) parts.push(`cache r ${fmt(cacheRead)}`);
  if (cacheCreate) parts.push(`cache w ${fmt(cacheCreate)}`);
  return parts.length ? parts.join(' · ') : '';
}

function shortPath(p) {
  if (!p) return '';
  const s = String(p);
  const m = s.match(/[^\\/]+$/);
  return m ? m[0] : s.slice(-40);
}

function clipStr(s, n) {
  s = String(s || '').replace(/\s+/g, ' ');
  return s.length > n ? s.slice(0, n) + '…' : s;
}

const TOOL_FRIENDLY = {
  Bash: (i) => `⚙️ Shell: ${clipStr(i.command, 80)}`,
  Read: (i) => `📄 Leggo ${shortPath(i.file_path)}`,
  Write: (i) => `✏️ Scrivo ${shortPath(i.file_path)}`,
  Edit: (i) => `🔧 Modifico ${shortPath(i.file_path)}`,
  Grep: (i) => `🔍 Cerco "${clipStr(i.pattern, 40)}"${i.path ? ' in ' + shortPath(i.path) : ''}`,
  Glob: (i) => `📂 File match "${clipStr(i.pattern, 40)}"`,
  TodoWrite: () => '📝 Aggiorno la lista attività',
  Agent: (i) => `🤖 Delego a ${i.subagent_type || 'agent'}${i.description ? ': ' + clipStr(i.description, 60) : ''}`,
  WebFetch: (i) => `🌍 Scarico ${clipStr(i.url, 60)}`,
  WebSearch: (i) => `🔎 Cerco sul web "${clipStr(i.query, 50)}"`,
  ToolSearch: (i) => `🔌 Carico tool "${clipStr(i.query, 40)}"`,
  Skill: (i) => `🎯 Skill ${i.skill || ''}`,
  CronCreate: () => '⏰ Schedulo task',
  CronDelete: () => '⏰ Cancello task',
  CronList: () => '⏰ Lista task',
  ScheduleWakeup: (i) => `⏰ Sveglia in ${i.delaySeconds || '?'}s`,
  'mcp__harness-browser__browser_navigate': (i) => `🌐 Apro ${clipStr(i.url, 60)}${i.instance && i.instance !== 'main' ? ` [${i.instance}]` : ''}`,
  'mcp__harness-browser__browser_click': (i) => `🖱️ Click ${clipStr(i.selector, 50)}`,
  'mcp__harness-browser__browser_type': (i) => `⌨️ Scrivo "${clipStr(i.text, 60)}"`,
  'mcp__harness-browser__browser_fill': (i) => `⌨️ Compilo ${clipStr(i.selector, 40)}`,
  'mcp__harness-browser__browser_press': (i) => `⌨️ Tasto ${i.key || ''}`,
  'mcp__harness-browser__browser_evaluate': () => '🔍 Ispeziono la pagina',
  'mcp__harness-browser__browser_screenshot': () => '📸 Screenshot',
  'mcp__harness-browser__browser_text': () => '👁 Leggo testo pagina',
  'mcp__harness-browser__browser_wait': (i) => `⏸ Attendo ${i.ms || 0}ms`,
  'mcp__harness-browser__browser_wait_selector': (i) => `⏸ Aspetto ${clipStr(i.selector, 40)}`,
  'mcp__harness-browser__browser_url': () => '🔗 URL corrente',
  'mcp__harness-browser__browser_pages': () => '🗂 Lista tab',
  'mcp__harness-browser__browser_new_tab': (i) => `➕ Nuovo tab${i.url ? ' → ' + clipStr(i.url, 50) : ''}`,
  'mcp__harness-browser__browser_close_tab': () => '❌ Chiudo tab',
  'mcp__harness-browser__browser_switch_tab': (i) => `↔ Tab #${i.index}`,
  'mcp__harness-browser__browser_lease': (i) => `🎫 Prenoto browser (${i.app || ''} · ${i.task_id || ''})`,
  'mcp__harness-browser__browser_release': () => '🎫 Rilascio browser',
  'mcp__harness-browser__browser_instances': () => '🗒 Stato istanze browser',
};

function friendlyTool(name, input = {}) {
  const fn = TOOL_FRIENDLY[name];
  if (fn) try { return fn(input || {}); } catch { /* fallback */ }
  const stripped = String(name).replace(/^mcp__[^_]+__/, '');
  return `🔧 ${stripped}`;
}

let liveWindowOpenedAt = 0;
function openLiveWindow(logFile) {
  if (Date.now() - liveWindowOpenedAt < 3600 * 1000) return;
  liveWindowOpenedAt = Date.now();
  const psCmd = `$Host.UI.RawUI.WindowTitle='Claude — sessione live'; $host.UI.RawUI.BackgroundColor='Black'; Clear-Host; Write-Host 'Sessione Claude live. La finestra resta aperta, ogni richiesta accoda nuove righe sotto.' -ForegroundColor Cyan; Write-Host ''; Get-Content -Path '${logFile.replace(/\\/g, '\\\\')}' -Wait`;
  const p = spawn('cmd.exe', ['/c', 'start', 'Claude Live', 'powershell.exe', '-NoProfile', '-NoExit', '-Command', psCmd], {
    detached: true, windowsHide: false, stdio: 'ignore'
  });
  p.unref();
}

function resetLiveWindow() { liveWindowOpenedAt = 0; }

function spawnClaude(cfg, args, onEvent, onSpawn) {
  const showLive = !!cfg.claude.show_live_window;
  const wantStream = showLive || typeof onEvent === 'function';
  const runLog = path.join(LOGS_DIR, 'current-run.log');

  return new Promise((resolve) => {
    if (showLive) {
      try {
        if (!fs.existsSync(runLog)) fs.writeFileSync(runLog, '');
        fs.appendFileSync(runLog, `\n\n\x1b[33m═══ Nuova richiesta ${new Date().toLocaleTimeString()} ═══\x1b[0m\n\n`);
      } catch {}
      openLiveWindow(runLog);
    }

    const streamArgs = wantStream
      ? args.map(a => a === 'json' ? 'stream-json' : a).concat(['--verbose'])
      : args;

    const child = spawn(cfg.claude.bin || 'claude', streamArgs, {
      shell: false,
      windowsHide: true,
      timeout: cfg.claude.timeout_ms || 600000
    });
    if (onSpawn) { try { onSpawn(child); } catch {} }
    let stdout = '', stderr = '';
    let pending = '';

    child.stdout.on('data', d => {
      const chunk = d.toString();
      stdout += chunk;
      if (!wantStream) return;
      pending += chunk;
      const lines = pending.split('\n');
      pending = lines.pop();
      for (const line of lines) {
        if (!line.trim()) continue;
        let parsed = null;
        try { parsed = JSON.parse(line); } catch {}
        if (parsed && onEvent) { try { onEvent(parsed); } catch {} }
        if (!showLive) continue;
        let pretty = '';
        if (parsed) {
          const o = parsed;
          if (o.type === 'system' && o.subtype === 'init') {
            pretty = `\x1b[90m[session ${o.session_id?.slice(0,8) || '?'}]\x1b[0m\n`;
          } else if (o.type === 'assistant' && o.message?.content) {
            for (const c of o.message.content) {
              if (c.type === 'text' && c.text?.trim()) pretty += `\n\x1b[32m${c.text}\x1b[0m\n`;
              else if (c.type === 'tool_use') {
                const input = JSON.stringify(c.input || {});
                pretty += `\x1b[36m▸ ${c.name}\x1b[0m ${input.slice(0, 120)}${input.length>120?'…':''}\n`;
              }
            }
          } else if (o.type === 'user' && o.message?.content) {
            for (const c of o.message.content) {
              if (c.type === 'tool_result') {
                const str = typeof c.content === 'string' ? c.content : JSON.stringify(c.content);
                const preview = str.replace(/\s+/g,' ').slice(0, 200);
                pretty += `\x1b[90m  ↳ ${preview}${str.length>200?'…':''}\x1b[0m\n`;
              }
            }
          } else if (o.type === 'result') {
            pretty += `\n\x1b[33m─── fine (${(o.duration_ms/1000).toFixed(1)}s, $${o.total_cost_usd?.toFixed(4) || '?'}) ───\x1b[0m\n\n`;
          }
        } else {
          pretty = line + '\n';
        }
        if (pretty) { try { fs.appendFileSync(runLog, pretty); } catch {} }
      }
    });
    child.stderr.on('data', d => stderr += d.toString());
    child.on('error', err => resolve({ error: err.message, code: -1 }));
    child.on('close', (code) => resolve({ stdout, stderr, code }));
  });
}

function getActiveSession(sessions, chatId, timeoutMin) {
  const entry = sessions[chatId];
  if (!entry) return null;
  if (typeof entry === 'string') return { session_id: entry, last_active_at: Date.now() };
  if (!timeoutMin || timeoutMin <= 0) return entry;
  const elapsedMin = (Date.now() - (entry.last_active_at || 0)) / 60000;
  if (elapsedMin > timeoutMin) return null;
  return entry;
}

async function runClaude(cfg, prompt, chatId, onEvent, onSpawn) {
  const sessions = loadSessions();
  const timeoutMin = parseInt(cfg.claude.session_timeout_minutes ?? 60, 10);
  const useSession = cfg.claude.continuous_session !== false;
  const active = useSession ? getActiveSession(sessions, chatId, timeoutMin) : null;

  async function attempt(sessionId, isNew) {
    const args = ['-p', prompt, '--output-format', 'json',
      '--permission-mode', cfg.claude.permission_mode || 'bypassPermissions'];
    if (cfg.claude.model) args.push('--model', cfg.claude.model);
    if (useSession) {
      if (isNew) {
        args.push('--session-id', sessionId);
        let sysPrompt = cfg.claude.system_prompt || '';
        try {
          if (fs.existsSync(CONTEXT_FILE)) {
            const ctx = fs.readFileSync(CONTEXT_FILE, 'utf8').trim();
            if (ctx) sysPrompt += `\n\n--- CONTESTO PROGETTO ---\n${ctx}\n--- FINE CONTESTO ---`;
          }
        } catch {}
        try {
          if (fs.existsSync(MEMORY_FILE)) {
            const memory = fs.readFileSync(MEMORY_FILE, 'utf8').trim();
            if (memory) sysPrompt += `\n\n--- MEMORIA CONVERSAZIONI PRECEDENTI ---\n${memory}\n--- FINE MEMORIA ---`;
          }
        } catch {}
        if (sysPrompt) args.push('--append-system-prompt', sysPrompt);
      } else {
        args.push('--resume', sessionId);
      }
    } else if (cfg.claude.system_prompt) {
      args.push('--append-system-prompt', cfg.claude.system_prompt);
    }
    return spawnClaude(cfg, args, onEvent, onSpawn);
  }

  let sessionId = active?.session_id || randomUUID();
  let isNew = !active;
  if (isNew && active === null && sessions[chatId]) {
    log('session expired (timeout ' + timeoutMin + 'min) for', chatId, '— new one');
    const expiredId = sessions[chatId]?.session_id || sessions[chatId];
    if (typeof expiredId === 'string') {
      saveMemorySnapshot(cfg, chatId, expiredId).catch(e => log('auto-memo on expiry error:', e.message));
    }
  }
  let res = await attempt(sessionId, isNew);

  if (isRateLimit(res)) {
    const interrupted = loadInterrupted();
    interrupted[chatId] = { prompt, at: Date.now() };
    saveInterrupted(interrupted);
    const killed = killAllActive();
    rateLimitBlocked = true;
    log('RATE LIMIT: killed', killed, 'processes, blocking new requests');
    notifyRateLimit(cfg).catch(() => {});
    return { error: 'RATE_LIMIT' };
  }

  if (!isNew && useSession && isSessionNotFound(res)) {
    log('session not found on server, starting fresh for', chatId);
    const sessions2 = loadSessions();
    delete sessions2[chatId];
    saveSessions(sessions2);
    sessionId = randomUUID();
    isNew = true;
    res = await attempt(sessionId, true);
    if (isRateLimit(res)) {
      const interrupted = loadInterrupted();
      interrupted[chatId] = { prompt, at: Date.now() };
      saveInterrupted(interrupted);
      const killed = killAllActive();
      rateLimitBlocked = true;
      log('RATE LIMIT (session retry): killed', killed, 'processes');
      notifyRateLimit(cfg).catch(() => {});
      return { error: 'RATE_LIMIT' };
    }
  }

  if (res.code !== 0 && !res.stdout && !isNew && useSession) {
    log('resume failed, starting fresh session for', chatId);
    sessionId = randomUUID();
    isNew = true;
    res = await attempt(sessionId, true);
    if (isRateLimit(res)) {
      const interrupted = loadInterrupted();
      interrupted[chatId] = { prompt, at: Date.now() };
      saveInterrupted(interrupted);
      const killed = killAllActive();
      rateLimitBlocked = true;
      log('RATE LIMIT (retry): killed', killed, 'processes');
      notifyRateLimit(cfg).catch(() => {});
      return { error: 'RATE_LIMIT' };
    }
  }

  if (res.code !== 0 && !res.stdout) {
    return { error: res.stderr || res.error || `exit ${res.code}` };
  }

  if (useSession) {
    sessions[chatId] = { session_id: sessionId, last_active_at: Date.now(), started_at: active?.started_at || Date.now() };
    saveSessions(sessions);
  }

  // Mirror del JSONL di sessione dentro logs/transcripts/<chatId>.jsonl.
  // Backup locale portabile: sopravvive a spostamenti della cartella bot e a pulizie di ~/.claude/.
  mirrorTranscript(chatId, sessionId);

  const out = res.stdout.trim();
  // Prova a estrarre result ed eventuale usage finale da stream-json o json
  const lines = out.split('\n').filter(Boolean);
  for (let i = lines.length - 1; i >= 0; i--) {
    try {
      const o = JSON.parse(lines[i]);
      if (o.type === 'result' && typeof o.result === 'string') {
        return { result: o.result, session_id: sessionId, session_new: isNew, usage: o.usage || null };
      }
    } catch {}
  }
  try {
    const j = JSON.parse(out);
    return { result: j.result || j.message || JSON.stringify(j), session_id: sessionId, session_new: isNew, usage: j.usage || null };
  } catch {}
  return { result: out || '(nessun output)', session_id: sessionId, session_new: isNew, usage: null };
}

// Conteggio task paralleli attivi per chat (fuori dalla coda principale)
const parallelActive = new Map(); // chatId -> count
const MAX_PARALLEL_PER_CHAT = 3;

async function runParallelTask(cfg, chatId, prompt, replyToMsgId) {
  const token = cfg.telegram.bot_token;
  const count = parallelActive.get(chatId) || 0;
  if (count >= MAX_PARALLEL_PER_CHAT) {
    await sendMessage(token, chatId, `⚠️ Troppi task paralleli attivi (${count}/${MAX_PARALLEL_PER_CHAT}). Aspetta che qualcuno finisca.`, { replyTo: replyToMsgId });
    return;
  }
  parallelActive.set(chatId, count + 1);
  const statusR = await tg(token, 'sendMessage', {
    chat_id: chatId,
    text: '📝 Aggiorno la memoria prima di lanciare il task parallelo…',
    reply_parameters: replyToMsgId ? { message_id: replyToMsgId, allow_sending_without_reply: true } : undefined
  });
  const statusMsgId = statusR?.result?.message_id || null;
  try {
    // 1) /memo "pre" — aspetta che finisca così il task fresh legge la memoria aggiornata
    try { await saveMemorySnapshot(cfg, chatId, null, 'pre-parallel'); }
    catch (e) { log('parallel pre-memo error:', e.message); }

    if (statusMsgId) {
      await tg(token, 'editMessageText', { chat_id: chatId, message_id: statusMsgId, text: '⚡ Task parallelo in esecuzione (istanza fresh)…' }).catch(() => {});
    }

    // 2) Task Claude fresh — NO --resume, sysPrompt = context + memory aggiornata
    let sysPrompt = cfg.claude.system_prompt || '';
    try {
      if (fs.existsSync(CONTEXT_FILE)) {
        const ctx = fs.readFileSync(CONTEXT_FILE, 'utf8').trim();
        if (ctx) sysPrompt += `\n\n--- CONTESTO PROGETTO ---\n${ctx}\n--- FINE CONTESTO ---`;
      }
    } catch {}
    try {
      if (fs.existsSync(MEMORY_FILE)) {
        const memory = fs.readFileSync(MEMORY_FILE, 'utf8').trim();
        if (memory) sysPrompt += `\n\n--- MEMORIA CONVERSAZIONI PRECEDENTI ---\n${memory}\n--- FINE MEMORIA ---`;
      }
    } catch {}
    const args = ['-p', prompt, '--output-format', 'json',
      '--permission-mode', cfg.claude.permission_mode || 'bypassPermissions'];
    if (cfg.claude.model) args.push('--model', cfg.claude.model);
    if (sysPrompt) args.push('--append-system-prompt', sysPrompt);

    const res = await spawnClaude(cfg, args, null, null);
    let result = '';
    const lines = (res.stdout || '').trim().split('\n').filter(Boolean);
    for (let i = lines.length - 1; i >= 0; i--) {
      try { const o = JSON.parse(lines[i]); if (o.type === 'result' && typeof o.result === 'string') { result = o.result; break; } } catch {}
    }
    if (!result) { try { const j = JSON.parse((res.stdout || '').trim()); result = j.result || j.message || ''; } catch {} }
    if (!result) result = res.stderr?.slice(0, 2000) || res.error || '(nessun output)';

    if (statusMsgId) await deleteMessage(token, chatId, statusMsgId);
    await sendMessage(token, chatId, `⚡ _parallelo_\n\n${result}`, { replyTo: replyToMsgId });
  } catch (e) {
    if (statusMsgId) await deleteMessage(token, chatId, statusMsgId).catch(() => {});
    await sendMessage(token, chatId, `❌ Errore task parallelo: ${e.message}`, { replyTo: replyToMsgId });
  } finally {
    const n = (parallelActive.get(chatId) || 1) - 1;
    if (n <= 0) parallelActive.delete(chatId); else parallelActive.set(chatId, n);
    // 3) /memo "post" — fire-and-forget, serializzato via coda
    saveMemorySnapshot(cfg, chatId, null, 'post-parallel').catch(e => log('parallel post-memo error:', e.message));
  }
}

let offset = 0;
const chatQueues = new Map();
const chatDepth = new Map(); // chatId -> quanti task attivi (running + in coda)
// Per aggiornare i messaggi "in coda" con la loro posizione corrente mentre la coda scorre
const pendingWaiters = new Map(); // chatId -> Array<{ statusMsgId, enqueuedAt, updateId, lastText }>
// Annullamento: child in esecuzione per chat + set di update_id marcati come cancellati
const runningChildren = new Map(); // chatId -> ChildProcess
const runningUpdates = new Map();  // chatId -> update_id attualmente in esecuzione
const runningMessageIds = new Map(); // chatId -> message_id (telegram) del messaggio attualmente in esecuzione
const cancelledUpdates = new Map(); // chatId -> Set<update_id>
let rateLimitBlocked = false;

function incDepth(chatId) {
  const d = (chatDepth.get(chatId) || 0) + 1;
  chatDepth.set(chatId, d);
  return d;
}
function decDepth(chatId) {
  const d = Math.max(0, (chatDepth.get(chatId) || 0) - 1);
  if (d === 0) chatDepth.delete(chatId); else chatDepth.set(chatId, d);
  return d;
}

function enqueue(chatId, fn) {
  const prev = chatQueues.get(chatId) || Promise.resolve();
  const next = prev.then(fn, fn);
  chatQueues.set(chatId, next);
  next.finally(() => {
    if (chatQueues.get(chatId) === next) chatQueues.delete(chatId);
  });
  return next;
}

function markCancelled(chatId, updateId) {
  let set = cancelledUpdates.get(chatId);
  if (!set) { set = new Set(); cancelledUpdates.set(chatId, set); }
  set.add(updateId);
}

function consumeCancelled(chatId, updateId) {
  const set = cancelledUpdates.get(chatId);
  if (!set) return false;
  const had = set.delete(updateId);
  if (!set.size) cancelledUpdates.delete(chatId);
  return had;
}

async function handleEditedMessage(cfg, u) {
  const em = u.edited_message;
  if (!em || !em.text) return;
  const chatId = String(em.chat.id);
  const token = cfg.telegram.bot_token;
  const allowed = (cfg.telegram.allowed_chat_ids || []).map(String);
  if (!allowed.includes(chatId)) return;

  const waiters = pendingWaiters.get(chatId) || [];
  const w = waiters.find(x => x.messageId === em.message_id);
  if (w) {
    // Aggiorna il testo sull'update salvato: il handler al momento dell'esecuzione leggerà il testo aggiornato
    if (w.u && w.u.message) w.u.message.text = em.text;
    const pos = waiters.indexOf(w) + 2; // 1 = running, quindi primo waiter è posizione 2
    const waitS = Math.floor((Date.now() - w.enqueuedAt) / 1000);
    const preview = em.text.replace(/\s+/g, ' ').slice(0, 80);
    const newStatus = `✏️ Messaggio aggiornato · in coda\n· posizione ${pos}\n· in attesa da ${waitS}s\n· nuovo testo: "${preview}${em.text.length > 80 ? '…' : ''}"`;
    w.lastText = newStatus;
    await editMessage(token, chatId, w.statusMsgId, newStatus);
    await sendMessage(token, chatId, '✏️ Modifica acquisita, elaboro con il nuovo testo quando è il tuo turno.', { replyTo: em.message_id });
    log('EDIT:', chatId, 'msg', em.message_id, 'applied to queued waiter');
    return;
  }

  const runningMsg = runningMessageIds.get(chatId);
  if (runningMsg === em.message_id) {
    await sendMessage(token, chatId, '⚠️ Troppo tardi: la tua richiesta è già in esecuzione. Usa /cancel e rimandala modificata.', { replyTo: em.message_id });
    log('EDIT:', chatId, 'msg', em.message_id, 'ignored — already running');
    return;
  }

  await sendMessage(token, chatId, '⚠️ Modifica ignorata — la richiesta originale è già stata elaborata.', { replyTo: em.message_id });
  log('EDIT:', chatId, 'msg', em.message_id, 'ignored — already done');
}

async function handleCancel(cfg, u) {
  const chatId = String(u.message.chat.id);
  const token = cfg.telegram.bot_token;
  const allowed = (cfg.telegram.allowed_chat_ids || []).map(String);
  if (!allowed.includes(chatId)) return;

  const running = runningChildren.get(chatId);
  let killedRunning = false;
  if (running) {
    try { running.kill('SIGTERM'); } catch {}
    setTimeout(() => { try { running.kill('SIGKILL'); } catch {} }, 2000);
    killedRunning = true;
    const runId = runningUpdates.get(chatId);
    if (runId != null) markCancelled(chatId, runId);
  }

  const waiters = pendingWaiters.get(chatId) || [];
  let dropped = 0;
  for (const w of waiters) {
    markCancelled(chatId, w.updateId);
    if (w.statusMsgId) deleteMessage(token, chatId, w.statusMsgId).catch(() => {});
    dropped++;
  }
  pendingWaiters.delete(chatId);

  const pieces = [];
  if (killedRunning) pieces.push('richiesta in corso fermata');
  if (dropped) pieces.push(`${dropped} in coda droppat${dropped === 1 ? 'a' : 'e'}`);
  if (!pieces.length) pieces.push('niente da annullare ora');
  await sendMessage(token, chatId, '⛔ Annullato · ' + pieces.join(' · '), { replyTo: u.message?.message_id });
  log('CANCEL:', chatId, pieces.join(' · '));
}

async function refreshWaiters(token, chatId) {
  const arr = pendingWaiters.get(chatId) || [];
  for (let i = 0; i < arr.length; i++) {
    const w = arr[i];
    const ahead = i + 1; // quante richieste davanti a questa (1 = quella in esecuzione)
    const waitS = Math.floor((Date.now() - w.enqueuedAt) / 1000);
    const text = `📥 In coda\n· posizione ${ahead + 1} (${ahead} davanti a te)\n· in attesa da ${waitS}s`;
    if (w.statusMsgId && w.lastText !== text) {
      w.lastText = text;
      await editMessage(token, chatId, w.statusMsgId, text);
    }
  }
}

async function drainOfflineQueue(cfg) {
  const token = cfg.telegram.bot_token;
  const allowed = (cfg.telegram.allowed_chat_ids || []).map(String);
  try {
    const r = await fetch(`https://api.telegram.org/bot${token}/getUpdates?offset=0&timeout=0`);
    const data = await r.json();
    if (!data.ok || !data.result?.length) { log('queue drain: nothing pending'); return; }

    const perChat = new Map();
    for (const u of data.result) {
      offset = u.update_id + 1;
      const m = u.message;
      if (!m || !m.text) continue;
      const chatId = String(m.chat.id);
      if (!allowed.includes(chatId)) continue;
      if (m.text === '/ping' || m.text === '/start' || m.text === '/help') continue;
      if (!perChat.has(chatId)) perChat.set(chatId, []);
      perChat.get(chatId).push(m.text);
    }

    for (const [chatId, msgs] of perChat.entries()) {
      const count = msgs.length;
      const preview = msgs.map(t => `• ${t.slice(0, 120)}`).join('\n');
      const note = count === 1
        ? `⚠️ Bridge offline quando hai scritto. Messaggio non elaborato:\n\n${preview}\n\nSe ti serve ancora, rimandalo.`
        : `⚠️ Bridge offline: ${count} messaggi in coda non elaborati:\n\n${preview}\n\nRimanda quelli che ti servono ancora.`;
      await sendMessage(token, chatId, note);
      log('queue drain: notified', chatId, 'for', count, 'queued msg(s)');
    }
    log('queue drain complete, offset=', offset);
  } catch (e) {
    log('queue drain error:', e.message);
  }
}

function buildWatchersPayload() {
  const status = watchers.getStatus();
  const list = status.watchers || [];
  const rlNote = status.rate_limit_active
    ? ` ⚠️ rate-limit fino ${new Date(status.rate_limit_paused_until).toLocaleTimeString('it-IT', { timeZone: 'Europe/Rome' })}`
    : '';
  const header = `🤖 Watchers (${list.length})${rlNote}`;
  const body = list.length ? list.map(w => {
    const last = w.last_fire_at ? Math.floor((Date.now() - w.last_fire_at) / 1000) + 's fa' : 'mai';
    const state = w.running_now ? '🔄' : (w.enabled ? '🟢' : '🔴');
    const budge = w.max_responses ? ` · 🎯 ${w.responses_count || 0}/${w.max_responses}` : '';
    const sum = (w.last_summary || '').slice(0, 80);
    return `${state} <code>${w.id}</code> · ${w.interval_sec}s · ${last}${budge}${sum ? '\n   <i>' + sum.replace(/[<>&]/g, c => ({'<':'&lt;','>':'&gt;','&':'&amp;'}[c])) + '</i>' : ''}`;
  }).join('\n') : '(nessun watcher configurato)';
  const text = header + '\n\n' + body + (list.length ? '\n\n<i>Tocca un watcher per aprirlo.</i>' : '');
  const rows = [];
  for (const w of list) {
    const state = w.running_now ? '🔄' : (w.enabled ? '🟢' : '🔴');
    rows.push([{ text: `${state} ${w.id}`, callback_data: `w:detail:${w.id}` }]);
  }
  rows.push([
    { text: '➕', callback_data: 'w:new' },
    { text: '🔄', callback_data: 'w:refresh' },
    { text: '✖', callback_data: 'w:close' }
  ]);
  return { text, reply_markup: { inline_keyboard: rows } };
}

function buildWatcherDetailPayload(id) {
  const list = watchers.getStatus().watchers || [];
  const w = list.find(x => x.id === id);
  if (!w) return null;
  const state = w.running_now ? '🔄 running' : (w.enabled ? '🟢 on' : '🔴 off');
  const last = w.last_fire_at
    ? new Date(w.last_fire_at).toLocaleString('it-IT', { timeZone: 'Europe/Rome' }) + ' (' + Math.floor((Date.now() - w.last_fire_at) / 1000) + 's fa)'
    : 'mai';
  const summary = (w.last_summary || '(vuoto)').slice(0, 1200);
  const esc = s => String(s).replace(/[<>&]/g, c => ({'<':'&lt;','>':'&gt;','&':'&amp;'}[c]));
  const budgetLine = w.max_responses
    ? `budget: ${w.responses_count || 0}/${w.max_responses} responses`
    : `budget: —`;
  const text = `📌 <b>${esc(w.name || w.id)}</b>\n\n` +
    `id: <code>${esc(w.id)}</code>\n` +
    `stato: ${state}\n` +
    `intervallo: ${w.interval_sec}s\n` +
    `use_session: ${w.use_session ? 'yes' : 'no'}\n` +
    `${budgetLine}\n` +
    `ultimo fire: ${last}\n` +
    `durata: ${w.last_duration_ms ? w.last_duration_ms + 'ms' : '—'}\n` +
    `exit code: ${w.last_exit_code ?? '—'}\n\n` +
    `<b>Ultimo output:</b>\n<i>${esc(summary)}</i>`;
  const toggleIcon = w.enabled ? '⏸ Pausa' : '▶️ Attiva';
  const rows = [
    [
      { text: toggleIcon, callback_data: `w:toggle:${w.id}` },
      { text: '🔥 Fire', callback_data: `w:fire:${w.id}` }
    ],
    [
      { text: '🎯 Budget', callback_data: `w:budget:${w.id}` },
      { text: '🔁 Reset', callback_data: `w:reset:${w.id}` }
    ],
    [
      { text: '📜 Log', callback_data: `w:log:${w.id}` },
      { text: '✏️ Modifica', callback_data: `w:edit:${w.id}` },
      { text: '🗑 Elimina', callback_data: `w:del:${w.id}` }
    ],
    [
      { text: '◀ Lista', callback_data: 'w:back' },
      { text: '🔄', callback_data: `w:refresh` },
      { text: '✖', callback_data: 'w:close' }
    ]
  ];
  return { text, reply_markup: { inline_keyboard: rows } };
}

// ============ WIZARD STATE (in-memory) ============
// chatId -> { action: 'new'|'edit'|'delete', step, data: {}, watcherId?, dashboardMessageId?, expectReplyToMsgId? }
const pendingWatcherFlows = new Map();

function clearWizard(chatId) { pendingWatcherFlows.delete(String(chatId)); }
function getWizard(chatId) { return pendingWatcherFlows.get(String(chatId)) || null; }

async function askWizardReply(token, chatId, promptText, placeholder = 'Rispondi qui...') {
  const r = await tg(token, 'sendMessage', {
    chat_id: chatId,
    text: promptText,
    parse_mode: 'HTML',
    reply_markup: { force_reply: true, input_field_placeholder: placeholder }
  });
  return r?.result?.message_id || null;
}

function escHtml(s) { return String(s || '').replace(/[<>&]/g, c => ({'<':'&lt;','>':'&gt;','&':'&amp;'}[c])); }

async function refreshDashboard(token, chatId, flow) {
  if (flow?.dashboardMessageId) {
    await updateWatchersMessage(token, chatId, flow.dashboardMessageId).catch(() => {});
  }
}

// ---- NEW wizard ----
async function wizardNewStart(token, chatId, dashboardMessageId) {
  const flow = { action: 'new', step: 'id', data: {}, dashboardMessageId };
  pendingWatcherFlows.set(String(chatId), flow);
  flow.expectReplyToMsgId = await askWizardReply(token, chatId,
    '➕ <b>Nuovo watcher — 1/6 · id</b>\n\nScegli un id univoco (lettere, numeri, <code>-</code>, <code>_</code>). Es. <code>my-watcher</code>.\n\nInvia <code>/annulla</code> per uscire.', 'id-watcher');
}

async function wizardNewStep(token, chatId, flow, step) {
  flow.step = step;
  flow.expectReplyToMsgId = null;
  if (step === 'name') {
    flow.expectReplyToMsgId = await askWizardReply(token, chatId,
      '➕ <b>2/6 · name</b>\n\nNome descrittivo. Invia <code>-</code> per usare l\'id.', 'Nome…');
  } else if (step === 'interval_sec') {
    flow.expectReplyToMsgId = await askWizardReply(token, chatId,
      '➕ <b>3/6 · interval_sec</b>\n\nIntervallo tra fire in secondi (min 5). Es. <code>60</code>.', '60');
  } else if (step === 'timeout_ms') {
    flow.expectReplyToMsgId = await askWizardReply(token, chatId,
      '➕ <b>4/6 · timeout_ms</b>\n\nTimeout singolo fire in ms (min 10000). Invia <code>-</code> per 180000 (3 min).', '180000');
  } else if (step === 'use_session') {
    await tg(token, 'sendMessage', {
      chat_id: chatId,
      text: '➕ <b>5/6 · use_session</b>\n\nSessione Claude persistente tra i fire (costa token ma mantiene contesto)?',
      parse_mode: 'HTML',
      reply_markup: { inline_keyboard: [[
        { text: '✅ Sì', callback_data: 'w:new_us:1' },
        { text: '❌ No', callback_data: 'w:new_us:0' }
      ], [{ text: '✖ Annulla', callback_data: 'w:wcancel' }]] }
    });
  } else if (step === 'prompt') {
    flow.expectReplyToMsgId = await askWizardReply(token, chatId,
      '➕ <b>6/6 · prompt</b>\n\nIncolla il prompt che Claude eseguirà ad ogni fire. Può essere multi-riga.', 'Prompt…');
  } else if (step === 'confirm') {
    const d = flow.data;
    await tg(token, 'sendMessage', {
      chat_id: chatId,
      text: `📋 <b>Riepilogo nuovo watcher</b>\n\nid: <code>${escHtml(d.id)}</code>\nname: ${escHtml(d.name)}\ninterval: ${d.interval_sec}s\ntimeout: ${d.timeout_ms}ms\nuse_session: ${d.use_session ? 'yes' : 'no'}\nprompt (${d.prompt.length} char):\n<i>${escHtml(d.prompt.slice(0,300))}${d.prompt.length>300?'…':''}</i>\n\nParte disabilitato — attivalo dalla dashboard.`,
      parse_mode: 'HTML',
      reply_markup: { inline_keyboard: [[
        { text: '💾 Salva', callback_data: 'w:new_save' },
        { text: '✖ Annulla', callback_data: 'w:wcancel' }
      ]] }
    });
  }
}

// ---- EDIT wizard ----
async function wizardEditStart(token, chatId, watcherId, dashboardMessageId) {
  const cur = watchers.loadWatchers();
  const w = (cur.watchers || []).find(x => x.id === watcherId);
  if (!w) return false;
  const flow = { action: 'edit', step: 'choose', data: {}, watcherId, dashboardMessageId };
  pendingWatcherFlows.set(String(chatId), flow);
  await tg(token, 'sendMessage', {
    chat_id: chatId,
    text: `✏ <b>Modifica</b> <code>${escHtml(watcherId)}</code>\n\nQuale campo?`,
    parse_mode: 'HTML',
    reply_markup: { inline_keyboard: [
      [{ text: `id`, callback_data: 'w:ef:id' },
       { text: `name`, callback_data: 'w:ef:name' }],
      [{ text: `interval (${w.interval_sec}s)`, callback_data: 'w:ef:interval_sec' },
       { text: `timeout (${w.timeout_ms||180000}ms)`, callback_data: 'w:ef:timeout_ms' }],
      [{ text: `use_session: ${w.use_session?'on':'off'}`, callback_data: 'w:ef:use_session' },
       { text: `budget (${typeof w.max_responses==='number'?w.max_responses:'—'})`, callback_data: 'w:ef:max_responses' }],
      [{ text: 'prompt', callback_data: 'w:ef:prompt' }],
      [{ text: '✖ Annulla', callback_data: 'w:wcancel' }]
    ] }
  });
  return true;
}

async function wizardEditAskField(token, chatId, flow, field) {
  flow.data.field = field;
  flow.expectReplyToMsgId = null;
  const id = flow.watcherId;
  if (field === 'use_session') {
    await tg(token, 'sendMessage', {
      chat_id: chatId,
      text: `✏ <b>use_session</b> per <code>${escHtml(id)}</code>`,
      parse_mode: 'HTML',
      reply_markup: { inline_keyboard: [[
        { text: '✅ Sì', callback_data: 'w:eb:1' },
        { text: '❌ No', callback_data: 'w:eb:0' }
      ], [{ text: '✖ Annulla', callback_data: 'w:wcancel' }]] }
    });
    return;
  }
  const prompts = {
    id: `✏ <b>Nuovo id</b> per <code>${escHtml(id)}</code>\n(lettere/numeri/-/_).`,
    name: `✏ <b>Nuovo name</b> per <code>${escHtml(id)}</code>`,
    interval_sec: `✏ <b>Nuovo interval_sec</b> (≥5) per <code>${escHtml(id)}</code>`,
    timeout_ms: `✏ <b>Nuovo timeout_ms</b> (≥10000) per <code>${escHtml(id)}</code>`,
    max_responses: `✏ <b>Budget</b> per <code>${escHtml(id)}</code>\n\nNumero di <i>responses</i> massime (intero &gt; 0) oppure <code>-</code> per rimuoverlo.`,
    prompt: `✏ <b>Nuovo prompt</b> per <code>${escHtml(id)}</code>\n\nIncolla il prompt completo.`
  };
  flow.expectReplyToMsgId = await askWizardReply(token, chatId, prompts[field]);
}

// ---- Process wizard input (called from handleUpdate) ----
async function processWizardInput(cfg, token, chatId, flow, text, reply) {
  if (text === '/annulla' || text === '/cancel') {
    clearWizard(chatId);
    await reply('✖ Wizard annullato.');
    return true;
  }
  if (flow.action === 'budget') {
    const raw = text.trim();
    if (raw === '-') {
      watchers.setBudget(flow.watcherId, null);
      await reply(`✅ Budget rimosso da <code>${escHtml(flow.watcherId)}</code>.`);
    } else {
      const n = parseInt(raw, 10);
      if (!Number.isFinite(n) || n <= 0) {
        await reply('❌ Inserisci un intero > 0, oppure <code>-</code> per rimuovere.');
        return true;
      }
      watchers.setBudget(flow.watcherId, n);
      await reply(`✅ Budget di <code>${escHtml(flow.watcherId)}</code> impostato a <b>${n}</b>.`);
    }
    await refreshDashboard(token, chatId, flow);
    if (flow.dashboardMessageId) {
      await updateWatcherDetailMessage(token, chatId, flow.dashboardMessageId, flow.watcherId).catch(() => {});
    }
    clearWizard(chatId);
    return true;
  }
  if (flow.action === 'new') {
    if (flow.step === 'id') {
      const id = text.trim();
      if (!/^[a-z0-9_-]+$/i.test(id)) { await reply('❌ id non valido.'); await wizardNewStep(token, chatId, flow, 'id'); return true; }
      const cur = watchers.loadWatchers();
      if ((cur.watchers||[]).some(w => w.id === id)) { await reply(`❌ id "${id}" già esistente.`); await wizardNewStep(token, chatId, flow, 'id'); return true; }
      flow.data.id = id;
      await wizardNewStep(token, chatId, flow, 'name');
      return true;
    }
    if (flow.step === 'name') {
      flow.data.name = text.trim() === '-' ? flow.data.id : text.trim();
      await wizardNewStep(token, chatId, flow, 'interval_sec');
      return true;
    }
    if (flow.step === 'interval_sec') {
      const n = parseInt(text.trim(), 10);
      if (!Number.isFinite(n) || n < 5) { await reply('❌ intero ≥ 5.'); await wizardNewStep(token, chatId, flow, 'interval_sec'); return true; }
      flow.data.interval_sec = n;
      await wizardNewStep(token, chatId, flow, 'timeout_ms');
      return true;
    }
    if (flow.step === 'timeout_ms') {
      const raw = text.trim();
      if (raw === '-') flow.data.timeout_ms = 180000;
      else {
        const n = parseInt(raw, 10);
        if (!Number.isFinite(n) || n < 10000) { await reply('❌ intero ≥ 10000.'); await wizardNewStep(token, chatId, flow, 'timeout_ms'); return true; }
        flow.data.timeout_ms = n;
      }
      await wizardNewStep(token, chatId, flow, 'use_session');
      return true;
    }
    if (flow.step === 'prompt') {
      if (!text.trim()) { await reply('❌ prompt vuoto.'); await wizardNewStep(token, chatId, flow, 'prompt'); return true; }
      flow.data.prompt = text;
      await wizardNewStep(token, chatId, flow, 'confirm');
      return true;
    }
  }
  if (flow.action === 'edit') {
    const field = flow.data.field;
    if (!field) return false;
    const cur = watchers.loadWatchers();
    const arr = cur.watchers || [];
    const i = arr.findIndex(x => x.id === flow.watcherId);
    if (i < 0) { await reply('❌ watcher scomparso.'); clearWizard(chatId); return true; }
    if (field === 'interval_sec' || field === 'timeout_ms') {
      const n = parseInt(text.trim(), 10);
      const min = field === 'interval_sec' ? 5 : 10000;
      if (!Number.isFinite(n) || n < min) { await reply(`❌ intero ≥ ${min}.`); await wizardEditAskField(token, chatId, flow, field); return true; }
      arr[i][field] = n;
    } else if (field === 'id') {
      const newId = text.trim();
      if (!/^[a-z0-9_-]+$/i.test(newId)) { await reply('❌ id non valido.'); await wizardEditAskField(token, chatId, flow, 'id'); return true; }
      if (newId !== flow.watcherId && arr.some(w => w.id === newId)) { await reply(`❌ id "${newId}" già in uso.`); await wizardEditAskField(token, chatId, flow, 'id'); return true; }
      arr[i].id = newId;
      flow.watcherId = newId;
    } else if (field === 'name') {
      arr[i].name = text.trim();
    } else if (field === 'max_responses') {
      const raw = text.trim();
      if (raw === '-') {
        delete arr[i].max_responses;
      } else {
        const n = parseInt(raw, 10);
        if (!Number.isFinite(n) || n <= 0) { await reply('❌ intero &gt; 0 oppure <code>-</code>.'); await wizardEditAskField(token, chatId, flow, 'max_responses'); return true; }
        arr[i].max_responses = n;
      }
    } else if (field === 'prompt') {
      if (!text.trim()) { await reply('❌ prompt vuoto.'); await wizardEditAskField(token, chatId, flow, 'prompt'); return true; }
      arr[i].prompt = text;
    }
    watchers.saveWatchers({ watchers: arr });
    watchers.start(cfg, log);
    await reply(`✅ ${field} aggiornato.`);
    await refreshDashboard(token, chatId, flow);
    clearWizard(chatId);
    return true;
  }
  return false;
}

async function updateWatchersMessage(token, chatId, messageId) {
  const { text, reply_markup } = buildWatchersPayload();
  try {
    await tg(token, 'editMessageText', { chat_id: chatId, message_id: messageId, text, parse_mode: 'HTML', reply_markup });
    const st = openWatcherDashboards.get(String(chatId));
    if (st && st.mid === messageId) { st.view = 'list'; st.wid = null; }
  } catch (e) {
    const msg = e.message || '';
    // Se il messaggio è stato cancellato dal client, rimuovi dalla mappa open
    if (/message to edit not found|message_id_invalid|message can't be edited/i.test(msg)) {
      const st = openWatcherDashboards.get(String(chatId));
      if (st && st.mid === messageId) openWatcherDashboards.delete(String(chatId));
    } else if (!/message is not modified/i.test(msg)) {
      log('edit watchers error:', msg);
    }
  }
}

async function updateWatcherDetailMessage(token, chatId, messageId, watcherId) {
  const payload = buildWatcherDetailPayload(watcherId);
  if (!payload) {
    // Watcher non esiste più: ricadi su list view
    await updateWatchersMessage(token, chatId, messageId);
    return;
  }
  try {
    await tg(token, 'editMessageText', { chat_id: chatId, message_id: messageId, text: payload.text, parse_mode: 'HTML', reply_markup: payload.reply_markup });
    const st = openWatcherDashboards.get(String(chatId));
    if (st && st.mid === messageId) { st.view = 'detail'; st.wid = watcherId; }
  } catch (e) {
    const msg = e.message || '';
    if (/message to edit not found|message_id_invalid|message can't be edited/i.test(msg)) {
      const st = openWatcherDashboards.get(String(chatId));
      if (st && st.mid === messageId) openWatcherDashboards.delete(String(chatId));
    } else if (!/message is not modified/i.test(msg)) {
      log('edit watcher detail error:', msg);
    }
  }
}

// chatId -> { mid, view: 'list'|'detail', wid }
const openWatcherDashboards = new Map();
// chatId -> timer di debounce per push updates
const dashboardPushTimers = new Map();

function scheduleDashboardPush(token) {
  for (const [chatId, st] of openWatcherDashboards.entries()) {
    if (dashboardPushTimers.has(chatId)) continue;
    const t = setTimeout(() => {
      dashboardPushTimers.delete(chatId);
      const cur = openWatcherDashboards.get(chatId);
      if (!cur) return;
      if (cur.view === 'detail' && cur.wid) {
        updateWatcherDetailMessage(token, chatId, cur.mid, cur.wid).catch(() => {});
      } else {
        updateWatchersMessage(token, chatId, cur.mid).catch(() => {});
      }
    }, 400);
    dashboardPushTimers.set(chatId, t);
  }
}

async function openWatchersDashboard(cfg, chatId, replyToMessageId) {
  const token = cfg.telegram.bot_token;
  const prev = openWatcherDashboards.get(String(chatId));
  if (prev) {
    await tg(token, 'deleteMessage', { chat_id: chatId, message_id: prev.mid }).catch(() => {});
    openWatcherDashboards.delete(String(chatId));
  }
  const { text, reply_markup } = buildWatchersPayload();
  const payload = { chat_id: chatId, text, parse_mode: 'HTML', reply_markup };
  if (replyToMessageId) payload.reply_parameters = { message_id: replyToMessageId, allow_sending_without_reply: true };
  const r = await tg(token, 'sendMessage', payload);
  const mid = r?.result?.message_id;
  if (mid) openWatcherDashboards.set(String(chatId), { mid, view: 'list', wid: null });
  return mid;
}

async function handleCallbackQuery(cfg, u) {
  const cq = u.callback_query;
  const token = cfg.telegram.bot_token;
  const chatId = cq.message?.chat?.id ? String(cq.message.chat.id) : null;
  const messageId = cq.message?.message_id;
  const allowed = (cfg.telegram.allowed_chat_ids || []).map(String);
  const ack = (text, show = false) => tg(token, 'answerCallbackQuery', { callback_query_id: cq.id, text: text || '', show_alert: !!show }).catch(() => {});
  if (!chatId || !allowed.includes(chatId)) { await ack('Accesso negato', true); return; }
  const data = cq.data || '';
  const parts = data.split(':');
  if (parts[0] !== 'w') { await ack(); return; }
  const action = parts[1];
  const id = parts.slice(2).join(':') || null;

  // Registra questa dashboard come aperta (la "vince" sulle altre per questa chat)
  if (messageId && action !== 'close') {
    const prev = openWatcherDashboards.get(String(chatId));
    if (prev && prev.mid !== messageId) {
      await tg(token, 'deleteMessage', { chat_id: chatId, message_id: prev.mid }).catch(() => {});
      openWatcherDashboards.set(String(chatId), { mid: messageId, view: 'list', wid: null });
    } else if (!prev) {
      openWatcherDashboards.set(String(chatId), { mid: messageId, view: 'list', wid: null });
    }
  }

  const currentView = () => openWatcherDashboards.get(String(chatId)) || { mid: messageId, view: 'list', wid: null };
  const refreshCurrent = async () => {
    const st = currentView();
    if (st.view === 'detail' && st.wid) {
      await updateWatcherDetailMessage(token, chatId, messageId, st.wid);
    } else {
      await updateWatchersMessage(token, chatId, messageId);
    }
  };

  if (action === 'noop') { return ack(); }
  if (action === 'refresh') {
    await refreshCurrent();
    return ack('Aggiornato');
  }
  if (action === 'close') {
    await tg(token, 'deleteMessage', { chat_id: chatId, message_id: messageId }).catch(() => {});
    const st = openWatcherDashboards.get(String(chatId));
    if (st && st.mid === messageId) openWatcherDashboards.delete(String(chatId));
    return ack('Chiuso');
  }
  if (action === 'back') {
    await updateWatchersMessage(token, chatId, messageId);
    return ack();
  }
  if (action === 'detail' && id) {
    const payload = buildWatcherDetailPayload(id);
    if (!payload) return ack('Non trovato', true);
    await updateWatcherDetailMessage(token, chatId, messageId, id);
    return ack();
  }
  if (action === 'toggle' && id) {
    const cur = watchers.loadWatchers();
    const arr = cur.watchers || [];
    const i = arr.findIndex(x => x.id === id);
    if (i < 0) return ack('Non trovato', true);
    arr[i].enabled = !arr[i].enabled;
    watchers.saveWatchers({ watchers: arr });
    watchers.start(cfg, log);
    await ack(arr[i].enabled ? `● ${id} ON` : `○ ${id} OFF`);
    await refreshCurrent();
    return;
  }
  if (action === 'fire' && id) {
    watchers.fireNow(id, cfg).catch(e => log('fire error:', e.message));
    await ack(`▶ ${id} avviato`);
    setTimeout(() => refreshCurrent().catch(() => {}), 1500);
    return;
  }
  if (action === 'log' && id) {
    try {
      const logPath = path.join(LOGS_DIR, 'watchers.log');
      const content = fs.existsSync(logPath) ? fs.readFileSync(logPath, 'utf8').split('\n').filter(Boolean) : [];
      const lines = content.filter(l => l.includes(`[${id}]`));
      const groups = [];
      let buf = [];
      for (const line of lines) {
        if (/ fire /.test(line)) {
          if (buf.length) groups.push(buf);
          buf = [line];
        } else if (/ done /.test(line)) {
          buf.push(line);
          groups.push(buf);
          buf = [];
        } else {
          if (buf.length) buf.push(line); else groups.push([line]);
        }
      }
      if (buf.length) groups.push(buf);
      const last = groups.slice(-10).map(g => g.join('\n')).join('\n\n');
      const body = last ? '<pre>' + last.replace(/[<>&]/g, c => ({'<':'&lt;','>':'&gt;','&':'&amp;'}[c])) + '</pre>' : `Nessuna riga per ${id}.`;
      await tg(token, 'sendMessage', { chat_id: chatId, text: `📜 Ultimi 10 log ${id}:\n${body}`, parse_mode: 'HTML' });
    } catch (e) { await tg(token, 'sendMessage', { chat_id: chatId, text: 'Errore: ' + e.message }); }
    return ack();
  }
  if (action === 'new') {
    await wizardNewStart(token, chatId, messageId);
    return ack('Wizard avviato');
  }
  if (action === 'new_us') {
    const flow = getWizard(chatId);
    if (!flow || flow.action !== 'new') return ack('Wizard scaduto', true);
    flow.data.use_session = id === '1';
    await wizardNewStep(token, chatId, flow, 'prompt');
    return ack();
  }
  if (action === 'new_save') {
    const flow = getWizard(chatId);
    if (!flow || flow.action !== 'new') return ack('Wizard scaduto', true);
    const d = flow.data;
    const cur = watchers.loadWatchers();
    const arr = cur.watchers || [];
    if (arr.some(w => w.id === d.id)) { clearWizard(chatId); return ack('id duplicato', true); }
    arr.push({ id: d.id, name: d.name, enabled: false, interval_sec: d.interval_sec, use_session: d.use_session, timeout_ms: d.timeout_ms, prompt: d.prompt });
    watchers.saveWatchers({ watchers: arr });
    watchers.start(cfg, log);
    await tg(token, 'sendMessage', { chat_id: chatId, text: `✅ Watcher <code>${escHtml(d.id)}</code> creato (disabilitato). Usa toggle per attivarlo.`, parse_mode: 'HTML' });
    await refreshDashboard(token, chatId, flow);
    clearWizard(chatId);
    return ack('Salvato');
  }
  if (action === 'edit' && id) {
    const ok = await wizardEditStart(token, chatId, id, messageId);
    return ack(ok ? 'Wizard edit' : 'Non trovato', !ok);
  }
  if (action === 'ef' && id) {
    const flow = getWizard(chatId);
    if (!flow || flow.action !== 'edit') return ack('Wizard scaduto', true);
    await wizardEditAskField(token, chatId, flow, id);
    return ack();
  }
  if (action === 'eb') {
    const flow = getWizard(chatId);
    if (!flow || flow.action !== 'edit' || flow.data.field !== 'use_session') return ack('Wizard scaduto', true);
    const cur = watchers.loadWatchers();
    const arr = cur.watchers || [];
    const i = arr.findIndex(x => x.id === flow.watcherId);
    if (i < 0) { clearWizard(chatId); return ack('Non trovato', true); }
    arr[i].use_session = id === '1';
    watchers.saveWatchers({ watchers: arr });
    watchers.start(cfg, log);
    await tg(token, 'sendMessage', { chat_id: chatId, text: `✅ use_session = ${arr[i].use_session}`, parse_mode: 'HTML' });
    await refreshDashboard(token, chatId, flow);
    clearWizard(chatId);
    return ack('Aggiornato');
  }
  if (action === 'del' && id) {
    await tg(token, 'sendMessage', {
      chat_id: chatId,
      text: `🗑 Elimino <code>${escHtml(id)}</code>?\n\nL'operazione è irreversibile.`,
      parse_mode: 'HTML',
      reply_markup: { inline_keyboard: [[
        { text: '⚠ Conferma', callback_data: `w:del_ok:${id}` },
        { text: '✖ Annulla', callback_data: 'w:wcancel' }
      ]] }
    });
    pendingWatcherFlows.set(String(chatId), { action: 'delete', watcherId: id, dashboardMessageId: messageId });
    return ack();
  }
  if (action === 'del_ok' && id) {
    const cur = watchers.loadWatchers();
    const arr = (cur.watchers || []).filter(w => w.id !== id);
    watchers.saveWatchers({ watchers: arr });
    watchers.start(cfg, log);
    const flow = getWizard(chatId);
    await tg(token, 'sendMessage', { chat_id: chatId, text: `🗑 Watcher <code>${escHtml(id)}</code> eliminato.`, parse_mode: 'HTML' });
    await refreshDashboard(token, chatId, flow);
    clearWizard(chatId);
    return ack('Eliminato');
  }
  if (action === 'budget' && id) {
    // Avvia un mini-wizard force_reply per impostare il budget (numero o "-" per rimuoverlo)
    const cur = watchers.loadWatchers();
    const w = (cur.watchers || []).find(x => x.id === id);
    if (!w) return ack('Non trovato', true);
    const curB = typeof w.max_responses === 'number' ? w.max_responses : '—';
    const mid = await askWizardReply(token, chatId,
      `🎯 <b>Budget</b> per <code>${escHtml(id)}</code>\n\nAttuale: <b>${curB}</b>\n\nInserisci numero di <b>responses</b> massime (es. <code>10</code>), oppure <code>-</code> per rimuovere il limite.\n\nInvia <code>/annulla</code> per uscire.`,
      'Numero o -');
    pendingWatcherFlows.set(String(chatId), { action: 'budget', watcherId: id, step: 'value', expectReplyToMsgId: mid, dashboardMessageId: messageId });
    return ack();
  }
  if (action === 'reset' && id) {
    await tg(token, 'sendMessage', {
      chat_id: chatId,
      text: `🔁 Reset budget counter di <code>${escHtml(id)}</code>?`,
      parse_mode: 'HTML',
      reply_markup: { inline_keyboard: [[
        { text: '⚠ Conferma', callback_data: `w:reset_ok:${id}` },
        { text: '✖ Annulla', callback_data: 'w:wcancel' }
      ]] }
    });
    return ack();
  }
  if (action === 'reset_ok' && id) {
    const ok = watchers.resetBudget(id);
    const flow = getWizard(chatId);
    await tg(token, 'sendMessage', { chat_id: chatId, text: ok ? `✅ Budget counter di <code>${escHtml(id)}</code> azzerato.` : `⚠ Nessuno state per <code>${escHtml(id)}</code>.`, parse_mode: 'HTML' });
    await refreshDashboard(token, chatId, flow);
    clearWizard(chatId);
    return ack(ok ? 'Reset ✓' : 'Niente da resettare');
  }
  if (action === 'wcancel') {
    clearWizard(chatId);
    return ack('Annullato');
  }
  await ack();
}

async function handleUpdate(cfg, u, presetStatusMsgId = null) {
  if (!u.message || !u.message.text) return;
  const m = u.message;
  const chatId = String(m.chat.id);
  // Normalizzazione: trim + rimozione mention al bot "/cmd@mybot" -> "/cmd"
  let text = m.text.trim();
  text = text.replace(/^(\/\S+)@\w+/, '$1');
  const token = cfg.telegram.bot_token;
  const allowed = (cfg.telegram.allowed_chat_ids || []).map(String);
  // Helper: ogni risposta diretta al messaggio dell'utente (threading)
  const reply = (t) => sendMessage(token, chatId, t, { replyTo: m.message_id });

  if (!allowed.includes(chatId)) {
    log('DENIED', chatId, m.from?.username, text.slice(0, 80));
    await reply('Accesso negato.');
    if (presetStatusMsgId) await deleteMessage(token, chatId, presetStatusMsgId);
    return;
  }

  // Se questa update è stata marcata come cancellata mentre era in coda, esci subito
  if (consumeCancelled(chatId, u.update_id)) {
    if (presetStatusMsgId) await deleteMessage(token, chatId, presetStatusMsgId);
    log('skipped cancelled update', u.update_id, 'for', chatId);
    return;
  }

  // Wizard watcher: se c'è un flow pendente e il messaggio è reply al prompt atteso,
  // consuma come input e NON forwardare a Claude.
  const wizFlow = getWizard(chatId);
  if (wizFlow) {
    const repliedTo = m.reply_to_message?.message_id;
    const isReplyToWizard = repliedTo && wizFlow.expectReplyToMsgId && repliedTo === wizFlow.expectReplyToMsgId;
    if (text === '/annulla' || (isReplyToWizard && (text === '/annulla' || text === '/cancel'))) {
      clearWizard(chatId);
      await reply('✖ Wizard annullato.');
      if (presetStatusMsgId) await deleteMessage(token, chatId, presetStatusMsgId);
      return;
    }
    if (isReplyToWizard) {
      try {
        const consumed = await processWizardInput(cfg, token, chatId, wizFlow, m.text, reply);
        if (consumed) {
          if (presetStatusMsgId) await deleteMessage(token, chatId, presetStatusMsgId);
          return;
        }
      } catch (e) {
        log('wizard error:', e.message);
        clearWizard(chatId);
        await reply('❌ Errore wizard: ' + e.message);
        if (presetStatusMsgId) await deleteMessage(token, chatId, presetStatusMsgId);
        return;
      }
    }
  }

  if (text === '/ping') {
    await reply('pong');
    return;
  }
  if (text === '/cancel' || text === '/stop' || text === '/annulla') {
    await handleCancel(cfg, u);
    return;
  }
  if (text === '/memo') {
    const qLen = memoState.queue.length + (snapshotInProgress ? 1 : 0);
    if (qLen > 0) {
      await reply(`📝 Memo già in corso o in coda (${qLen}). Accodo il tuo.`);
    } else {
      await reply('📝 Salvo riassunto della conversazione…');
    }
    saveMemorySnapshot(cfg, chatId, null, 'manual')
      .then((r) => {
        if (r && r.ok && fs.existsSync(MEMORY_FILE)) {
          const preview = fs.readFileSync(MEMORY_FILE, 'utf8').slice(0, 600).trim();
          return sendMessage(token, chatId, `✅ Memoria salvata:\n\n${preview}${preview.length >= 600 ? '…' : ''}`);
        }
        return sendMessage(token, chatId, `⚠️ Nessun contenuto da salvare (${r?.error || 'sessione vuota'}).`);
      })
      .catch(e => sendMessage(token, chatId, `Errore salvataggio: ${e.message}`));
    return;
  }
  if (text === '/memos') {
    const h = memoState.history.slice(-10).reverse();
    const active = snapshotInProgress ? 1 : 0;
    const queued = memoState.queue.length;
    const header = `📝 Memo — attivo: ${active}, in coda: ${queued}, totali salvati: ${memoState.history.length}`;
    const body = h.length ? h.map(r => {
      const when = new Date(r.startedAt).toLocaleTimeString('it-IT', { timeZone: 'Europe/Rome' });
      const dur = r.endedAt ? Math.round((r.endedAt - r.startedAt) / 1000) + 's' : '—';
      const tag = r.ok ? '✅' : '❌';
      return `${tag} ${when} · ${r.reason} · ${dur}${r.error ? ' · ' + r.error : ''}`;
    }).join('\n') : '(nessun memo in history)';
    await reply(`${header}\n\n${body}`);
    return;
  }
  // /parallel <prompt> — lancia un task Claude fresh fuori dalla coda della chat
  const mPar = text.match(/^\/parallel\s+([\s\S]+)$/);
  if (mPar) {
    const pPrompt = mPar[1].trim();
    if (!pPrompt) { await reply('Uso: /parallel <prompt>'); return; }
    const active = parallelActive.get(chatId) || 0;
    if (active >= MAX_PARALLEL_PER_CHAT) {
      await reply(`⚠️ Già ${active}/${MAX_PARALLEL_PER_CHAT} task paralleli attivi. Aspetta.`);
      return;
    }
    // fire-and-forget, NON usa enqueue — non blocca la chat corrente
    runParallelTask(cfg, chatId, pPrompt, m.message_id).catch(e => {
      sendMessage(token, chatId, `❌ Parallel error: ${e.message}`, { replyTo: m.message_id });
    });
    return;
  }
  if (text === '/parallel') {
    await reply('Uso: /parallel <prompt>\n\nLancia un task Claude in parallelo (istanza fresh) senza bloccare la chat corrente. Prima del lancio salva un /memo automatico; alla fine ne salva un altro.');
    return;
  }
  if (text === '/restart') {
    rateLimitBlocked = false;
    try { watchers.clearRateLimit(); } catch (e) { log('RESTART: clearRateLimit failed', e?.message); }
    const interrupted = loadInterrupted();
    const tasks = Object.entries(interrupted);
    clearInterrupted();
    log('RESTART: rate limit cleared (bridge + watchers), re-queuing', tasks.length, 'interrupted task(s)');
    if (tasks.length === 0) {
      await reply('✅ Limite rimosso. Bridge operativo.');
      return;
    }
    await reply(`✅ Limite rimosso. Ripristino ${tasks.length} sessione/i interrotte con il nuovo account…`);
    for (const [targetChatId, { prompt: savedPrompt }] of tasks) {
      enqueue(targetChatId, async () => {
        const statusR = await tg(token, 'sendMessage', { chat_id: targetChatId, text: '♻️ Ripristino sessione…' });
        const statusMsgId = statusR?.result?.message_id || null;
        const { result, error: resumeErr } = await runClaude(cfg, savedPrompt, targetChatId, null, null);
        if (statusMsgId) await deleteMessage(token, targetChatId, statusMsgId);
        if (resumeErr && resumeErr !== 'RATE_LIMIT') {
          await sendMessage(token, targetChatId, `Errore ripristino:\n${resumeErr.slice(0, 2000)}`);
        } else if (result) {
          await sendMessage(token, targetChatId, result);
        }
      });
    }
    return;
  }
  if (text === '/clean' || text.startsWith('/clean ')) {
    const arg = parseInt(text.split(' ')[1]);
    const deletedAt = Date.now();
    let ids = [];
    try {
      if (fs.existsSync(CHAT_MESSAGES_FILE)) {
        const data = JSON.parse(fs.readFileSync(CHAT_MESSAGES_FILE, 'utf8'));
        const tracked = (data[chatId] || []);
        ids = [...new Set(tracked.map(e => e.id))];
        data[chatId] = tracked.map(e => ({ ...e, deleted: true, deleted_at: deletedAt }));
        fs.writeFileSync(CHAT_MESSAGES_FILE, JSON.stringify(data, null, 2));
      }
    } catch {}
    if (arg > 0) {
      const rangeIds = Array.from({ length: arg }, (_, i) => m.message_id - i).filter(id => id > 0);
      ids = [...new Set([...ids, ...rangeIds])];
      // Traccia i nuovi ID come già cancellati
      try {
        const data = fs.existsSync(CHAT_MESSAGES_FILE) ? JSON.parse(fs.readFileSync(CHAT_MESSAGES_FILE, 'utf8')) : {};
        const existing = new Set((data[chatId] || []).map(e => e.id));
        const newEntries = rangeIds.filter(id => !existing.has(id)).map(id => ({ id, ts: null, deleted: true, deleted_at: deletedAt }));
        data[chatId] = [...(data[chatId] || []), ...newEntries];
        fs.writeFileSync(CHAT_MESSAGES_FILE, JSON.stringify(data, null, 2));
      } catch {}
    }
    ids.push(m.message_id);
    ids = [...new Set(ids)];
    for (let i = 0; i < ids.length; i += 100) {
      await tg(token, 'deleteMessages', { chat_id: chatId, message_ids: ids.slice(i, i + 100) });
    }
    await sendMessage(token, chatId, '🧹 Chat pulita!');
    return;
  }
  if (text === '/reboot') {
    const panelPort = cfg.ui?.port || 7777;
    await reply('🔄 Riavvio bridge tra 2 secondi...');
    try { fs.writeFileSync(REBOOT_FLAG_FILE, JSON.stringify({ chatId, ts: Date.now() })); } catch {}
    setTimeout(() => {
      fetch(`http://localhost:${panelPort}/api/bridge/restart`, { method: 'POST' }).catch(() => {});
    }, 2000);
    return;
  }
  if (text === '/reload_panel') {
    const panelPort = cfg.ui?.port || 7777;
    try {
      const r = await fetch(`http://127.0.0.1:${panelPort}/api/panel/reload`, { method: 'POST' });
      const j = await r.json().catch(() => ({}));
      if (r.ok && j.ok) {
        const when = j.reloaded_at ? new Date(j.reloaded_at).toLocaleTimeString('it-IT', { timeZone: 'Europe/Rome' }) : '?';
        await reply(`✅ Panel routes ricaricate alle ${when}`);
      } else {
        await reply(`⚠️ Reload fallito: ${j.error || r.status}`);
      }
    } catch (e) { await reply(`❌ Errore reload: ${e.message}`); }
    return;
  }
  // /watchers — lista (chiude dashboard precedente se esiste)
  if (text === '/watchers' || text === '/workers') {
    await openWatchersDashboard(cfg, chatId, m.message_id);
    return;
  }
  // /watcher <id> — dettaglio
  const mW = text.match(/^\/(watcher|worker)\s+(\S+)$/);
  if (mW) {
    const id = mW[2];
    const list = watchers.getStatus().watchers;
    const w = list.find(x => x.id === id);
    if (!w) { await reply(`Watcher "${id}" non trovato.`); return; }
    const last = w.last_fire_at ? new Date(w.last_fire_at).toISOString() + ' (' + Math.floor((Date.now() - w.last_fire_at)/1000) + 's fa)' : 'mai';
    const lines = [
      `📌 ${w.name || w.id}`,
      `id: ${w.id}`,
      `enabled: ${w.enabled}`,
      `running now: ${w.running_now}`,
      `intervallo: ${w.interval_sec}s`,
      `use_session: ${w.use_session}`,
      `session_id: ${w.session_id || '—'}`,
      `ultimo fire: ${last}`,
      `durata: ${w.last_duration_ms ? w.last_duration_ms + 'ms' : '—'}`,
      `exit code: ${w.last_exit_code === null || w.last_exit_code === undefined ? '—' : w.last_exit_code}`,
      '',
      `Ultimo output:\n${(w.last_summary || '(vuoto)').slice(0, 1200)}`
    ];
    await reply(lines.join('\n'));
    return;
  }
  // /watcher_fire <id>
  const mF = text.match(/^\/watcher_fire\s+(\S+)$/);
  if (mF) {
    const id = mF[1];
    watchers.fireNow(id, cfg).catch(e => log('fire error:', e.message));
    await reply(`▶ Watcher "${id}" avviato (fire manuale). Usa /watcher ${id} fra qualche secondo per vedere output.`);
    return;
  }
  // /watcher_say <id> <testo> — inietta un'istruzione prioritaria one-shot nel prossimo fire
  const mSay = text.match(/^\/watcher_say\s+(\S+)\s+([\s\S]+)$/);
  if (mSay) {
    const id = mSay[1];
    const msg = mSay[2].trim();
    const list = watchers.getStatus().watchers;
    if (!list.some(w => w.id === id)) { await reply(`Watcher "${id}" non trovato.`); return; }
    const instructionsFile = path.join(LOGS_DIR, `${id}-instructions.md`);
    try {
      const stamp = new Date().toISOString();
      fs.appendFileSync(instructionsFile, `\n\n--- ${stamp} ---\n${msg}\n`);
      await reply(`📝 Istruzione aggiunta per "${id}" — sarà applicata al prossimo fire.\n\n${msg.slice(0, 400)}`);
    } catch (e) {
      await reply(`❌ Errore scrittura istruzione: ${e.message}`);
    }
    return;
  }
  // /watcher_on <id> / /watcher_off <id>
  const mT = text.match(/^\/watcher_(on|off)\s+(\S+)$/);
  if (mT) {
    const enable = mT[1] === 'on';
    const id = mT[2];
    const cur = watchers.loadWatchers();
    const arr = cur.watchers || [];
    const i = arr.findIndex(x => x.id === id);
    if (i < 0) { await reply(`Watcher "${id}" non trovato.`); return; }
    arr[i].enabled = enable;
    watchers.saveWatchers({ watchers: arr });
    watchers.start(cfg, log);
    await reply(`${enable ? '●' : '○'} Watcher "${id}" ${enable ? 'attivato' : 'disattivato'}.`);
    return;
  }
  // /watcher_budget <id> <n|off> — imposta il budget max_responses
  const mB = text.match(/^\/watcher_budget\s+(\S+)\s+(\S+)$/);
  if (mB) {
    const id = mB[1];
    const raw = mB[2];
    const cur = watchers.loadWatchers();
    if (!(cur.watchers || []).some(w => w.id === id)) { await reply(`Watcher "${id}" non trovato.`); return; }
    if (raw === 'off' || raw === '-') {
      watchers.setBudget(id, null);
      await reply(`✅ Budget rimosso da "${id}".`);
    } else {
      const n = parseInt(raw, 10);
      if (!Number.isFinite(n) || n <= 0) { await reply('❌ Uso: /watcher_budget <id> <n>|off'); return; }
      watchers.setBudget(id, n);
      await reply(`✅ Budget di "${id}" impostato a ${n}.`);
    }
    return;
  }
  // /watcher_reset <id> — azzera il contatore responses_count
  const mR = text.match(/^\/watcher_reset\s+(\S+)$/);
  if (mR) {
    const id = mR[1];
    const ok = watchers.resetBudget(id);
    await reply(ok ? `✅ Budget counter di "${id}" azzerato.` : `⚠ Nessuno state per "${id}".`);
    return;
  }
  // /watcher_log [id] — se id presente filtra, altrimenti tutte
  const mL = text.match(/^\/watcher_log(?:\s+(\S+))?$/);
  if (mL) {
    const id = mL[1];
    try {
      const logPath = path.join(LOGS_DIR, 'watchers.log');
      const content = fs.existsSync(logPath) ? fs.readFileSync(logPath, 'utf8').split('\n').filter(Boolean) : [];
      const lines = id ? content.filter(l => l.includes(`[${id}]`)) : content;
      const groups = [];
      let buf = [];
      for (const line of lines) {
        if (/ fire /.test(line)) {
          if (buf.length) groups.push(buf);
          buf = [line];
        } else if (/ done /.test(line)) {
          buf.push(line);
          groups.push(buf);
          buf = [];
        } else {
          if (buf.length) buf.push(line); else groups.push([line]);
        }
      }
      if (buf.length) groups.push(buf);
      const last = groups.slice(-10).map(g => g.join('\n')).join('\n\n');
      await reply(last ? '```\n' + last + '\n```' : 'Nessuna riga' + (id ? ` per "${id}"` : '') + '.');
    } catch (e) { await reply('Errore: ' + e.message); }
    return;
  }

  // Catch-all: comandi watcher_* / watcher / worker scritti senza argomento
  // (es. se uno clicca /watcher_off dal menu Telegram e invia senza id).
  // Senza questo catcher, il messaggio cadrebbe nel fallback e verrebbe inoltrato a Claude.
  const bareWatcher = text.match(/^\/(watcher|worker)(_fire|_on|_off|_log|_budget|_reset)?$/);
  if (bareWatcher) {
    const full = text.slice(1);
    const list = watchers.getStatus().watchers;
    const rows = list.map(w => {
      const dot = w.running_now ? '🔄' : (w.enabled ? '●' : '○');
      return `${dot} \`${w.id}\` — ${w.name || ''}`;
    }).join('\n');
    const suffix = bareWatcher[2] ? ` <id>` : ' <id>';
    const usage = {
      watcher: 'Uso: `/watcher <id>` — dettaglio di un watcher',
      watcher_fire: 'Uso: `/watcher_fire <id>` — scatena subito un fire',
      watcher_on: 'Uso: `/watcher_on <id>` — attiva watcher',
      watcher_off: 'Uso: `/watcher_off <id>` — disattiva watcher',
      watcher_log: 'Uso: `/watcher_log [id]` — ultimi 10 cicli di log (fire→done, filtrato per id se specificato)',
      watcher_budget: 'Uso: `/watcher_budget <id> <n|off>` — imposta budget risposte (n intero > 0) oppure off per rimuoverlo',
      watcher_reset: 'Uso: `/watcher_reset <id>` — azzera il contatore delle risposte',
      worker: 'Alias di /watcher. Uso: `/worker <id>`'
    }[full] || `Uso: /${full}${suffix}`;
    const msg = `${usage}\n\nWatchers disponibili:\n${rows || '(nessuno)'}`;
    await reply(msg);
    return;
  }
  if (text === '/live') {
    if (!cfg.claude.show_live_window) {
      await reply('Modalità live disattivata. Attivala dal panel (Configurazione → Finestra sessione Claude live).');
    } else {
      resetLiveWindow();
      const runLog = path.join(LOGS_DIR, 'current-run.log');
      openLiveWindow(runLog);
      await reply('Finestra live riaperta.');
    }
    return;
  }
  if (text === '/model' || text.startsWith('/model ')) {
    const MODELS = {
      'sonnet': 'claude-sonnet-4-6',
      'opus': 'claude-opus-4-7',
      'haiku': 'claude-haiku-4-5-20251001',
      'sonnet4': 'claude-sonnet-4-6',
      'opus4': 'claude-opus-4-7',
    };
    const arg = text.split(' ')[1]?.toLowerCase();
    if (!arg) {
      const current = cfg.claude.model || 'default (sonnet)';
      await reply(`Modello attuale: \`${current}\`\n\nDisponibili:\n• sonnet — claude-sonnet-4-6\n• opus — claude-opus-4-7\n• haiku — claude-haiku-4-5-20251001\n\nUso: /model sonnet`);
    } else {
      const resolved = MODELS[arg] || arg;
      cfg.claude.model = resolved;
      const cfgPath = new URL('./config.json', import.meta.url).pathname.replace(/^\/([A-Z]:)/, '$1');
      const raw = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
      raw.claude.model = resolved;
      fs.writeFileSync(cfgPath, JSON.stringify(raw, null, 2), 'utf8');
      await reply(`Modello cambiato: \`${resolved}\`\nAttivo dalla prossima richiesta.`);
    }
    return;
  }
  if (text === '/reset' || text === '/new') {
    const sessions = loadSessions();
    if (sessions[chatId]) {
      await reply('📝 Salvo memoria prima di azzerare…');
      await saveMemorySnapshot(cfg, chatId);
      delete sessions[chatId];
      saveSessions(sessions);
      await reply('🧹 Sessione azzerata. La prossima richiesta inizia una nuova conversazione.');
    } else {
      await reply('Nessuna sessione attiva.');
    }
    return;
  }
  if (text === '/help' || text === '/start') {
    const cmds = Object.keys(cfg.shortcuts || {});
    const sessions = loadSessions();
    const timeoutMin = parseInt(cfg.claude.session_timeout_minutes ?? 60, 10);
    const active = getActiveSession(sessions, chatId, timeoutMin);
    let sess;
    if (active) {
      const min = Math.floor((Date.now() - active.last_active_at) / 60000);
      sess = `\n\nSessione attiva (ultimo msg ${min}m fa, scade tra ${Math.max(0, timeoutMin-min)}m).`;
    } else {
      sess = `\n\nNessuna sessione attiva. Timeout: ${timeoutMin}m.`;
    }
    const currentModel = cfg.claude.model || 'default';
    const help = `Bridge attivo.\n\nComandi:\n/ping — test\n/cancel — annulla la richiesta in corso e svuota la coda\n/reset — nuova conversazione\n/model — mostra/cambia modello (attuale: ${currentModel})\n/help — questo messaggio\n\nScorciatoie:\n${cmds.length ? cmds.join('\n') : '(nessuna)'}${sess}`;
    await reply(help);
    return;
  }

  let expanded = (cfg.shortcuts && cfg.shortcuts[text.trim()]) || text;
  if (m.reply_to_message) {
    const rtm = m.reply_to_message;
    const quoted = rtm.text || rtm.caption || null;
    if (quoted) {
      const clean = quoted.replace(/\n?—\s*[\d.]+s\s*·[^\n]*/g, '').trim();
      const snippet = clean.length > 700 ? clean.slice(0, 700) + '…' : clean;
      const role = rtm.from?.is_bot ? 'assistant' : 'user';
      const msgId = rtm.message_id;
      expanded = `<LinkedMessage role="${role}" id="${msgId}">\n${snippet}\n</LinkedMessage>\n\n${expanded}`;
    }
  }

  log('REQ:', text, expanded !== text ? `→ ${expanded.slice(0, 60)}...` : '');
  state.requests++;
  state.last_request = { time: Date.now(), text: text.slice(0, 200) };
  saveState();

  const liveStatus = cfg.claude.live_status !== false;

  await tg(token, 'sendChatAction', { chat_id: chatId, action: 'typing' });
  let statusMsgId = presetStatusMsgId;
  if (!statusMsgId) {
    const initialR = await tg(token, 'sendMessage', { chat_id: chatId, text: '⏳ Avvio…' });
    statusMsgId = initialR?.result?.message_id || null;
  }
  log('status msg id:', statusMsgId, 'liveStatus:', liveStatus);

  const started = Date.now();
  const progress = {
    currentTool: null,
    currentToolLabel: null,
    toolCount: 0,
    lastAssistantText: '',
    input: 0, output: 0, cacheRead: 0, cacheCreate: 0,
    sessionShort: null,
    phase: 'starting' // starting → thinking → working → writing → done
  };
  let lastEditAt = 0;
  let lastRenderedText = '';
  let eventCount = 0;
  let editCount = 0;

  function buildStatusText() {
    const elapsed = Math.floor((Date.now() - started) / 1000);
    const lines = [];
    // Riga principale: stato corrente, chiaro
    let header;
    if (progress.currentToolLabel) {
      header = progress.currentToolLabel;
    } else if (progress.phase === 'writing' || progress.lastAssistantText) {
      header = '✍️ Sto scrivendo la risposta…';
    } else if (progress.phase === 'thinking' || progress.sessionShort) {
      header = '🤔 Sto ragionando…';
    } else {
      header = '⏳ Avvio…';
    }
    lines.push(header);
    // Riga stats
    const stats = [`⏱ ${elapsed}s`];
    if (progress.toolCount) stats.push(`🛠 ${progress.toolCount} azion${progress.toolCount > 1 ? 'i' : 'e'}`);
    const tok = fmtTokens(progress);
    if (tok) stats.push(tok);
    lines.push(stats.join(' · '));
    // Snippet ultimo testo solo quando non c'è tool attivo (altrimenti ridondante)
    if (progress.lastAssistantText && !progress.currentToolLabel) {
      const snippet = progress.lastAssistantText.replace(/\s+/g, ' ').slice(0, 140);
      lines.push(`💬 "${snippet}${progress.lastAssistantText.length > 140 ? '…' : ''}"`);
    }
    return lines.join('\n');
  }

  async function pushStatus(force = false) {
    if (!liveStatus || !statusMsgId) return;
    const now = Date.now();
    if (!force && now - lastEditAt < 1500) return;
    const text = buildStatusText();
    if (text === lastRenderedText) return;
    lastRenderedText = text;
    lastEditAt = now;
    editCount++;
    await editMessage(token, chatId, statusMsgId, text);
  }

  const onEvent = (o) => {
    eventCount++;
    if (!liveStatus) return;
    if (o.type === 'system' && o.subtype === 'init' && o.session_id) {
      progress.sessionShort = o.session_id.slice(0, 8);
      progress.phase = 'thinking';
    } else if (o.type === 'assistant' && o.message) {
      if (Array.isArray(o.message.content)) {
        for (const c of o.message.content) {
          if (c.type === 'tool_use') {
            progress.currentTool = c.name;
            progress.currentToolLabel = friendlyTool(c.name, c.input || {});
            progress.toolCount += 1;
            progress.phase = 'working';
          } else if (c.type === 'text' && c.text?.trim()) {
            progress.lastAssistantText = c.text.trim();
            // Claude ha iniziato a scrivere testo: niente più tool attivo
            progress.currentTool = null;
            progress.currentToolLabel = null;
            progress.phase = 'writing';
          }
        }
      }
      if (o.message.usage) {
        const u = o.message.usage;
        if (typeof u.input_tokens === 'number') progress.input = u.input_tokens;
        if (typeof u.output_tokens === 'number') progress.output += u.output_tokens;
        if (typeof u.cache_read_input_tokens === 'number') progress.cacheRead += u.cache_read_input_tokens;
        if (typeof u.cache_creation_input_tokens === 'number') progress.cacheCreate += u.cache_creation_input_tokens;
      }
    } else if (o.type === 'user' && Array.isArray(o.message?.content)) {
      // tool_result ricevuto: il tool appena lanciato è finito. Torna in "ragionando" finché non arriva il prossimo evento.
      progress.currentTool = null;
      progress.currentToolLabel = null;
      progress.phase = 'thinking';
    }
    pushStatus(false);
  };

  // tick per aggiornare il cronometro anche senza eventi
  const tick = liveStatus && statusMsgId ? setInterval(() => pushStatus(false), 2000) : null;

  const onSpawn = (child) => {
    runningChildren.set(chatId, child);
  };

  if (rateLimitBlocked) {
    if (statusMsgId) await deleteMessage(token, chatId, statusMsgId);
    await reply('⛔ Limite Claude attivo. Cambia account sul PC, poi invia /restart per riprendere.');
    return;
  }

  runningUpdates.set(chatId, u.update_id);
  runningMessageIds.set(chatId, m.message_id);
  const { result, error, usage } = await runClaude(cfg, expanded, chatId, onEvent, onSpawn);
  runningChildren.delete(chatId);
  runningUpdates.delete(chatId);
  runningMessageIds.delete(chatId);
  if (tick) clearInterval(tick);
  const dur = ((Date.now() - started) / 1000).toFixed(1);

  // Se la richiesta è stata annullata mid-run, esci senza inviare risposta finale
  if (consumeCancelled(chatId, u.update_id)) {
    log('cancel: mid-run update', u.update_id);
    if (statusMsgId) await deleteMessage(token, chatId, statusMsgId);
    return;
  }

  // Preferisci usage finale dal result event se presente
  if (usage) {
    if (typeof usage.input_tokens === 'number') progress.input = usage.input_tokens;
    if (typeof usage.output_tokens === 'number') progress.output = usage.output_tokens;
    if (typeof usage.cache_read_input_tokens === 'number') progress.cacheRead = usage.cache_read_input_tokens;
    if (typeof usage.cache_creation_input_tokens === 'number') progress.cacheCreate = usage.cache_creation_input_tokens;
  }
  const tokLine = fmtTokens(progress);

  log('events:', eventCount, 'edits:', editCount);
  if (statusMsgId) await deleteMessage(token, chatId, statusMsgId);

  if (error) {
    state.errors++;
    state.last_error = { time: Date.now(), text: error.slice(0, 500) };
    saveState();
    log('ERR:', error.slice(0, 200));
    if (error !== 'RATE_LIMIT') {
      const foot = tokLine ? `\n— ${dur}s · ${tokLine}` : `\n— ${dur}s`;
      await reply(`Errore:${foot}\n${error.slice(0, 3500)}`);
    }
  } else {
    log('OK:', `${dur}s`, tokLine, (result || '').slice(0, 120));
    const ctxPct = progress.input ? Math.round(progress.input / 200000 * 100) : null;

    if (/prompt is too long/i.test(result || '')) {
      const sessions = loadSessions();
      delete sessions[chatId];
      saveSessions(sessions);
      log('context too long: auto-reset session for', chatId);
      const memNote = fs.existsSync(MEMORY_FILE)
        ? '\n\nHo un riassunto salvato della sessione precedente: verrà usato come memoria nella prossima sessione.'
        : '\n\nNon ho un riassunto salvato (era sotto il 75% quando si è saturato). Invia /memo subito dopo il prossimo messaggio per salvarne uno manualmente.';
      await reply(`⚠️ Sessione troppo lunga — contesto azzerato automaticamente.${memNote}\n\nRipeti il messaggio per continuare.`);
    } else {
      const ctxLine = ctxPct !== null ? ` · 📊 ${ctxPct}%` : '';
      const foot = tokLine ? `\n\n— ${dur}s · ${tokLine}${ctxLine}` : `\n\n— ${dur}s${ctxLine}`;
      await reply(`${result}${foot}`);
      if (ctxPct !== null && ctxPct >= 75 && !snapshotInProgress) {
        await sendMessage(token, chatId, `⚠️ Contesto al ${ctxPct}% — sto salvando un riassunto in background per non perdere nulla…`);
        saveMemorySnapshot(cfg, chatId).catch(e => log('memory snapshot error:', e.message));
      }
    }
  }
}

async function loop() {
  log('bridge started');
  try {
    const cfg = loadConfig();
    await drainOfflineQueue(cfg);
  } catch (e) { log('initial drain failed:', e.message); }
  // Avvia i watcher worker (polling persistente, indipendente dai messaggi Telegram)
  try {
    const cfg = loadConfig();
    // Push-based: quando un watcher cambia stato, edita le dashboard aperte (debounced)
    watchers.onStateChange(() => scheduleDashboardPush(cfg.telegram.bot_token));
    const n = watchers.start(cfg, log);
    log(`watchers: ${n} attivi`);
  } catch (e) { log('watchers start failed:', e.message); }
  // Avvia server RPC loopback per mutazioni watcher dal panel (porta 7778)
  try {
    const cfg = loadConfig();
    startRpc(cfg, log);
  } catch (e) { log('rpc start failed:', e.message); }
  // Registra comandi bot per l'autocomplete di Telegram
  try {
    const cfg = loadConfig();
    await registerTelegramCommands(cfg.telegram.bot_token, cfg);
  } catch (e) { log('register commands failed:', e.message); }
  // Notifica post-reboot se richiesta
  try {
    if (fs.existsSync(REBOOT_FLAG_FILE)) {
      const { chatId } = JSON.parse(fs.readFileSync(REBOOT_FLAG_FILE, 'utf8'));
      fs.unlinkSync(REBOOT_FLAG_FILE);
      const cfg = loadConfig();
      await sendMessage(cfg.telegram.bot_token, chatId, '✅ Bridge riavviato e comandi aggiornati!');
    }
  } catch (e) { log('reboot notify error:', e.message); }
  // Aggiorna periodicamente i contatori "in attesa da Ns" dei messaggi in coda
  setInterval(() => {
    try {
      const cfg = loadConfig();
      const token = cfg.telegram.bot_token;
      for (const chatId of pendingWaiters.keys()) {
        refreshWaiters(token, chatId).catch(() => {});
      }
    } catch {}
  }, 5000);
  while (true) {
    let cfg;
    try { cfg = loadConfig(); }
    catch (e) { log('config error, retry in 5s:', e.message); await new Promise(r=>setTimeout(r,5000)); continue; }

    try {
      const r = await fetch(`https://api.telegram.org/bot${cfg.telegram.bot_token}/getUpdates?offset=${offset}&timeout=30`);
      const data = await r.json();
      if (data.ok) {
        for (const u of data.result) {
          offset = u.update_id + 1;
          // Telegram edited_message: ri-indirizza il prompt sul waiter ancora in coda
          if (u.edited_message) {
            handleEditedMessage(cfg, u).catch(e => log('edit handler error:', e.message));
            continue;
          }
          // Callback query da inline keyboard (pulsanti watcher)
          if (u.callback_query) {
            handleCallbackQuery(cfg, u).catch(e => log('callback handler error:', e.message));
            continue;
          }
          const msg = u.message;
          const chatId = msg?.chat?.id ? String(msg.chat.id) : null;
          if (chatId && msg?.message_id) logMsgId(chatId, msg.message_id);
          const hasVoice = !!(msg?.voice || msg?.audio || msg?.video_note);
          const fixedCmds = ['/ping','/start','/help','/reset','/new','/live','/cancel','/stop','/annulla','/watchers','/workers','/restart','/memo','/memos','/parallel','/model','/reboot','/reload_panel','/clean'];
          const isWatcherCmd = msg?.text && /^\/(watcher|worker)(_fire|_on|_off|_log|_budget|_reset|_say)?(\s|$)/.test(msg.text);
          const isParallelCmd = msg?.text && /^\/parallel(\s|$)/.test(msg.text);
          if (chatId && (msg?.text || hasVoice) && !(msg?.text && fixedCmds.includes(msg.text)) && !isWatcherCmd && !isParallelCmd) {
            const token = cfg.telegram.bot_token;
            const posBefore = chatDepth.get(chatId) || 0; // quanti task già in coda/running prima di questo
            incDepth(chatId);
            let initialText;
            if (hasVoice) {
              initialText = posBefore === 0
                ? '🎤 Trascrivendo vocale…'
                : `📥 In coda (vocale)\n· posizione ${posBefore + 1} (${posBefore} davanti a te)\n· trascriverò appena tocca a te`;
            } else {
              initialText = posBefore === 0
                ? '⏳ Avvio…'
                : `📥 In coda\n· posizione ${posBefore + 1} (${posBefore} davanti a te)\n· in attesa da 0s`;
            }
            let statusMsgId = null;
            try {
              const body = {
                chat_id: chatId,
                text: initialText,
                reply_parameters: { message_id: msg.message_id, allow_sending_without_reply: true }
              };
              const r = await tg(token, 'sendMessage', body);
              statusMsgId = r?.result?.message_id || null;
              if (statusMsgId) logMsgId(chatId, statusMsgId);
            } catch (e) { log('initial status send fail:', e.message); }
            let waiter = null;
            if (posBefore > 0 && statusMsgId) {
              // Riferimento a `u` nel waiter: se l'utente EDITA il msg in coda mutiamo u.message.text
              // e il handler quando fa partire la richiesta usa il prompt aggiornato.
              waiter = { statusMsgId, enqueuedAt: Date.now(), lastText: initialText, updateId: u.update_id, messageId: msg.message_id, u };
              const arr = pendingWaiters.get(chatId) || [];
              arr.push(waiter);
              pendingWaiters.set(chatId, arr);
            }
            enqueue(chatId, async () => {
              // Questa richiesta è la prossima che parte: rimuovila dai waiters
              if (waiter) {
                const arr = pendingWaiters.get(chatId) || [];
                const idx = arr.indexOf(waiter);
                if (idx >= 0) arr.splice(idx, 1);
                if (arr.length) pendingWaiters.set(chatId, arr); else pendingWaiters.delete(chatId);
              }
              // Trascrizione vocale (se serve) prima di passare a Claude
              if (hasVoice) {
                try {
                  if (statusMsgId) await editMessage(token, chatId, statusMsgId, '🎤 Trascrivendo vocale…');
                  const voiceObj = msg.voice || msg.audio || msg.video_note;
                  const t0 = Date.now();
                  const { text: transcript } = await transcribeTelegramVoice(token, voiceObj.file_id, { language: 'it' });
                  const tdur = ((Date.now() - t0) / 1000).toFixed(1);
                  if (!transcript) throw new Error('Trascrizione vuota');
                  log(`VOICE transcribed in ${tdur}s:`, transcript.slice(0, 120));
                  // Inietta il testo trascritto nel messaggio con prefisso chiaro
                  u.message.text = `🎤 ${transcript}`;
                  if (statusMsgId) await editMessage(token, chatId, statusMsgId, `🎤 "${transcript.slice(0, 160)}${transcript.length > 160 ? '…' : ''}"\n⏳ Avvio…`);
                } catch (e) {
                  log('voice transcription error:', e.message);
                  if (statusMsgId) await deleteMessage(token, chatId, statusMsgId);
                  await sendMessage(token, chatId, `⚠️ Trascrizione fallita: ${e.message}`, { replyTo: msg.message_id });
                  decDepth(chatId);
                  refreshWaiters(token, chatId).catch(() => {});
                  return;
                }
              }
              try {
                await handleUpdate(cfg, u, statusMsgId);
              } catch (e) {
                log('handler error:', e.message);
              } finally {
                decDepth(chatId);
                // Aggiorna le posizioni dei messaggi ancora in coda
                refreshWaiters(token, chatId).catch(() => {});
              }
            });
          } else {
            handleUpdate(cfg, u).catch(e => log('handler error:', e.message));
          }
        }
      } else {
        log('getUpdates not ok:', JSON.stringify(data).slice(0, 200));
        await new Promise(r => setTimeout(r, 3000));
      }
    } catch (e) {
      log('poll error:', e.message);
      await new Promise(r => setTimeout(r, 5000));
    }
  }
}

loop();
