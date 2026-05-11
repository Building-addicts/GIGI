// iOS local-LLM endpoint (Phase 2 — GATE 4).
//
// REST + SSE bridge between iOS app and harness Ollama (Path 3).
// Mounted by ios-router.js at:
//   POST  /api/ios/local-llm/generate   → SSE stream of chunks
//   GET   /api/ios/local-llm/status     → reachable, models, tier
//   POST  /api/ios/local-llm/cancel     → abort an in-flight run
//
// Auth: same Bearer middleware as ios-router (ios-auth.js).
// Streaming: server-sent events (SSE), iOS consumes via URLSession.bytes.
//
// Reference: docs/plans/frolicking-stargazing-pancake.md §3.2
// ADR-0010 (TBD) — Ollama as first-class Path 3

import { OllamaClient, getDefaultOllamaClient } from '../local-llm/ollama-client.js';
import { log } from '../logger.js';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const logger = {
  info: (msg, meta) => log(`[local-llm] ${msg}`, meta || ''),
  warn: (msg, meta) => log(`[local-llm][warn] ${msg}`, meta || ''),
};
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

// MARK: - Config

// Use __dirname (api/) → go up one level to server/, then into local-llm/
// Previous use of process.cwd() was unreliable because cwd depends on how
// the harness was launched (start-all.sh sets it to server/, but server.js
// might be invoked from elsewhere).
const CONFIG_PATH = process.env.HARNESS_LOCAL_LLM_CONFIG
  || path.join(__dirname, '..', 'local-llm', 'config.json');

let cachedConfig = null;
function loadConfig() {
  if (cachedConfig) return cachedConfig;
  try {
    if (fs.existsSync(CONFIG_PATH)) {
      cachedConfig = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf-8'));
      return cachedConfig;
    }
  } catch (err) {
    logger?.warn?.('local_llm_config_load_failed', { err: String(err) });
  }
  // Fall back to example config.
  try {
    const examplePath = path.join(path.dirname(CONFIG_PATH), 'config.example.json');
    cachedConfig = JSON.parse(fs.readFileSync(examplePath, 'utf-8'));
  } catch {
    cachedConfig = { ollama: { tier: 'default', tier_models: { default: 'qwen3:14b' } } };
  }
  return cachedConfig;
}

function selectModel(requestedModel) {
  const cfg = loadConfig();
  const ollama = cfg.ollama || {};
  if (requestedModel) return requestedModel;
  if (ollama.model) return ollama.model;
  const tier = ollama.tier || 'default';
  return ollama.tier_models?.[tier] || 'qwen3:14b';
}

// MARK: - In-flight runs (cancellation registry)

const inFlight = new Map(); // runId → AbortController

function makeRunId() {
  return `local-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

// MARK: - SSE writers

function sseInit(res) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache, no-transform',
    'Connection': 'keep-alive',
    'X-Accel-Buffering': 'no',
    'Access-Control-Allow-Origin': '*',
  });
}

function sseSend(res, event, data) {
  const payload = typeof data === 'string' ? data : JSON.stringify(data);
  res.write(`event: ${event}\n`);
  res.write(`data: ${payload}\n\n`);
}

function sseDone(res) {
  res.end();
}

// MARK: - Handlers

/**
 * POST /api/ios/local-llm/generate
 * Body: { prompt, model?, think?, history?, sessionId? }
 * Response: SSE stream — event:chunk + event:done + event:error
 */
export async function handleGenerate(req, res, deps) {
  const rawBody = await deps.readBody(req);
  let body;
  try {
    body = rawBody ? JSON.parse(rawBody) : {};
  } catch {
    return deps.sendJson(res, 400, { ok: false, error: { code: 'BAD_JSON', message: 'Body must be JSON' } });
  }
  const prompt = String(body.prompt || '').trim();
  if (!prompt) {
    return deps.sendJson(res, 400, { ok: false, error: { code: 'PROMPT_EMPTY', message: 'prompt is required' } });
  }
  const requestedModel = body.model;
  const think = body.think ?? false;
  const model = selectModel(requestedModel);
  const runId = body.sessionId || makeRunId();

  // Start SSE response.
  sseInit(res);

  const client = getDefaultOllamaClient();
  const controller = new AbortController();
  inFlight.set(runId, controller);

  const started = Date.now();
  let chunks = 0;

  // Handle client disconnect: abort the request.
  req.on('close', () => {
    if (inFlight.has(runId)) {
      logger?.info?.('local_llm_client_disconnect', { runId });
      controller.abort();
      inFlight.delete(runId);
    }
  });

  try {
    for await (const chunk of client.generate({ model, prompt, signal: controller.signal, think })) {
      chunks++;
      sseSend(res, 'chunk', { text: chunk });
    }
    sseSend(res, 'done', { latencyMs: Date.now() - started, chunks, model, runId });
    sseDone(res);
    logger?.info?.('local_llm_done', { runId, model, chunks, latencyMs: Date.now() - started });
  } catch (err) {
    logger?.warn?.('local_llm_error', { runId, err: String(err) });
    sseSend(res, 'error', { message: String(err.message || err) });
    sseDone(res);
  } finally {
    inFlight.delete(runId);
  }
}

/**
 * GET /api/ios/local-llm/status
 * Response: { reachable, models, currentTier, model, recommendedTier }
 */
export async function handleStatus(req, res, deps) {
  const cfg = loadConfig();
  const ollama = cfg.ollama || {};
  const client = getDefaultOllamaClient();
  const probe = await client.isReachable();
  const ramGB = Math.round((os.totalmem() / (1024 ** 3)) * 10) / 10;
  const recommended = ramGB >= 32 ? 'pro'
    : ramGB >= 16 ? 'default'
    : ramGB >= 8 ? 'standard'
    : 'lite';
  deps.sendJson(res, 200, {
    ok: true,
    data: {
      reachable: probe.ok,
      version: probe.version,
      models: probe.models || [],
      currentTier: ollama.tier || 'default',
      model: selectModel(),
      hostRamGB: ramGB,
      recommendedTier: recommended,
    },
  });
}

/**
 * GET /api/ios/local-llm/install-status
 * Probe: Ollama installed? daemon reachable? compatible model installed?
 * Returns the granular status iOS uses to decide Fix-Automatically next step.
 */
export async function handleInstallStatus(req, res, deps) {
  const cfg = loadConfig();
  const tiers = cfg.ollama?.tier_models || {};
  const compatibleModels = Object.values(tiers);

  // Step 1: binary present on PATH?
  const cliInstalled = await new Promise((resolve) => {
    const probe = spawn(process.platform === 'win32' ? 'where' : 'which', ['ollama'], { shell: false });
    probe.on('close', (code) => resolve(code === 0));
    probe.on('error', () => resolve(false));
  });

  // Step 2: daemon reachable?
  const client = getDefaultOllamaClient();
  const probe = await client.isReachable();
  const daemonReachable = probe.ok;
  const installed = probe.models || [];
  const installedCompatible = installed.filter((m) => compatibleModels.includes(m));

  deps.sendJson(res, 200, {
    ok: true,
    data: {
      cliInstalled,
      daemonReachable,
      version: probe.version || null,
      installedModels: installed,
      installedCompatibleModels: installedCompatible,
      compatibleTiers: tiers,
      // Next-step hint for the iOS "Fix Automatically" cascade
      nextAction: !cliInstalled
        ? 'install-ollama'
        : !daemonReachable
          ? 'start-ollama-daemon'
          : installedCompatible.length === 0
            ? 'pull-model'
            : 'ready',
      hostPlatform: process.platform,
    },
  });
}

/**
 * POST /api/ios/local-llm/install-ollama
 * Installs Ollama via the platform-native package manager. Streams progress
 * via SSE. Idempotent (no-op if already installed).
 */
export async function handleInstallOllama(req, res, deps) {
  sseInit(res);
  sseSend(res, 'thought', { text: `Installing Ollama on ${process.platform}...` });

  const isWin = process.platform === 'win32';
  const isMac = process.platform === 'darwin';
  const isLinux = process.platform === 'linux';

  let cmd, args;
  if (isWin) {
    cmd = 'winget';
    args = ['install', '--id', 'Ollama.Ollama', '--silent', '--accept-package-agreements', '--accept-source-agreements'];
  } else if (isMac) {
    cmd = 'brew';
    args = ['install', 'ollama'];
  } else if (isLinux) {
    // Linux: official curl-pipe-sh installer
    cmd = 'sh';
    args = ['-c', 'curl -fsSL https://ollama.com/install.sh | sh'];
  } else {
    sseSend(res, 'error', { code: 'UNSUPPORTED_PLATFORM', message: `Cannot auto-install on ${process.platform}. Install manually from https://ollama.com/download` });
    return res.end();
  }

  const child = spawn(cmd, args, { shell: isWin, stdio: ['ignore', 'pipe', 'pipe'] });

  child.stdout.on('data', (d) => {
    const line = d.toString().trim();
    if (line) sseSend(res, 'thought', { text: line.slice(0, 200) });
  });
  child.stderr.on('data', (d) => {
    const line = d.toString().trim();
    if (line) sseSend(res, 'thought', { text: '[stderr] ' + line.slice(0, 200) });
  });
  child.on('error', (err) => {
    sseSend(res, 'error', { code: 'SPAWN_FAILED', message: err.message });
    res.end();
  });
  child.on('close', (code) => {
    if (code === 0) {
      sseSend(res, 'thought', { text: 'Ollama installed successfully. You may need to start the daemon manually with `ollama serve` if it does not autostart.' });
      sseSend(res, 'done', { status: 'installed', exitCode: code });
    } else {
      sseSend(res, 'error', { code: 'INSTALL_FAILED', message: `Installer exited with code ${code}`, exitCode: code });
    }
    res.end();
  });

  // Client abort → kill child
  req.on('close', () => {
    if (!child.killed) child.kill();
  });
}

/**
 * POST /api/ios/local-llm/pull-model
 * Body: { model: "qwen3:14b" }
 * Streams pull progress via SSE.
 */
export async function handlePullModel(req, res, deps) {
  const rawBody = await deps.readBody(req);
  let body;
  try { body = JSON.parse(rawBody || '{}'); } catch { body = {}; }
  const model = String(body.model || '').trim();
  if (!model) {
    return deps.sendJson(res, 400, { ok: false, error: { code: 'MODEL_REQUIRED', message: 'model name is required' } });
  }

  sseInit(res);
  sseSend(res, 'thought', { text: `Pulling ${model}...` });

  const client = getDefaultOllamaClient();
  try {
    let lastPct = 0;
    for await (const event of client.pullModel(model)) {
      // Ollama pull events: { status, digest, total, completed }
      if (event.completed && event.total) {
        const pct = Math.floor((event.completed / event.total) * 100);
        if (pct >= lastPct + 5) {
          lastPct = pct;
          sseSend(res, 'progress', { pct, status: event.status, completed: event.completed, total: event.total });
        }
      } else if (event.status) {
        sseSend(res, 'thought', { text: event.status });
      }
    }
    sseSend(res, 'done', { model, status: 'pulled' });
  } catch (err) {
    sseSend(res, 'error', { code: 'PULL_FAILED', message: err.message || String(err) });
  } finally {
    res.end();
  }
}

/**
 * POST /api/ios/local-llm/cancel
 * Body: { runId }
 */
export async function handleCancel(req, res, deps) {
  const rawBody = await deps.readBody(req);
  let body;
  try { body = JSON.parse(rawBody || '{}'); } catch { body = {}; }
  const runId = String(body.runId || '');
  const ctrl = inFlight.get(runId);
  if (ctrl) {
    ctrl.abort();
    inFlight.delete(runId);
    deps.sendJson(res, 200, { ok: true, data: { cancelled: true, runId } });
  } else {
    deps.sendJson(res, 200, { ok: true, data: { cancelled: false, runId, reason: 'not_found' } });
  }
}

export default {
  handleGenerate, handleStatus, handleCancel,
  handleInstallStatus, handleInstallOllama, handlePullModel
};
