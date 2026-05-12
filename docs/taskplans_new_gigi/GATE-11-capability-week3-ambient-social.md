# GATE 11 — Capability Expansion Week 3: Ambient & Social

> **Status**: Pending (richiede GATE 10 chiuso)
> **Effort stimato**: ~14h (≈2 giorni lavorativi pieni)
> **Bloccanti pre-gate**: GATE 10 chiuso (Capability Week 2 mergiato in main, registry esteso, AC Week 2 verdi su device fisico); HomeKit accessories già configurati su Home app del tester (almeno 1 luce dimmable, 1 luce colorabile, 1 termostato — se mancano, GATE 11.A degrada a "lab simulato" con `HMHomeManager` mock); permission CoreLocation `WhenInUse` non ancora richiesta (chiediamola in GATE 11.B); `LSApplicationQueriesSchemes` di `Info.plist` già include `tg`, `sgnl`, `mailto` (verifica con grep, altrimenti aggiungerli come prima task del GATE); entitlement Focus presente in `GIGI.entitlements` (`com.apple.developer.user-fed` o `com.apple.developer.usernotifications.communication` a seconda di iOS target — verifica con `plutil`).
> **Sblocca**: GATE 12 (Capability Week 4 "Active help & memory"), che dipende dalle stesse fondamenta location/contact/share-sheet introdotte qui.
> **Funzione consegnata (1 frase)**: GIGI può ora comandare HomeKit in modo fine (brightness/color/thermostat), conoscere e condividere la propria posizione, comporre email/Telegram/Signal via deep link, e attivare Focus mode iOS — coprendo i 9 tool "ambient & social" della Week 3 del capability expansion plan.

---

## 1. Obiettivo

Estendere il registry Apple FM e il GigiFallbackRouter introdotti in GATE 3/9/10 con 9 nuovi tool che attivano API native iOS finora non coperte:

1. **HomeKit fine control** (3 tool): oltre `homekit_on/off` di GATE 3, ora `set_homekit_brightness` (0-100), `set_homekit_color` (hue/saturation da nome colore inglese), `set_homekit_thermostat` (target temp °C). Tutti via `HMHomeManager` shared singleton con delegate discovery accessories.
2. **Location** (2 tool): `get_location_now` (single-shot CoreLocation, ritorna città + coords) e `share_my_location` (apre Messages con map URL + duration opzionale). Richiede `NSLocationWhenInUseUsageDescription` in `Info.plist`.
3. **Email & messaging deep links** (3 tool): `send_email` via `MFMailComposeViewController` (presented su MainActor con delegate), `send_telegram` via `tg://msg?to=<contact>&text=<encoded>`, `send_signal` via `sgnl://send?phone=<digits>`.
4. **Focus mode** (1 tool): `set_focus_mode` (DND/Work/Sleep/Personal + duration) via `INSetFocusFilterIntent` (richiede Focus entitlement).

Output concreto:
- `GigiFoundationToolRegistry.swift` esteso da 18 a 27 `Tool` struct
- `GigiHomeKitController.swift` (NEW, ~180 righe) — wrapper su `HMHomeManager` con discovery callback + write helpers per Brightness/Hue/Saturation/TargetTemperature
- `GigiLocationProvider.swift` (NEW, ~120 righe) — `CLLocationManager` single-shot async wrapper + reverse-geocode città
- `GigiMailComposer.swift` (NEW, ~80 righe) — `MFMailComposeViewControllerDelegate` adapter + present helper
- `GigiFocusController.swift` (NEW, ~90 righe) — `INSetFocusFilterIntent` adapter
- `GigiFallbackRouter.swift` aggiornato con 9 nuove keyword entries
- `Info.plist` aggiornato (`NSLocationWhenInUseUsageDescription`, `LSApplicationQueriesSchemes` se mancanti)
- `GIGI.entitlements` aggiornato se Focus entitlement assente

---

## 2. Pre-condizioni

- [ ] GATE 0..10 chiusi (Capability Week 1 + Week 2 mergiati in `main`)
- [ ] **HomeKit lab setup**: il tester ha configurato almeno 1 luce dimmable, 1 luce HSB-capable, 1 termostato sulla Home app. Lista nome accessory documentata in `docs/research/gate-11-homekit-inventory.md`. Senza setup il GATE 11.A degrada a "build verify + simulator HMHomeManager mock"
- [ ] `LSApplicationQueriesSchemes` di `02_GIGI_APP/GIGI/Info.plist` contiene `tg`, `sgnl`, `mailto`. Verifica:
  ```bash
  plutil -p "02_GIGI_APP/GIGI/Info.plist" | grep -E "LSApplicationQueriesSchemes|tg|sgnl|mailto"
  ```
  Se mancanti, aggiungerli come PRIMO step del GATE.
- [ ] `NSLocationWhenInUseUsageDescription` in `Info.plist` o pianificato per Task 11.2
- [ ] `GIGI.entitlements` ha Focus entitlement (`com.apple.developer.usernotifications.communication` o equivalente per iOS 26). Verifica:
  ```bash
  plutil -p "02_GIGI_APP/GIGI/GIGI.entitlements" | grep -i focus
  ```
- [ ] Telegram + Signal installati sul device tester per E2E (altrimenti deep link fallback alza alert "App not installed")
- [ ] iPhone 15 Pro+ fisico con Apple Intelligence on (per Apple FM tool calling test)

---

## 3. Task implementativi

### Task 11.1 — HomeKit fine control (3 tool, 5h)

- **File NUOVO**: `02_GIGI_APP/GIGI/GigiHomeKitController.swift` (~180 righe)
- **Pattern singleton + delegate discovery**:
  ```swift
  @MainActor
  final class GigiHomeKitController: NSObject, HMHomeManagerDelegate {
      static let shared = GigiHomeKitController()
      private let manager = HMHomeManager()
      private var ready: CheckedContinuation<Void, Never>?

      private override init() {
          super.init()
          manager.delegate = self
      }

      func waitUntilReady() async {
          if manager.primaryHome != nil { return }
          await withCheckedContinuation { cont in
              self.ready = cont
          }
      }

      func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
          ready?.resume(); ready = nil
      }

      func accessory(named fuzzy: String) -> HMAccessory? {
          guard let home = manager.primaryHome else { return nil }
          return home.accessories.first(where: { $0.name.lowercased().contains(fuzzy.lowercased()) })
      }

      func setBrightness(_ level: Int, on fuzzy: String) async throws {
          await waitUntilReady()
          guard let acc = accessory(named: fuzzy),
                let svc = acc.services.first(where: { $0.serviceType == HMServiceTypeLightbulb }),
                let ch = svc.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeBrightness })
          else { throw NSError(domain: "GigiHomeKit", code: 404, userInfo: [NSLocalizedDescriptionKey: "Accessory \(fuzzy) not found"]) }
          try await ch.writeValue(NSNumber(value: max(0, min(100, level))))
      }

      func setColor(hueName: String, on fuzzy: String) async throws { /* map color → (hue, sat) */ }
      func setThermostat(_ celsius: Double, on fuzzy: String) async throws { /* HMCharacteristicTypeTargetTemperature */ }
  }
  ```
- **Color name → (hue, sat) mapping table** (interna a `GigiHomeKitController`):
  ```swift
  private static let colorMap: [String: (hue: Double, sat: Double)] = [
      "red":    (0,   100),
      "orange": (30,  100),
      "yellow": (60,  100),
      "green":  (120, 100),
      "cyan":   (180, 100),
      "blue":   (240, 100),
      "purple": (270, 100),
      "pink":   (320,  60),
      "white":  (0,     0)
  ]
  ```
- **3 `Tool` struct in `GigiFoundationToolRegistry.swift`** (description inglese, regola CLAUDE.md):
  ```swift
  struct SetHomeKitBrightnessTool: Tool {
      let name = "set_homekit_brightness"
      let description = "Set the brightness level (0-100) of a HomeKit light. Use when the user asks to dim/brighten a specific light."
      @Generable struct Arguments {
          @Guide(description: "Accessory name, e.g. 'bedroom light', 'kitchen ceiling'.")
          var accessory: String
          @Guide(description: "Brightness 0-100 where 0=off, 100=max.")
          var level: Int
      }
      func call(arguments: Arguments) async -> String {
          do {
              try await GigiHomeKitController.shared.setBrightness(arguments.level, on: arguments.accessory)
              return "Brightness set to \(arguments.level)%"
          } catch { return "HomeKit error: \(error.localizedDescription)" }
      }
  }
  // Analoghi: SetHomeKitColorTool, SetHomeKitThermostatTool
  ```
- **`allTools` array**: aggiungere le 3 nuove entry mantenendo l'ordine canonico.

### Task 11.2 — Location tools (2 tool, 3h)

- **File NUOVO**: `02_GIGI_APP/GIGI/GigiLocationProvider.swift` (~120 righe)
- **Single-shot async wrapper su `CLLocationManager`**:
  ```swift
  @MainActor
  final class GigiLocationProvider: NSObject, CLLocationManagerDelegate {
      static let shared = GigiLocationProvider()
      private let manager = CLLocationManager()
      private var cont: CheckedContinuation<CLLocation, Error>?

      private override init() {
          super.init()
          manager.delegate = self
          manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
      }

      func currentLocation() async throws -> CLLocation {
          let status = manager.authorizationStatus
          switch status {
          case .notDetermined:
              manager.requestWhenInUseAuthorization()
              try await Task.sleep(nanoseconds: 500_000_000) // brief wait, app handles re-request
              throw NSError(domain: "GigiLocation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Permission requested. Please retry."])
          case .denied, .restricted:
              throw NSError(domain: "GigiLocation", code: 2, userInfo: [NSLocalizedDescriptionKey: "Location denied. Enable in Settings → Privacy → Location."])
          case .authorizedWhenInUse, .authorizedAlways:
              return try await withCheckedThrowingContinuation { c in
                  self.cont = c
                  manager.requestLocation()
              }
          @unknown default:
              throw NSError(domain: "GigiLocation", code: 3)
          }
      }

      func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
          if let loc = locs.first { cont?.resume(returning: loc); cont = nil }
      }
      func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
          cont?.resume(throwing: error); cont = nil
      }

      func cityName(for loc: CLLocation) async -> String? {
          let geo = CLGeocoder()
          let placemarks = try? await geo.reverseGeocodeLocation(loc)
          return placemarks?.first?.locality
      }
  }
  ```
- **Tool 1 — `get_location_now`**: nessun argument; ritorna formatted speech `"You are in \(city) at \(lat), \(lon)"`.
- **Tool 2 — `share_my_location`**: argument `{ contact: String, duration: String? }`; costruisce `https://maps.apple.com/?ll=lat,lon` e apre Messages compose con `MFMessageComposeViewController` (riusa pattern di `send_email` Task 11.3, vedi).
- **`Info.plist`**: aggiungere `NSLocationWhenInUseUsageDescription = "GIGI needs your location to answer 'where am I' and to share it on request."` se assente.

### Task 11.3 — Email/Telegram/Signal deep links (3 tool, 4h)

- **File NUOVO**: `02_GIGI_APP/GIGI/GigiMailComposer.swift` (~80 righe)
- **Pattern `MFMailComposeViewControllerDelegate` adapter**:
  ```swift
  @MainActor
  final class GigiMailComposer: NSObject, MFMailComposeViewControllerDelegate {
      static let shared = GigiMailComposer()
      private var cont: CheckedContinuation<Bool, Never>?

      func present(to: String, subject: String, body: String) async -> Bool {
          guard MFMailComposeViewController.canSendMail() else { return false }
          let vc = MFMailComposeViewController()
          vc.mailComposeDelegate = self
          vc.setToRecipients([to])
          vc.setSubject(subject)
          vc.setMessageBody(body, isHTML: false)
          guard let root = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene })
                  .flatMap({ $0.windows }).first(where: { $0.isKeyWindow })?.rootViewController
          else { return false }
          return await withCheckedContinuation { c in
              self.cont = c
              root.present(vc, animated: true)
          }
      }

      func mailComposeController(_ controller: MFMailComposeViewController,
                                 didFinishWith result: MFMailComposeResult,
                                 error: Error?) {
          controller.dismiss(animated: true)
          cont?.resume(returning: result == .sent); cont = nil
      }
  }
  ```
- **Tool — `send_email`**: argument `{ to: String, subject: String, body: String }` → chiama `GigiMailComposer.shared.present(...)`. Ritorna `"Email composed"` (l'utente conferma il tap "Send" nel composer iOS).
- **Tool — `send_telegram`**: argument `{ contact: String, text: String }`.
  - Risolvere `contact` → handle username via `GigiContactsProvider.usernameForTelegram(name: contact)` (helper esistente in GATE 9 o nuovo se assente — in tal caso fallback: passare contact letterale come username).
  - URL: `tg://msg?to=\(encodedHandle)&text=\(encodedText)` → `UIApplication.shared.open(url)`.
  - Se `canOpenURL` false → ritorna `"Telegram is not installed on this device"`.
- **Tool — `send_signal`**: argument `{ contact: String, text: String }`.
  - Risolvere `contact` → phone digits via `GigiContactsProvider.phoneE164(name: contact)`.
  - URL: `sgnl://send?phone=\(digits)` (Signal non supporta body precompilato — il `text` viene messo in pasteboard come fallback, comunicato all'utente).
  - Se `canOpenURL` false → `"Signal is not installed"`.

### Task 11.4 — Focus mode (1 tool, 2h)

- **File NUOVO**: `02_GIGI_APP/GIGI/GigiFocusController.swift` (~90 righe)
- **Pattern `INSetFocusFilterIntent`**:
  ```swift
  @available(iOS 26, *)
  @MainActor
  enum GigiFocusController {
      enum Mode: String {
          case dnd       = "Do Not Disturb"
          case work      = "Work"
          case sleep     = "Sleep"
          case personal  = "Personal"
      }
      static func activate(_ mode: Mode, durationMinutes: Int?) async throws {
          let intent = INSetFocusFilterIntent()
          intent.focusName = mode.rawValue
          if let m = durationMinutes {
              intent.endDate = Calendar.current.date(byAdding: .minute, value: m, to: .now)
          }
          let interaction = INInteraction(intent: intent, response: nil)
          try await interaction.donate()
          // Schedule via ShortcutsRunner or system Focus filter — see Apple docs
      }
  }
  ```
- **Tool — `set_focus_mode`**: argument `{ mode: String, durationMinutes: Int? }`.
  - Description: `"Activate iOS Focus mode (Do Not Disturb / Work / Sleep / Personal) optionally for a duration in minutes. Use when the user asks for quiet, focus, or no notifications."`.
  - Mappare `mode` lowercase → `GigiFocusController.Mode` (fallback `.dnd` se sconosciuto).
- **Entitlement check** in Task pre-cond: `plutil -p GIGI.entitlements | grep -i focus`. Se manca, aggiungere chiave Focus filter prima di compilare (vedi Apple docs `com.apple.developer.usernotifications.communication`).

### Task 11.5 — Aggiornare `GigiFallbackRouter.swift` con 9 nuove keyword entries

- **File**: `02_GIGI_APP/GIGI/GigiFallbackRouter.swift`
- Aggiungere alla `keywordTable`:
  ```swift
  "set_homekit_brightness": ["dim", "brightness", "brighter", "dimmer", "set light to"],
  "set_homekit_color":      ["color", "colour", "turn it red", "make it blue"],
  "set_homekit_thermostat": ["thermostat", "temperature to", "set heat", "set cool"],
  "get_location_now":       ["where am i", "my location", "current position"],
  "share_my_location":      ["share my location", "send my location to", "tell where i am"],
  "send_email":             ["email", "send an email", "compose email"],
  "send_telegram":          ["telegram", "send telegram", "tg"],
  "send_signal":            ["signal", "send signal"],
  "set_focus_mode":         ["focus", "do not disturb", "dnd", "quiet mode", "sleep mode"]
  ```

### Task 11.6 — `respondWithTools` registrazione + test grep

- **File**: `GigiFoundationToolRegistry.swift` `static let allTools` deve ora contenere 27 entries (18 da GATE 10 + 9 nuove).
- Smoke test grep:
  ```bash
  grep -c "let name = " "02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift"
  # Atteso: 27
  ```

---

## 4. Acceptance Criteria

- [ ] **AC-11.1** — `GigiHomeKitController.swift` esiste, conforme `HMHomeManagerDelegate`, espone `shared` singleton + `setBrightness`/`setColor`/`setThermostat` async throws.
- [ ] **AC-11.2** — `GigiHomeKitController.colorMap` ha almeno 9 entries (red, orange, yellow, green, cyan, blue, purple, pink, white).
- [ ] **AC-11.3** — 3 `Tool` struct HomeKit fine (`SetHomeKitBrightnessTool`, `SetHomeKitColorTool`, `SetHomeKitThermostatTool`) presenti in `GigiFoundationToolRegistry.swift`, tutte description inglese.
- [ ] **AC-11.4** — `GigiLocationProvider.swift` esiste, gestisce `notDetermined`/`denied`/`authorizedWhenInUse` con `currentLocation()` async throws + `cityName(for:)` async.
- [ ] **AC-11.5** — 2 `Tool` struct location (`GetLocationNowTool`, `ShareMyLocationTool`) presenti, description inglese, denied state → string `"Location denied. Enable in Settings..."`.
- [ ] **AC-11.6** — `Info.plist` contiene `NSLocationWhenInUseUsageDescription` con testo inglese non vuoto.
- [ ] **AC-11.7** — `GigiMailComposer.swift` esiste, `MFMailComposeViewControllerDelegate` conforming, `present(to:subject:body:)` async ritorna `Bool` (true = sent).
- [ ] **AC-11.8** — 3 `Tool` struct messaging (`SendEmailTool`, `SendTelegramTool`, `SendSignalTool`) presenti, `canOpenURL` check rispettato per Telegram/Signal.
- [ ] **AC-11.9** — `LSApplicationQueriesSchemes` in `Info.plist` contiene `tg`, `sgnl`, `mailto`.
- [ ] **AC-11.10** — `GigiFocusController.swift` esiste, enum `Mode` con 4 cases, `activate(_:durationMinutes:)` async throws via `INSetFocusFilterIntent`.
- [ ] **AC-11.11** — `SetFocusModeTool` presente, description menziona "Do Not Disturb / Work / Sleep / Personal".
- [ ] **AC-11.12** — `GIGI.entitlements` contiene Focus entitlement.
- [ ] **AC-11.13** — `GigiFallbackRouter.keywordTable` ha 9 nuove entries (set_homekit_brightness, set_homekit_color, set_homekit_thermostat, get_location_now, share_my_location, send_email, send_telegram, send_signal, set_focus_mode).
- [ ] **AC-11.14** — `GigiFoundationToolRegistry.allTools` count == 27 (verificabile via grep `let name = `).
- [ ] **AC-11.15** — Build verify: `xcodebuild` BUILD SUCCEEDED su iPhone 15 Pro+ scheme.
- [ ] **AC-11.16** — Tutte le tool description e `@Guide` description sono in inglese (regola CLAUDE.md, no italiano user-facing).

---

## 5. Test E2E sul telefono (verificabili dall'utente)

Tutti i test su iPhone 15 Pro+ fisico con Apple Intelligence on. Se device non-Apple-FM, ripetere via `GigiFallbackRouter`.

- **E2E-11.1** — *"Set the bedroom light brightness to 50 percent"*
  Atteso: Apple FM invoca `SetHomeKitBrightnessTool{accessory:"bedroom light", level:50}` → HomeKit accessory dims al 50% → speech `"Brightness set to 50%"`.

- **E2E-11.2** — *"Turn the kitchen light blue"*
  Atteso: `SetHomeKitColorTool{accessory:"kitchen", color:"blue"}` → HSB write (hue 240, sat 100) → luce blu.

- **E2E-11.3** — *"Set the thermostat to 21 degrees"*
  Atteso: `SetHomeKitThermostatTool{accessory:"thermostat", temp_c:21}` → HomeKit target temperature 21°C.

- **E2E-11.4** — *"Where am I?"*
  Atteso (prima volta): permission alert "Allow GIGI to access location While Using". Accept → `GetLocationNowTool` ritorna `"You are in Bologna at 44.49, 11.34"`.

- **E2E-11.5** — *"Share my location with Marco for 1 hour"*
  Atteso: `ShareMyLocationTool{contact:"Marco", duration:"1 hour"}` → Messages compose si apre con contatto Marco precompilato + URL maps.apple.com.

- **E2E-11.6** — *"Send an email to alice@example.com with subject 'Meeting' and body 'Let's sync tomorrow'"*
  Atteso: `SendEmailTool` apre `MFMailComposeViewController` con campi precompilati. Utente conferma "Send" → email partita.

- **E2E-11.7** — *"Send a Telegram message to Federico saying I'm running late"*
  Atteso: `SendTelegramTool` → Telegram app si apre con chat Federico + body precompilato. Se Telegram non installato: speech `"Telegram is not installed on this device"`.

- **E2E-11.8** — *"Send a Signal message to Sara saying hi"*
  Atteso: `SendSignalTool` → Signal app si apre con conversazione Sara. Body Signal non precompila → pasteboard contiene testo + alert "Pasted, paste manually".

- **E2E-11.9** — *"Enable Do Not Disturb for one hour"*
  Atteso: `SetFocusModeTool{mode:"dnd", durationMinutes:60}` → Focus DND attivato per 60 min, status bar mostra crescent moon icon.

- **E2E-11.10 (fallback)** — Disattivare Apple Intelligence in iOS Settings → pronunciare *"Dim the living room light to 30 percent"*.
  Atteso: `GigiFallbackRouter` keyword match `"dim" → set_homekit_brightness`, slot extraction `{accessory:"living room", level:30}`, dispatch corretto.

---

## 6. Test post-creazione (verifica autonoma)

### 6.1 Verifica via grep

```bash
ROOT="C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/02_GIGI_APP/GIGI"

# 1. 27 tool struct totali (18 pre-GATE-11 + 9 nuovi)
grep -c "let name = " "$ROOT/GigiFoundationToolRegistry.swift"
# Atteso: 27

# 2. 9 nuovi tool nominali esistono
for t in set_homekit_brightness set_homekit_color set_homekit_thermostat \
         get_location_now share_my_location \
         send_email send_telegram send_signal set_focus_mode; do
  count=$(grep -c "let name = \"$t\"" "$ROOT/GigiFoundationToolRegistry.swift")
  echo "$t: $count"
done
# Atteso: tutte 1

# 3. 4 file controller nuovi esistono
ls "$ROOT/GigiHomeKitController.swift" "$ROOT/GigiLocationProvider.swift" \
   "$ROOT/GigiMailComposer.swift" "$ROOT/GigiFocusController.swift"
# Atteso: 4 file presenti

# 4. Info.plist ha NSLocationWhenInUseUsageDescription
plutil -p "02_GIGI_APP/GIGI/Info.plist" | grep -i "NSLocationWhenInUseUsageDescription"
# Atteso: 1 match con testo inglese

# 5. Info.plist LSApplicationQueriesSchemes include tg, sgnl, mailto
plutil -p "02_GIGI_APP/GIGI/Info.plist" | grep -E "tg|sgnl|mailto"
# Atteso: 3+ match

# 6. GigiFallbackRouter ha 9 nuove keyword entries
grep -E "\"set_homekit_brightness\"|\"set_homekit_color\"|\"set_homekit_thermostat\"|\"get_location_now\"|\"share_my_location\"|\"send_email\"|\"send_telegram\"|\"send_signal\"|\"set_focus_mode\"" "$ROOT/GigiFallbackRouter.swift" | wc -l
# Atteso: >=9

# 7. Entitlement Focus
plutil -p "02_GIGI_APP/GIGI/GIGI.entitlements" | grep -i "focus\|com.apple.developer.usernotifications.communication"
# Atteso: 1+ match
```

### 6.2 Verifica via xcodebuild

```bash
ssh user297422@FF125.macincloud.com "cd ~/GIGI-armando-rework/02_GIGI_APP && /usr/bin/xcodebuild -scheme GIGI -destination 'generic/platform=iOS' build 2>&1 | grep -E 'BUILD SUCCEEDED|BUILD FAILED|error:'"
# Atteso: BUILD SUCCEEDED, zero error:
```

### 6.3 Verifica runtime su device

Re-eseguire le 10 E2E sopra (o subset random di 5) e verificare via Console.app log `tool_invoked: <name>` per ognuno.

---

## 7. Rollback plan

Se HomeKit/Location/Focus tool si rivelano instabili in produzione:

```bash
cd "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework"
git revert <SHA-gate-11>
```

Alternative meno destructive:
- **Feature flag granulare** in `GigiRequestRouter`:
  - `gigi.feature.week3_homekit_fine: bool` default true
  - `gigi.feature.week3_location: bool` default true
  - `gigi.feature.week3_messaging: bool` default true
  - `gigi.feature.week3_focus: bool` default true
- Quando false, il tool corrispondente è rimosso da `allTools` dynamic + `GigiFallbackRouter` skippa la keyword → routing cade su `delegate_to_claude`.
- Permette toggle runtime per category senza revert.

Side effects:
- `NSLocationWhenInUseUsageDescription` aggiunto in `Info.plist`: rimovibile, ma se ci sono già autorizzazioni concesse, gli utenti non perdono permission (iOS le persiste).
- Focus entitlement aggiunto: rimovibile, nessuna persistenza utente.
- UserDefaults: nessuna nuova chiave introdotta.

---

## 8. Files modificati / creati

| Path | Operazione | Righe stimate |
|---|---|---|
| `02_GIGI_APP/GIGI/GigiHomeKitController.swift` | CREATE | ~180 |
| `02_GIGI_APP/GIGI/GigiLocationProvider.swift` | CREATE | ~120 |
| `02_GIGI_APP/GIGI/GigiMailComposer.swift` | CREATE | ~80 |
| `02_GIGI_APP/GIGI/GigiFocusController.swift` | CREATE | ~90 |
| `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` | MODIFY (+9 Tool struct, allTools array) | +220 |
| `02_GIGI_APP/GIGI/GigiFallbackRouter.swift` | MODIFY (keywordTable +9 entries) | +12 |
| `02_GIGI_APP/GIGI/Info.plist` | MODIFY (NSLocationWhenInUseUsageDescription, LSApplicationQueriesSchemes) | +12 |
| `02_GIGI_APP/GIGI/GIGI.entitlements` | MODIFY (Focus entitlement if missing) | +4 |
| `docs/research/gate-11-homekit-inventory.md` | CREATE (test lab setup doc) | ~30 |
| `docs/research/gate-11-tool-coverage.md` | CREATE (E2E results) | ~50 |

---

## 9. ADR collegati

- **ADR-0008** (Apple FM Tool calling vs scored registry) — questo GATE estende il registry da 18 a 27 tool. Status resta Accepted.
- **ADR-0010** (proposed — "HomeKit + Location + Focus capability boundary"): documenta perché GIGI integra HomeKit con singleton condiviso vs creare HMHomeManager nuovo per call (lifecycle + discovery cost), perché location è single-shot vs continuous monitoring (privacy + battery), perché Focus passa via `INSetFocusFilterIntent` vs `UNNotificationCenter` direct. Da creare in questo GATE come `docs/adr/0010-homekit-location-focus-boundary.md`.
- ADR-0009 (Hardware targets and modes) — `GigiFallbackRouter` aggiornato con 9 nuove keyword entries, riferimento all'implementazione.

---

## 10. Note operative

- **Branch**: `feat/gate-11-capability-week3`
- **Worktree**: `$CLAUDE_PROJECT_DIR/../GIGI-work/issue-gate-11-capability-week3`
- **HomeKit privacy**: la prima volta che l'app chiama `HMHomeManager`, iOS presenta permission "Allow GIGI to access your home". Il tester deve accettare. Se rifiuta: `manager.primaryHome` resta nil e i tool ritornano `"HomeKit access denied"`.
- **Telegram/Signal contact resolution**: ipotizza che `GigiContactsProvider` (da GATE 9/10) esponga `usernameForTelegram(name:)` e `phoneE164(name:)`. Se queste helper non esistono ancora, primo step del GATE 11.C è aggiungerle in `GigiContactsProvider.swift` (~30 righe extra, scope minimo).
- **MFMailComposeViewController su simulator**: non funziona (no Mail account). Tester deve usare device fisico con almeno 1 Mail account configurato.
- **Focus entitlement provisioning**: se l'entitlement Focus richiede approval Apple Developer Portal, processo può richiedere 1-2 giorni. Pianificare in anticipo. In caso di mancanza, GATE 11.D è bloccato e va spostato in GATE 11+ (post-fix).
- **Conventional Commits suggeriti**:
  ```
  feat(ios): GATE 11.1 — GigiHomeKitController + 3 fine-control tools (brightness/color/thermostat)
  feat(ios): GATE 11.2 — GigiLocationProvider + get_location_now / share_my_location tools
  feat(ios): GATE 11.3 — GigiMailComposer + send_email / send_telegram / send_signal tools
  feat(ios): GATE 11.4 — GigiFocusController + set_focus_mode tool via INSetFocusFilterIntent
  feat(ios): GATE 11.5 — GigiFallbackRouter keyword table updated for 9 new Week 3 tools
  chore(ios): GATE 11 — Info.plist + entitlements for location/Focus/queries-schemes
  test(ios): GATE 11.6 — tool coverage results for Week 3 (Ambient & Social)
  ```

### GATE intermedi (gating checkpoint)

Il GATE 11 è suddiviso in 4 sub-gate sequenziali. Ogni sub-gate è un commit indipendente + verifica lab prima di passare al successivo.

- **GATE 11.A — HomeKit brightness/color/thermostat shipped + lab test** (Task 11.1)
  - AC chiusi: AC-11.1, AC-11.2, AC-11.3, AC-11.14 (parziale, count = 21)
  - Lab test: E2E-11.1, E2E-11.2, E2E-11.3 PASS su device con HomeKit accessory configurati
  - Solo dopo PASS → procedere a GATE 11.B

- **GATE 11.B — Location tools shipped** (Task 11.2)
  - AC chiusi: AC-11.4, AC-11.5, AC-11.6, AC-11.14 (parziale, count = 23)
  - Lab test: E2E-11.4, E2E-11.5 PASS, permission flow verificato
  - Solo dopo PASS → procedere a GATE 11.C

- **GATE 11.C — Email/Telegram/Signal deep links shipped** (Task 11.3)
  - AC chiusi: AC-11.7, AC-11.8, AC-11.9, AC-11.14 (parziale, count = 26)
  - Lab test: E2E-11.6, E2E-11.7, E2E-11.8 PASS (con Telegram + Signal installati sul device)
  - Solo dopo PASS → procedere a GATE 11.D

- **GATE 11.D — Focus mode shipped** (Task 11.4)
  - AC chiusi: AC-11.10, AC-11.11, AC-11.12, AC-11.14 (final, count = 27), AC-11.15, AC-11.16
  - Lab test: E2E-11.9 PASS (status bar mostra Focus icon)
  - Tutti i 27 tool funzionano in `allTools` array → GATE 11 chiuso, merge in main

### Cosa fare se un tool specifico fallisce

Esempio: `SetHomeKitColorTool` non cambia colore della luce.

1. Verificare in Home app che l'accessory supporti effettivamente Hue/Saturation (non tutte le luci dimmable hanno color HSB).
2. Loggare 5+ tentativi reali in `docs/research/gate-11-tool-coverage.md` con accessory name + color requested + outcome.
3. Esaminare se è problema di:
   - **Accessory matching** (fuzzy `name.contains` troppo permissivo) → restringere a `==` lowercase
   - **Service type discovery** (`HMServiceTypeLightbulb` non trovato) → loggare `accessory.services.map{$0.serviceType}`
   - **Characteristic write** (timeout, permission HomeKit denied) → loggare errore `try await ch.writeValue`
4. Se problema cronico per categoria: aggiungere alert nel tool result `"This light doesn't support color. Use brightness instead."` invece di silent fail.

### Cosa fare se 27 tool sfora context budget Apple FM

Se `respondWithTools(tools: allTools)` ritorna `.exceededContextWindowSize`:
1. Implementare **subset selection upfront** già pianificato in GATE 3 §"Context budget" nel `GigiRequestRouter`: passare solo i 3-5 tool più rilevanti per la query corrente in base al `primaryAction` pre-classificato dal router.
2. Latency +1s ma context resta sotto 4096 token.
3. Alternative: ridurre verbosity di description (target ≤60 token per tool invece di 80).
