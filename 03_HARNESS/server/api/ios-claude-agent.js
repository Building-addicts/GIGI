// iOS Claude Code agent endpoint — Phase 2 (GATE 5 scaffold).
//
// Mounted at:
//   POST /api/ios/agent/claude   → SSE stream of claude events (thought, tool_use, text, done)
//   POST /api/ios/agent/confirm  → confirm/deny a confirm_required gate
//   POST /api/ios/agent/cancel   → cancel an in-flight run
//
// Current state: SCAFFOLD. Returns a structured "not yet wired" SSE error
// so the iOS client falls back to the legacy GigiClaudeBridge.run() path
// (which already works via /api/ios/agent/run).
//
// GATE 5 will replace the body of `handleClaude` with the real Claude
// Code subprocess spawn via `claude-runner.js` + MCP `harness-browser`,
// streaming `thought`, `tool_use`, `confirm_required`, `text`, `done`
// events back to the client.
//
// Reference: docs/plans/frolicking-stargazing-pancake.md §3.5 + §4.4
// docs/taskplans_new_gigi/GATE-5-path-4-claude-code-subprocess.md

import { logger } from '../logger.js';

const inFlight = new Map(); // runId → AbortController

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

function makeRunId() {
  return `claude-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

/**
 * POST /api/ios/agent/claude
 * Body: { prompt, mcpServers?, deviceId, runId? }
 * Response: SSE stream of claude events.
 */
export async function handleClaude(req, res, deps) {
  const rawBody = await deps.readBody(req);
  let body;
  try { body = JSON.parse(rawBody || '{}'); }
  catch { return deps.sendJson(res, 400, { ok: false, error: { code: 'BAD_JSON', message: 'Body must be JSON' } }); }

  const prompt = String(body.prompt || '').trim();
  if (!prompt) {
    return deps.sendJson(res, 400, { ok: false, error: { code: 'PROMPT_EMPTY', message: 'prompt is required' } });
  }
  const mcpServers = Array.isArray(body.mcpServers) ? body.mcpServers : [];
  const runId = body.runId || makeRunId();

  sseInit(res);
  const controller = new AbortController();
  inFlight.set(runId, controller);
  req.on('close', () => {
    if (inFlight.has(runId)) {
      controller.abort();
      inFlight.delete(runId);
    }
  });

  logger?.info?.('claude_agent_request', { runId, mcpServersCount: mcpServers.length });

  // SCAFFOLD: emit a structured error so the iOS client falls back to the
  // legacy GigiClaudeBridge.run() path. GATE 5 will replace this body with
  // the real claude-runner.js subprocess spawn + MCP wiring.
  sseSend(res, 'thought', { text: 'Claude Code subprocess endpoint not yet wired in harness (GATE 5 scaffold).' });
  sseSend(res, 'error', {
    code: 'CLAUDE_RUNNER_NOT_WIRED',
    message: 'POST /api/ios/agent/claude is scaffolded; full Claude Code subprocess + MCP harness-browser wiring lands in GATE 5. Falling back to legacy agent/run.',
    runId,
  });
  res.end();
  inFlight.delete(runId);
}

/**
 * POST /api/ios/agent/confirm
 * Body: { runId, approved }
 */
export async function handleConfirm(req, res, deps) {
  const rawBody = await deps.readBody(req);
  let body;
  try { body = JSON.parse(rawBody || '{}'); }
  catch { return deps.sendJson(res, 400, { ok: false, error: { code: 'BAD_JSON', message: 'Body must be JSON' } }); }
  const { runId, approved } = body;
  if (!runId) {
    return deps.sendJson(res, 400, { ok: false, error: { code: 'RUNID_REQUIRED', message: 'runId is required' } });
  }
  // GATE 5: forward to subprocess stdin (or MCP AskUserQuestion reply).
  // For now: log + 200.
  logger?.info?.('claude_confirm', { runId, approved });
  deps.sendJson(res, 200, { ok: true, data: { runId, approved: !!approved, status: 'scaffold' } });
}

/**
 * POST /api/ios/agent/cancel (with X-Cancel-Target: claude header)
 * Body: { runId }
 */
export async function handleCancel(req, res, deps) {
  const rawBody = await deps.readBody(req);
  let body;
  try { body = JSON.parse(rawBody || '{}'); }
  catch { body = {}; }
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

export default { handleClaude, handleConfirm, handleCancel };
