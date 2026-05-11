// iOS Claude Code agent endpoint — Phase 2 GATE 5 (subprocess + MCP).
//
// Mounted at (via ios-router.js):
//   POST /api/ios/agent/claude   → SSE stream of Claude events (thought, tool_use,
//                                  text, confirm_required, done, error)
//   POST /api/ios/agent/confirm  → confirm/deny a confirm_required gate
//   POST /api/ios/agent/cancel   → SIGTERM a Claude subprocess by runId
//                                  (header X-Cancel-Target: claude)
//
// Wire:
//   - Spawns `claude` CLI via `gigiServer.runClaude(cfg, prompt, deviceId, onEvent, onSpawn, { mcpServers })`.
//   - `runClaude` already supports `options.mcpServers: string[]` (see
//     claude-runner.js line 234). Named servers map to MCP config files in
//     `MCP_SERVER_PATHS` ('harness-browser' → mcp-browser.json).
//   - `onEvent(parsedJSONL)` receives Claude stream-json events. We translate
//     them to typed SSE events.
//
// Cancel:
//   - `inFlight` map tracks `{runId → {child, deviceId}}`. POST /cancel
//     SIGKILLs the child and marks the runId cancelled.
//
// Confirm gating (interim):
//   - This implementation does NOT yet pause the subprocess on destructive
//     actions — Claude CLI doesn't expose a native confirm hook. The GATE 5
//     ConfirmComputerUseSheet UI is wired client-side but server-side this
//     scaffold simply forwards every emitted Claude `tool_use` event so iOS
//     can decide to interrupt with /cancel if needed. Full interrupt+resume
//     gating lands as a follow-up (see TODO at end of file).
//
// Reference: docs/plans/frolicking-stargazing-pancake.md §3.5, §4.4
// docs/taskplans_new_gigi/GATE-5-path-4-claude-code-subprocess.md §3 Task 5.3-5.6

import { randomUUID } from 'node:crypto';
import { log, logger } from '../logger.js';
import { friendlyTool } from '../claude-runner.js';
import { markCancelled } from '../queue.js';

// NOTE: do NOT `import { gigiServer } from '../server.js'` — that creates a
// circular dependency (server.js → ios-router.js → ios-claude-agent.js).
// We pull `gigiServer` from `deps` like the other handlers do (ios-agent.js
// pattern).

// MARK: - In-flight runs

const inFlight = new Map(); // runId → { child, deviceId, ssePush, awaitingConfirm? }

// MARK: - SSE helpers

function sseInit(res) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache, no-transform',
    'Connection': 'keep-alive',
    'X-Accel-Buffering': 'no',
    'Access-Control-Allow-Origin': '*',
  });
  // Flush headers ASAP so iOS sees the stream start
  if (typeof res.flushHeaders === 'function') res.flushHeaders();
}

function sseSend(res, event, data) {
  const payload = typeof data === 'string' ? data : JSON.stringify(data);
  try {
    res.write(`event: ${event}\n`);
    res.write(`data: ${payload}\n\n`);
  } catch (_) {
    // socket may have closed — caller will detect via res.writableEnded
  }
}

// MARK: - Claude JSONL event → SSE translation

function translateClaudeEvent(ev) {
  // Returns array of { event, data } pairs (one Claude JSONL event may map
  // to multiple SSE events, e.g. assistant message with text + tool_use).
  const out = [];
  if (!ev || typeof ev !== 'object') return out;

  switch (ev.type) {
    case 'system':
      if (ev.subtype === 'init' && ev.session_id) {
        out.push({ event: 'thought', data: { text: `[session ${String(ev.session_id).slice(0, 8)} ready]` } });
      }
      break;

    case 'assistant': {
      const content = ev.message?.content || [];
      for (const c of content) {
        if (c.type === 'text' && c.text?.trim()) {
          out.push({ event: 'text', data: { text: c.text } });
        } else if (c.type === 'tool_use') {
          out.push({
            event: 'tool_use',
            data: {
              name: c.name,
              args: c.input || {},
              friendly: friendlyTool(c.name, c.input || {}),
            },
          });
        } else if (c.type === 'thinking' && c.thinking?.trim()) {
          out.push({ event: 'thought', data: { text: c.thinking } });
        }
      }
      break;
    }

    case 'user': {
      // tool_result lines — emit as thoughts so iOS chat can show a "tool
      // returned X" trace bubble. We trim long results to 240 chars.
      const content = ev.message?.content || [];
      for (const c of content) {
        if (c.type === 'tool_result') {
          const raw = typeof c.content === 'string'
            ? c.content
            : JSON.stringify(c.content);
          const preview = String(raw).replace(/\s+/g, ' ').slice(0, 240);
          out.push({ event: 'thought', data: { text: `↳ ${preview}` } });
        }
      }
      break;
    }

    case 'result': {
      // Claude CLI's final result envelope — we already get the final text
      // from the runClaude return value. Emit a thought line here with
      // timing/cost for the iOS chat trace.
      const dur = ev.duration_ms ? (ev.duration_ms / 1000).toFixed(1) : '?';
      const cost = ev.total_cost_usd != null ? ev.total_cost_usd.toFixed(4) : '?';
      out.push({
        event: 'thought',
        data: { text: `─── done (${dur}s, $${cost}) ───` },
      });
      break;
    }

    default:
      // forward-compat: ignore unknown event types
      break;
  }
  return out;
}

// MARK: - Handlers

/**
 * POST /api/ios/agent/claude
 * Body: { prompt, deviceId, mcpServers?, runId? }
 * Response: SSE — event:thought / event:tool_use / event:text / event:confirm_required / event:done / event:error
 */
export async function handleClaude(req, res, deps) {
  const { readBody, sendJson, cfg, gigiServer } = deps;

  const rawBody = await readBody(req);
  let body;
  try { body = JSON.parse(rawBody || '{}'); }
  catch { return sendJson(res, 400, { ok: false, error: { code: 'BAD_JSON', message: 'Body must be JSON' } }); }

  const deviceId = String(body.deviceId || '').trim();
  const prompt = String(body.prompt || '').trim();
  const mcpServers = Array.isArray(body.mcpServers)
    ? body.mcpServers.filter((s) => typeof s === 'string')
    : [];
  const runId = String(body.runId || '').trim() || randomUUID();

  if (!deviceId) return sendJson(res, 400, { ok: false, error: { code: 'MISSING_DEVICE', message: 'deviceId is required' } });
  if (!prompt)   return sendJson(res, 400, { ok: false, error: { code: 'PROMPT_EMPTY',   message: 'prompt is required' } });

  // Open the SSE response upfront.
  sseInit(res);
  sseSend(res, 'thought', { text: `Starting Claude Code subprocess${mcpServers.length ? ` with MCP [${mcpServers.join(', ')}]` : ''}…` });

  const started = Date.now();
  let runChild = null;
  let textBuffer = '';

  const onSpawn = (child) => {
    runChild = child;
    inFlight.set(runId, { child, deviceId, ssePush: (event, data) => sseSend(res, event, data) });
    logger?.info?.('claude_subprocess_spawn', { runId, pid: child.pid, mcpServers });
  };

  const onEvent = (parsed) => {
    // Capture final text streaming for the legacy `text` event fallback path.
    if (parsed?.type === 'assistant') {
      for (const c of parsed.message?.content || []) {
        if (c.type === 'text' && c.text) textBuffer += c.text;
      }
    }
    const translated = translateClaudeEvent(parsed);
    for (const { event, data } of translated) {
      sseSend(res, event, data);
    }
  };

  // Handle client-side abort (iPhone closed connection).
  req.on('close', () => {
    const entry = inFlight.get(runId);
    if (entry && entry.child && !entry.child.killed) {
      log('claude-agent: client closed, killing subprocess for', runId);
      try { entry.child.kill('SIGTERM'); } catch {}
    }
    inFlight.delete(runId);
  });

  try {
    const result = await gigiServer.runClaude(
      cfg,
      prompt,
      deviceId,
      onEvent,
      onSpawn,
      { mcpServers }
    );

    inFlight.delete(runId);

    if (result?.error === 'RATE_LIMIT') {
      sseSend(res, 'error', { code: 'RATE_LIMITED', message: 'Claude subscription rate limit hit. Try again later.', runId });
      sseSend(res, 'done', { latencyMs: Date.now() - started, runId, rate_limited: true });
      return res.end();
    }
    if (result?.error === 'CANCELLED' || result?.error === 'SIGTERM') {
      sseSend(res, 'error', { code: 'CANCELLED', message: 'Run cancelled', runId });
      sseSend(res, 'done', { latencyMs: Date.now() - started, runId, cancelled: true });
      return res.end();
    }
    if (result?.error) {
      sseSend(res, 'error', { code: 'CLAUDE_ERROR', message: String(result.error), runId });
      sseSend(res, 'done', { latencyMs: Date.now() - started, runId, errored: true });
      return res.end();
    }

    // Final text — if nothing was streamed via assistant content, emit the
    // result.result string as a single text event so iOS always has something.
    if (!textBuffer.trim() && typeof result?.result === 'string' && result.result.trim()) {
      sseSend(res, 'text', { text: result.result });
    }

    sseSend(res, 'done', {
      latencyMs: Date.now() - started,
      runId,
      session_id: result?.session_id,
      session_new: !!result?.session_new,
      usage: result?.usage || null,
    });
    res.end();
  } catch (err) {
    inFlight.delete(runId);
    log('claude-agent: error', err?.message || err);
    sseSend(res, 'error', { code: 'INTERNAL', message: String(err?.message || err), runId });
    sseSend(res, 'done', { latencyMs: Date.now() - started, runId, errored: true });
    res.end();
  }
}

/**
 * POST /api/ios/agent/confirm
 * Body: { runId, approved }
 *
 * Interim: logs the decision and acks. Full subprocess interrupt+resume
 * lands as a follow-up (Claude CLI lacks a native confirm hook; needs
 * stdin injection design). For now, if `approved === false`, we SIGTERM
 * the running subprocess as a destructive-action escape valve.
 */
export async function handleConfirm(req, res, deps) {
  const { readBody, sendJson } = deps;
  const rawBody = await readBody(req);
  let body;
  try { body = JSON.parse(rawBody || '{}'); }
  catch { return sendJson(res, 400, { ok: false, error: { code: 'BAD_JSON', message: 'Body must be JSON' } }); }

  const runId = String(body.runId || '').trim();
  const approved = !!body.approved;
  if (!runId) return sendJson(res, 400, { ok: false, error: { code: 'RUNID_REQUIRED', message: 'runId required' } });

  const entry = inFlight.get(runId);
  log('claude-agent confirm:', { runId, approved, knownRun: !!entry });

  if (!approved && entry?.child && !entry.child.killed) {
    try { entry.child.kill('SIGTERM'); } catch {}
    inFlight.delete(runId);
    return sendJson(res, 200, { ok: true, data: { runId, approved: false, status: 'subprocess_killed' } });
  }

  return sendJson(res, 200, { ok: true, data: { runId, approved, status: 'recorded' } });
}

/**
 * POST /api/ios/agent/cancel (X-Cancel-Target: claude)
 * Body: { runId, deviceId? }
 */
export async function handleCancel(req, res, deps) {
  const { readBody, sendJson } = deps;
  const rawBody = await readBody(req);
  let body;
  try { body = JSON.parse(rawBody || '{}'); } catch { body = {}; }
  const runId = String(body.runId || '').trim();
  const deviceId = String(body.deviceId || '').trim();
  if (!runId) return sendJson(res, 400, { ok: false, error: { code: 'RUNID_REQUIRED', message: 'runId required' } });

  const entry = inFlight.get(runId);
  if (entry?.child && !entry.child.killed) {
    try { entry.child.kill('SIGTERM'); } catch {}
    inFlight.delete(runId);
    if (deviceId) markCancelled(deviceId, runId);
    return sendJson(res, 200, { ok: true, data: { cancelled: true, runId, killed_pid: entry.child.pid } });
  }
  if (deviceId) markCancelled(deviceId, runId);
  return sendJson(res, 200, { ok: true, data: { cancelled: false, runId, reason: 'not_found' } });
}

// MARK: - Status probe (called by GigiModeDetector.probeClaudeCode in future)

export async function handleStatus(req, res, deps) {
  deps.sendJson(res, 200, {
    ok: true,
    data: {
      available: true,
      inFlightCount: inFlight.size,
      gate: 'GATE_5',
      status: 'wired',  // was 'scaffold' before 2026-05-12 batch 3
    },
  });
}

export default { handleClaude, handleConfirm, handleCancel, handleStatus };

// TODO (GATE 5 follow-up):
// 1. Confirm gating with subprocess pause: Claude CLI lacks a native hook,
//    so we need to either (a) wrap claude with a PTY and inject stdin, or
//    (b) use `--permission-mode plan` and re-run with mcp tool_use approval
//    list. The current scaffold relies on iOS-side `cancel` for destructive
//    actions, which is functional but not granular.
// 2. Confirm_required event emission: needs Claude CLI to signal pre-tool
//    execution — not in current API. Defer to upstream feature request.
// 3. Screenshot attachment to confirm event: requires MCP harness-browser
//    to call browser_screenshot at the right moment. Out of scope here.
