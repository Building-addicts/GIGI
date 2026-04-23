// API astratta MemoryStore. Backend swappabile via env MEMORY_BACKEND.
// Contratto:
//   put({ userId, text, tags? }) → { id, userId, text, tags, ts }
//   query(text, { userId, limit }) → Array<{ ...entry, score }>
//   delete(id, { userId }) → boolean
//   all(userId) → Array<entry>
let _store = null;

export async function getStore() {
  if (_store) return _store;
  const backend = process.env.MEMORY_BACKEND || 'json';
  if (backend === 'json') {
    const mod = await import('./backends/json-store.js');
    _store = mod.createStore();
  } else if (backend === 'lancedb') {
    const mod = await import('./backends/lancedb-store.js');
    _store = mod.createStore();
  } else {
    throw new Error(`MEMORY_BACKEND sconosciuto: ${backend}`);
  }
  return _store;
}
