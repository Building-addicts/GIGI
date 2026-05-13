# Phase 2 — AI Shortcut Pipeline Setup

> Step-by-step config to enable end-to-end AI-generated Shortcuts:
> *"GIGI build me a shortcut that..."* → iOS Shortcuts preview → 1 tap install.
>
> Architecture in ADR-0014. Requires:
> - Mac (cloud or local) with Cherri installed
> - SSH access from harness host to the Mac
> - GIGI harness running with the env vars set

## 1. Provision the signing Mac

The Mac must have:
- macOS 12+ (for `shortcuts` CLI with `sign` subcommand)
- `cherri` binary at `~/bin/cherri` (or another path you configure)
- SSH server enabled (typically default for cloud Macs)
- Network reachable from the harness host

### Cherri install on the Mac

```bash
ssh user@your.mac.example
mkdir -p ~/bin
cd /tmp
curl -fsSL -o cherri.zip \
  "https://github.com/electrikmilk/cherri/releases/download/v2.2.0/cherri_darwin-arm64.zip"
unzip -o cherri.zip
chmod +x cherri
mv cherri ~/bin/cherri
~/bin/cherri --help
```

(Use `cherri_darwin-x86_64.zip` if your Mac is Intel.)

### Test the Cherri smoke run

```bash
mkdir -p ~/cherri-test
cat > ~/cherri-test/hello.cherri <<'EOF'
// GIGI smoke test
show("Hello from GIGI — AI-generated Shortcut!")
EOF
cd ~/cherri-test && ~/bin/cherri hello.cherri
ls -la hello.shortcut
```

If you see `hello.shortcut` (~22 KB AEA1 signed bytes), Cherri is working.

## 2. SSH access from harness to Mac

Harness uses `scp` + `ssh` shell commands. SSH key-based auth required —
no interactive password prompts.

### Generate + install SSH key (one-time)

On the harness host:
```bash
ssh-keygen -t ed25519 -f ~/.ssh/gigi_mac_signer -N ""
ssh-copy-id -i ~/.ssh/gigi_mac_signer.pub user@your.mac.example
```

Add to `~/.ssh/config`:
```
Host your.mac.example
    User user
    IdentityFile ~/.ssh/gigi_mac_signer
    StrictHostKeyChecking accept-new
```

Test:
```bash
ssh user@your.mac.example 'echo OK'
# Should print "OK" without prompting for password
```

## 3. Configure harness env vars

Add to your harness `.env` or `start.sh`:

```bash
# Required — SSH target for Mac signing
export HARNESS_MAC_SIGN_HOST="user@your.mac.example"

# Optional — overrides (defaults shown)
export HARNESS_MAC_SIGN_TMPDIR="/tmp"
export HARNESS_MAC_CHERRI_BIN="~/bin/cherri"

# Optional — public base URL for the signed-file serving endpoint.
# When iOS is connecting via Cloudflare Tunnel, this should be the
# tunnel URL so iOS can fetch the signed .shortcut over the public net.
# Falls back to the request Host header if unset.
export HARNESS_PUBLIC_BASE_URL="https://your-tunnel.example.com"
```

Restart the harness:
```bash
./start-harness.sh
# or
cd 03_HARNESS/server && node server.js
```

## 4. Verify end-to-end

On the iPhone with the GIGI app (`GIGI-phase2-*` IPA installed):

1. Open GIGI → chat
2. Type or speak:
   > "GIGI build me a shortcut that turns on the torch and waits 5 seconds and turns it off"
3. **Expected behavior**:
   - Banner: 🔧 *"Building Shortcut..."*
   - 3-8 seconds wait
   - Banner: ⚡️ *"Ready — tap Add Shortcut"*
   - Chat: *"Built 'Quick Torch'. Tap 'Add Shortcut' to install."*
   - iOS Shortcuts.app opens with a preview titled "Quick Torch"
   - 3 actions visible
   - Tap **Add Shortcut** → installed
   - Open Shortcuts.app → run the new "Quick Torch" → torch flashes 5 sec

## 5. Troubleshooting

### Chat: *"Harness error building the Shortcut: HARNESS_MAC_SIGN_HOST not configured"*

Env var not set or not picked up. `printenv | grep HARNESS_MAC_SIGN_HOST`
on the harness host. Restart harness after setting it.

### Chat: *"Compile failed: Command failed (exit ...): Unknown action 'X'"*

Cherri vocabulary doesn't include the action Apple FM tried to use, OR
Cherri itself doesn't have that action in its stdlib. Check
`02_GIGI_APP/GIGI/GigiCherriDSL.swift` CHERRI_VOCABULARY map.

### Chat: *"Compile failed: Command timed out"*

Cherri took >30s. Usually a SSH connectivity issue. Test manually:
```bash
echo 'show("test")' > /tmp/test.cherri
scp /tmp/test.cherri user@your.mac.example:/tmp/test.cherri
ssh user@your.mac.example '~/bin/cherri /tmp/test.cherri && ls -la /tmp/test.shortcut'
```

### iOS: file opens but Shortcuts.app says "Invalid Shortcut format"

Signing failed. Cherri probably fell back to HubSign which may be down.
Check on the Mac:
```bash
cd ~/cherri-test && ~/bin/cherri hello.cherri 2>&1
# Look for "Signing using HubSign service..." or local sign success
```

If HubSign is down and local `shortcuts sign` is broken, the only fix
is to wait for HubSign recovery or self-host
[scaxyz/shortcut-signing-server](https://github.com/scaxyz/shortcut-signing-server)
on a separate Mac (deferred to GATE 16).

### iOS: chat says "Built 'X'" but Shortcuts.app doesn't open

iOS opened the URL but the file didn't trigger the Shortcuts app. Could be:
- Content-Type wrong: should be `application/x-apple-aspen-config`
- File extension wrong: should end `.shortcut`
- iOS settings blocking external URLs: check Settings → Screen Time

## 6. Cleanup / disable

To disable the AI Shortcut authoring without removing the code:
- Don't set `HARNESS_MAC_SIGN_HOST` — chat will surface a clear error
- OR add `build_shortcut` to a feature-flag block in `route()` if needed

To remove old hosted files manually:
```bash
rm -rf $TMPDIR/gigi-shortcuts/*.cherri $TMPDIR/gigi-shortcuts/*.shortcut
```

(They auto-prune after 5 min anyway.)

## Roadmap (post-MVP)

- Replace HubSign fallback with self-hosted signing server (GATE 16)
- Expand Cherri vocabulary to ~50 actions (HomeKit fine, Calendar,
  Reminders, etc.)
- AI-suggest aliases for newly built Shortcuts (auto-register in
  `GigiShortcutRegistry`)
- Multi-user signing with per-user Apple ID (OSS scaling)
