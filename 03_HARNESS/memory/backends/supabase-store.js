// Supabase backend for GIGI memory.
// Uses PostgREST RPCs from supabase/migrations/202605030001_gigi_core.sql.
// No @supabase/supabase-js dependency: Node 20+ has fetch built in.

const SUPABASE_URL = (process.env.SUPABASE_URL || '').replace(/\/+$/, '');
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY || '';

function assertConfigured() {
  if (!SUPABASE_URL) throw new Error('SUPABASE_URL mancante per MEMORY_BACKEND=supabase');
  if (!SUPABASE_SERVICE_ROLE_KEY) throw new Error('SUPABASE_SERVICE_ROLE_KEY mancante per MEMORY_BACKEND=supabase');
}

async function rpc(name, body = {}) {
  assertConfigured();
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      apikey: SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`
    },
    body: JSON.stringify(body)
  });

  const text = await res.text();
  let payload = null;
  if (text) {
    try { payload = JSON.parse(text); }
    catch { payload = text; }
  }

  if (!res.ok) {
    const message = payload?.message || payload?.error || text || `Supabase RPC ${name} failed`;
    throw new Error(`Supabase ${res.status} ${name}: ${message}`);
  }

  return payload;
}

function normalizeEntry(entry, fallbackUserId) {
  if (!entry || typeof entry !== 'object') return entry;
  return {
    id: String(entry.id),
    userId: String(entry.userId || fallbackUserId),
    text: String(entry.text || ''),
    tags: Array.isArray(entry.tags) ? entry.tags : [],
    ts: Number(entry.ts || Date.now()),
    ...(entry.score === undefined ? {} : { score: Number(entry.score) })
  };
}

export function createStore() {
  return {
    async put({ userId, text, tags = [] }) {
      const entry = await rpc('gigi_memory_put', {
        p_device_id: userId,
        p_text: text,
        p_tags: Array.isArray(tags) ? tags : []
      });
      return normalizeEntry(entry, userId);
    },

    async query(text, { userId, limit = 10 }) {
      const results = await rpc('gigi_memory_query', {
        p_device_id: userId,
        p_query: text || '',
        p_limit: limit || 10
      });
      return Array.isArray(results) ? results.map(e => normalizeEntry(e, userId)) : [];
    },

    async delete(id, { userId }) {
      const removed = await rpc('gigi_memory_delete', {
        p_device_id: userId,
        p_id: id
      });
      return Boolean(removed);
    },

    async all(userId) {
      const results = await rpc('gigi_memory_all', {
        p_device_id: userId,
        p_limit: 1000
      });
      return Array.isArray(results) ? results.map(e => normalizeEntry(e, userId)) : [];
    }
  };
}
