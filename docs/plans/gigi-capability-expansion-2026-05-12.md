# GIGI Capability Expansion — Apple FM Tools + Discovery UX

**Author:** Armando Battaglino (PM) · planned via Claude `/plan` direct mode
**Date:** 2026-05-12
**Scope:** Post-MVP (week 1-4 dopo lancio 1 maggio 2026)
**Status:** Draft for review
**Related:**
  - `docs/adr/0008-apple-fm-tool-calling-vs-scored-registry.md` (current tool architecture)
  - `docs/adr/0007-hybrid-5-path-router.md` (router decision flow)
  - `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` (real impl pattern)
  - `02_GIGI_APP/GIGI/GIGI.entitlements` (already grants HomeKit, Siri, iCloud, App Groups)

---

## 1. Requirements Summary

Espandere le capability di GIGI da **17 tool attuali** a **~60 tool** coprendo
sistematicamente ogni dominio di vita digitale dell'utente iOS. Costruire
contemporaneamente un **meccanismo di scoperta** così l'utente sa cosa GIGI
sa fare (oggi è opaco — l'utente deve "indovinare" i comandi).

**Constraints**:
- Solo tool implementabili con **API iOS pubbliche** (no private API, no
  rejection App Store).
- Ogni nuovo tool deve passare per il pattern esistente in
  `GigiFoundationToolRegistry.swift` (Apple FM `Tool` protocol + `@Generable`
  Arguments + `@Guide` annotation).
- Dispatch sempre via `GigiActionBridge.execute(intent:)` — no logica di
  business dentro il tool, solo translation layer.
- Non rompere la decision logic del router (`GigiRequestRouter`): aggiungere
  tool **non** deve degradare la latenza p99 di Apple FM constrained decoding
  oltre +50ms per ogni 10 tool aggiunti.

**Non-goals**:
- VoIP entitlement / CallKit / `tel://` popup bypass — chiusi come iOS
  limit accettato (vedi research bug-006 in questa sessione).
- Apple Watch / visionOS / iPad specific tool — pure iPhone iOS 26 per ora.
- Mac / Windows / Android — fuori scope.

---

## 2. Guiding Principles

1. **Description quality > tool count.** Un tool con `description` ambigua
   peggiora la qualità del router più di 10 tool ben descritti. Ogni
   description segue il pattern: *"<azione>. Use when <trigger>. NOT for
   <controesempio>."*
2. **Capability-first, UI-second.** Prima sblocchiamo la capability lato
   tool, poi mostriamo come scoprirla. Mai aggiungere tool che non possiamo
   *insegnare* all'utente.
3. **Native iOS frameworks first.** EventKit, HomeKit, WeatherKit, CoreLocation,
   UIPasteboard, MusicKit. Web fallback (`web_search`, `web_order_food`) solo
   per gap che iOS non copre.
4. **One meta-tool to rule them all.** `run_shortcut` come escape hatch
   universale per qualsiasi cosa l'utente sa già costruire in Shortcuts —
   estendibilità infinita senza nostro coding.
5. **Discovery deve essere conversational.** L'utente chiede *"cosa sai
   fare?"* o *"come ti dico di X?"* e GIGI risponde con esempi rilevanti
   al contesto. No menu statico di 60 voci.

---

## 3. Top 3 Decision Drivers

1. **Tempo dev**: 1 dev (Armando) part-time post-MVP, ~10-15h/settimana sul
   capability expansion. Determina ordering e batch size.
2. **Latenza router**: ogni tool aggiunto va nel system prompt di Apple FM.
   60 tool descriptions = ~3-4 KB di prompt = ~150ms extra in constrained
   decoding. Trade-off vs. capability coverage.
3. **Discovery UX**: senza meccanismo di scoperta, il 90% dei tool resta
   inutilizzato (cf. Alexa skills marketplace, dove top-5 skill coprono
   80% dell'uso). Discovery è priorità ≥ del singolo tool.

---

## 4. Tassonomia Completa — 7 Categorie + ~60 Tool

Ogni categoria ha: descrizione, casi d'uso utente, framework iOS, lista tool.

### 4.1 SISTEMA & DISPOSITIVO (7 tool — domain: device state)

Stato del dispositivo, settings system-wide, info hardware.

| Tool | Description (preview) | Framework | Args | Complessità | Valore |
|---|---|---|---|---|---|
| `get_device_battery` | Read battery level + charging state. | `UIDevice` | none | S | 🟢🟢 |
| `set_focus_mode` | Activate Focus mode (DND/Work/Sleep) for a duration. | `INSetFocusFilterIntent` | mode, duration_minutes | M | 🟢🟢🟢 |
| `get_focus_mode_status` | Read which Focus is currently active. | `INFocusStatusCenter` | none | S | 🟢 |
| `set_volume` | Change media/ringer/call volume. | `AVAudioSession` + `MPVolumeView` | level (0-100), target | M | 🟢🟢 |
| `toggle_flashlight` | Turn the flashlight on/off. | `AVCaptureDevice.torchMode` | on (bool) | S | 🟢🟢 |
| `take_screenshot` | Capture the current screen to Photos. | `UIScreen.snapshotView` (limited) — fallback to Shortcut | photo_target | M | 🟢🟢 |
| `read_clipboard` | Read clipboard text and read it back. | `UIPasteboard.general.string` | none | S | 🟢🟢 |

### 4.2 SOCIAL & COMUNICAZIONE (8 tool — domain: contacts + messaging)

Estensione del set esistente `send_message`, `make_call`, `facetime`.

| Tool | Description | Framework | Args | Complessità | Valore |
|---|---|---|---|---|---|
| `send_email` | Compose + send an email draft. | `MFMailComposeViewController` | to, subject, body | M | 🟢🟢🟢 |
| `read_email_unread_count` | Tell how many unread emails are in primary inbox. | EventKit Mail (limited) → Mail Shortcut fallback | inbox | M | 🟢🟢 |
| `read_messages_unread_count` | Tell how many unread iMessage threads. | Shortcut bridge | none | M | 🟢🟢 |
| `send_telegram` | Send a Telegram message via deep link. | `tg://msg?to=X&text=Y` | contact, text | S | 🟢🟢 |
| `send_signal` | Send a Signal message via deep link. | `sgnl://send?phone=X` | contact, text | S | 🟢 |
| `share_contact_card` | Share a contact via system share sheet. | `CNContactViewController` | name | M | 🟢🟢 |
| `find_contact_info` | Look up phone/email/address of a contact. | `CNContactStore` | name, field | S | 🟢🟢🟢 |
| `block_number` | Add a number to system call-block list (iOS 13+). | `CallDirectoryExtension` + `CXCallDirectoryManager` | phone | L | 🟢 |

### 4.3 PRODUTTIVITÀ (10 tool — domain: agenda/notes/files)

Calendar, reminder, note, file system, document scanner.

| Tool | Description | Framework | Args | Complessità | Valore |
|---|---|---|---|---|---|
| `create_calendar_event` | Create a calendar event with title, time, attendees. | `EventKit.EKEventStore.save` | title, start, end, location, attendees, notes | M | 🟢🟢🟢 |
| `move_calendar_event` | Reschedule an existing event to a new time. | EventKit | event_id, new_start, new_end | M | 🟢🟢 |
| `cancel_calendar_event` | Delete a calendar event after confirmation. | EventKit `remove` | event_id | M | 🟢🟢 |
| `add_to_note` | Append text to an existing note by title. | Shortcut bridge → Notes app | note_title, content, position | M | 🟢🟢🟢 |
| `create_note_with_tag` | Create a tagged note (folder + title). | `create_note` + Shortcut for tag/folder | folder, title, body, tags | M | 🟢🟢 |
| `search_notes` | Search notes for a query string. | Shortcut bridge "Find Notes" | query | M | 🟢🟢 |
| `complete_reminder` | Mark a reminder as completed. | `EKReminder.isCompleted = true` | reminder_id_or_title | S | 🟢🟢 |
| `scan_document` | Open document scanner (VisionKit). | `VNDocumentCameraViewController` | save_to | M | 🟢🟢 |
| `read_pdf_aloud` | Read aloud a PDF the user just opened. | `AVSpeechSynthesizer` + `PDFKit` | path | L | 🟢 |
| `save_to_files` | Save a piece of text or URL to iCloud Files. | `FileManager` + iCloud container | name, content, folder | M | 🟢 |

### 4.4 INTRATTENIMENTO & MEDIA (6 tool — domain: music/podcast/video)

Estende `play_music` con controlli specifici.

| Tool | Description | Framework | Args | Complessità | Valore |
|---|---|---|---|---|---|
| `play_podcast` | Start a podcast episode by show name. | `MPMusicPlayerController` (Podcasts) | show, episode | M | 🟢🟢 |
| `skip_track` | Skip current track forward/back. | `MPRemoteCommandCenter` | direction | S | 🟢🟢 |
| `set_playlist` | Switch to a specific playlist. | MusicKit | playlist_name | M | 🟢🟢 |
| `like_current_track` | Add current track to Library. | MusicKit `addToLibrary` | none | S | 🟢 |
| `read_now_playing` | Tell what's currently playing. | `MPMusicPlayerController.nowPlayingItem` | none | S | 🟢🟢 |
| `play_radio_station` | Tune Apple Music radio or station. | MusicKit | station_name | M | 🟢 |

### 4.5 AMBIENTE & SMART HOME (8 tool — domain: HomeKit + location)

Estende `homekit_on`/`homekit_off` con controllo fine.

| Tool | Description | Framework | Args | Complessità | Valore |
|---|---|---|---|---|---|
| `set_homekit_scene` | Activate a HomeKit scene by name. | `HMHomeManager` + `HMActionSet` | scene_name | M | 🟢🟢🟢 |
| `set_homekit_brightness` | Set light brightness 0-100. | HomeKit `HMCharacteristic.Brightness` | accessory, level | M | 🟢🟢 |
| `set_homekit_color` | Set light color (hue/sat). | HomeKit `HMCharacteristic.Hue/Saturation` | accessory, color_name | M | 🟢 |
| `set_homekit_thermostat` | Set thermostat target temperature. | HomeKit `HMCharacteristic.TargetTemp` | accessory, temp_c | M | 🟢🟢 |
| `read_homekit_sensor` | Read a HomeKit sensor (temp/humidity/motion). | HomeKit Characteristic read | accessory, sensor_type | M | 🟢🟢 |
| `get_location_now` | Get current geographic location (city + coords). | `CLLocationManager` single-shot | none | S | 🟢🟢🟢 |
| `share_my_location` | Share current location with a contact. | `MFMessageComposeViewController` with map URL | contact, duration | M | 🟢🟢 |
| `set_geofence_reminder` | Trigger a reminder when arriving/leaving a place. | EventKit `EKLocationStructuredLocation` | place, action, message | L | 🟢🟢 |

### 4.6 CONOSCENZA & WEB (6 tool — domain: info retrieval)

Risposta a query fattuali — l'unico dominio dove il `delegate_cloud` Claude
fallback resta cruciale.

| Tool | Description | Framework | Args | Complessità | Valore |
|---|---|---|---|---|---|
| `web_search` | Open Safari with a DuckDuckGo/Google query. | `UIApplication.open` | query | S | 🟢🟢 |
| `web_search_inline` | Fetch top result snippet inline (no Safari). | URLSession to SearXNG/DDG instant answer | query | M | 🟢🟢🟢 |
| `define_word` | Read a dictionary definition aloud. | `UIReferenceLibraryViewController` (system) | word, language | S | 🟢🟢 |
| `translate_text` | Translate text between two languages. | Translation framework iOS 18+ | text, from, to | M | 🟢🟢🟢 |
| `get_news_headlines` | Read top news headlines for a topic. | News app Shortcut bridge | topic | M | 🟢 |
| `calculate_math` | Evaluate a math expression. | `NSExpression` | expression | S | 🟢🟢 |

### 4.7 AUTOMAZIONE & META (5 tool — domain: extensibility)

Strumenti che rendono GIGI **estendibile dall'utente** senza il nostro coding.

| Tool | Description | Framework | Args | Complessità | Valore |
|---|---|---|---|---|---|
| `run_shortcut` ⭐ | Run any pre-installed Shortcut by name with optional input. | `shortcuts://x-callback-url/run-shortcut` | name, input | S | 🟢🟢🟢🟢 |
| `list_shortcuts` | Tell the user which Shortcuts are installed. | Shortcuts app: `My Shortcuts` URL | filter | M | 🟢🟢 |
| `set_automation` | Suggest a Personal Automation setup (cannot create programmatically). | UI hint + tutorial | trigger, action | M | 🟢 |
| `repeat_last_action` | Re-execute the last tool call (e.g. "call him again"). | In-memory action log | none | S | 🟢🟢 |
| `undo_last_action` | Undo a reversible action (delete reminder, cancel event). | per-action `inverse(intent:)` hook | none | M | 🟢🟢 |

**Special: `discover_capabilities`** — non un tool eseguibile, ma un
**intent speciale** intercettato dal router quando l'utente chiede
*"cosa sai fare?"* / *"what can you do?"* / *"aiuto"*. Vedi §5 Discovery.

---

## 5. Discovery — Come l'Utente Sa Cosa GIGI Sa Fare

Tre layer complementari (non alternativi). Tutti sono on-device, nessun
server-side.

### 5.1 Layer A — Onboarding Conversational (one-shot)

Alla prima apertura post-pairing, GIGI fa **un tour conversazionale di 3 step**:

1. *"Hi, I'm GIGI. Try saying 'set a timer for 5 minutes' to see how I work."*
   → user prova, GIGI esegue → micro-celebration *"There you go!"*.
2. *"I can also help with calendar, contacts, smart home, and more. Want a quick tour?"*
   → se sì → GIGI elenca 3 capability categories con 1 esempio ciascuna.
3. *"Whenever you're not sure, just ask 'what can you do?' or 'how do I X?'"*
   → setup completo.

Impl: `GigiOnboardingFlow.swift` (nuovo file), trigger: `UserDefaults flag`
`onboarding_completed_v2`. Skip se utente ha già usato GIGI ≥5 turni.

### 5.2 Layer B — Conversational Discovery (always-available)

L'utente in qualsiasi momento può chiedere:

- *"What can you do?"* / *"Cosa sai fare?"* → GIGI risponde con la **top-3
  categories rilevante per il contesto** (es. ora del giorno, location,
  recent activity). Esempio mattina: *"I can read your calendar for today, set
  reminders, control your HomeKit. Want me to show more?"*
- *"How do I X?"* → GIGI trova il tool più rilevante per X via Apple FM
  semantic match, e risponde con un **esempio di frase** da usare. Es.
  *"How do I send a Telegram message?"* → *"Just say: 'send a Telegram to
  Marco saying I'll be late.'"*
- *"What else can you do with [calendar/HomeKit/etc.]?"* → enumera i tool
  della categoria con 1 esempio ciascuno.

Impl: **`discover_capabilities` pseudo-tool** intercettato in
`GigiRequestRouter` PRIMA del tool calling normale. Lookup table:
`tool_name → user_facing_example_phrase` (popolata da `description` di ogni
tool + 1 esempio canonico curato). File: `GigiCapabilityCatalog.swift`.

### 5.3 Layer C — UI Discovery (passive, in-app)

**Capability Sheet** accessibile dal Dashboard (tab in fondo, già esistente):

- 7 categorie collassabili (sistema, social, produttività, intrattenimento,
  ambiente, conoscenza, automazione)
- Ogni categoria: lista tool con **frase esempio** (es. *"Set Focus mode"* →
  esempio *"Activate Work Focus for 1 hour"*)
- Tap su un esempio → copia frase in chat + invia automaticamente (instant
  try)
- Indicatore **"recently used"** sui tool che hai usato negli ultimi 7gg
- Indicatore **"not yet tried"** sui tool nuovi → invoglia esplorazione

Impl: `CapabilitySheetView.swift` (SwiftUI), data source
`GigiCapabilityCatalog`. Aggiornamento real-time via `@Published`.

### 5.4 Layer D — Proactive Suggestions (opt-in, post-MVP+2)

GIGI **suggerisce capability rilevanti** in base al contesto:

- Mattina alle 8: *"Want me to read your calendar for today?"* (Dashboard banner)
- Dopo `make_call` fallito (popup iOS): *"Tip: you can also Telegram or Email \(name)."*
- Dopo 3 timer in 1 giorno: *"Did you know I can also set recurring reminders?"*

Tutti dismissibili. Impl: `GigiSuggestionEngine.swift`, trigger ogni `process(text:)`.

---

## 6. Implementation Phases — Post-MVP Roadmap

Ordering by **value/effort ratio** + dependency.

### 🚀 Week 1 (post-launch, ~12h): "Power user unlock"

3 tool ad altissimo valore + Layer A onboarding.

| Item | Effort | Files |
|---|---|---|
| `run_shortcut` (meta-tool universal) | 3h | `GigiFoundationToolRegistry.swift` + `GigiActionBridge.swift` |
| `set_homekit_scene` (entitlement già presente) | 4h | New `GigiHomeKitEngine.swift` + tool wrapper |
| `web_search` (Safari open) | 1h | Tool wrapper only |
| Onboarding flow (Layer A) | 4h | New `GigiOnboardingFlow.swift` + `OnboardingView.swift` |

**AC Week 1**: utente può dire *"esegui modo lavoro"* (Shortcut), *"accendi scena cinema"* (HomeKit), *"cerca su web ricette pasta"* (Safari). Onboarding mostra primo tour ai nuovi utenti.

### 🛠️ Week 2 (~14h): "Productivity boost"

Calendar/note/clipboard — coverage di workflow tipici.

| Item | Effort | Files |
|---|---|---|
| `create_calendar_event` | 4h | EventKit integration + tool |
| `add_to_note` (via Shortcut bridge) | 2h | Shortcut creation guide + tool |
| `read_clipboard` + `get_device_battery` + `toggle_flashlight` | 2h | Tool wrappers |
| `define_word` + `calculate_math` + `translate_text` | 4h | UIReferenceLibrary + NSExpression + Translation framework |
| Layer B conversational discovery | 4h | `GigiCapabilityCatalog.swift` + router intercept |

**AC Week 2**: utente può creare eventi, aggiungere note, leggere clipboard, tradurre. *"What can you do?"* funziona conversazionalmente con risposta context-aware.

### 🏠 Week 3 (~14h): "Ambient & social"

HomeKit avanzato, location, social messaging.

| Item | Effort | Files |
|---|---|---|
| `set_homekit_brightness/color/thermostat` | 5h | HomeKit Characteristic write |
| `get_location_now` + `share_my_location` | 3h | CoreLocation + share sheet |
| `send_email` + `send_telegram` + `send_signal` | 4h | URL schemes + MFMail |
| `set_focus_mode` | 2h | INSetFocusFilterIntent |

**AC Week 3**: utente può comandare luci/clima dettagliato, condividere posizione, mandare email/Telegram/Signal.

### 🌐 Week 4 (~14h): "Knowledge & meta"

Web search inline, news, document scanning, undo/repeat.

| Item | Effort | Files |
|---|---|---|
| `web_search_inline` (URLSession + DDG/SearXNG) | 4h | New `GigiWebFetchService.swift` |
| `scan_document` (VisionKit) | 3h | VNDocumentCameraViewController |
| `get_news_headlines` (via Shortcut bridge) | 2h | Tool wrapper |
| `repeat_last_action` + `undo_last_action` | 3h | Action log + inverse intent hook |
| Layer C Capability Sheet (UI) | 2h | `CapabilitySheetView.swift` (SwiftUI) |

**AC Week 4**: utente può cercare info inline (senza aprire Safari), scannerizzare documenti, ripetere/annullare azioni. Dashboard mostra capability sheet con esempi tappabili.

### 💡 Week 5+ (post-base): "Long tail + Proactive"

Tutti i tool rimanenti del catalogo (~30) + Layer D proactive suggestions.
Implementazione **a richiesta** — non tutti hanno alto ROI per ogni utente.

---

## 7. ADR Proposal — Tool Taxonomy + Discovery UX

**Title**: ADR-0010 — Capability Taxonomy + Discovery Mechanism for Apple FM Tools

**Status**: Proposed (this plan)

**Context**:
GIGI ha 17 tool ma manca: (a) sistematizzazione per crescere a 60+, (b)
meccanismo di scoperta. L'utente non sa cosa l'app sa fare.

**Decision**:
- Adottare **7-category taxonomy** (sistema, social, produttività,
  intrattenimento, ambiente, conoscenza, automazione) come struttura
  organizzativa di `GigiFoundationToolRegistry` (raggruppare i tool per
  category, non più flat list).
- **3-layer discovery**: Onboarding (1x), Conversational (always),
  UI Sheet (passive). Layer D proactive opt-in più avanti.
- **Pseudo-tool `discover_capabilities`** intercettato dal router PRIMA
  del tool calling normale, risponde con suggerimenti context-aware.
- **`run_shortcut` come meta-tool** — escape hatch universale per
  capability che non vogliamo coding-ifare.

**Alternatives considered**:
- *Flat tool list*: peggiore per discovery (utente vede 60 nomi opachi).
- *Pre-defined menu UI only*: non scalabile, perde la conversational nature
  di GIGI.
- *Cloud-based capability list*: aggiunge dipendenza da harness, peggiora
  latenza e privacy.

**Consequences**:
- ✅ Capability expansion scalabile linearmente.
- ✅ Utenti scoprono feature senza tutorial pesante.
- ⚠️ System prompt cresce (~150ms latency per +30 tool) — mitigabile con
  prompt compression o tool subsetting per categoria.
- ⚠️ Manutenzione catalog: ogni nuovo tool va aggiunto a `GigiCapabilityCatalog.swift`
  in modo coerente (campo `category`, `userExample`, `discoveryHint`).

**Follow-ups**:
- Telemetry su quali tool sono effettivamente usati (anonimo, opt-in).
- A/B test discovery layer A vs no-onboarding sui beta tester.
- Eventuale tool subsetting dinamico se latenza diventa problema.

---

## 8. Acceptance Criteria (testabili)

### Per-tool (applicato a ogni nuovo tool)
- [ ] **AC-T1**: Tool registrato in `GigiFoundationToolRegistry.allTools` E in `canonicalActions`.
- [ ] **AC-T2**: `description` segue pattern *"<action>. Use when <trigger>. NOT for <controesempio>."*
- [ ] **AC-T3**: Almeno 1 `@Guide` su ogni argument con esempio concreto.
- [ ] **AC-T4**: Unit test in `GigiFoundationToolRegistryTests.swift` che verifica: (a) tool resolva da `tool(for:)`, (b) `call(arguments:)` dispatch sull'intent corretto in `GigiActionBridge`.
- [ ] **AC-T5**: E2E test pronunciabile sull'iPhone fisico (1 frase di esempio nel commit message).
- [ ] **AC-T6**: Aggiunto a `GigiCapabilityCatalog.swift` con `category`, `userExample`, `discoveryHint`.

### Per-discovery layer
- [ ] **AC-D1 (Onboarding)**: Nuovo utente vede tour 3-step alla prima apertura. Skip se ≥5 turn già fatti.
- [ ] **AC-D2 (Conversational)**: *"What can you do?"* / *"Cosa sai fare?"* triggera `discover_capabilities` invece di routing normale. Risposta cita ≥3 capability rilevanti al contesto temporale (mattina/sera) e location (casa/fuori).
- [ ] **AC-D3 (UI Sheet)**: Dashboard tab "Capabilities" mostra 7 categorie, tap su esempio invia frase in chat. Indicatore "recently used" e "not yet tried" funzionanti.
- [ ] **AC-D4 (Proactive)**: Suggestion engine emette ≥1 suggestion/giorno rilevante, dismissibile.

### Per-rollout phase
- [ ] **AC-P1 (Week 1)**: 3 tool nuovi + onboarding shippati. Beta tester confermano: *"esegui modo lavoro"*, *"accendi scena cinema"*, *"cerca su web ricette pasta"* funzionano.
- [ ] **AC-P2 (Week 2-4)**: Ogni settimana ≥6 tool nuovi + 1 discovery layer.
- [ ] **AC-P3 (E2E)**: Latenza Apple FM constrained decoding p99 ≤ 1.5s con catalog completo (60 tool). Mitigation pronto se peggiora.

---

## 9. Risks + Mitigations

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| **R1**: Tool descriptions confondono il router → mis-routing | Alto | Medio | Eval set di 50 query etichettate, regression test ogni nuovo tool. Description style guide in CONTRIBUTING.md. |
| **R2**: Catalog cresce, latenza router p99 supera 1.5s | Medio | Medio | Categoria-aware tool subsetting: router decide categoria prima (1 fast LLM call), poi passa solo i tool della categoria a Apple FM. |
| **R3**: Discovery layer C (UI sheet) è "feature ghetto" — utenti la ignorano | Alto | Medio | Layer B (conversational) è il primary path. Layer C è solo backup. Telemetry sull'uso del sheet — se <5% MAU lo apre, deprecate. |
| **R4**: Shortcut bridge `run_shortcut` apre Shortcuts visibilmente (~1-2s bridge) → percepito come bug | Medio | Alto | TTS pre-announce: *"Switching to Shortcuts to run <name>"* + haptic. Documentare come "by design iOS". |
| **R5**: HomeKit tool falliscono per accessory offline / config errata | Basso | Alto | Graceful error: *"I couldn't reach \(accessory). Try again or check Home app."* No crash. |
| **R6**: VisionKit `scan_document` richiede permission camera già concesso | Medio | Basso | Permission check + fallback message *"Grant Camera in Settings to scan documents."* |
| **R7**: Onboarding flow allunga TTV (time-to-value) — utenti abbandonano | Alto | Basso | Onboarding ≤ 60 secondi totali. Skip button visibile. Vale solo per nuovi (flag `onboarding_completed_v2`). |
| **R8**: Lingua: tutti i tool description in EN ma utenti italiani → router potrebbe matchare worse su query IT | Medio | Medio | Test parity EN/IT su eval set. Aggiungere esempi IT in `@Guide` quando ambigui (es. *"chiama" or "call"*). |

---

## 10. Verification Steps (per shipping ogni phase)

1. **Build verify** (ogni commit): `xcodebuild` BUILD SUCCEEDED + no nuove warning.
2. **Tool registry self-test**: a startup, log la lista di tool registrati. Visivamente confermare contro `allTools` array.
3. **Apple FM eval set**: run 50-query eval su `LanguageModelSession` con nuovi tool, verifica accuracy ≥ 90%.
4. **Latency test**: 100 invocazioni back-to-back, p99 latency tracking. Alarm se > 1.5s.
5. **E2E test pronunciabile** (Mac in-cloud + iPhone fisico): 1 frase per ogni nuovo tool, confermare side effect visibile.
6. **Discovery test**: *"What can you do?"* deve rispondere con esempi rilevanti, non lista cieca di 60 tool.
7. **Onboarding test**: fresh install + first launch → tour visualizzato. Reinstall after `onboarding_completed_v2=true` → skip.
8. **HomeKit test**: con account dev iCloud + simulator HomeKit setup, verifica scene activation funziona end-to-end.
9. **Latency degradation guard**: dopo ogni batch di +10 tool, misura latency Apple FM constrained decoding. Se +50ms, prima del prossimo batch implementare tool subsetting per categoria.
10. **ADR-0010 cross-check**: ogni decisione di design (categoria, discovery layer) coerente con ADR scritta.

---

## 11. File Table (riferimento implementazione)

| File | Stato | Cosa contiene |
|---|---|---|
| `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` | Modifica | +43 nuovi `Tool` struct, riorganizzazione `allTools` per categoria |
| `02_GIGI_APP/GIGI/GigiActionBridge.swift` | Modifica | +43 handler per nuove intent (dispatch via `execute(intent:)`) |
| `02_GIGI_APP/GIGI/GigiCapabilityCatalog.swift` | **Nuovo** | Lookup `tool_name → (category, userExample, discoveryHint, recentlyUsed)` |
| `02_GIGI_APP/GIGI/GigiHomeKitEngine.swift` | **Nuovo** | Wrapper `HMHomeManager` + scene/brightness/color/thermostat |
| `02_GIGI_APP/GIGI/GigiOnboardingFlow.swift` | **Nuovo** | State machine 3-step tour + `UserDefaults` flag |
| `02_GIGI_APP/GIGI/OnboardingView.swift` | **Nuovo** | SwiftUI view per Layer A |
| `02_GIGI_APP/GIGI/CapabilitySheetView.swift` | **Nuovo** | SwiftUI view per Layer C in Dashboard |
| `02_GIGI_APP/GIGI/GigiSuggestionEngine.swift` | **Nuovo** | Layer D proactive suggestions (week 5+) |
| `02_GIGI_APP/GIGI/GigiWebFetchService.swift` | **Nuovo** | `web_search_inline` via URLSession |
| `02_GIGI_APP/GIGI/GigiRequestRouter.swift` | Modifica | Intercept `discover_capabilities` pseudo-intent prima del tool calling |
| `02_GIGI_APP/GIGI.entitlements` | Modifica eventuale | Add `com.apple.developer.event-kit` se non già presente |
| `docs/adr/0010-tool-taxonomy-discovery.md` | **Nuovo** | ADR formal |
| `docs/runbooks/add-new-tool.md` | **Nuovo** | Runbook step-by-step per aggiungere un tool |
| `docs/eval/router-eval-set.md` | **Nuovo** | 50-query eval set EN+IT con labels |
| `docs/taskplans_new_gigi/POST-MVP-week1-quick-wins.md` | **Nuovo** | Granularizzazione Week 1 in sub-task |

---

## 12. Verification of Plan Quality (self-check)

- [x] Acceptance criteria testabili: 6 per-tool + 4 per-discovery + 3 per-rollout = 13 AC binari ✅
- [x] Reference a file specifici: ~16 file citati con path completo ✅
- [x] Riferimenti a ADR esistenti (0007, 0008) per coerenza ✅
- [x] No vague terms: "p99 ≤ 1.5s", "≤60s", "≥90% accuracy" — tutte metriche concrete ✅
- [x] Risk mitigations specifiche: 8 risk con mitigazione concreta (no "monitor and adjust") ✅
- [x] Plan salvato in `docs/plans/` ✅
- [x] Phased rollout con effort per item ✅
- [x] Discovery UX esplicitamente scomposta in 4 layer A/B/C/D ✅

---

## 13. Execution Handoff

Plan completo, **NON eseguito**. Per ralph this:

```
/ralph docs/plans/gigi-capability-expansion-2026-05-12.md --phase=week1
```

Oppure step-by-step:
1. PM (Armando) review questa plan, approva o richiede REVISE
2. Approvazione → split di Week 1 in 4 sub-task GitHub (#run_shortcut, #homekit_scene, #web_search, #onboarding)
3. Lavoro post-MVP, partire da `run_shortcut` (highest value/effort ratio)
4. Ogni completion → commit + IPA + test E2E + comment timeline su #19

---

**End of plan.**
