# MDM Profile — GIGI iOS Automation

The profile `gigi_profile_signed.mobileconfig` grants GIGI the system-level permissions
needed for UI automation (screenshots, tap injection, accessibility) via Apple's MDM framework.

Without this profile, computer-use features (automated form filling, browser control on-device)
are limited to what standard app entitlements allow.

---

## What the profile enables

- **Accessibility automation** — lets GIGI interact with other apps via UIAccessibility
- **Screen capture** — allows GIGI to take screenshots for computer-use vision loop
- **Supervised device features** — unlocks MDM-only entitlements on non-jailbroken devices

---

## Installation (USB)

> Requires macOS with Apple Configurator 2 or Xcode Devices window.

1. Connect iPhone via USB cable.
2. Trust the computer if prompted on the device.
3. **Option A — Apple Configurator 2** (recommended):
   - Open Apple Configurator 2.
   - Select your device → `Actions → Add → Profiles`.
   - Choose `gigi_profile_signed.mobileconfig`.
   - Confirm "Install" on the device.
4. **Option B — Xcode**:
   - Open `Window → Devices and Simulators`.
   - Select device → under "Installed Profiles" click `+`.
   - Select the `.mobileconfig` file.

---

## Installation (Wi-Fi / AirDrop)

1. AirDrop `gigi_profile_signed.mobileconfig` to the iPhone.
2. On iPhone: `Settings → General → VPN & Device Management → Downloaded Profile`.
3. Tap "Install" → enter device passcode → "Install" again → "Trust".

---

## Verify installation

1. `Settings → General → VPN & Device Management`.
2. Profile **"GIGI Automation"** should appear with status **Verified** (green checkmark if signed).

---

## Removal

`Settings → General → VPN & Device Management → GIGI Automation → Remove Profile`.

Removing the profile disables automation features; GIGI core (voice, brain, harness) keeps working.

---

## Re-signing / custom profile

If you need to build a custom profile (different bundle ID, additional entitlements):

```bash
# Install profile signing tool
brew install libimobiledevice

# Sign with your Apple Developer certificate
openssl smime -sign \
  -signer /path/to/your.crt \
  -inkey /path/to/your.key \
  -nodetach -outform DER \
  -in gigi_profile.mobileconfig \
  -out gigi_profile_signed.mobileconfig
```

See [Apple MDM Protocol Reference](https://developer.apple.com/documentation/devicemanagement) for profile payload keys.
