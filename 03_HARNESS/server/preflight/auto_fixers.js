// Auto-fix functions for the diagnostics endpoint. Each fixer is an async
// function that attempts to resolve one specific check failure on the
// server side. They are invoked by POST /api/setup/autofix.
//
//   FixResult shape:
//     { fixed: bool, detail?: string, needsUser?: string, needsRepair?: bool, error?: string }
//
// Fixers are intentionally narrow — they only touch what they own. They
// do NOT cascade (e.g. fixing tunnel_mode_active does NOT also start the
// tunnel; the tunnel_running fixer does that, and is invoked separately
// in the autofix batch). This keeps each fixer testable in isolation
// and lets the user opt out of individual fixes if needed.
//
// Adding a new fixer: add a function here + register it in `FIXERS`.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import { install as installCloudflared } from '../tunnel/install-cloudflared.js';

function spawnClaudeAuthLogin(bin) {
  if (process.platform === 'win32') {
    // Claude Code is a console executable. Launching it directly from the
    // background harness can produce a terminal that flashes and disappears,
    // while stdout is ignored and the user never sees the OAuth URL/prompt.
    // Start a persistent cmd window. Avoid `start "" "path"` here: when
    // invoked through Node/cmd /s it can be parsed incorrectly and Windows
    // may try to open a bogus "\\" path.
    const scriptPath = path.join(os.tmpdir(), 'gigi-claude-auth-login.cmd');
    const script = [
      '@echo off',
      'title GIGI Claude Login',
      'echo Starting Claude sign-in for GIGI...',
      'echo.',
      `"${bin}" auth login`,
      'echo.',
      'echo Claude login command exited.',
      'echo If the browser opened, finish sign-in there, then close this window.',
      'echo If nothing opened, run this command manually:',
      'echo claude auth login',
      'echo.',
      'pause'
    ].join('\r\n');
    fs.writeFileSync(scriptPath, script, 'utf8');

    return spawn('cmd.exe', ['/d', '/s', '/k', scriptPath], {
      stdio: 'ignore',
      detached: true,
      windowsHide: false
    });
  }

  return spawn(bin, ['auth', 'login'], {
    stdio: 'ignore',
    detached: true
  });
}

// ---------------------------------------------------------------------------
// Fixers

/**
 * Generates a fresh 32-byte hex secret and writes it to config.json.
 * Side effect: invalidates any currently-paired iOS device — the caller
 * (autofix endpoint) sets needsRepair:true so the iOS app knows it has
 * to re-pair.
 */
async function fix_config_secret_strength({ cfg, cfgPath }) {
  const newSecret = crypto.randomBytes(32).toString('hex');   // 64 hex chars
  try {
    const onDisk = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
    onDisk.ios = onDisk.ios || {};
    onDisk.ios.shared_secret = newSecret;
    fs.writeFileSync(cfgPath, JSON.stringify(onDisk, null, 2), 'utf8');

    // Mirror into in-memory cfg so /api/pair etc. see the new secret
    // immediately without a full server restart.
    cfg.ios = cfg.ios || {};
    cfg.ios.shared_secret = newSecret;

    return {
      fixed: true,
      detail: 'Generated a new 64-char secret and wrote it to config.json.',
      needsRepair: true
    };
  } catch (e) {
    return { fixed: false, error: e.message };
  }
}

/**
 * Sets tunnel.mode = "quick" if it was "manual" (the default placeholder).
 * If mode is already chosen (quick / named), this is a no-op success
 * — we don't override an intentional choice.
 */
async function fix_tunnel_mode_active({ cfg, cfgPath }) {
  const current = cfg?.tunnel?.mode || 'manual';
  if (current !== 'manual') {
    return {
      fixed: true,
      detail: `Mode already set to "${current}", no change needed.`
    };
  }
  try {
    const onDisk = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
    onDisk.tunnel = onDisk.tunnel || { named: {}, quick: {} };
    onDisk.tunnel.mode = 'quick';
    fs.writeFileSync(cfgPath, JSON.stringify(onDisk, null, 2), 'utf8');

    cfg.tunnel = cfg.tunnel || { named: {}, quick: {} };
    cfg.tunnel.mode = 'quick';

    return {
      fixed: true,
      detail: 'Set mode to "quick" — Cloudflare Quick Tunnel is the easiest default.'
    };
  } catch (e) {
    return { fixed: false, error: e.message };
  }
}

/**
 * Starts cloudflared in the configured mode. If mode is "manual" this is
 * a no-op success (modalità 'lan' rimossa nel rework armando-rework).
 */
async function fix_tunnel_running({ cfg, cloudflared }) {
  const mode = cfg?.tunnel?.mode || 'manual';
  if (mode === 'manual') {
    return {
      fixed: true,
      detail: `Mode is "manual", tunnel process not required.`
    };
  }
  if (!cloudflared) {
    return { fixed: false, error: 'cloudflared manager not available' };
  }
  try {
    if (mode === 'quick') {
      const localPort = cfg?.server?.port || 7779;
      await cloudflared.startQuick({ localPort });
      // Poll up to 12s for the URL to appear in stdout
      for (let i = 0; i < 24; i++) {
        if (cloudflared.status().publicUrl) break;
        await new Promise(r => setTimeout(r, 500));
      }
      const url = cloudflared.status().publicUrl;
      return {
        fixed: !!url,
        detail: url ? `Started Quick Tunnel at ${url}` : 'Started, waiting for URL…'
      };
    }
    if (mode === 'named') {
      const named = cfg?.tunnel?.named || {};
      if (!named.tunnel_uuid || !named.config_path) {
        return {
          fixed: false,
          needsUser: 'Named tunnel not yet configured. Open localhost:7777/setup and complete the Named Tunnel wizard.'
        };
      }
      await cloudflared.startNamed({
        tunnelName: named.tunnel_uuid,
        configPath: named.config_path,
        localPort: cfg?.server?.port || 7779
      });
      return {
        fixed: true,
        detail: `Started Named Tunnel for ${named.hostname}.`
      };
    }
    return { fixed: false, error: `Unsupported mode "${mode}".` };
  } catch (e) {
    return { fixed: false, error: e.message };
  }
}

/**
 * Forces re-download of the cloudflared binary into ~/.gigi/bin/.
 * Slow path (single ~64MB download) — caller passes a longer timeout.
 */
async function fix_cloudflared_binary() {
  try {
    const r = await installCloudflared({ log: () => {} });
    return {
      fixed: true,
      detail: `Downloaded cloudflared ${r.version} (sha256: ${r.sha256.slice(0, 12)}…).`
    };
  } catch (e) {
    return { fixed: false, error: e.message };
  }
}

/**
 * Spawns `claude auth login` on the server. The claude CLI opens the
 * default browser, the OAuth flow has to be completed by a human in
 * front of the PC. So we return needsUser, not fixed:true.
 */
async function fix_claude_cli_authenticated({ cfg }) {
  const bin = cfg?.claude?.bin;
  if (!bin || !fs.existsSync(bin)) {
    return {
      fixed: false,
      needsUser: 'Claude CLI not installed. Install it from claude.com/code first.'
    };
  }
  try {
    const child = spawnClaudeAuthLogin(bin);
    child.unref();
    return {
      fixed: false,
      needsUser: 'Opened a Claude sign-in terminal on your PC. If no window stays open, run %TEMP%\\gigi-claude-auth-login.cmd manually. Complete the browser login, then come back.'
    };
  } catch (e) {
    return {
      fixed: false,
      error: e.message,
      needsUser: 'Could not auto-launch Claude auth. Open a terminal on your PC and run: claude auth login'
    };
  }
}

// ---------------------------------------------------------------------------
// Registry

const FIXERS = {
  config_secret_strength: fix_config_secret_strength,
  tunnel_mode_active:     fix_tunnel_mode_active,
  tunnel_running:         fix_tunnel_running,
  cloudflared_binary:     fix_cloudflared_binary,
  claude_cli_authenticated: fix_claude_cli_authenticated
};

/**
 * Per-fixer timeout (ms). The cloudflared binary download legitimately
 * takes ~30-60s on slow networks; everything else should be fast.
 */
const FIXER_TIMEOUT_MS = {
  cloudflared_binary: 90_000,
  default:            15_000
};

/** True if we know how to auto-fix this check. Frontend uses the same
 * set via the `autoFixable` flag exposed in CheckResult. */
export const AUTO_FIXABLE_IDS = new Set(Object.keys(FIXERS));

/**
 * Runs a single fixer with timeout. Always resolves with a FixResult.
 *
 * @param {string} checkId
 * @param {object} ctx — {cfg, cfgPath, cloudflared}
 * @returns {Promise<FixResult>}
 */
export async function runFixer(checkId, ctx) {
  const fn = FIXERS[checkId];
  if (!fn) {
    return { fixed: false, error: `No fixer registered for "${checkId}"` };
  }
  const timeout = FIXER_TIMEOUT_MS[checkId] || FIXER_TIMEOUT_MS.default;
  return await Promise.race([
    Promise.resolve().then(() => fn(ctx)).catch(e => ({
      fixed: false, error: String(e?.message || e).slice(0, 300)
    })),
    new Promise(resolve => setTimeout(() => resolve({
      fixed: false, error: `fixer timed out after ${timeout / 1000}s`
    }), timeout))
  ]);
}

/**
 * Runs a batch of fixers in series, collecting per-id results.
 *
 * @param {string[]} checkIds — list of check ids to fix; "all" expands to
 *                              every registered fixer
 * @param {object} ctx
 * @returns {Promise<{results, summary}>}
 */
export async function runBatch(checkIds, ctx) {
  const ids = checkIds.length === 1 && checkIds[0] === 'all'
    ? [...AUTO_FIXABLE_IDS]
    : checkIds;
  const startedAt = Date.now();
  const results = [];
  for (const id of ids) {
    const r = await runFixer(id, ctx);
    results.push({ id, ...r });
  }
  const fixedCount     = results.filter(r => r.fixed).length;
  const needsUserCount = results.filter(r => !r.fixed && r.needsUser).length;
  const errorCount     = results.filter(r => !r.fixed && r.error && !r.needsUser).length;
  return {
    results,
    summary: {
      fixedCount, needsUserCount, errorCount,
      total: results.length,
      elapsed_ms: Date.now() - startedAt
    }
  };
}
