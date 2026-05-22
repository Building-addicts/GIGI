// Claude CLI runner: spawn + streaming stdout JSONL.
// - spawnClaude(cfg, args, onEvent?, onSpawn?): promessa con {stdout, stderr, code}.
//   Se onEvent presente → aggiunge --verbose, stream-json, emette eventi parsati.
// - runClaude(cfg, prompt, deviceId, onEvent?, onSpawn?): high-level che:
//   * usa session-manager per --resume / --session-id
//   * rileva rate limit → markInterrupted + kill all
//   * fallback session-not-found → ritenta con sessione nuova
//   * salva sessions aggiornata + mirror transcript
// - runParallelTask(cfg, deviceId, prompt, onProgress?): task paralleli (max 3/device),
//   fresh claude con memoria+contesto iniettata nel system prompt.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

// Module-level __dirname for ESM (used by spawnClaude sandbox cwd resolution).
const __MODULE_DIR__ = path.dirname(fileURLToPath(import.meta.url));
import { LOGS_DIR, MEMORY_FILE, CONTEXT_FILE } from './paths.js';
import { log } from './logger.js';
import {
  loadSessions, saveSessions, getActiveSession
} from './session-manager.js';
import {
  isRateLimit, isSessionNotFound, notifyRateLimit, markInterrupted
} from './rate-limit.js';
import { killAllActive } from './queue.js';
import { mirrorTranscript } from './transcript-mirror.js';

// ─────────────────────────────────────────────────────────────
// Live window (solo Windows). No-op su macOS/Linux.
// ─────────────────────────────────────────────────────────────
let liveWindowOpenedAt = 0;

function openLiveWindow(logFile) {
  if (process.platform !== 'win32') return;
  if (Date.now() - liveWindowOpenedAt < 3600 * 1000) return;
  liveWindowOpenedAt = Date.now();
  const psCmd = `$Host.UI.RawUI.WindowTitle='Claude — sessione live'; $host.UI.RawUI.BackgroundColor='Black'; Clear-Host; Write-Host 'Sessione Claude live.' -ForegroundColor Cyan; Write-Host ''; Get-Content -Path '${logFile.replace(/\\/g, '\\\\')}' -Wait`;
  const p = spawn('cmd.exe', ['/c', 'start', 'Claude Live', 'powershell.exe', '-NoProfile', '-NoExit', '-Command', psCmd], {
    detached: true, windowsHide: false, stdio: 'ignore'
  });
  p.unref();
}

export function resetLiveWindow() { liveWindowOpenedAt = 0; }

// ─────────────────────────────────────────────────────────────
// Pretty print tool calls (usato da panel + stream WS iOS).
// ─────────────────────────────────────────────────────────────
function clipStr(s, n) {
  s = String(s || '').replace(/\s+/g, ' ');
  return s.length > n ? s.slice(0, n) + '…' : s;
}

function shortPath(p) {
  if (!p) return '';
  const s = String(p);
  const m = s.match(/[^\\/]+$/);
  return m ? m[0] : s.slice(-40);
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

export { clipStr, shortPath, fmtTokens, friendlyTool };

// ─────────────────────────────────────────────────────────────
// spawnClaude — low-level, streaming
// ─────────────────────────────────────────────────────────────
export function spawnClaude(cfg, args, onEvent, onSpawn) {
  const showLive = !!cfg.claude.show_live_window && process.platform === 'win32';
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

    // Strip ANTHROPIC_API_KEY from env — Claude CLI uses its own stored credentials.
    // A placeholder value in .env would override the stored key and cause "Invalid API key".
    const claudeEnv = { ...process.env };
    delete claudeEnv.ANTHROPIC_API_KEY;

    // 2026-05-21 MCP STARTUP RACE FIX:
    // In headless (-p) mode the CLI otherwise begins the agent turn before
    // stdio MCP servers (harness-browser connects to CDP, ~1-3s) finish their
    // handshake. The deferred-tool index is then empty, so the agent's first
    // `ToolSearch select:mcp__harness-browser__…` returns "No matching deferred
    // tools found" and it flails / fabricates. Force a blocking connect with a
    // generous timeout so the tools are always indexed before turn 1.
    claudeEnv.MCP_CONNECTION_NONBLOCKING = 'false';
    claudeEnv.MCP_TIMEOUT = claudeEnv.MCP_TIMEOUT || '30000';

    // 2026-05-12 LANGUAGE-LEAK FIX:
    // Claude Code CLI auto-loads CLAUDE.md from the CWD and every parent dir
    // (walk-up). When spawned from the default harness CWD it picks up the
    // team-shared Italian CLAUDE.md files (03_HARNESS/CLAUDE.md + repo-root
    // CLAUDE.md, ~814 lines combined) which override the
    // `--append-system-prompt` we pass. Result: Claude responds in Italian
    // regardless of our English instructions.
    //
    // Fix: spawn from a dedicated sandbox dir whose only CLAUDE.md is an
    // English-only operator manual. Walk-up still stops within `~/.claude/`
    // (global) but that file is also English. The IT docs in the repo
    // remain untouched — only the spawned subprocess is isolated.
    const sandboxDir = path.join(__MODULE_DIR__, '.claude-sandbox');
    const claudeCwd = fs.existsSync(path.join(sandboxDir, 'CLAUDE.md'))
      ? sandboxDir
      : __MODULE_DIR__;

    const child = spawn(cfg.claude.bin || 'claude', streamArgs, {
      shell: false,
      windowsHide: true,
      timeout: cfg.claude.timeout_ms || 600000,
      env: claudeEnv,
      cwd: claudeCwd
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

// ─────────────────────────────────────────────────────────────
// runClaude — high-level per sessione iOS
// ─────────────────────────────────────────────────────────────
function injectSystemContext(baseSysPrompt) {
  let sysPrompt = baseSysPrompt || '';
  try {
    if (fs.existsSync(CONTEXT_FILE)) {
      const ctx = fs.readFileSync(CONTEXT_FILE, 'utf8').trim();
      if (ctx) sysPrompt += `\n\n--- CONTESTO PROGETTO ---\n${ctx}\n--- FINE CONTESTO ---`;
    }
  } catch {}
  // 2026-05-21 ANTI-FABRICATION: memory.md injection DISABLED.
  // memory.md is an auto-generated free-text chat summary (saveMemorySnapshot)
  // containing unverified narrative — tried-but-failed orders, inferred
  // preferences, restaurant names that never became a real order. Injecting it
  // primed hallucinations ("the usual from Nana Poke"). The redesign's only
  // verified memory is ~/.gigi-memory/orders.json, surfaced as <past_orders>.
  // Do NOT re-enable without separating verified facts from narrative.
  return sysPrompt;
}

export async function runClaude(cfg, prompt, deviceId, onEvent, onSpawn, onSessionExpired, options) {
  const sessions = loadSessions();
  const timeoutMin = parseInt(cfg.claude.session_timeout_minutes ?? 60, 10);
  const useSession = cfg.claude.continuous_session !== false;
  const active = useSession ? getActiveSession(sessions, deviceId, timeoutMin) : null;

  // options.domain: route to domain-specific system prompt + MCP config
  // options.schema: append JSON schema constraint to prompt
  // options.mcp_config: explicit MCP config path override
  // options.mcpServers: array of named MCP servers to include (Phase 3 prep,
  //   2026-05-11). Resolves each name to a config path via MCP_SERVER_PATHS,
  //   then picks the first valid one (full multi-server merge will come with
  //   the 5-path computer-use rewrite — see plan §4 / ADR-0007 TBD).
  const domain = options?.domain || null;
  const schema = options?.schema || null;
  const mcpServers = Array.isArray(options?.mcpServers) ? options.mcpServers : [];
  const mcpConfigPath = options?.mcp_config || cfg.claude.mcp_config || null;

  // Use fileURLToPath (via __MODULE_DIR__), NOT new URL(...).pathname: the
  // latter leaves %20 encoded for spaces in the path ("Last GIGI"), so the
  // resolved mcp-browser.json path fails fs.existsSync and --mcp-config gets
  // silently dropped → MCP tools never load → "No matching deferred tools".
  const __dirname = __MODULE_DIR__;

  // Domain → MCP config (browser tools for web/research domains)
  const DOMAIN_MCP = {
    browser:  path.join(__dirname, 'mcp-browser.json'),
    research: path.join(__dirname, 'mcp-browser.json'),
  };

  // Named MCP server registry (Phase 3 prep). Add new MCP servers here as
  // they land. The iOS app passes server names — never raw paths — so the
  // harness owns the actual config file locations.
  const MCP_SERVER_PATHS = {
    'harness-browser': path.join(__dirname, 'mcp-browser.json'),
  };
  const mcpServersConfigPath = mcpServers.length > 0
    ? (MCP_SERVER_PATHS[mcpServers[0]] || null)
    : null;

  // Domain → system prompt override
  const now = new Date().toISOString().slice(0, 10);
  const DOMAIN_PROMPTS = {
    browser:  `You are GIGI's browser automation agent. Use the harness-browser MCP tools to navigate pages, fill forms, extract data, and complete web tasks. If structured output is requested, respond ONLY with valid JSON. Today: ${now}.`,
    research: `You are GIGI's research agent. Use browser tools to find live, accurate information from multiple sources. If structured output is requested, respond ONLY with valid JSON. Today: ${now}.`,
    calendar: `You are GIGI's scheduling assistant. Help with calendar analysis, scheduling decisions, and time-related tasks. Today: ${now}.`,
    messaging:`You are GIGI's communication assistant. Draft messages, emails, and notifications concisely. Today: ${now}.`,
  };

  // Precedence: explicit mcp_config > named mcpServers > domain default
  const effectiveMcpConfig = mcpConfigPath
    || mcpServersConfigPath
    || (domain ? DOMAIN_MCP[domain] : null);
  const domainSystemPrompt = domain ? DOMAIN_PROMPTS[domain] : null;

  // If schema requested, append constraint to prompt
  const effectivePrompt = schema
    ? `${prompt}\n\nIMPORTANT: Respond ONLY with valid JSON matching this schema: ${schema}`
    : prompt;

  async function attempt(sessionId, isNew) {
    const args = ['-p', effectivePrompt, '--output-format', 'json',
      '--permission-mode', cfg.claude.permission_mode || 'bypassPermissions'];
    if (cfg.claude.model) args.push('--model', cfg.claude.model);
    if (effectiveMcpConfig && fs.existsSync(effectiveMcpConfig)) {
      args.push('--mcp-config', effectiveMcpConfig);
    }
    if (useSession) {
      if (isNew) {
        // 2026-05-12 Opzione B — clean-on-new-session.
        // Every time we open a brand-new Claude session (not --resume), wipe
        // any leftover working memory in the sandbox. Guarantees the new
        // session starts with zero context: no stale notepad entries, no
        // "Supabase MCP disconnected" residue, no IT phrases sticking around.
        // Resume sessions intentionally keep their state (multi-turn).
        try {
          const sandboxClaudeDir = path.join(__MODULE_DIR__, '.claude-sandbox', '.claude');
          if (fs.existsSync(sandboxClaudeDir)) {
            fs.rmSync(sandboxClaudeDir, { recursive: true, force: true });
            log('[claude-runner] wiped .claude-sandbox/.claude/ on new session');
          }
        } catch (e) {
          log('[claude-runner] sandbox wipe failed:', e.message);
        }

        args.push('--session-id', sessionId);
        const baseSysPrompt = domainSystemPrompt || cfg.claude.system_prompt;
        const sysPrompt = injectSystemContext(baseSysPrompt);
        if (sysPrompt) args.push('--append-system-prompt', sysPrompt);
      } else {
        args.push('--resume', sessionId);
      }
    } else {
      const baseSysPrompt = domainSystemPrompt || cfg.claude.system_prompt;
      if (baseSysPrompt) args.push('--append-system-prompt', injectSystemContext(baseSysPrompt));
    }
    return spawnClaude(cfg, args, onEvent, onSpawn);
  }

  let sessionId = active?.session_id || randomUUID();
  let isNew = !active;
  if (isNew && active === null && sessions[deviceId]) {
    log('session expired (timeout ' + timeoutMin + 'min) for', deviceId, '— new one');
    const expiredId = sessions[deviceId]?.session_id || sessions[deviceId];
    if (typeof expiredId === 'string' && typeof onSessionExpired === 'function') {
      try { onSessionExpired(expiredId); } catch {}
    }
  }
  let res = await attempt(sessionId, isNew);

  function handleRateLimit(tag) {
    markInterrupted(deviceId, prompt);
    const killed = killAllActive();
    log(`RATE LIMIT${tag ? ' (' + tag + ')' : ''}: killed`, killed, 'processes, blocking new requests');
    notifyRateLimit(cfg);
    return { error: 'RATE_LIMIT' };
  }

  if (isRateLimit(res)) return handleRateLimit();

  if (!isNew && useSession && isSessionNotFound(res)) {
    log('session not found on server, starting fresh for', deviceId);
    const sessions2 = loadSessions();
    delete sessions2[deviceId];
    saveSessions(sessions2);
    sessionId = randomUUID();
    isNew = true;
    res = await attempt(sessionId, true);
    if (isRateLimit(res)) return handleRateLimit('session retry');
  }

  if (res.code !== 0 && !res.stdout && !isNew && useSession) {
    log('resume failed, starting fresh session for', deviceId);
    sessionId = randomUUID();
    isNew = true;
    res = await attempt(sessionId, true);
    if (isRateLimit(res)) return handleRateLimit('retry');
  }

  if (res.code !== 0 && !res.stdout) {
    return { error: res.stderr || res.error || `exit ${res.code}` };
  }

  if (useSession) {
    sessions[deviceId] = { session_id: sessionId, last_active_at: Date.now(), started_at: active?.started_at || Date.now() };
    saveSessions(sessions);
  }

  mirrorTranscript(deviceId, sessionId);

  const out = res.stdout.trim();
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

// ─────────────────────────────────────────────────────────────
// runParallelTask — max 3 per device, fresh session con memoria iniettata
// ─────────────────────────────────────────────────────────────
const parallelActive = new Map();
const MAX_PARALLEL_PER_DEVICE = 3;

export async function runParallelTask(cfg, deviceId, prompt, onProgress, saveMemorySnapshot) {
  const count = parallelActive.get(deviceId) || 0;
  if (count >= MAX_PARALLEL_PER_DEVICE) {
    return { error: `too many parallel (${count}/${MAX_PARALLEL_PER_DEVICE})` };
  }
  parallelActive.set(deviceId, count + 1);
  if (onProgress) try { onProgress({ stage: 'pre-memo', msg: 'Aggiorno memoria prima del task parallelo' }); } catch {}
  try {
    if (saveMemorySnapshot) {
      try { await saveMemorySnapshot(cfg, deviceId, null, 'pre-parallel'); }
      catch (e) { log('parallel pre-memo error:', e.message); }
    }

    if (onProgress) try { onProgress({ stage: 'running', msg: 'Task parallelo in esecuzione' }); } catch {}

    const sysPrompt = injectSystemContext(cfg.claude.system_prompt);
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

    return { result };
  } catch (e) {
    return { error: e.message };
  } finally {
    const n = (parallelActive.get(deviceId) || 1) - 1;
    if (n <= 0) parallelActive.delete(deviceId); else parallelActive.set(deviceId, n);
    if (saveMemorySnapshot) {
      saveMemorySnapshot(cfg, deviceId, null, 'post-parallel').catch(e => log('parallel post-memo error:', e.message));
    }
  }
}
