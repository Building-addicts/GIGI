# Code Map
_Last updated: 2026-04-24 — after Phase 4 (Tailscale + QR pairing) commit `ca8a599` by code-mapper_

Bootstrap note: this file is first-created here. Only Phase 4 surfaces are mapped. Prior surfaces (Phase 1-3, harness fasi 10-18) are intentionally not retro-mapped — they will be added incrementally as subsequent tasks touch them.

## Module Index
| File | Key Exports | Purpose |
|------|-------------|---------|
| `02_GIGI_APP/GIGI/GigiPairScanner.swift` | `GigiPairScannerView` | VisionKit `DataScannerViewController` wrapper for QR scan + camera permission flow |
| `02_GIGI_APP/GIGI/GigiPairingSheet.swift` | `GigiPairingSheet` | End-to-end pairing state machine (scan → validate → Keychain save → health probe → rollback) |
| `02_GIGI_APP/GIGI/SettingsView.swift` | `SettingsView`, `SettingsField` | Settings screen; `harnessSection` rewritten in P4.6 to primary-button + collapsible manual config |
| `02_GIGI_APP/GIGI/MainTabView.swift` | `MainTabView` | Root tabs; P4.7 added purple pairing banner overlay shown when `!isConfigured` |
| `02_GIGI_APP/GIGI/GigiClaudeBridge.swift` | `GigiClaudeBridge` | Claude delegation bridge; P4.8 extended `userFacingError` with Tailscale hint + 401 re-pair copy |
| `02_GIGI_APP/GIGI/Info.plist` | `NSCameraUsageDescription` | iOS privacy string for QR scanner camera access (P4.3) |
| `03_HARNESS/server/api/pair.js` | `handlePair` | Loopback-only `GET /api/pair` — JSON payload (url+secret+deviceName+createdAt) or SVG QR (`?format=svg`) |
| `03_HARNESS/server/public/pair.html` | (static page) | Panel page served at `/pair`; fetches `http://<host>:7779/api/pair` client-side, renders QR + obfuscated secret + copy-URL |
| `03_HARNESS/server/server.js` | bootstrap + HTTP orchestrator | P4.1 imports `handlePair` and dispatches it BEFORE `handleIosRequest` on port 7779 |
| `03_HARNESS/server/panel-routes.js` | panel route handler | P4.2 added `GET /pair` → serves `public/pair.html` |
| `03_HARNESS/server/package.json` | deps manifest | Adds `qrcode` dependency |

## Function Graph

### `02_GIGI_APP/GIGI/GigiPairScanner.swift` :: `GigiPairScannerView`
- **Purpose:** SwiftUI full-screen scanner that requests camera permission, hosts `DataScannerViewController`, and fires `onScan(String)` once on the first QR read. Shows denied / unavailable / waiting overlays as needed.
- **Called by:** `GigiPairingSheet.body` in the `.scanning` phase (`02_GIGI_APP/GIGI/GigiPairingSheet.swift:37`)
- **Calls:** `AVCaptureDevice.authorizationStatus(for:)`, `AVCaptureDevice.requestAccess(for:)` (system), inner `DataScannerRepresentable` → `DataScannerViewController` (VisionKit)
- **Inputs:** `onScan: (String) -> Void`, `onCancel: () -> Void`
- **Output:** SwiftUI `View`
- **Side effects:** requests camera permission; opens camera; can open iOS Settings URL (`UIApplication.openSettingsURLString`) from denied overlay
- **Complexity note:** permission is read synchronously at init from `AVCaptureDevice.authorizationStatus` and then updated via a `@MainActor.run` hop after the async `requestAccess` resolves; the `fired` guard inside the `DataScannerViewControllerDelegate.Coordinator` debounces duplicate emissions before `stopScanning()` returns.
- **Last modified:** 2026-04-24 in Phase 4 (P4.4) by frontend-dev

### `02_GIGI_APP/GIGI/GigiPairScanner.swift` :: `GigiPairScannerView.requestPermission() async`
- **Purpose:** Request camera permission once (guarded by `requestInFlight`) and push the resolved state back on the main actor.
- **Called by:** `GigiPairScannerView.body` via `.task { await requestPermission() }` when `permission == .notDetermined`
- **Calls:** `AVCaptureDevice.requestAccess(for: .video)`, `MainActor.run`
- **Inputs:** none (implicit `self`)
- **Output:** `Void`
- **Side effects:** mutates `@State permission` and `@State requestInFlight`
- **Last modified:** 2026-04-24 in Phase 4 (P4.4)

### `02_GIGI_APP/GIGI/GigiPairScanner.swift` :: `DataScannerRepresentable` (private) + `Coordinator`
- **Purpose:** UIViewControllerRepresentable bridge that instantiates `DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])])` and delegates QR recognition to a `Coordinator` that fires `onScan` once.
- **Called by:** `GigiPairScannerView.body` (authorized branch)
- **Calls:** `DataScannerViewController.startScanning()`, `DataScannerViewController.stopScanning()`
- **Inputs:** `onScan: (String) -> Void`
- **Output:** `DataScannerViewController`
- **Side effects:** starts/stops camera capture
- **Last modified:** 2026-04-24 in Phase 4 (P4.4)

### `02_GIGI_APP/GIGI/GigiPairingSheet.swift` :: `GigiPairingSheet`
- **Purpose:** SwiftUI sheet orchestrating the pair flow across four phases (`scanning`, `validating`, `success`, `failure`). Auto-dismisses 1.4 s after success; offers a "Riprova" loop on failure.
- **Called by:**
  - `SettingsView.harnessSection` via `.sheet(isPresented: $showPairingSheet)` at `02_GIGI_APP/GIGI/SettingsView.swift:202`
  - `MainTabView` via `.sheet(isPresented: $showPairingSheet)` at `02_GIGI_APP/GIGI/MainTabView.swift:70`
- **Calls:** `GigiPairScannerView`, `GigiKeychain.save`, `GigiKeychain.delete`, `GigiHarnessClient.ensureDeviceId`, `GigiHarnessClient.shared.health()`
- **Inputs:** `onPaired: (String) -> Void` (deviceName)
- **Output:** SwiftUI `View`
- **Side effects:** writes/deletes Keychain entries for `harnessBaseURL` / `harnessSecret`; triggers `ensureDeviceId` which may create a device UUID; performs one health HTTP request
- **Last modified:** 2026-04-24 in Phase 4 (P4.5)

### `02_GIGI_APP/GIGI/GigiPairingSheet.swift` :: `process(_ payload: String) async` (private)
- **Purpose:** Core validator. Parses the scanned JSON into `PairPayload`, sanity-checks url/secret, persists to Keychain, runs `ensureDeviceId`, verifies reachability with `health()`, rolls back Keychain on failure, and transitions the phase state.
- **Called by:** `GigiPairingSheet.handleScan(_:)`
- **Calls:** `JSONDecoder.decode`, `GigiKeychain.save`, `GigiKeychain.delete`, `GigiHarnessClient.ensureDeviceId`, `GigiHarnessClient.shared.health()`, `MainActor.run`, `Task.sleep`, internal `userMessage(for:)`, `fail(_:)`, `onPaired`
- **Inputs:** `payload: String` (raw QR body)
- **Output:** `Void` (state transitions); on success invokes `onPaired(deviceName)` on the main actor
- **Side effects:**
  - Keychain writes: `GigiKeychain.Key.harnessBaseURL`, `GigiKeychain.Key.harnessSecret`
  - Keychain deletes on health failure (rollback)
  - `GigiHarnessClient.ensureDeviceId()` may mint a fresh device id
  - network: one `GET /api/ios/health` call
  - dismisses sheet after 1.4 s on success
- **Last modified:** 2026-04-24 in Phase 4 (P4.5)

### `02_GIGI_APP/GIGI/GigiPairingSheet.swift` :: `userMessage(for: GigiHarnessClient.Error) -> String` (private)
- **Purpose:** Translate `GigiHarnessClient.Error` variants into short Italian user-facing strings scoped to the pairing context (different copy than `GigiClaudeBridge.userFacingError`).
- **Called by:** `GigiPairingSheet.process(_:)`
- **Inputs:** `GigiHarnessClient.Error`
- **Output:** `String`
- **Side effects:** none
- **Last modified:** 2026-04-24 in Phase 4 (P4.5)

### `02_GIGI_APP/GIGI/SettingsView.swift` :: `harnessSection` (computed property)
- **Purpose:** Harness Backend section of Settings. Primary pair button → `GigiPairingSheet`; status row; "Verifica connessione" and "Rimuovi pairing" only when paired; `DisclosureGroup "Configurazione manuale (avanzata)"` preserves the raw URL+secret TextField flow.
- **Called by:** `SettingsView.body` list composition
- **Calls:** `GigiKeychain.load`, `GigiHarnessClient.shared.isConfigured` (via `harnessIsPaired`), `removePairing()`, `saveAndTestHarness()`, presents `GigiPairingSheet`
- **Inputs:** SwiftUI `@State` fields on `SettingsView` (`harnessURL`, `harnessSecret`, `harnessStatus`, `isTestingHarness`, `showPairingSheet`, `pairedDeviceName`)
- **Output:** `some View`
- **Side effects:** presenting the sheet triggers Keychain writes/deletes inside `GigiPairingSheet.process`; "Rimuovi pairing" directly clears Keychain via `removePairing()`
- **BREAKING CHANGE note (P4.6):** the old raw TextField-only version of `harnessSection` is now collapsed under `DisclosureGroup`. Nothing else in the codebase consumes `harnessSection` directly, so no callers break.
- **Last modified:** 2026-04-24 in Phase 4 (P4.6)

### `02_GIGI_APP/GIGI/SettingsView.swift` :: `removePairing()` (private)
- **Purpose:** Nukes Keychain pairing state and resets view fields.
- **Called by:** `harnessSection` "Rimuovi pairing" button
- **Calls:** `GigiKeychain.delete` (twice)
- **Side effects:** Keychain delete of `harnessBaseURL` + `harnessSecret`; UI state reset
- **Last modified:** 2026-04-24 in Phase 4 (P4.6)

### `02_GIGI_APP/GIGI/SettingsView.swift` :: `harnessIsPaired` (computed property, private)
- **Purpose:** Derived bool for the section UI — true iff both Keychain slots are non-empty.
- **Called by:** `harnessSection` (button label + conditional controls)
- **Calls:** `GigiKeychain.load` (twice)
- **Side effects:** none (read-only)
- **Last modified:** 2026-04-24 in Phase 4 (P4.6)

### `02_GIGI_APP/GIGI/MainTabView.swift` :: `pairingBanner` (computed property, private)
- **Purpose:** Purple gradient banner overlaid at the top of `MainTabView` when harness is not configured and onboarding is done. Tap opens `GigiPairingSheet`.
- **Called by:** `MainTabView.body` ZStack (shown when `!harnessConfigured && !showOnboarding`)
- **Calls:** none directly; tap sets `showPairingSheet = true`
- **Side effects:** triggers sheet presentation; sheet callback refreshes `harnessConfigured` from `GigiHarnessClient.shared.isConfigured`
- **Complexity note:** `harnessConfigured` is seeded eagerly at `@State` init AND refreshed in `.onAppear` AND from the sheet's `onPaired` callback — three places because iOS doesn't observe Keychain.
- **Last modified:** 2026-04-24 in Phase 4 (P4.7)

### `02_GIGI_APP/GIGI/GigiClaudeBridge.swift` :: `userFacingError(for: GigiHarnessClient.Error) -> String` (private static)
- **Purpose:** Translates harness errors into Italian user copy shown in chat.
- **Called by:** `GigiClaudeBridge.run(task:context:)` in the `.failure` branch
- **Calls:** `GigiKeychain.load(forKey: .harnessBaseURL)`
- **Inputs:** `GigiHarnessClient.Error`
- **Output:** `String`
- **Side effects:** none
- **Change in P4.8:** `.transport` branch now appends "Controlla Tailscale attivo su PC e iPhone." when the stored base URL starts with `://100.` (CGNAT). `.badResponse(401)` now returns "Secret non più valido. Ri-pair dal Panel." instead of the generic HTTP message.
- **BREAKING CHANGE:** none (same signature, richer copy).
- **Last modified:** 2026-04-24 in Phase 4 (P4.8)

### `03_HARNESS/server/api/pair.js` :: `handlePair(req, res, { cfg }) async`
- **Purpose:** Route `GET /api/pair` on port 7779 — returns JSON pairing payload by default or an SVG QR when `?format=svg`. Loopback-only.
- **Called by:** `server.js` iOS HTTP request handler (line 176), invoked BEFORE `handleIosRequest` so it bypasses the iOS Bearer middleware.
- **Calls:** internal `isLoopback(req)`, `buildPayload(cfg)`, `pickHostIp(cfg)`, `QRCode.toString` (from `qrcode` npm dep), `os.networkInterfaces`, `os.hostname`, `sendJson(res, ...)` (internal helper)
- **Inputs:** `req: http.IncomingMessage`, `res: http.ServerResponse`, `{ cfg }` (loaded harness config)
- **Output:** `Promise<boolean>` — `true` if the route matched (caller must stop dispatch), `false` otherwise
- **Side effects:** writes HTTP response (200/403/405/500); never mutates config or disk
- **Response shapes:**
  - JSON: `{ ok: true, data: { url, secret, deviceName, createdAt } }` with CORS `Access-Control-Allow-Origin: http://localhost:7777`
  - SVG: `image/svg+xml` QR of `JSON.stringify(payload)` with error-correction `H`, width `320`
  - 403 JSON: `{ ok: false, error: { code: 'LOOPBACK_ONLY', ... } }`
  - 405 JSON: `{ ok: false, error: { code: 'METHOD_NOT_ALLOWED', ... } }`
- **Complexity note:** `pickHostIp` prefers Tailscale CGNAT (`^100\.`) over any other non-internal IPv4; falls back to first non-link-local IPv4; last resort is `cfg.server.host`. This is best-effort — if Tailscale is not running on the PC the QR may encode a LAN address that the iPhone can't reach over cellular (expected during dev).
- **Security:** secret is only returned for loopback requests (`127.0.0.1` / `::1` / `::ffff:127.0.0.1`); remote IPs get 403.
- **Last modified:** 2026-04-24 in Phase 4 (P4.1)

### `03_HARNESS/server/api/pair.js` :: `pickHostIp(cfg)` (private)
- **Purpose:** Best-effort detection of the PC's Tailscale-assigned IPv4.
- **Called by:** `buildPayload`
- **Calls:** `os.networkInterfaces()`
- **Output:** `string` (IPv4 address)
- **Side effects:** none
- **Last modified:** 2026-04-24 in Phase 4 (P4.1)

### `03_HARNESS/server/api/pair.js` :: `isLoopback(req)` (private)
- **Purpose:** Guard clause rejecting non-loopback peers.
- **Called by:** `handlePair`
- **Output:** `boolean`
- **Last modified:** 2026-04-24 in Phase 4 (P4.1)

### `03_HARNESS/server/api/pair.js` :: `buildPayload(cfg)` (private)
- **Purpose:** Assemble `{ url, secret, deviceName, createdAt }` from config + network interfaces + hostname.
- **Called by:** `handlePair`
- **Calls:** `pickHostIp(cfg)`, `os.hostname`, `new Date().toISOString()`
- **Output:** `{ url: string, secret: string, deviceName: string, createdAt: string }`
- **Last modified:** 2026-04-24 in Phase 4 (P4.1)

### `03_HARNESS/server/server.js` :: iOS HTTP request handler (`http.createServer` callback, anonymous)
- **Purpose:** Orchestrates every request on port 7779. Now dispatches `/api/pair` via `handlePair` before the iOS Bearer-protected router.
- **Called by:** Node `http` server dispatch on port 7779
- **Calls:** `handlePair(req, res, { cfg })` (new), `handleIosRequest(req, res, { cfg, gigiServer })`
- **Inputs:** `req`, `res`
- **Output:** response written to `res`
- **Side effects:** HTTP response; 500 on unhandled exception
- **BREAKING CHANGE note:** none for existing iOS callers — `/api/pair` is a new, loopback-gated path; all `/api/ios/*` paths still flow through `handleIosRequest` unchanged.
- **Last modified:** 2026-04-24 in Phase 4 (P4.1)

### `03_HARNESS/server/panel-routes.js` :: `/pair` handler (inline)
- **Purpose:** Serves `public/pair.html` as `text/html` when the panel (port 7777) receives `GET /pair`. No auth (panel is already loopback-admin).
- **Called by:** panel-routes dispatcher in `panel.js`
- **Calls:** `fs.readFile(path.join(PUBLIC_DIR, 'pair.html'))`
- **Side effects:** disk read; HTTP response (200 or 404)
- **Last modified:** 2026-04-24 in Phase 4 (P4.2)

### `03_HARNESS/server/public/pair.html` :: `<script> loadPair()` (browser)
- **Purpose:** Client-side fetch of the pair payload and the SVG QR from `http://<host>:7779/api/pair[?format=svg]`; renders URL, obfuscated secret, deviceName, inline SVG QR, and "Copia" for the URL.
- **Called by:** `window.load` + `window.focus` listeners in the same script
- **Calls:** `fetch(API_BASE + '/api/pair')`, `fetch(API_BASE + '/api/pair?format=svg')`, `navigator.clipboard.writeText`
- **Inputs:** none (uses `location.hostname`)
- **Output:** mutates DOM (`#qr`, `#url`, `#device`, `#secretMasked`)
- **Side effects:** two network requests per load/focus; clipboard write on button click
- **Complexity note:** the script targets `location.hostname + ':7779'` so the page only works when both panel (7777) and iOS server (7779) are bound to the same host. Over Tailscale this works because CORS on `/api/pair` whitelists `http://localhost:7777`; if the panel were ever served from a different origin the fetch would 403 at the browser layer.
- **Last modified:** 2026-04-24 in Phase 4 (P4.2)

## Cross-module edges (Phase 4)

- `MainTabView.pairingBanner` → reads `GigiHarnessClient.shared.isConfigured`, presents `GigiPairingSheet` → its `onPaired` callback re-reads `isConfigured`.
- `SettingsView.harnessSection` → presents `GigiPairingSheet`; calls `GigiKeychain.delete` on unpair; `saveAndTestHarness()` unchanged from pre-Phase 4 except it is now the "advanced" path.
- `GigiPairingSheet.process(_:)` → `GigiKeychain.save` (2x) → `GigiHarnessClient.ensureDeviceId` → `GigiHarnessClient.shared.health()` → on failure `GigiKeychain.delete` (rollback).
- `GigiPairScannerView.requestPermission` → `AVCaptureDevice.requestAccess(for: .video)`.
- `GigiPairScannerView` internal `DataScannerRepresentable` → `DataScannerViewController` (VisionKit) with `.barcode(symbologies: [.qr])`, `.balanced` quality.
- `server.js` request flow → `handlePair` (loopback-only) → `handleIosRequest` (Bearer-auth).
- `panel-routes.js /pair` → serves `public/pair.html`.
- `pair.html` JS → fetches `http://<host>:7779/api/pair` and `?format=svg` (CORS `http://localhost:7777`).

## Removed Functions
_None in Phase 4._
