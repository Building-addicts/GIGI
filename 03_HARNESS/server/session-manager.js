// Sessioni Claude per deviceId iOS.
// Una sessione mantiene il contesto Claude (--resume <session_id>) per
// timeout_minutes. Scade → prossima richiesta apre sessione nuova.
import fs from 'node:fs';
import { SESSIONS_FILE } from './paths.js';

export function loadSessions() {
  try { return JSON.parse(fs.readFileSync(SESSIONS_FILE, 'utf8')); } catch { return {}; }
}

export function saveSessions(s) {
  try { fs.writeFileSync(SESSIONS_FILE, JSON.stringify(s, null, 2)); } catch {}
}

export function getActiveSession(sessions, deviceId, timeoutMin) {
  const entry = sessions[deviceId];
  if (!entry) return null;
  if (typeof entry === 'string') return { session_id: entry, last_active_at: Date.now() };
  if (!timeoutMin || timeoutMin <= 0) return entry;
  const elapsedMin = (Date.now() - (entry.last_active_at || 0)) / 60000;
  if (elapsedMin > timeoutMin) return null;
  return entry;
}
