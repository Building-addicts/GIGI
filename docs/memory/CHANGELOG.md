# Changelog

Append-only, reverse-chronological log of every task that affects the codebase (code, planning, research). Managed by the code-mapper agent.

---
## 2026-04-24 — Phase 4: Tailscale + QR pairing (commit `ca8a599`)
**Agent:** frontend-dev + backend-dev (executed across P4.1 - P4.8)
**Triggered by:** Source plan `docs/plans/tailscale-qr-pairing.md`. Goal: zero-typing pairing that works from any network (4G, hotel Wi-Fi, abroad) by bootstrapping over Tailscale CGNAT and letting the iPhone scan a one-shot QR served only on the PC's localhost panel.

### Files Modified
| File | Change Type | Description |
|------|-------------|-------------|
| `02_GIGI_APP/GIGI/GigiPairScanner.swift` | ADDED | VisionKit `DataScannerViewController` wrapper + permission flow (P4.4). |
| `02_GIGI_APP/GIGI/GigiPairingSheet.swift` | ADDED | Pairing state machine: scan → validate → Keychain save → health → rollback (P4.5). |
| `03_HARNESS/server/api/pair.js` | ADDED | Loopback-only `GET /api/pair` JSON + SVG QR endpoint (P4.1). |
| `03_HARNESS/server/public/pair.html` | ADDED | Panel page that fetches `/api/pair` client-side and renders the QR (P4.2). |
| `02_GIGI_APP/GIGI/Info.plist` | MODIFIED | Added `NSCameraUsageDescription` (P4.3). |
| `02_GIGI_APP/GIGI/SettingsView.swift` | MODIFIED | `harnessSection` rewritten: primary "Pair con Harness" button, paired-status row, "Rimuovi pairing", raw URL+secret fields moved under `DisclosureGroup "Configurazione manuale (avanzata)"` (P4.6). |
| `02_GIGI_APP/GIGI/MainTabView.swift` | MODIFIED | Purple `pairingBanner` overlay + `GigiPairingSheet` presentation when `!GigiHarnessClient.shared.isConfigured` (P4.7). |
| `02_GIGI_APP/GIGI/GigiClaudeBridge.swift` | MODIFIED | `userFacingError(for:)` appends "Controlla Tailscale attivo su PC e iPhone." on `.transport` when the stored URL is CGNAT (`://100.`); `.badResponse(401)` now returns "Secret non più valido. Ri-pair dal Panel." (P4.8). |
| `03_HARNESS/server/server.js` | MODIFIED | Imports `handlePair` and dispatches it BEFORE `handleIosRequest` in the port-7779 request handler (P4.1). |
| `03_HARNESS/server/panel-routes.js` | MODIFIED | Added `GET /pair` → serves `public/pair.html` (P4.2). |
| `03_HARNESS/server/package.json` | MODIFIED | New dep `qrcode`. |
| `03_HARNESS/server/package-lock.json` | MODIFIED | Lock regen for `qrcode`. |

### Functions Added
- `GigiPairScannerView` (struct) in `02_GIGI_APP/GIGI/GigiPairScanner.swift` — SwiftUI full-screen scanner with permission overlays.
- `GigiPairScannerView.requestPermission() async` — guarded one-shot `AVCaptureDevice.requestAccess` bridge.
- `DataScannerRepresentable` + `Coordinator` (private) in `GigiPairScanner.swift` — UIViewControllerRepresentable over `DataScannerViewController`, debounces duplicate QR emissions with a `fired` flag and calls `stopScanning()` on first payload.
- `GigiPairingSheet` (struct) in `02_GIGI_APP/GIGI/GigiPairingSheet.swift` — four-phase sheet (`scanning`, `validating`, `success`, `failure`).
- `GigiPairingSheet.process(_ payload: String) async` (private) — parse → validate → Keychain save → `ensureDeviceId` → `health()` → rollback on failure.
- `GigiPairingSheet.userMessage(for: GigiHarnessClient.Error) -> String` (private) — pairing-scoped Italian error copy.
- `GigiPairingSheet.handleScan(_:)` / `fail(_:)` — state transition helpers.
- `handlePair(req, res, { cfg }) async` in `03_HARNESS/server/api/pair.js` — exported loopback-only route.
- `pickHostIp(cfg)` / `isLoopback(req)` / `buildPayload(cfg)` / `sendJson(res, code, obj)` (private) in `pair.js`.
- `pairingBanner` (private computed property) in `MainTabView.swift` — purple top banner; tap → `showPairingSheet = true`.
- `SettingsView.removePairing()` (private) — Keychain nuke + UI reset.
- `SettingsView.harnessIsPaired` (private computed) — derived bool from Keychain presence.
- `loadPair()` JS function in `public/pair.html` — client-side fetch + DOM render.

### Functions Modified
- `SettingsView.harnessSection` — full rewrite; primary button + `DisclosureGroup` for advanced raw input. `saveAndTestHarness()` body unchanged but now only reachable from the advanced section.
- `SettingsView.body` / `MainTabView.body` — added `.sheet(isPresented: $showPairingSheet) { GigiPairingSheet { ... } }`.
- `GigiClaudeBridge.userFacingError(for:)` — `.transport` appends Tailscale hint when stored URL contains `://100.` (CGNAT); `.badResponse(401)` replaced with "Secret non più valido. Ri-pair dal Panel.".
- `server.js` HTTP callback on port 7779 — dispatches `await handlePair(req, res, { cfg })` first; returns early on match.
- `panel-routes.js` — new `GET /pair` branch serving `public/pair.html` with `text/html; charset=utf-8` and `Cache-Control: no-store`.

### Functions Removed
_None. The old raw-only `harnessSection` is preserved as a `DisclosureGroup` child rather than deleted._

### Connection Changes
- NEW: `MainTabView.pairingBanner` → depends on `GigiHarnessClient.shared.isConfigured`; presents `GigiPairingSheet` on tap.
- NEW: `SettingsView.harnessSection` → presents `GigiPairingSheet`; calls `GigiKeychain.delete` on unpair.
- NEW: `GigiPairingSheet.process(_:)` → `GigiKeychain.save`, `GigiHarnessClient.ensureDeviceId`, `GigiHarnessClient.shared.health()`, `GigiKeychain.delete` (rollback).
- NEW: `GigiPairScannerView.requestPermission` → `AVCaptureDevice.requestAccess(for: .video)`.
- NEW: `GigiPairScannerView` → `DataScannerViewController` (VisionKit) with `.barcode(symbologies: [.qr])`.
- NEW: port-7779 request flow → `handlePair` (loopback-only) → `handleIosRequest` (Bearer-auth).
- NEW: panel-routes → `public/pair.html` on `GET /pair`.
- NEW: `pair.html` JS → `fetch http://<host>:7779/api/pair` and `?format=svg`, CORS-whitelisted for `http://localhost:7777`.
- NEW npm dep edge: `api/pair.js` → `qrcode`.

### Impact on Other Code
- `GigiHarnessClient.shared.isConfigured`, `ensureDeviceId()`, `health()` are now invoked from additional call sites (`GigiPairingSheet`, `MainTabView`). No interface change — just new callers. Anyone modifying these APIs should keep the four call sites in mind: `SettingsView.loadState`, `SettingsView.saveAndTestHarness`, `GigiPairingSheet.process`, `MainTabView.onAppear`.
- `GigiKeychain.Key.harnessBaseURL` / `.harnessSecret` now have two writer paths (manual save in Settings + QR save in sheet). Schema unchanged.
- `GigiClaudeBridge.userFacingError(for:)` is now dependent on Keychain state (reads `harnessBaseURL` to detect CGNAT). If the key is renamed, this helper must be updated or the hint silently disappears.
- Panel `/pair` page trusts that the iOS server on 7779 is reachable from the same host — if someone changes `cfg.server.host` to bind only a non-loopback interface, the `fetch` in `pair.html` breaks.
- `/api/pair` must never be exposed beyond loopback. Any future middleware that short-circuits the `isLoopback` check would leak the shared secret to Tailnet peers. This is enforced inside `pair.js` itself (defense in depth) and MUST stay in place.
- Bootstrap note: this changelog was created together with `CODE_MAP.md` during Phase 4 close-out. Earlier phases (P1.1 / P1.2 / P1.3 / P1.4) are not backfilled here — their state lives in `docs/memory/ACTIVITY_LOG.md` and `docs/TASK_PLAN.md` Progress Log.

---
