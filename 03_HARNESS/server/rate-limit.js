// Rate limit detection + interrupted state recovery.
// Quando Claude CLI risponde con rate-limit o errore 529 salviamo il prompt in
// interrupted.json + alziamo il flag globale. Il resume manuale (reset via
// /api/ios/rate-limit/reset) riattiva il flusso.
import fs from 'node:fs';
import { INTERRUPTED_FILE } from './paths.js';
import { log } from './logger.js';

export function loadInterrupted() {
  try { return JSON.parse(fs.readFileSync(INTERRUPTED_FILE, 'utf8')); } catch { return {}; }
}

export function saveInterrupted(obj) {
  try { fs.writeFileSync(INTERRUPTED_FILE, JSON.stringify(obj, null, 2)); } catch {}
}

export function clearInterrupted() {
  try { fs.writeFileSync(INTERRUPTED_FILE, '{}'); } catch {}
}

export function isRateLimit(res) {
  const haystack = ((res.stderr || '') + ' ' + (res.error || '') + ' ' + (res.stdout || '')).toLowerCase();
  if (haystack.includes("you've hit your limit") || haystack.includes('you have hit your limit')) return true;
  if (res.code === 0) return false;
  return ['rate limit', 'rate_limit', 'too many requests', 'usage limit', 'overloaded', '529', 'claude ai usage', 'quota exceeded'].some(p => haystack.includes(p));
}

export function isSessionNotFound(res) {
  const haystack = ((res.stdout || '') + ' ' + (res.stderr || '')).toLowerCase();
  return haystack.includes('no conversation found with session id');
}

// Broadcasted ai client iOS via WebSocket in fase 12.
export function notifyRateLimit(_cfg) {
  log('RATE LIMIT: notificare client iOS quando WS sarà attivo (fase 12)');
}

// Flag globale modulare
const state = { blocked: false };

export function isBlocked() { return state.blocked; }
export function setBlocked(v) { state.blocked = !!v; }

export function resetRateLimit() {
  state.blocked = false;
  clearInterrupted();
  log('rate limit flag cleared, ready for new requests');
}

export function markInterrupted(deviceId, prompt) {
  const interrupted = loadInterrupted();
  interrupted[deviceId] = { prompt, at: Date.now() };
  saveInterrupted(interrupted);
  state.blocked = true;
}
