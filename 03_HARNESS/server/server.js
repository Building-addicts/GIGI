// GIGI harness server — backend per app iOS GIGI.
//
// Orchestratore minimale. I moduli in questa cartella espongono la logica:
// - paths.js            → path costanti (VPS-ready via env)
// - logger.js           → log(...) shared
// - session-manager.js  → sessioni Claude per deviceId
// - claude-runner.js    → spawnClaude, runClaude, runParallelTask
// - queue.js            → enqueue/cancel + tracking child per device
// - rate-limit.js       → detection + interrupted state + recovery
// - memory-snapshot.js  → /memo serializzato
// - transcript-mirror.js→ backup JSONL Claude
// - watchers.js         → worker autonomi periodici (proactive)
// - bridge-rpc.js       → RPC loopback per panel
//
// Gli endpoint iOS HTTP/WS vengono montati in fase 12 via panel-routes.js.

import fs from 'node:fs';
import http from 'node:http';
import {
  LOGS_DIR, CONFIG_PATH, STATE_FILE, LOCK_FILE, REBOOT_FLAG_FILE,
  TRANSCRIPTS_DIR, MEMORY_FILE, CONTEXT_FILE, INTERRUPTED_FILE
} from './paths.js';
import { log } from './logger.js';
import * as sessionManager from './session-manager.js';
import * as claudeRunner from './claude-runner.js';
import * as queue from './queue.js';
import * as rateLimit from './rate-limit.js';
import * as memorySnapshot from './memory-snapshot.js';
import * as transcriptMirror from './transcript-mirror.js';
import * as watchers from './watchers.js';
import { startRpc } from './bridge-rpc.js';
import { handleIosRequest } from './api/ios-router.js';
import { handlePair } from './api/pair.js';
import { handleSetup } from './api/setup.js';
import { handleDiagnostics } from './api/diagnostics.js';
import { handleAutofix } from './api/autofix.js';
import { attachWebSocketServer } from './api/ios-stream.js';
import { handlePanelRequest } from './api/panel-connections.js';

// ─────────────────────────────────────────────────────────────
// Lock file: evita istanze duplicate
// ─────────────────────────────────────────────────────────────
(function acquireLock() {
  if (fs.existsSync(LOCK_FILE)) {
    const pid = parseInt(fs.readFileSync(LOCK_FILE, 'utf8').trim(), 10);
    let alive = false;
    try { process.kill(pid, 0); alive = true; } catch {}
    if (alive) {
      console.error(`[server] already running (pid ${pid}), exiting.`);
      process.exit(0);
    }
  }
  fs.writeFileSync(LOCK_FILE, String(process.pid));
  process.on('exit', () => { try { fs.unlinkSync(LOCK_FILE); } catch {} });
  process.on('SIGINT', () => process.exit(0));
  process.on('SIGTERM', () => process.exit(0));
})();

// ─────────────────────────────────────────────────────────────
// Config + state
// ─────────────────────────────────────────────────────────────
function loadConfig() {
  return JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
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

// ─────────────────────────────────────────────────────────────
// API pubblica — importata dai route handler iOS (fase 12) via `panel-routes.js`.
// Wrapper memory-snapshot per iniettare saveMemorySnapshot in runParallelTask.
// ─────────────────────────────────────────────────────────────
function runParallelTaskWithMemo(cfg, deviceId, prompt, onProgress) {
  return claudeRunner.runParallelTask(cfg, deviceId, prompt, onProgress, memorySnapshot.saveMemorySnapshot);
}

function runClaudeWithExpiryMemo(cfg, prompt, deviceId, onEvent, onSpawn) {
  return claudeRunner.runClaude(cfg, prompt, deviceId, onEvent, onSpawn,
    (expiredId) => memorySnapshot.saveMemorySnapshot(cfg, deviceId, expiredId, 'expiry')
      .catch(e => log('auto-memo on expiry error:', e.message))
  );
}

export const gigiServer = {
  // sessions
  loadSessions: sessionManager.loadSessions,
  saveSessions: sessionManager.saveSessions,
  getActiveSession: sessionManager.getActiveSession,
  // claude
  runClaude: runClaudeWithExpiryMemo,
  runParallelTask: runParallelTaskWithMemo,
  spawnClaude: claudeRunner.spawnClaude,
  // memory
  saveMemorySnapshot: memorySnapshot.saveMemorySnapshot,
  getMemoHistory: memorySnapshot.getMemoHistory,
  // transcript
  mirrorTranscript: transcriptMirror.mirrorTranscript,
  getDeviceTranscript: transcriptMirror.getDeviceTranscript,
  // queue
  enqueue: queue.enqueue,
  incDepth: queue.incDepth,
  decDepth: queue.decDepth,
  markCancelled: queue.markCancelled,
  consumeCancelled: queue.consumeCancelled,
  killAllActive: queue.killAllActive,
  trackChild: queue.trackChild,
  untrackChild: queue.untrackChild,
  // rate limit
  isRateLimit: rateLimit.isRateLimit,
  isSessionNotFound: rateLimit.isSessionNotFound,
  resetRateLimit: rateLimit.resetRateLimit,
  get rateLimitBlocked() { return rateLimit.isBlocked(); },
  loadInterrupted: rateLimit.loadInterrupted,
  saveInterrupted: rateLimit.saveInterrupted,
  clearInterrupted: rateLimit.clearInterrupted,
  // log
  log, loadConfig,
  // state
  state, saveState,
  // helpers
  friendlyTool: claudeRunner.friendlyTool,
  fmtTokens: claudeRunner.fmtTokens,
  shortPath: claudeRunner.shortPath,
  clipStr: claudeRunner.clipStr,
  // paths
  LOGS_DIR, CONFIG_PATH, TRANSCRIPTS_DIR,
  MEMORY_FILE, CONTEXT_FILE, INTERRUPTED_FILE, REBOOT_FLAG_FILE,
};

// ─────────────────────────────────────────────────────────────
// Main — avvia watchers + RPC. HTTP server iOS viene aggiunto in fase 12.
// ─────────────────────────────────────────────────────────────
async function main() {
  let cfg;
  try {
    cfg = loadConfig();
  } catch (e) {
    console.error(`[server] impossibile leggere ${CONFIG_PATH}: ${e.message}`);
    console.error('[server] crea config.json copiando da config.example.mac.json');
    process.exit(1);
  }

  log('GIGI harness server avviato — pid', process.pid);
  log('config:', CONFIG_PATH);
  log('logs:', LOGS_DIR);

  try {
    watchers.start(cfg, log);
    log('watchers started');
  } catch (e) {
    log('watchers start error:', e.message);
  }

  try {
    startRpc(cfg, log);
  } catch (e) {
    log('rpc start error:', e.message);
  }

  setInterval(() => {
    state.uptime_s = Math.floor((Date.now() - state.started_at) / 1000);
    saveState();
  }, 30000);

  const iosPort = cfg.server?.port || 7779;
  const iosHost = cfg.server?.host || '127.0.0.1';
  const iosServer = http.createServer(async (req, res) => {
    try {
      // /api/pair is loopback-only (enforced inside handlePair) and MUST
      // run before the iOS router, because it intentionally skips the
      // Bearer check (the QR itself hands out the Bearer).
      if (await handlePair(req, res, { cfg })) return;
      // /api/setup/diagnostics — Bearer-authed (same secret as iOS API).
      // MUST run before handleSetup, since handleSetup also matches
      // /api/setup/* but enforces loopback-only — the iPhone is NOT
      // on loopback when calling diagnostics.
      if (await handleDiagnostics(req, res, { cfg, gigiServer })) return;
      // /api/setup/autofix — Bearer-authed batch fixer. Same reasoning
      // as diagnostics: matches /api/setup/* but bypasses loopback gate.
      if (await handleAutofix(req, res, { cfg, cfgPath: CONFIG_PATH })) return;
      // /api/panel/* — Connections tab (loopback-only). Lives in the bridge
      // process because it inspects in-memory state (cloudflared, WS rooms,
      // request log) that the panel process can't reach directly.
      if (await handlePanelRequest(req, res, { cfg, cfgPath: CONFIG_PATH })) return;
      // /api/setup/* — wizard endpoints, also loopback-only + bearer-free.
      if (await handleSetup(req, res, { cfg, cfgPath: CONFIG_PATH })) return;
      const handled = await handleIosRequest(req, res, { cfg, gigiServer });
      if (!handled) {
        res.writeHead(404, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ ok: false, error: { code: 'NOT_FOUND', message: 'endpoint sconosciuto' } }));
      }
    } catch (e) {
      log('iOS HTTP handler error:', e.message);
      if (!res.headersSent) {
        res.writeHead(500, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ ok: false, error: { code: 'INTERNAL', message: e.message } }));
      }
    }
  });
  attachWebSocketServer(iosServer, cfg);
  iosServer.on('error', (err) => {
    if (err.code === 'EADDRINUSE') log(`iOS server: porta ${iosPort} occupata — skip`);
    else log('iOS server error:', err.message);
  });
  iosServer.listen(iosPort, iosHost, () => {
    log(`iOS HTTP+WS: http://${iosHost}:${iosPort}  ·  ws://${iosHost}:${iosPort}/ws/ios/stream`);
  });

  log('panel admin: avvia separatamente con `node panel.js` (porta 7777 default)');
}

main().catch(e => {
  console.error('[server] fatal:', e);
  process.exit(1);
});
