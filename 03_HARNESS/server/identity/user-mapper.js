// user-mapper.js
// Bidirectional mapping: channel identity ↔ gigiUserId ↔ deviceId
// Persists to logs/user-identities.json
// A channel user gets a stable synthetic deviceId so session-manager.js
// can key their session state the same way iOS devices do.

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';

let identities = {}; // { "<channel>:<externalId>": { gigiUserId, deviceId, channel, externalId } }
let filePath = null;

export function init(logsDir) {
  filePath = join(logsDir, 'user-identities.json');
  if (existsSync(filePath)) {
    try { identities = JSON.parse(readFileSync(filePath, 'utf8')); }
    catch { identities = {}; }
  }
}

/**
 * Get or create a GIGI user for an inbound channel message.
 * @param {string} channel  - 'telegram' | 'whatsapp'
 * @param {string} externalId - Telegram userId or WhatsApp phone number
 * @returns {{ gigiUserId: string, deviceId: string }}
 */
export function getOrCreateUser(channel, externalId) {
  const key = `${channel}:${externalId}`;
  if (!identities[key]) {
    const id = randomUUID();
    identities[key] = {
      gigiUserId: id,
      deviceId:   `${channel}-${id}`,  // stable synthetic deviceId
      channel,
      externalId,
      createdAt: new Date().toISOString(),
    };
    persist();
  }
  return { gigiUserId: identities[key].gigiUserId, deviceId: identities[key].deviceId };
}

export function lookupByGigiUserId(gigiUserId) {
  return Object.values(identities).filter(e => e.gigiUserId === gigiUserId);
}

function persist() {
  if (!filePath) return;
  try { writeFileSync(filePath, JSON.stringify(identities, null, 2)); }
  catch (e) { console.error('[user-mapper] persist failed:', e.message); }
}
