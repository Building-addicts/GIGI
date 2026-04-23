// Logger condiviso. Scrive a stdout + LOG_FILE.
import fs from 'node:fs';
import { LOG_FILE } from './paths.js';

export function log(...args) {
  const line = `[${new Date().toISOString()}] ${args.map(a => typeof a === 'string' ? a : JSON.stringify(a)).join(' ')}`;
  console.log(line);
  try { fs.appendFileSync(LOG_FILE, line + '\n'); } catch {}
}
