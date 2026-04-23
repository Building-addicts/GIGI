// Mirror del JSONL Claude (backup portabile per deviceId).
// Claude scrive la conversazione in ~/.claude/projects/<cwd>/<session>.jsonl.
// Copia idempotente in logs/transcripts/<deviceId>.jsonl così lo storico
// completo viaggia con la cartella del server anche se sposti 03_HARNESS.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { SERVER_DIR, TRANSCRIPTS_DIR } from './paths.js';
import { loadSessions } from './session-manager.js';
import { log } from './logger.js';

export function claudeProjectDir(cwd = SERVER_DIR) {
  const encoded = cwd.replace(/[\\\/:]/g, '-');
  return path.join(os.homedir(), '.claude', 'projects', encoded);
}

export function claudeSessionJsonlPath(sessionId) {
  if (!sessionId) return null;
  return path.join(claudeProjectDir(), `${sessionId}.jsonl`);
}

export function mirrorTranscript(deviceId, sessionId) {
  if (!deviceId || !sessionId) return;
  const src = claudeSessionJsonlPath(sessionId);
  if (!src || !fs.existsSync(src)) return;
  const dst = path.join(TRANSCRIPTS_DIR, `${deviceId}.jsonl`);
  try { fs.copyFileSync(src, dst); } catch (e) { log('mirror transcript error:', e.message); }
}

export function getDeviceTranscript(deviceId) {
  const mirrored = path.join(TRANSCRIPTS_DIR, `${deviceId}.jsonl`);
  let source = null;
  if (fs.existsSync(mirrored)) source = mirrored;
  else {
    const sessions = loadSessions();
    const entry = sessions[deviceId];
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
