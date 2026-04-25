// MARK: - install-service.js (Phase 5.10)
//
// Cross-platform autostart for the harness panel — so cloudflared comes back
// up at boot without the user opening the panel manually. The harness panel
// already manages cloudflared's lifecycle, so we only need to autostart the
// panel itself.
//
// Strategy per platform:
//   Windows: write a .vbs in the Startup folder (already implemented in
//            panel.js as `enableAutostart()`; this script wraps it for CLI)
//   macOS:   write a launchd plist to ~/Library/LaunchAgents/com.gigi.harness.plist
//            and `launchctl load` it
//   Linux:   write a systemd user unit to ~/.config/systemd/user/gigi-harness.service
//            and `systemctl --user enable --now gigi-harness`
//
// Usage:
//   node tunnel/install-service.js install
//   node tunnel/install-service.js uninstall
//   node tunnel/install-service.js status
//
// Idempotent: install twice does nothing extra; uninstall on a system that
// never installed is a no-op.

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SERVER_DIR = path.resolve(__dirname, '..');
const PANEL_JS = path.join(SERVER_DIR, 'panel.js');
const NODE_BIN = process.execPath;
const LOG_PATH = path.join(SERVER_DIR, 'logs', 'panel.log');

const PLATFORM = process.platform; // 'win32' | 'darwin' | 'linux'

// MARK: - macOS (launchd)

const MAC_PLIST_DIR = path.join(os.homedir(), 'Library', 'LaunchAgents');
const MAC_PLIST_PATH = path.join(MAC_PLIST_DIR, 'com.gigi.harness.plist');
const MAC_LABEL = 'com.gigi.harness';

function macInstall() {
  fs.mkdirSync(MAC_PLIST_DIR, { recursive: true });
  fs.mkdirSync(path.dirname(LOG_PATH), { recursive: true });
  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${MAC_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${NODE_BIN}</string>
    <string>${PANEL_JS}</string>
  </array>
  <key>WorkingDirectory</key><string>${SERVER_DIR}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${LOG_PATH}</string>
  <key>StandardErrorPath</key><string>${LOG_PATH}</string>
</dict>
</plist>
`;
  fs.writeFileSync(MAC_PLIST_PATH, plist);
  try { execSync(`launchctl unload "${MAC_PLIST_PATH}" 2>/dev/null`); } catch {}
  execSync(`launchctl load -w "${MAC_PLIST_PATH}"`);
  console.log(`[install-service] macOS: launchd plist installed at ${MAC_PLIST_PATH}`);
  console.log('[install-service] panel will start at login and respawn if it crashes.');
}

function macUninstall() {
  if (!fs.existsSync(MAC_PLIST_PATH)) {
    console.log('[install-service] macOS: not installed, nothing to do');
    return;
  }
  try { execSync(`launchctl unload "${MAC_PLIST_PATH}"`); } catch {}
  fs.unlinkSync(MAC_PLIST_PATH);
  console.log('[install-service] macOS: launchd plist removed');
}

function macStatus() {
  const installed = fs.existsSync(MAC_PLIST_PATH);
  let loaded = false;
  try {
    const out = execSync(`launchctl list | grep ${MAC_LABEL}`, { encoding: 'utf8' });
    loaded = !!out.trim();
  } catch {}
  return { installed, loaded };
}

// MARK: - Linux (systemd --user)

const LIN_UNIT_DIR = path.join(os.homedir(), '.config', 'systemd', 'user');
const LIN_UNIT_PATH = path.join(LIN_UNIT_DIR, 'gigi-harness.service');

function linInstall() {
  fs.mkdirSync(LIN_UNIT_DIR, { recursive: true });
  fs.mkdirSync(path.dirname(LOG_PATH), { recursive: true });
  const unit = `[Unit]
Description=GIGI Harness panel + cloudflared supervisor
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${SERVER_DIR}
ExecStart=${NODE_BIN} ${PANEL_JS}
Restart=on-failure
RestartSec=5
StandardOutput=append:${LOG_PATH}
StandardError=append:${LOG_PATH}

[Install]
WantedBy=default.target
`;
  fs.writeFileSync(LIN_UNIT_PATH, unit);
  execSync('systemctl --user daemon-reload');
  execSync('systemctl --user enable --now gigi-harness.service');
  console.log(`[install-service] Linux: systemd user unit installed at ${LIN_UNIT_PATH}`);
  console.log('[install-service] panel will start on user login and on boot if linger is enabled.');
  console.log('[install-service] hint: run `loginctl enable-linger $USER` to start without GUI login.');
}

function linUninstall() {
  if (!fs.existsSync(LIN_UNIT_PATH)) {
    console.log('[install-service] Linux: not installed, nothing to do');
    return;
  }
  try { execSync('systemctl --user disable --now gigi-harness.service'); } catch {}
  fs.unlinkSync(LIN_UNIT_PATH);
  try { execSync('systemctl --user daemon-reload'); } catch {}
  console.log('[install-service] Linux: systemd unit removed');
}

function linStatus() {
  const installed = fs.existsSync(LIN_UNIT_PATH);
  let active = false;
  try {
    execSync('systemctl --user is-active --quiet gigi-harness.service');
    active = true;
  } catch {}
  return { installed, active };
}

// MARK: - Windows (Startup folder VBS)

const WIN_STARTUP_DIR = path.join(process.env.APPDATA || '', 'Microsoft', 'Windows', 'Start Menu', 'Programs', 'Startup');
const WIN_STARTUP_FILE = path.join(WIN_STARTUP_DIR, 'GigiHarness.vbs');

function winInstall() {
  fs.mkdirSync(path.dirname(LOG_PATH), { recursive: true });
  const panelEsc = PANEL_JS.replace(/\\/g, '\\\\');
  const logEsc = LOG_PATH.replace(/\\/g, '\\\\');
  const dirEsc = SERVER_DIR.replace(/\\/g, '\\\\');
  const nodeEsc = NODE_BIN.replace(/\\/g, '\\\\');
  const vbs = `Set WshShell = CreateObject("WScript.Shell")\r\nWshShell.CurrentDirectory = "${dirEsc}"\r\nWshShell.Run "cmd /c ""${nodeEsc}"" ""${panelEsc}"" >> ""${logEsc}"" 2>&1", 0, False\r\n`;
  fs.writeFileSync(WIN_STARTUP_FILE, vbs);
  console.log(`[install-service] Windows: VBS installed at ${WIN_STARTUP_FILE}`);
  console.log('[install-service] panel will start at user login.');
}

function winUninstall() {
  if (!fs.existsSync(WIN_STARTUP_FILE)) {
    console.log('[install-service] Windows: not installed, nothing to do');
    return;
  }
  fs.unlinkSync(WIN_STARTUP_FILE);
  console.log('[install-service] Windows: VBS removed');
}

function winStatus() {
  return { installed: fs.existsSync(WIN_STARTUP_FILE) };
}

// MARK: - Dispatcher

function run(cmd) {
  switch (PLATFORM) {
    case 'darwin':
      if (cmd === 'install')   return macInstall();
      if (cmd === 'uninstall') return macUninstall();
      if (cmd === 'status')    return console.log(JSON.stringify(macStatus(), null, 2));
      break;
    case 'linux':
      if (cmd === 'install')   return linInstall();
      if (cmd === 'uninstall') return linUninstall();
      if (cmd === 'status')    return console.log(JSON.stringify(linStatus(), null, 2));
      break;
    case 'win32':
      if (cmd === 'install')   return winInstall();
      if (cmd === 'uninstall') return winUninstall();
      if (cmd === 'status')    return console.log(JSON.stringify(winStatus(), null, 2));
      break;
    default:
      console.error(`[install-service] unsupported platform: ${PLATFORM}`);
      process.exit(2);
  }
  console.error(`[install-service] usage: node install-service.js {install|uninstall|status}`);
  process.exit(1);
}

// Run when invoked as CLI (not when imported).
if (import.meta.url === `file://${process.argv[1]}` ||
    process.argv[1]?.endsWith('install-service.js')) {
  run(process.argv[2] || 'status');
}

export { macInstall, macUninstall, macStatus, linInstall, linUninstall, linStatus, winInstall, winUninstall, winStatus };
