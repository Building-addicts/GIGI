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
import { logger } from '../logger.js';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

// MARK: - Config

const CONFIG_PATH = process.env.HARNESS_LOCAL_LLM_CONFIG
  || path.join(process.cwd(), '03_HARNESS', 'server', 'local-llm', 'config.json');

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

export default { handleGenerate, handleStatus, handleCancel };
