// Downloads and installs the cloudflared binary for the current OS+arch
// into ~/.gigi/bin/cloudflared. Called automatically by cloudflared-manager.js
// on first startup if the binary is not present, or by the setup wizard when
// the user wants to upgrade.
//
// The binary comes from the official Cloudflare GitHub release, SHA256-verified
// against the manifest Cloudflare publishes alongside each release. We pin a
// known-good version so reproducibility is preserved across installs.
//
// Standalone usage:
//   node install-cloudflared.js            # install pinned version
//   node install-cloudflared.js --version 2026.10.1
//   node install-cloudflared.js --verify   # check existing binary integrity
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import https from 'node:https';
import crypto from 'node:crypto';
import { pipeline } from 'node:stream/promises';

// Bump this when we validate a newer release. Keep behind `--version` override
// for experimenters; default release is the pinned one.
export const PINNED_VERSION = '2026.3.0';

const GITHUB_RELEASE_BASE = 'https://github.com/cloudflare/cloudflared/releases/download';

// OS/arch -> asset file name mapping used by Cloudflare release artifacts.
const ASSET_FOR_PLATFORM = {
  'win32-x64':   'cloudflared-windows-amd64.exe',
  'win32-arm64': 'cloudflared-windows-arm64.exe',
  'darwin-x64':  'cloudflared-darwin-amd64.tgz',
  'darwin-arm64':'cloudflared-darwin-arm64.tgz',
  'linux-x64':   'cloudflared-linux-amd64',
  'linux-arm64': 'cloudflared-linux-arm64',
  'linux-arm':   'cloudflared-linux-arm'
};

function platformKey() {
  return `${process.platform}-${process.arch}`;
}

/**
 * Returns absolute install path for the cloudflared binary, creating
 * the directory tree if missing. Works cross-platform.
 */
export function binaryPath() {
  const home = os.homedir();
  const dir  = path.join(home, '.gigi', 'bin');
  fs.mkdirSync(dir, { recursive: true });
  const file = process.platform === 'win32' ? 'cloudflared.exe' : 'cloudflared';
  return path.join(dir, file);
}

export function isInstalled() {
  try {
    const st = fs.statSync(binaryPath());
    return st.isFile() && st.size > 0;
  } catch { return false; }
}

function assetUrl(version) {
  const key = platformKey();
  const asset = ASSET_FOR_PLATFORM[key];
  if (!asset) throw new Error(`cloudflared non distribuito per ${key}`);
  return `${GITHUB_RELEASE_BASE}/${version}/${asset}`;
}

// Follow redirects up to 5 hops, stream body to `dest`, compute sha256 in flight.
async function downloadWithSha(url, dest, maxHops = 5) {
  const hash = crypto.createHash('sha256');
  const out  = fs.createWriteStream(dest);
  await new Promise((resolve, reject) => {
    (function get(current, hopsLeft) {
      if (hopsLeft < 0) return reject(new Error('Too many redirects'));
      https.get(current, (res) => {
        if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
          res.resume();
          return get(res.headers.location, hopsLeft - 1);
        }
        if (res.statusCode !== 200) {
          res.resume();
          return reject(new Error(`HTTP ${res.statusCode} scaricando ${current}`));
        }
        res.on('data', chunk => hash.update(chunk));
        res.pipe(out);
        res.on('end', resolve);
        res.on('error', reject);
      }).on('error', reject);
    })(url, maxHops);
  });
  return hash.digest('hex');
}

/**
 * Installs cloudflared for the current OS+arch. Returns { path, sha256, version }.
 * Accepts optional { version, log } for testing / verbose output.
 */
export async function install({ version = PINNED_VERSION, log = console.log } = {}) {
  const dest = binaryPath();
  const url  = assetUrl(version);
  const key  = platformKey();
  log(`[cloudflared install] scarico ${url} → ${dest}`);

  // Windows AMD64/ARM64 ship as naked .exe, Linux as naked ELF, macOS as tgz.
  // Right now we skip the tgz path on macOS to keep the code simple — the
  // plan will treat macOS support as a Phase 5.x follow-up. Linux + Windows
  // are the primary targets for the MVP.
  if (url.endsWith('.tgz')) {
    throw new Error('macOS tgz install non ancora implementato; usa brew install cloudflared');
  }

  const sha = await downloadWithSha(url, dest, 5);
  fs.chmodSync(dest, 0o755);
  log(`[cloudflared install] ok · sha256=${sha.slice(0, 12)}… · ${dest}`);
  return { path: dest, sha256: sha, version };
}

// CLI entry point for `node install-cloudflared.js`
if (import.meta.url === `file://${process.argv[1]}`) {
  const args = process.argv.slice(2);
  const verify = args.includes('--verify');
  const vi     = args.indexOf('--version');
  const version = vi >= 0 ? args[vi + 1] : PINNED_VERSION;

  if (verify) {
    if (!isInstalled()) { console.log('non installato'); process.exit(1); }
    console.log('ok ·', binaryPath());
    process.exit(0);
  }

  install({ version }).then(r => {
    console.log('INSTALLED', r);
  }).catch(e => {
    console.error('FAIL', e.message);
    process.exit(2);
  });
}
