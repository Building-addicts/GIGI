// Path constants centralizzati. Override via env var (VPS-ready).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export const SERVER_DIR = __dirname;
export const LOGS_DIR = process.env.HARNESS_LOGS_DIR || path.join(__dirname, 'logs');
export const CONFIG_PATH = process.env.HARNESS_CONFIG || path.join(__dirname, 'config.json');
export const LOG_FILE = path.join(LOGS_DIR, 'bridge.log');
export const STATE_FILE = path.join(LOGS_DIR, 'state.json');
export const SESSIONS_FILE = path.join(LOGS_DIR, 'sessions.json');
export const LOCK_FILE = path.join(LOGS_DIR, 'bridge.lock');
export const INTERRUPTED_FILE = path.join(LOGS_DIR, 'interrupted.json');
export const REBOOT_FLAG_FILE = path.join(LOGS_DIR, 'reboot_pending.json');
export const TRANSCRIPTS_DIR = path.join(LOGS_DIR, 'transcripts');

const DOCS_MEMORY = path.join(__dirname, '..', 'docs', 'memory');
export const MEMORY_FILE = path.join(DOCS_MEMORY, 'memory.md');
export const CONTEXT_FILE = path.join(DOCS_MEMORY, 'context.md');

try { fs.mkdirSync(LOGS_DIR, { recursive: true }); } catch {}
try { fs.mkdirSync(TRANSCRIPTS_DIR, { recursive: true }); } catch {}
