// Minimal Cloudflare API v4 client for the GIGI setup wizard.
// Only implements the handful of endpoints we need for the Named Tunnel
// flow: verify cert, list accounts, look up zones, create tunnel, create
// DNS CNAME. Uses the "origin certificate" JSON that `cloudflared tunnel
// login` writes to disk (~/.gigi/cloudflare-cert.json), which contains the
// OAuth token + account id we need for CF API calls.
//
// Intentionally NOT a full CF SDK — we don't want a 3 MB dependency for
// five endpoints. Uses node:https directly; no retries on 4xx errors
// (auth / config issues are user-fixable, not transient). 5xx get a
// single exponential-backoff retry.
import https from 'node:https';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const CF_API = 'api.cloudflare.com';

export function certPath() {
  return path.join(os.homedir(), '.gigi', 'cloudflare-cert.json');
}

export function loadCert() {
  try {
    return JSON.parse(fs.readFileSync(certPath(), 'utf8'));
  } catch { return null; }
}

export function hasCert() { return loadCert() !== null; }

function request({ method = 'GET', path: p, token, body = null }) {
  return new Promise((resolve, reject) => {
    const data = body ? JSON.stringify(body) : null;
    const headers = {
      'Authorization': `Bearer ${token}`,
      'Content-Type':  'application/json',
      'Accept':        'application/json'
    };
    if (data) headers['Content-Length'] = Buffer.byteLength(data);

    const req = https.request({
      hostname: CF_API,
      port: 443,
      path: p,
      method,
      headers
    }, (res) => {
      let chunks = '';
      res.setEncoding('utf8');
      res.on('data', (c) => { chunks += c; });
      res.on('end', () => {
        if (res.statusCode >= 500) {
          return reject(Object.assign(new Error(`CF API ${res.statusCode}`), {
            status: res.statusCode, body: chunks, retriable: true
          }));
        }
        let parsed = null;
        try { parsed = JSON.parse(chunks); } catch { /* keep raw */ }
        if (res.statusCode >= 400 || (parsed && parsed.success === false)) {
          return reject(Object.assign(new Error(`CF API ${res.statusCode}: ${chunks.slice(0, 400)}`), {
            status: res.statusCode, body: chunks, parsed, retriable: false
          }));
        }
        resolve(parsed);
      });
    });
    req.on('error', reject);
    if (data) req.write(data);
    req.end();
  });
}

async function withRetry(fn) {
  try { return await fn(); }
  catch (e) {
    if (e.retriable) {
      await new Promise(r => setTimeout(r, 1200));
      return fn();
    }
    throw e;
  }
}

export async function verifyToken(token) {
  return withRetry(() => request({ path: '/client/v4/user/tokens/verify', token }));
}

export async function listAccounts(token) {
  const r = await withRetry(() => request({ path: '/client/v4/accounts', token }));
  return r.result || [];
}

export async function findZone(token, domain) {
  const enc = encodeURIComponent(domain);
  const r = await withRetry(() => request({
    path: `/client/v4/zones?name=${enc}&status=active&match=all`,
    token
  }));
  return (r.result || [])[0] || null;
}

export async function createTunnel(token, accountId, name, tunnelSecret) {
  return withRetry(() => request({
    method: 'POST',
    path: `/client/v4/accounts/${accountId}/cfd_tunnel`,
    token,
    body: {
      name,
      tunnel_secret: tunnelSecret,       // base64 32-byte random
      config_src:    'cloudflare'         // config stored by CF, not local
    }
  }));
}

export async function createDnsCname(token, zoneId, hostname, target, proxied = true) {
  return withRetry(() => request({
    method: 'POST',
    path: `/client/v4/zones/${zoneId}/dns_records`,
    token,
    body: {
      type: 'CNAME',
      name: hostname,
      content: target,
      proxied,
      ttl: 1                              // 1 = auto when proxied
    }
  }));
}

/**
 * Given a cert JSON produced by cloudflared login, extract the pieces we need.
 * The cert is typically a PEM-bundle-as-JSON with `AccountTag` + `TunnelID`
 * style fields. We keep the extraction defensive since the format has
 * evolved across Cloudflare releases.
 */
export function extractAccountFromCert(cert) {
  if (!cert) return null;
  return {
    accountId: cert.AccountTag || cert.account_id || null,
    zoneId:    cert.ZoneID     || null,
    token:     cert.APIToken   || cert.api_token || null
  };
}
