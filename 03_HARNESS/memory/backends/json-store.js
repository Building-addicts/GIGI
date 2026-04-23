// JSON file backend. Un file per userId in memory/logs/<userId>.json.
// Retrieval: keyword scoring (case-insensitive, term frequency).
// Sostituibile in futuro con LanceDB + BGE-M3 senza toccare ios-memory.js.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DATA_DIR = process.env.HARNESS_MEMORY_DIR || path.join(__dirname, '..', 'logs');

try { fs.mkdirSync(DATA_DIR, { recursive: true }); } catch {}

function fileForUser(userId) {
  const safe = String(userId).replace(/[^\w.-]/g, '_');
  return path.join(DATA_DIR, `${safe}.json`);
}

function loadForUser(userId) {
  try { return JSON.parse(fs.readFileSync(fileForUser(userId), 'utf8')); } catch { return []; }
}

function saveForUser(userId, arr) {
  try { fs.writeFileSync(fileForUser(userId), JSON.stringify(arr, null, 2)); } catch {}
}

function scoreEntry(entry, terms) {
  if (!terms.length) return 0;
  const haystack = (entry.text + ' ' + (entry.tags || []).join(' ')).toLowerCase();
  let score = 0;
  for (const t of terms) {
    if (!t) continue;
    const occ = (haystack.match(new RegExp(t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'g')) || []).length;
    score += occ;
  }
  return score;
}

export function createStore() {
  return {
    async put({ userId, text, tags = [] }) {
      const arr = loadForUser(userId);
      const entry = {
        id: randomUUID(),
        userId, text,
        tags: Array.isArray(tags) ? tags : [],
        ts: Date.now()
      };
      arr.push(entry);
      saveForUser(userId, arr);
      return entry;
    },

    async query(text, { userId, limit = 10 }) {
      const arr = loadForUser(userId);
      const terms = String(text || '').toLowerCase().split(/\s+/).filter(t => t.length >= 2);
      if (!terms.length) {
        return arr.slice(-limit).reverse().map(e => ({ ...e, score: 0 }));
      }
      return arr
        .map(e => ({ ...e, score: scoreEntry(e, terms) }))
        .filter(e => e.score > 0)
        .sort((a, b) => b.score - a.score)
        .slice(0, limit);
    },

    async delete(id, { userId }) {
      const arr = loadForUser(userId);
      const idx = arr.findIndex(e => e.id === id);
      if (idx === -1) return false;
      arr.splice(idx, 1);
      saveForUser(userId, arr);
      return true;
    },

    async all(userId) {
      return loadForUser(userId).slice().reverse();
    }
  };
}
