// Memory snapshot /memo — serializzato via coda.
// Chiediamo a Claude (--resume) di generare un riassunto strutturato della
// sessione e lo salviamo in docs/memory/memory.md. Una sola /memo alla volta:
// se arriva mentre una è in corso, si accoda e parte dopo.
import fs from 'node:fs';
import { MEMORY_FILE } from './paths.js';
import { log } from './logger.js';
import { loadSessions } from './session-manager.js';
import { spawnClaude } from './claude-runner.js';

let snapshotInProgress = false;
const memoState = {
  queue: [],    // Array<{ cfg, deviceId, overrideSessionId, reason, resolve, reject, queuedAt }>
  history: []   // Array<{...}>, max 50
};

async function _doMemoSnapshot(cfg, deviceId, overrideSessionId) {
  const sessions = loadSessions();
  const entry = overrideSessionId ? { session_id: overrideSessionId } : sessions[deviceId];
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
  const rec = { deviceId: job.deviceId, reason: job.reason, queuedAt: job.queuedAt, startedAt, endedAt: null, ok: false };
  try {
    const r = await _doMemoSnapshot(job.cfg, job.deviceId, job.overrideSessionId);
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
    setImmediate(_processMemoQueue);
  }
}

export function saveMemorySnapshot(cfg, deviceId, overrideSessionId = null, reason = 'manual') {
  return new Promise((resolve, reject) => {
    memoState.queue.push({ cfg, deviceId, overrideSessionId, reason, resolve, reject, queuedAt: Date.now() });
    _processMemoQueue();
  });
}

export function getMemoHistory() {
  return memoState.history.slice();
}

export function isMemoInProgress() {
  return snapshotInProgress;
}
