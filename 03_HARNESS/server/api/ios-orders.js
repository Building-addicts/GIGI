// GET /api/ios/orders/recent?limit=N
//
// Returns recent confirmed orders from ~/.gigi-memory/orders.json (written
// by the gigi-memory MCP server when Claude cloud completes a real cart
// staging). iOS reads this at the start of each turn and injects the
// most recent N entries into the FM router context so GIGI can offer
// "same as last time" without the local FM needing memory of its own.
//
// Single-user store — deviceId is intentionally ignored here.

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const STORE_PATH = path.join(os.homedir(), '.gigi-memory', 'orders.json');

function readStore() {
  try {
    const raw = fs.readFileSync(STORE_PATH, 'utf8');
    const parsed = JSON.parse(raw);
    if (!parsed || !Array.isArray(parsed.orders)) return { orders: [] };
    return parsed;
  } catch (err) {
    if (err.code === 'ENOENT') return { orders: [] };
    return { orders: [], _error: err.message };
  }
}

export async function handleRecent(req, res, deps) {
  const { sendJson } = deps;
  const url = new URL(req.url, `http://${req.headers.host}`);
  const limit = Math.min(Math.max(parseInt(url.searchParams.get('limit') || '5', 10) || 5, 1), 50);
  const kind = url.searchParams.get('kind') || '';
  const store = readStore();
  let orders = store.orders.slice().reverse();
  if (kind) orders = orders.filter(o => o.kind === kind);
  orders = orders.slice(0, limit);
  return sendJson(res, 200, { ok: true, data: { orders } });
}
