// Owns the lifecycle of the `cloudflared` child process.
//   - startQuick()   → anonymous ephemeral trycloudflare.com URL (dev mode)
//   - startNamed()   → stable named tunnel on user's domain (production)
//   - stop()         → terminate gracefully
//   - status()       → { running, mode, publicUrl, pid, uptime }
//
// We parse cloudflared stdout to detect the Quick Tunnel URL (cloudflared
// prints a line like "Your quick Tunnel has been created! Visit it at:
// https://<name>.trycloudflare.com"). The URL, once detected, is cached
// in `state.publicUrl` and persisted to ~/.gigi/tunnel-current-url.txt so
// the setup wizard can read it without tailing the log.
//
// Auto-restart on crash: up to 3 attempts within 60s window, then we stop
// trying and the wizard shows an error. Manual restart via the API reset
// the counter.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { binaryPath, isInstalled, install } from './install-cloudflared.js';
import { log } from '../logger.js';

const URL_FILE = path.join(os.homedir(), '.gigi', 'tunnel-current-url.txt');

class CloudflaredManager {
  constructor() {
    this.proc = null;
    this.mode = null;                 // 'quick' | 'named' | null
    this.publicUrl = null;
    this.startedAt = null;
    this.restartAttempts = 0;
    this.restartWindow  = [];          // rolling 60s window of restart timestamps
    this.totalRestarts  = 0;            // monotonic counter (Phase 6B), reset on stop()
    this.lastError = null;
    this.onStatusChange = null;        // setter for the setup wizard UI
  }

  status() {
    return {
      running:      !!this.proc,
      mode:         this.mode,
      publicUrl:    this.publicUrl,
      pid:          this.proc?.pid || null,
      uptime_s:     this.startedAt ? Math.floor((Date.now() - this.startedAt) / 1000) : 0,
      restartCount: this.totalRestarts,
      lastError:    this.lastError
    };
  }

  isRunning() { return !!this.proc; }

  async ensureBinary() {
    if (!isInstalled()) {
      log('[cloudflared] binary assente, installing...');
      await install();
    }
    return binaryPath();
  }

  async startQuick({ localPort = 7779 } = {}) {
    await this.stop();
    const bin = await this.ensureBinary();
    this.mode = 'quick';
    this.publicUrl = null;
    this.lastError = null;
    this.restartAttempts = 0;

    const args = ['tunnel', '--no-autoupdate', '--url', `http://localhost:${localPort}`];
    this._spawn(bin, args);
    return this.status();
  }

  async startNamed({ tunnelName, configPath, localPort = 7779 } = {}) {
    if (!tunnelName) throw new Error('tunnelName required');
    await this.stop();
    const bin = await this.ensureBinary();
    this.mode = 'named';
    this.publicUrl = null;      // set by wizard after DNS creation, not by cloudflared output
    this.lastError = null;
    this.restartAttempts = 0;

    const args = configPath
      ? ['tunnel', '--no-autoupdate', '--config', configPath, 'run', tunnelName]
      : ['tunnel', '--no-autoupdate', 'run', tunnelName];
    this._spawn(bin, args);
    return this.status();
  }

  /**
   * Spawns `cloudflared tunnel login`. The binary opens the user's default
   * browser to the Cloudflare dashboard, the user authenticates and picks a
   * zone, the browser redirects back to a Cloudflare callback which causes
   * `cloudflared` to download an origin certificate and write it to
   * `~/.cloudflared/cert.pem`. We poll for that file and resolve once it
   * appears. Timeout 5 minutes — the user might take a moment to click
   * through the dashboard on the first login.
   */
  async login({ timeoutMs = 300_000 } = {}) {
    const bin = await this.ensureBinary();
    const certPath = path.join(os.homedir(), '.cloudflared', 'cert.pem');
    // Clear any stale cert so we reliably detect the new one
    try { fs.unlinkSync(certPath); } catch {}
    log('[cloudflared] spawn login');
    const child = spawn(bin, ['tunnel', 'login'], {
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true
    });
    child.stdout.on('data', d => log('[cloudflared login]', d.toString().trim()));
    child.stderr.on('data', d => log('[cloudflared login]', d.toString().trim()));

    const start = Date.now();
    return await new Promise((resolve, reject) => {
      const poll = setInterval(() => {
        if (fs.existsSync(certPath)) {
          clearInterval(poll);
          try { child.kill('SIGTERM'); } catch {}
          resolve({ certPath });
          return;
        }
        if (Date.now() - start > timeoutMs) {
          clearInterval(poll);
          try { child.kill('SIGTERM'); } catch {}
          reject(new Error('timeout attesa login Cloudflare — riprova'));
        }
      }, 1500);
      child.on('exit', (code) => {
        if (!fs.existsSync(certPath)) {
          clearInterval(poll);
          reject(new Error(`cloudflared login uscito (code=${code}) senza scrivere cert.pem`));
        }
      });
    });
  }

  /**
   * Creates (or looks up if already exists) a named tunnel via `cloudflared`
   * and returns the tunnel UUID + credential JSON path. Uses the cert written
   * by `login()` — must be called after.
   */
  async createNamedTunnel({ name }) {
    const bin = await this.ensureBinary();
    return await new Promise((resolve, reject) => {
      const p = spawn(bin, ['tunnel', 'create', name], {
        stdio: ['ignore', 'pipe', 'pipe'],
        windowsHide: true
      });
      let out = '', err = '';
      p.stdout.on('data', d => { out += d.toString(); });
      p.stderr.on('data', d => { err += d.toString(); });
      p.on('exit', (code) => {
        const combined = out + err;
        // Parse "Created tunnel <name> with id <uuid>" or "A tunnel with the
        // name <name> already exists" — handle both as success.
        const m1 = combined.match(/tunnel .*? with id ([0-9a-f-]{36})/i);
        const m2 = combined.match(/already exists .*? id:? ([0-9a-f-]{36})/i);
        const uuid = (m1 && m1[1]) || (m2 && m2[1]);
        if (code === 0 && uuid) return resolve({ uuid, name });
        // As a fallback try `cloudflared tunnel list --output json` to find uuid
        reject(new Error(`tunnel create failed (${code}): ${combined.slice(0, 400)}`));
      });
    });
  }

  /**
   * Routes DNS for a named tunnel: creates a CNAME `<hostname>` → `<uuid>.cfargotunnel.com`.
   * Requires the zone for hostname to be active in the user's Cloudflare account.
   */
  async routeDns({ uuid, hostname }) {
    const bin = await this.ensureBinary();
    return await new Promise((resolve, reject) => {
      const p = spawn(bin, ['tunnel', 'route', 'dns', uuid, hostname], {
        stdio: ['ignore', 'pipe', 'pipe'],
        windowsHide: true
      });
      let out = '', err = '';
      p.stdout.on('data', d => { out += d.toString(); });
      p.stderr.on('data', d => { err += d.toString(); });
      p.on('exit', (code) => {
        if (code === 0) return resolve({ hostname, uuid });
        reject(new Error(`tunnel route dns failed (${code}): ${(out+err).slice(0, 400)}`));
      });
    });
  }

  async stop() {
    if (!this.proc) return;
    const p = this.proc;
    this.proc = null;
    this.mode = null;
    this.publicUrl = null;
    this.startedAt = null;
    try { p.kill('SIGTERM'); } catch {}
    // Give it ~2s to exit gracefully, then SIGKILL
    await new Promise(res => {
      const killer = setTimeout(() => { try { p.kill('SIGKILL'); } catch {}; res(); }, 2000);
      p.once('exit', () => { clearTimeout(killer); res(); });
    });
    this._emit();
  }

  setNamedPublicUrl(url) {
    this.publicUrl = url;
    try { fs.writeFileSync(URL_FILE, url + '\n', 'utf8'); } catch {}
    this._emit();
  }

  // ---- private ----

  _spawn(bin, args) {
    log(`[cloudflared] spawn ${bin} ${args.join(' ')}`);
    const p = spawn(bin, args, {
      stdio:    ['ignore', 'pipe', 'pipe'],
      windowsHide: true
    });
    this.proc = p;
    this.startedAt = Date.now();

    const onLine = (line) => this._parseLine(line);
    p.stdout.on('data', (buf) => buf.toString().split(/\r?\n/).forEach(onLine));
    p.stderr.on('data', (buf) => buf.toString().split(/\r?\n/).forEach(onLine));

    p.once('exit', (code, signal) => {
      const wasTheCurrentProc = (this.proc === p);
      log(`[cloudflared] exit code=${code} signal=${signal}`);
      if (!wasTheCurrentProc) return;      // stopped intentionally
      this.proc = null;
      this.startedAt = null;
      this.lastError = `exited code=${code} signal=${signal}`;
      this._emit();
      this._maybeRestart(bin, args);
    });
    this._emit();
  }

  _parseLine(line) {
    if (!line) return;
    // Quick Tunnel URL detection. Cloudflared outputs the URL in a line
    // shaped like "https://<name>.trycloudflare.com". We match that anywhere
    // in the line and take the first match only (cloudflared sometimes logs
    // the URL twice across consecutive lines).
    if (this.mode === 'quick' && !this.publicUrl) {
      const m = line.match(/https?:\/\/[\w-]+\.trycloudflare\.com/);
      if (m) {
        this.publicUrl = m[0];
        try { fs.writeFileSync(URL_FILE, this.publicUrl + '\n', 'utf8'); } catch {}
        log(`[cloudflared] quick URL: ${this.publicUrl}`);
        this._emit();
      }
    }
  }

  _maybeRestart(bin, args) {
    const now = Date.now();
    this.restartWindow = this.restartWindow.filter(t => now - t < 60_000);
    this.restartWindow.push(now);
    if (this.restartWindow.length > 3) {
      log(`[cloudflared] restart loop detected (>3 in 60s), giving up`);
      this.lastError = 'troppi restart in 60s — controlla i log cloudflared';
      this._emit();
      return;
    }
    log(`[cloudflared] auto-restart in 2s (attempt ${this.restartWindow.length})`);
    this.totalRestarts++;
    setTimeout(() => this._spawn(bin, args), 2000);
  }

  _emit() {
    if (typeof this.onStatusChange === 'function') {
      try { this.onStatusChange(this.status()); } catch {}
    }
  }
}

// Singleton — the harness process has exactly one cloudflared child at a time.
export const cloudflared = new CloudflaredManager();
