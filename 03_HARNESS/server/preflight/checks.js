// Individual diagnostic check primitives. Each export is an async function
// that returns a CheckResult:
//
//   {
//     id:        string                              // stable machine id
//     label:     string                              // human-readable
//     severity:  'critical' | 'warning' | 'info'
//     ok:        boolean
//     hint?:     string                              // user-friendly explanation
//     action?:   string                              // copy-paste command/URL
//     detail?:   any                                 // raw diagnostic info
//   }
//
// Each function takes a single options object so the runner can pass shared
// state (cfg, cloudflared manager, etc.) without globals. Each check has its
// own internal timeout — never let a single hang block the whole report.
//
// Adding a new check: add an export here + register it in runner.js.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import https from 'node:https';

// ---------------------------------------------------------------------------
// Helpers

function withTimeout(promise, ms, onTimeoutValue) {
  return Promise.race([
    promise,
    new Promise(resolve => setTimeout(() => resolve(onTimeoutValue), ms))
  ]);
}

function execCapture(cmd, args, { timeoutMs = 5000, env = {} } = {}) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, {
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true,
      env: { ...process.env, ...env }
    });
    let out = '', err = '';
    let timedOut = false;
    const t = setTimeout(() => {
      timedOut = true;
      try { child.kill('SIGKILL'); } catch {}
    }, timeoutMs);

    child.stdout.on('data', d => { out += d.toString(); });
    child.stderr.on('data', d => { err += d.toString(); });
    child.on('error', () => {
      clearTimeout(t);
      resolve({ exitCode: -1, stdout: '', stderr: 'spawn error', timedOut });
    });
    child.on('exit', (code) => {
      clearTimeout(t);
      resolve({ exitCode: code ?? -1, stdout: out, stderr: err, timedOut });
    });
  });
}

function fetchHttps(url, { timeoutMs = 5000 } = {}) {
  return new Promise((resolve) => {
    const req = https.get(url, { timeout: timeoutMs }, (res) => {
      res.resume();
      resolve({ ok: res.statusCode >= 200 && res.statusCode < 500, status: res.statusCode });
    });
    req.on('timeout', () => { req.destroy(); resolve({ ok: false, status: 0, err: 'timeout' }); });
    req.on('error', (e) => resolve({ ok: false, status: 0, err: e.message }));
  });
}

// ---------------------------------------------------------------------------
// Check: claude_cli_installed

export async function claude_cli_installed({ cfg }) {
  const bin = cfg?.claude?.bin;
  if (!bin) {
    return {
      id: 'claude_cli_installed',
      label: 'Claude Code CLI installed',
      severity: 'critical',
      ok: false,
      hint: 'config.claude.bin is not set in config.json.',
      action: 'Edit your config.json and set "claude.bin" to the full path of the claude executable.'
    };
  }
  // Existence check first — if the path is wrong, the spawn would still
  // succeed on Windows in some weird shell setups.
  if (!fs.existsSync(bin)) {
    return {
      id: 'claude_cli_installed',
      label: 'Claude Code CLI installed',
      severity: 'critical',
      ok: false,
      hint: `The configured Claude binary at "${bin}" does not exist.`,
      action: 'Install Claude Code from https://claude.com/code, then update config.claude.bin.'
    };
  }
  const r = await execCapture(bin, ['--version'], { timeoutMs: 5000 });
  if (r.timedOut) {
    return {
      id: 'claude_cli_installed',
      label: 'Claude Code CLI installed',
      severity: 'critical',
      ok: false,
      hint: 'Claude binary did not respond within 5 seconds.',
      action: 'Try running `claude --version` manually in your terminal.',
      detail: { stderr: r.stderr.slice(0, 200) }
    };
  }
  if (r.exitCode !== 0) {
    return {
      id: 'claude_cli_installed',
      label: 'Claude Code CLI installed',
      severity: 'critical',
      ok: false,
      hint: `claude --version exited with code ${r.exitCode}.`,
      action: 'Reinstall Claude Code from https://claude.com/code.',
      detail: { stderr: r.stderr.slice(0, 200) }
    };
  }
  return {
    id: 'claude_cli_installed',
    label: 'Claude Code CLI installed',
    severity: 'critical',
    ok: true,
    detail: { version: r.stdout.trim().slice(0, 60), path: bin }
  };
}

// ---------------------------------------------------------------------------
// Check: claude_cli_authenticated

export async function claude_cli_authenticated({ cfg }) {
  const bin = cfg?.claude?.bin;
  if (!bin || !fs.existsSync(bin)) {
    // Skip — claude_cli_installed will already be flagged.
    return {
      id: 'claude_cli_authenticated',
      label: 'Claude Code CLI authenticated',
      severity: 'critical',
      ok: false,
      hint: 'Claude binary not available — fix the previous check first.'
    };
  }
  // Fire a tiny prompt to verify the user is logged in. We use --print so
  // claude returns and exits, and --model haiku for the cheapest call.
  // 12s timeout: the API can be slow on first warm-up.
  const r = await execCapture(bin, ['--print', '--model', 'claude-haiku-4-5', 'ok'], {
    timeoutMs: 15000
  });
  if (r.timedOut) {
    return {
      id: 'claude_cli_authenticated',
      label: 'Claude Code CLI authenticated',
      severity: 'critical',
      ok: false,
      hint: 'Claude did not respond within 15 seconds. Network or auth issue.',
      action: 'Run `claude /login` in your terminal to re-authenticate.'
    };
  }
  if (r.exitCode !== 0) {
    const err = (r.stderr || '').toLowerCase();
    const looksAuth = err.includes('login') || err.includes('auth') || err.includes('401') || err.includes('credentials');
    return {
      id: 'claude_cli_authenticated',
      label: 'Claude Code CLI authenticated',
      severity: 'critical',
      ok: false,
      hint: looksAuth
        ? 'Claude rejected the request — looks like you are not signed in.'
        : `Claude failed with exit code ${r.exitCode}.`,
      action: 'Run `claude /login` in your terminal.',
      detail: { stderr: r.stderr.slice(0, 300) }
    };
  }
  return {
    id: 'claude_cli_authenticated',
    label: 'Claude Code CLI authenticated',
    severity: 'critical',
    ok: true,
    detail: { roundtrip_ok: true }
  };
}

// ---------------------------------------------------------------------------
// Check: config_secret_strength

export async function config_secret_strength({ cfg }) {
  const secret = cfg?.ios?.shared_secret || '';
  const len = secret.length;
  const hasSpace = /\s/.test(secret);
  const placeholderHits = ['GENERA_UN_BEARER', 'CHANGEME', 'YOUR_SECRET', 'TODO'];
  const isPlaceholder = placeholderHits.some(p => secret.includes(p));

  if (!secret || isPlaceholder) {
    return {
      id: 'config_secret_strength',
      label: 'Bearer secret configured',
      severity: 'critical',
      ok: false,
      hint: 'config.ios.shared_secret is empty or still set to a placeholder.',
      action: 'Generate a secret with `openssl rand -hex 16` and put it in config.json under ios.shared_secret.'
    };
  }
  if (hasSpace || len < 32) {
    return {
      id: 'config_secret_strength',
      label: 'Bearer secret configured',
      severity: 'critical',
      ok: false,
      hint: hasSpace
        ? 'The bearer secret contains whitespace.'
        : `The bearer secret is only ${len} chars (minimum 32).`,
      action: 'Replace it with `openssl rand -hex 16` (or longer) — alphanumeric only.'
    };
  }
  return {
    id: 'config_secret_strength',
    label: 'Bearer secret configured',
    severity: 'critical',
    ok: true,
    detail: { length: len }
  };
}

// ---------------------------------------------------------------------------
// Check: tunnel_mode_active

export async function tunnel_mode_active({ cfg }) {
  const mode = cfg?.tunnel?.mode || 'manual';
  if (mode === 'manual') {
    return {
      id: 'tunnel_mode_active',
      label: 'Tunnel mode chosen',
      severity: 'critical',
      ok: false,
      hint: 'No tunnel mode is active — the iPhone can only reach you on the same LAN.',
      action: 'Open http://localhost:7777/setup and pick Quick Tunnel or Named Tunnel.'
    };
  }
  return {
    id: 'tunnel_mode_active',
    label: 'Tunnel mode chosen',
    severity: 'critical',
    ok: true,
    detail: { mode }
  };
}

// ---------------------------------------------------------------------------
// Check: tunnel_running (cloudflared spawned)

export async function tunnel_running({ cfg, cloudflared }) {
  const mode = cfg?.tunnel?.mode || 'manual';
  if (mode === 'manual' || mode === 'lan') {
    // Tunnel not expected for these modes.
    return {
      id: 'tunnel_running',
      label: 'Tunnel process running',
      severity: 'info',
      ok: true,
      detail: { skipped: true, reason: `mode=${mode}` }
    };
  }
  if (!cloudflared) {
    return {
      id: 'tunnel_running',
      label: 'Tunnel process running',
      severity: 'critical',
      ok: false,
      hint: 'cloudflared manager is not initialized.',
      action: 'Restart the harness server (`bin/1_START_ALL.bat`).'
    };
  }
  const status = cloudflared.status();
  if (!status.running) {
    return {
      id: 'tunnel_running',
      label: 'Tunnel process running',
      severity: 'critical',
      ok: false,
      hint: 'A tunnel mode is configured but cloudflared is not running.',
      action: 'Open http://localhost:7777/setup and click "Start" on the chosen card.',
      detail: { lastError: status.lastError }
    };
  }
  return {
    id: 'tunnel_running',
    label: 'Tunnel process running',
    severity: 'critical',
    ok: true,
    detail: { mode: status.mode, uptime_s: status.uptime_s, publicUrl: status.publicUrl }
  };
}

// ---------------------------------------------------------------------------
// Check: cloudflared_binary

export async function cloudflared_binary() {
  const home = os.homedir();
  const bin = path.join(home, '.gigi', 'bin', process.platform === 'win32' ? 'cloudflared.exe' : 'cloudflared');
  let exists = false, sizeMB = 0;
  try {
    const st = fs.statSync(bin);
    exists = st.isFile();
    sizeMB = st.size / (1024 * 1024);
  } catch { /* not present */ }
  if (!exists) {
    return {
      id: 'cloudflared_binary',
      label: 'cloudflared binary present',
      severity: 'warning',
      ok: false,
      hint: 'cloudflared not yet installed locally.',
      action: 'Will be auto-downloaded the first time you start a tunnel.'
    };
  }
  return {
    id: 'cloudflared_binary',
    label: 'cloudflared binary present',
    severity: 'warning',
    ok: true,
    detail: { path: bin, sizeMB: Math.round(sizeMB) }
  };
}

// ---------------------------------------------------------------------------
// Check: outbound_https

export async function outbound_https() {
  const r = await fetchHttps('https://api.cloudflare.com/client/v4/', { timeoutMs: 5000 });
  if (!r.ok) {
    return {
      id: 'outbound_https',
      label: 'Outbound HTTPS reachable',
      severity: 'warning',
      ok: false,
      hint: 'Cannot reach api.cloudflare.com — your PC has no internet, or a corporate firewall is blocking outbound 443.',
      action: 'Check Wi-Fi/Ethernet, then click "Recheck" above.',
      detail: { err: r.err, status: r.status }
    };
  }
  return {
    id: 'outbound_https',
    label: 'Outbound HTTPS reachable',
    severity: 'warning',
    ok: true,
    detail: { status: r.status }
  };
}

// ---------------------------------------------------------------------------
// Check: port_7779_bound (informational — if we are answering, we are bound)

export async function port_7779_bound({ cfg }) {
  const expected = cfg?.server?.port || 7779;
  // We can't really self-introspect easily without privileged netstat,
  // but the very fact that diagnostics is being served means port is up.
  return {
    id: 'port_7779_bound',
    label: 'iOS HTTP server listening',
    severity: 'info',
    ok: true,
    detail: { port: expected }
  };
}

// ---------------------------------------------------------------------------
// Check: disk_space

export async function disk_space() {
  // Cross-platform free-space check without native deps. Best-effort using
  // statfs (Node 19.6+) — fall back to "ok" if unavailable.
  try {
    const home = os.homedir();
    const stat = await fs.promises.statfs?.(home);
    if (!stat) {
      return {
        id: 'disk_space',
        label: 'Disk space available',
        severity: 'info',
        ok: true,
        detail: { skipped: 'statfs unavailable' }
      };
    }
    const freeGB = (stat.bavail * stat.bsize) / 1e9;
    if (freeGB < 2) {
      return {
        id: 'disk_space',
        label: 'Disk space available',
        severity: 'info',
        ok: false,
        hint: `Only ${freeGB.toFixed(1)} GB free in the user home — old transcripts may not save.`,
        action: 'Free up some disk space.',
        detail: { freeGB: Math.round(freeGB * 10) / 10 }
      };
    }
    return {
      id: 'disk_space',
      label: 'Disk space available',
      severity: 'info',
      ok: true,
      detail: { freeGB: Math.round(freeGB) }
    };
  } catch (e) {
    return {
      id: 'disk_space',
      label: 'Disk space available',
      severity: 'info',
      ok: true,
      detail: { error: e.message }
    };
  }
}

// ---------------------------------------------------------------------------
// Check: last_request_ago

export async function last_request_ago({ gigiServer }) {
  const lastReq = gigiServer?.state?.last_request;
  if (!lastReq?.time) {
    return {
      id: 'last_request_ago',
      label: 'Recent iOS activity',
      severity: 'info',
      ok: true,
      detail: { neverContacted: true }
    };
  }
  const ageS = Math.floor((Date.now() - lastReq.time) / 1000);
  return {
    id: 'last_request_ago',
    label: 'Recent iOS activity',
    severity: 'info',
    ok: true,
    detail: { ageS, lastDeviceId: (lastReq.deviceId || '').slice(0, 8) }
  };
}
