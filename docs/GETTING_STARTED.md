# Getting Started with GIGI

GIGI is a personal voice assistant that runs on your iPhone and delegates
complex tasks to Claude on your PC. The PC half is called the **harness**.
This guide walks through pairing your phone to the PC and getting both
sides talking.

Total time: about 10 minutes.

## What you need

- An iPhone running iOS 17+
- A PC running Windows, macOS, or Linux with:
  - Node.js v20+
  - The Claude Code CLI (`claude --version` should print a version)
- An Apple ID with at least the free Sideloadly path or a developer account
  for installing the iOS app

## 1. Install the harness on your PC

Clone the repo and start the harness panel:

```bash
git clone https://github.com/Leonardo-Corte/GIGI.git
cd GIGI/03_HARNESS/server
npm install
node panel.js
```

The first run prints:

```
Control Panel: http://localhost:7777
```

Open `http://localhost:7777` in your browser. You should see the harness
dashboard with tabs: Stato, Connections, Configurazione, Browsers, Workers,
Log.

Click the **Setup** button in the header to go to the tunnel chooser.

## 2. Pick a tunnel mode

The harness needs a way to reach your phone from outside your home network.
GIGI supports four modes — pick the one that matches your situation:

| Mode | Best for | Setup |
|---|---|---|
| **Cloudflare Quick Tunnel** ⭐ recommended | Quick start, no account | One click |
| **Cloudflare Named Tunnel** | Stable URL, your domain | Cloudflare account + domain |
| **LAN (mDNS)** | Same Wi-Fi only | Zero config |
| **Manual / Tailscale** | Custom relay, advanced | Tailscale install |

For most users, **Cloudflare Quick Tunnel** is the right answer. Click its
card → **Start tunnel**. Within 15 seconds you'll see a public URL like
`https://random-words.trycloudflare.com`. The harness has stored it; you
don't need to copy it.

## 3. Run the diagnostic check

Before pairing, the harness verifies your PC is healthy. The diagnostic
runs ten checks (Claude CLI installed and authed, secret strength, tunnel
running, outbound HTTPS, disk space). On the **Setup** page you'll see
results inline. Anything red has a one-click "Auto-fix" button when
possible, otherwise a copyable shell command. Fix everything red, then
move on.

## 4. Generate the pair QR

Open `http://localhost:7777/pair` in the same browser. The page shows a
QR code containing the public URL + a one-time pair secret. Keep this tab
open.

## 5. Install the iOS app

For now, GIGI is sideloaded (App Store distribution coming later). The
shortest path:

1. Install [Sideloadly](https://sideloadly.io) on your PC
2. Connect your iPhone via USB
3. Drop the latest `GIGI.ipa` (from the project release page or built from
   `02_GIGI_APP/GIGI.xcodeproj`) into Sideloadly
4. Sign in with your Apple ID and click **Start**

Trust the developer profile on your iPhone:
**Settings → General → VPN & Device Management → trust your Apple ID**.

## 6. Pair the phone with the PC

Open the GIGI app on iPhone. The first launch shows a welcome flow, then
returns you to the chat. A **purple banner** at the top says
*Connect GIGI to your PC*. Tap it.

The phone opens the camera. Point it at the QR on your PC browser. The
app:

1. Reads the URL + secret from the QR
2. Saves them in the iOS Keychain
3. Calls `/api/ios/health` on the harness — green check on success
4. Runs the same diagnostic the PC saw and shows ✓ next to each check
5. Tap **Finalize pair** when all critical checks are green

The purple banner disappears. You're paired.

## 7. Test it

Type or say "Ciao GIGI, come stai?" — Groq answers instantly. Now try
something harder: "Analizza il mio calendario della settimana e trovami
slot per sport" — the app routes through Claude on your PC, you see live
thoughts streaming in chat, and a final answer when Claude is done.

If you want every turn to go through Claude (slower, smarter), open
**Settings → Brain Mode** and toggle **Force Claude**.

## Troubleshooting

**Banner stays purple even after pairing.** Force-quit and reopen — recent
fix lands the persistence correction. If it still happens, **Settings →
Run diagnostics** and check that all critical rows are green.

**"Harness unreachable" errors after a while.** The Quick Tunnel URL
is ephemeral — every time you stop and restart cloudflared, the URL
changes, and your old QR no longer works. Re-pair with a fresh QR
from `localhost:7777/pair`. For a stable URL, switch to Named Tunnel.

**Make the harness start at boot.** Run, once:

```bash
cd 03_HARNESS/server
node tunnel/install-service.js install
```

The script writes a launchd plist (macOS), systemd user unit (Linux), or
Startup folder VBS (Windows). After this, the panel comes back on its own
after a reboot, and cloudflared comes back with it.

**Revoke a phone.** Open `http://localhost:7777` → **Connections** tab →
find the device → **Revoke**. The next request from that phone gets `403
DEVICE_REVOKED`.

## Architecture in one paragraph

iPhone → Cloudflare Tunnel → harness (Node.js) on your PC →
spawns the Claude Code CLI → streams Claude's thoughts back over a
WebSocket. Pair secret + URL live in iOS Keychain. Claude session state
lives on the PC. Memory is yours, on your machine.

## Where to go next

- `docs/Architecture-Armando-Revision.md` — full architecture
- `docs/TASK_PLAN.md` — current development plan
- `03_HARNESS/docs/api/ios-integration.md` — HTTP/WS API spec
