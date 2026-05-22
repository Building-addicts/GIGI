#!/usr/bin/env node
// MCP server: gigi-memory
//
// Persists user-confirmed order/buy/book history so the on-device FM can
// propose "the usual" / "same as last time" on a future turn. Source of
// truth: ~/.gigi-memory/orders.json (single-user). The harness REST layer
// reads this file too; the MCP server is the WRITE path (Claude cloud
// calls record_order after every successful cart staging).
//
// Design constraints (per session 2026-05-20 redesign):
//  - Starts EMPTY. No seed orders, no fake preferences.
//  - Only Claude cloud writes (after real browser action). Local FM only
//    reads. The on-device FM cannot fabricate by writing here.
//  - Plain JSON file, ispezionabile a mano.

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { randomUUID } from 'node:crypto';

const STORE_DIR = path.join(os.homedir(), '.gigi-memory');
const STORE_PATH = path.join(STORE_DIR, 'orders.json');
const MAX_ORDERS = 200; // ring buffer cap — prevents unbounded growth

function readStore() {
  try {
    const raw = fs.readFileSync(STORE_PATH, 'utf8');
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== 'object' || !Array.isArray(parsed.orders)) {
      return { orders: [] };
    }
    return parsed;
  } catch (err) {
    if (err.code === 'ENOENT') return { orders: [] };
    // Corrupted file: log to stderr (visible in claude-agent log via MCP)
    // and start fresh rather than crashing the MCP server.
    process.stderr.write(`gigi-memory: store unreadable (${err.message}) — starting empty\n`);
    return { orders: [] };
  }
}

function writeStore(store) {
  fs.mkdirSync(STORE_DIR, { recursive: true });
  const tmp = STORE_PATH + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(store, null, 2), 'utf8');
  fs.renameSync(tmp, STORE_PATH); // atomic on POSIX
}

const TOOLS = [
  {
    name: 'record_order',
    description:
      'Record a user-confirmed order/buy/book in GIGI memory. Call this exactly once, after you have successfully staged the cart in the live browser session and read the real price off the page. Do NOT call this for items you only proposed or recommended — only for orders the user said go on and that you actually staged. Future turns will surface this memory back to GIGI so it can offer "same as last time" without you having to re-discover everything.',
    inputSchema: {
      type: 'object',
      required: ['kind', 'merchant', 'item', 'summary'],
      properties: {
        kind: {
          type: 'string',
          enum: ['order', 'buy', 'book'],
          description: 'Action kind. order = food delivery / pickup. buy = product purchase. book = reservation / booking.'
        },
        merchant: {
          type: 'string',
          description: 'The merchant the user ordered from, e.g. "Just Eat — Roppongi", "Amazon", "Trenitalia". Verbatim as you saw on the page when you can.'
        },
        item: {
          type: 'string',
          description: 'Short name of what was ordered, e.g. "Regular poke salmon avocado edamame mango spicy mayo". This is the bit GIGI will quote back as "the usual" on a future turn — make it specific enough to re-order verbatim.'
        },
        variant: {
          type: 'string',
          description: 'Optional variant / size / customization detail not already in item name, e.g. "size M", "no onions", "first class".'
        },
        total: {
          type: 'string',
          description: 'Total price as displayed on the page, including currency. Example: "€12.90". Empty string if not visible.'
        },
        merchantUrl: {
          type: 'string',
          description: 'URL of the merchant page where the cart was staged. Empty if N/A.'
        },
        summary: {
          type: 'string',
          description: 'One-sentence TTS-friendly summary of what was staged, e.g. "Regular poke staged at Roppongi for pickup in 15 min, €12.90". This is what GIGI may read back to the user.'
        }
      },
      additionalProperties: false
    }
  },
  {
    name: 'list_recent_orders',
    description:
      'Read the user\'s recent confirmed orders. Use this when you need to check whether the user has a past order matching their current request (e.g. they asked for "the usual poke" or "order another one"). Returns newest-first.',
    inputSchema: {
      type: 'object',
      properties: {
        limit: { type: 'integer', minimum: 1, maximum: 50, default: 10 },
        kind: {
          type: 'string',
          enum: ['order', 'buy', 'book'],
          description: 'Optional filter by kind.'
        }
      },
      additionalProperties: false
    }
  }
];

const server = new Server(
  { name: 'gigi-memory', version: '1.0.0' },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const name = req.params?.name;
  const args = req.params?.arguments || {};

  if (name === 'record_order') {
    const required = ['kind', 'merchant', 'item', 'summary'];
    for (const f of required) {
      if (!args[f] || typeof args[f] !== 'string' || !args[f].trim()) {
        return {
          content: [{ type: 'text', text: `error: missing required field "${f}"` }],
          isError: true
        };
      }
    }
    const store = readStore();
    const entry = {
      id: randomUUID(),
      ts: new Date().toISOString(),
      kind: args.kind,
      merchant: args.merchant.trim(),
      item: args.item.trim(),
      variant: (args.variant || '').trim(),
      total: (args.total || '').trim(),
      merchantUrl: (args.merchantUrl || '').trim(),
      summary: args.summary.trim(),
      source: 'claude_cloud'
    };
    store.orders.push(entry);
    if (store.orders.length > MAX_ORDERS) {
      store.orders = store.orders.slice(-MAX_ORDERS);
    }
    writeStore(store);
    return {
      content: [{
        type: 'text',
        text: `recorded order ${entry.id} — ${entry.kind} at ${entry.merchant}`
      }]
    };
  }

  if (name === 'list_recent_orders') {
    const limit = Math.min(Math.max(args.limit || 10, 1), 50);
    const kind = args.kind;
    const store = readStore();
    let orders = store.orders.slice().reverse();
    if (kind) orders = orders.filter(o => o.kind === kind);
    orders = orders.slice(0, limit);
    return {
      content: [{
        type: 'text',
        text: orders.length
          ? JSON.stringify({ orders }, null, 2)
          : '{"orders": []}  // no past orders yet'
      }]
    };
  }

  return {
    content: [{ type: 'text', text: `error: unknown tool "${name}"` }],
    isError: true
  };
});

const transport = new StdioServerTransport();
await server.connect(transport);
process.stderr.write(`gigi-memory MCP server up. store=${STORE_PATH}\n`);
