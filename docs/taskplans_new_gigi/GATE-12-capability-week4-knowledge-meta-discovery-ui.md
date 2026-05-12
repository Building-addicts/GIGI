# GATE 12 — Capability Expansion Week 4: Knowledge & Meta + Discovery UI

> **Status**: Pending (richiede GATE 11 chiuso)
> **Effort stimato**: ~14h (≈2 giorni lavorativi full-time)
> **Bloccanti pre-gate**: GATE 11 chiuso (Week 3 — Ambient & social tool shipped); Camera permission gestita in `Info.plist`; in-memory action log infrastructure pulita (no leftover); `GigiFoundationToolRegistry` con almeno i tool dei GATE 9/10/11 registrati
> **Sblocca**: GATE 13 (Week 5+ — long tail + Layer D proactive suggestions)
> **Funzione consegnata (1 frase)**: GIGI guadagna 4 capability "knowledge & meta" (web search inline senza Safari, scan documento, news headlines, repeat/undo ultima azione) e, dal Dashboard, una **Capability Sheet** tappabile con 7 categorie che permette all'utente di scoprire ed eseguire ogni tool con un singolo tap (Layer C discovery).

---

## 1. Obiettivo

Chiudere la **Week 4** del piano `docs/plans/gigi-capability-expansion-2026-05-12.md` (§6) — un blocco da ~14h che porta GIGI dai ~30 tool post-Week 3 a ~34 tool, ma soprattutto introduce il **primo Layer C UI** di discovery passiva (l'utente per la prima volta può VEDERE l'intero catalogo di ciò che GIGI sa fare).

I 4 tool nuovi attaccano la dimensione "knowledge & meta":

1. **`web_search_inline`** — URLSession diretto a DuckDuckGo Instant Answer API. Restituisce la risposta inline (testo + URL fonte) senza aprire Safari. Per query factoid tipo *"capitale del Cile"*, *"chi ha vinto Champions 2024"*, *"a cosa serve la vitamina B12"*.
2. **`scan_document`** — apre `VNDocumentCameraViewController` (VisionKit). L'utente fotografa una pagina, il PDF risultante viene salvato in Files o passato a un Shortcut "Save to" successivo.
3. **`get_news_headlines`** — bridge Shortcut a News app con `topic` param. Output: titoli top 5.
4. **`repeat_last_action`** + **`undo_last_action`** — action log in-memory (ring buffer 20 entries, reset on cold launch). `repeat` re-invoca l'ultima `executeRaw`. `undo` invoca l'inverse hook se l'azione è reversibile (delete reminder → reminder ripristinato; cancel event → event ripristinato; timer set → timer cancellato).

La **Capability Sheet** (Layer C) è la novità UX più visibile del gate. Vive come **nuovo tab nel Dashboard esistente** (NON una root view nuova), data source `GigiCapabilityCatalog`, 7 categorie collassabili (system, social, productivity, entertainment, ambient, knowledge, automation). Ogni categoria espone i tool con un esempio canonico tappabile — tap → frase viene messa in chat input + invio automatico → tool si attiva (instant try, riferimento §5.3 master plan).

Output concreti:
- `GigiWebFetchService.swift` (NEW, ~140 righe) — URLSession wrapper per DDG Instant Answer
- `GigiFoundationToolRegistry.swift` (MODIFY) — 4 nuovi `Tool` struct + categoria knowledge/meta
- `GigiActionLog.swift` (NEW, ~110 righe) — ring buffer azioni + inverse hook registry
- `GigiCapabilityCatalog.swift` (MODIFY) — popolare categorie + esempi canonici per ogni tool del catalogo
- `CapabilitySheetView.swift` (NEW, ~260 righe SwiftUI) — UI Sheet con 7 categorie, tap-to-try, badge "recently used" / "not yet tried"
- `DashboardView.swift` (MODIFY) — aggiungere nuovo tab "Capabilities" (o "What I can do")
- `Info.plist` (MODIFY) — `NSCameraUsageDescription` se non già presente
- ADR-0010 promosso da Proposed → Accepted (specifica Layer C UI definitiva)

---

## 2. Pre-condizioni

- [ ] GATE 11 chiuso (Week 3 Ambient & social shipped, registry > 28 tool)
- [ ] `Info.plist` contiene `NSCameraUsageDescription` (per `scan_document`) — se assente, aggiungere stringa inglese *"GIGI uses the camera to scan documents into PDF when you ask."*
- [ ] `GigiFoundationToolRegistry.allTools` esiste e raggruppa per category (struttura post-GATE 10/11)
- [ ] `GigiActionDispatcher.bridge.executeRaw(label:, params:)` accetta tutti i label dei tool già esistenti — `GigiActionLog` aggancia un hook qui
- [ ] Dashboard `DashboardView.swift` ha già un `TabView` o equivalente — il nuovo tab "Capabilities" si innesta come tab N+1, non come nuovo root NavigationStack
- [ ] iPhone 15 Pro+ fisico con Apple Intelligence attiva, iOS 26.3+ installato, Camera permission concedibile a runtime
- [ ] Rete internet disponibile durante test (DDG API)
- [ ] Almeno 1 Shortcut bridge "News headlines" creato in Shortcuts app — guida utente fornita

---

## 3. Task implementativi

- **Task 12.1 — Implementare `GigiWebFetchService.swift` + `web_search_inline` tool** (4h)
  - File NEW: `02_GIGI_APP/GIGI/GigiWebFetchService.swift` (~140 righe)
  - API target: `https://api.duckduckgo.com/?q=<encoded>&format=json&no_html=1&skip_disambig=1` — **no API key**, response JSON con campi `AbstractText`, `AbstractSource`, `AbstractURL`, `Heading`, `RelatedTopics[]`
  - Signature:
    ```swift
    actor GigiWebFetchService {
        static let shared = GigiWebFetchService()

        struct InstantAnswer {
            let summary: String   // AbstractText o RelatedTopics[0].Text fallback
            let source: String?   // AbstractSource
            let url: URL?         // AbstractURL
        }

        enum FetchError: Error { case noAnswer, network(Error), timeout, malformed }

        func instantAnswer(query: String, timeout: TimeInterval = 5) async throws -> InstantAnswer
    }
    ```
  - Logica:
    1. Build URL con `URLComponents`, `URLQueryItem(name: "q", value: query)` (lascia `URLSession` fare URL-encoding)
    2. `URLSession.shared.data(for: request)` con `URLRequest.timeoutInterval = 5`
    3. Decode con `JSONDecoder` su struct `DDGResponse` (campi opzionali Strings)
    4. Se `abstractText` non vuoto → ritorna `InstantAnswer(summary: abstractText, source: abstractSource, url: URL(string: abstractURL))`
    5. Se vuoto ma `relatedTopics[0].text` esiste → fallback con quello
    6. Altrimenti → throw `.noAnswer`
  - Tool wrapper in `GigiFoundationToolRegistry.swift`:
    ```swift
    @available(iOS 26, *)
    struct WebSearchInlineTool: Tool {
        let name = "web_search_inline"
        let description = "Search the web and read a short factual answer inline, without opening Safari. Use for factual questions like 'capital of Chile' or 'what is vitamin B12'."

        @Generable
        struct Arguments {
            @Guide(description: "The search query in natural language.")
            var query: String
        }

        func call(arguments: Arguments) async -> String {
            do {
                let ans = try await GigiWebFetchService.shared.instantAnswer(query: arguments.query)
                let src = ans.source.map { " (source: \($0))" } ?? ""
                return "\(ans.summary)\(src)"
            } catch GigiWebFetchService.FetchError.noAnswer {
                return "No instant answer found. Try opening Safari for full search."
            } catch {
                return "Web search failed: \(error.localizedDescription)"
            }
        }
    }
    ```
  - Registrare in `allTools` sotto category `.knowledge`
  - NO Safari open: GIGI parla il summary in TTS direttamente

- **Task 12.2 — Implementare `scan_document` con VisionKit** (3h)
  - File MODIFY: `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` + `02_GIGI_APP/GIGI/GigiActionBridge.swift` (handler `scan_document`)
  - Tool struct:
    ```swift
    @available(iOS 26, *)
    struct ScanDocumentTool: Tool {
        let name = "scan_document"
        let description = "Open the camera-based document scanner to capture a page or receipt as PDF. Use when the user asks to scan, photograph a document, or capture a receipt."

        @Generable
        struct Arguments {
            @Guide(description: "Optional file name (without extension) for the saved PDF. Empty = auto-generated.")
            var fileName: String
        }

        func call(arguments: Arguments) async -> String {
            return await GigiActionDispatcher.shared.bridge.executeRaw(
                label: "scan_document",
                params: ["fileName": arguments.fileName]
            )
        }
    }
    ```
  - Handler in `GigiActionBridge.swift`:
    - Check `AVCaptureDevice.authorizationStatus(for: .video)`
      - `.notDetermined` → request, attendere risposta
      - `.denied` / `.restricted` → ritorna stringa *"Grant Camera in Settings to scan documents."*
      - `.authorized` → procedere
    - Present `VNDocumentCameraViewController` via `UIApplication.shared.connectedScenes` rootViewController
    - Delegate methods:
      - `documentCameraViewController(_:didFinishWith:)` → iterare `scan.pageCount`, convertire ogni `scan.imageOfPage(at:)` in `UIImage`, costruire `PDFDocument` (PDFKit) e salvarlo in `FileManager.default.urls(for: .documentDirectory)`
      - `documentCameraViewControllerDidCancel(_:)` → return *"Scan cancelled."*
      - `documentCameraViewController(_:didFailWithError:)` → return error string
    - Ritornare *"Scanned N pages, saved as <filename>.pdf in Files."*
  - Registry: category `.productivity` (ADR-0010 raggruppa scan con productivity)

- **Task 12.3 — Implementare `get_news_headlines` via Shortcut bridge** (2h)
  - File MODIFY: `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` + nessun nuovo Swift handler (delega a Shortcut)
  - Tool struct:
    ```swift
    @available(iOS 26, *)
    struct GetNewsHeadlinesTool: Tool {
        let name = "get_news_headlines"
        let description = "Read the top 5 news headlines for a topic (technology, sports, world, business). Bridges to the News app via a user-installed Shortcut."

        @Generable
        struct Arguments {
            @Guide(description: "News topic. One of: technology, sports, world, business, science, entertainment.")
            var topic: String
        }

        func call(arguments: Arguments) async -> String {
            return await GigiActionDispatcher.shared.bridge.executeRaw(
                label: "get_news_headlines",
                params: ["topic": arguments.topic]
            )
        }
    }
    ```
  - Handler in `GigiActionBridge.swift` (`scan_document` style):
    - Build `URL(string: "shortcuts://x-callback-url/run-shortcut?name=GIGI%20News%20Headlines&input=text&text=<topic>&x-success=gigi://news-result")`
    - Open via `UIApplication.shared.open(url, options:)`
    - Risposta arriva su deep link `gigi://news-result?headlines=...` — handler in `SceneDelegate` o `GigiURLCoordinator` parsa e re-emette via `GigiSpeechController`
  - Guida utente (in `docs/runbooks/`): istruzioni per creare lo Shortcut "GIGI News Headlines" con action "Get Latest News" + Return parameter
  - Registry: category `.knowledge`

- **Task 12.4 — Implementare `GigiActionLog` + `repeat_last_action` + `undo_last_action`** (3h)
  - File NEW: `02_GIGI_APP/GIGI/GigiActionLog.swift` (~110 righe)
  - Struttura:
    ```swift
    @MainActor
    final class GigiActionLog: ObservableObject {
        static let shared = GigiActionLog()

        struct Entry {
            let id = UUID()
            let timestamp: Date
            let label: String                  // canonical action name
            let params: [String: String]
            let inverseHookId: String?         // id registrato in inverseRegistry, se reversible
        }

        @Published private(set) var entries: [Entry] = []   // ring buffer, max 20
        private let capacity = 20

        // chiamato da GigiActionBridge.executeRaw DOPO dispatch success
        func record(label: String, params: [String: String], inverseHookId: String?)

        // ultima Entry o nil
        var last: Entry? { entries.last }

        // ripete l'ultima azione (re-call executeRaw con stessi label/params)
        func repeatLast() async -> String

        // invoca l'inverse hook dell'ultima Entry se presente
        func undoLast() async -> String
    }

    // Registry inverse hooks
    enum GigiInverseRegistry {
        // map label → closure inversa
        // es. "set_reminder" → closure che cancella il reminder appena creato (usa params["reminderId"])
        static let hooks: [String: (params: [String: String]) async -> String] = [...]
    }
    ```
  - Wire in `GigiActionBridge.executeRaw` (MODIFY): dopo dispatch success, chiamare `GigiActionLog.shared.record(...)`. Non loggare azioni `noop` o `error`
  - Inverse hooks da registrare (almeno 4 per coverage AC):
    - `set_reminder` → `EKEventStore.remove(reminder:commit:)` per il `reminderId` salvato in params
    - `set_timer` → cancella la `UNNotificationRequest` con identifier salvato
    - `create_calendar_event` → `EKEventStore.remove(event:span:)` 
    - `set_focus_mode` → re-imposta `default` focus
  - Tool struct:
    ```swift
    @available(iOS 26, *)
    struct RepeatLastActionTool: Tool {
        let name = "repeat_last_action"
        let description = "Re-execute the last action GIGI performed. Use when the user says 'do it again', 'repeat', or 'call him again'."

        @Generable struct Arguments {}

        func call(arguments: Arguments) async -> String {
            await GigiActionLog.shared.repeatLast()
        }
    }

    @available(iOS 26, *)
    struct UndoLastActionTool: Tool {
        let name = "undo_last_action"
        let description = "Undo the last reversible action GIGI performed (e.g., delete the reminder just created, cancel the event just scheduled)."

        @Generable struct Arguments {}

        func call(arguments: Arguments) async -> String {
            await GigiActionLog.shared.undoLast()
        }
    }
    ```
  - Registry: category `.automation`
  - Persistenza: **NESSUNA**, ring buffer in-memory reset on cold launch (vincolo del gate)

- **Task 12.5 — Layer C: `CapabilitySheetView.swift` + Dashboard tab integration** (2h)
  - File NEW: `02_GIGI_APP/GIGI/CapabilitySheetView.swift` (~260 righe SwiftUI)
  - File MODIFY: `02_GIGI_APP/GIGI/GigiCapabilityCatalog.swift` — assicurarsi che ogni tool registrato abbia:
    - `category: ToolCategory` (enum: system, social, productivity, entertainment, ambient, knowledge, automation)
    - `canonicalExample: String` (frase pronta da tappare, es. *"Set a 10 minute timer"*)
    - `lastUsedAt: Date?` (alimentato leggendo `GigiActionLog.shared.entries`)
  - File MODIFY: `02_GIGI_APP/GIGI/DashboardView.swift` — aggiungere nuovo `Tab` (label *"Capabilities"*, icon `sparkles`)
  - UI structure SwiftUI:
    ```swift
    struct CapabilitySheetView: View {
        @StateObject private var catalog = GigiCapabilityCatalog.shared
        @State private var expandedCategories: Set<ToolCategory> = [.knowledge]   // default: knowledge aperta

        var body: some View {
            NavigationStack {
                List {
                    ForEach(ToolCategory.allCases, id: \.self) { cat in
                        Section {
                            if expandedCategories.contains(cat) {
                                ForEach(catalog.tools(in: cat)) { tool in
                                    CapabilityRow(tool: tool, onTap: { tryTool(tool) })
                                }
                            }
                        } header: {
                            CategoryHeader(category: cat,
                                           isExpanded: expandedCategories.contains(cat),
                                           toggle: { toggle(cat) })
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle("What I can do")
            }
        }

        func tryTool(_ tool: ToolEntry) {
            // Copia canonicalExample in chat input + invio automatico
            GigiChatController.shared.injectAndSubmit(tool.canonicalExample)
        }
    }
    ```
  - `CapabilityRow` mostra:
    - Nome tool (es. *"Set Timer"*)
    - Esempio canonico in piccolo (es. *"Set a 10 minute timer"*)
    - Badge **"Recently used"** se `tool.lastUsedAt` < 7gg fa (verde)
    - Badge **"Not yet tried"** se `tool.lastUsedAt == nil` (blu)
  - Tap row → `tryTool` → `GigiChatController.injectAndSubmit` mette la frase nel TextField del chat + invia
  - Header categoria mostra count `(N tools)` + chevron rotation animato
  - Default 7 categorie, ordine: system, social, productivity, entertainment, ambient, knowledge, automation
  - Accessibility: ogni row `accessibilityHint("Tap to try this capability")`

- **Task 12.6 — Aggiornare ADR-0010 da Proposed → Accepted** (30min)
  - File MODIFY: `docs/adr/0010-tool-taxonomy-and-discovery.md` (se non esiste, crearlo seguendo `docs/adr/0000-template.md`)
  - Status: `Accepted` (2026-05-12)
  - Aggiungere riferimento esplicito a `CapabilitySheetView.swift` come implementazione canonica Layer C
  - Documentare la decisione: **action log NON persistente** (in-memory only, reset on cold launch) — semplifica privacy, niente file da migrare/cifrare. Reconsider in v1.1 se utenti chiedono "ripeti azione di ieri"

- **Task 12.7 — Test coverage doc** (1h)
  - File CREATE: `docs/research/gate-12-capability-week4-coverage.md`
  - Tabella: tool, query test, esito (PASS/FAIL), latency, note
  - Almeno 5 query per `web_search_inline`, 2 per `scan_document`, 3 per `get_news_headlines`, 4 per `repeat/undo`
  - Screenshot della Capability Sheet (3 stati: chiusa, una categoria aperta, badge visibili)

---

## 4. Acceptance Criteria (AC)

Tool funzionali:

- [ ] **AC-12.1** — `GigiWebFetchService.swift` esiste come `actor`, espone `instantAnswer(query:timeout:)` con timeout default 5s
- [ ] **AC-12.2** — `WebSearchInlineTool` registrato in `GigiFoundationToolRegistry.allTools`, category `.knowledge`, description in inglese, `Arguments.query` con `@Guide` inglese
- [ ] **AC-12.3** — `ScanDocumentTool` registrato, presenta `VNDocumentCameraViewController` quando Camera permission `.authorized`, gestisce `.denied` con messaggio utente
- [ ] **AC-12.4** — `Info.plist` contiene `NSCameraUsageDescription` in inglese
- [ ] **AC-12.5** — `GetNewsHeadlinesTool` registrato, category `.knowledge`, apre Shortcut tramite `shortcuts://x-callback-url/run-shortcut?name=GIGI%20News%20Headlines`, deep link `gigi://news-result` parsato e re-emesso via speech
- [ ] **AC-12.6** — `GigiActionLog.swift` esiste, `entries` è ring buffer cap 20, `record(...)` chiamato da `GigiActionBridge.executeRaw` dopo ogni success
- [ ] **AC-12.7** — `RepeatLastActionTool` e `UndoLastActionTool` registrati, category `.automation`, description e `@Guide` inglesi
- [ ] **AC-12.8** — `GigiInverseRegistry.hooks` contiene almeno 4 voci (`set_reminder`, `set_timer`, `create_calendar_event`, `set_focus_mode`)
- [ ] **AC-12.9** — Cold launch resetta `GigiActionLog.entries` a `[]` (verifica: stop app, riapri, query `repeat_last_action` → risponde *"No previous action to repeat."*)

Layer C UI Sheet:

- [ ] **AC-12.10** — `CapabilitySheetView.swift` esiste, montato come nuovo `Tab` in `DashboardView` (label *"Capabilities"*, icon `sparkles`)
- [ ] **AC-12.11** — La Sheet mostra esattamente 7 categorie (system, social, productivity, entertainment, ambient, knowledge, automation) — verificato visualmente
- [ ] **AC-12.12** — Categorie collassabili: tap header → toggle expand/collapse, chevron ruota
- [ ] **AC-12.13** — Ogni row tool mostra: nome, esempio canonico, badge "Recently used" (se usato <7gg fa) o "Not yet tried" (se mai usato) — almeno 1 di ogni badge visibile dopo 1 uso reale di un tool
- [ ] **AC-12.14** — Tap su una row → `GigiChatController.injectAndSubmit(canonicalExample)` → la frase compare nel chat input E viene inviata automaticamente E il tool si attiva (verifica su `set_timer` → notifica iOS schedulata)
- [ ] **AC-12.15** — Build verify: `xcodebuild` BUILD SUCCEEDED su iPhone 15 Pro target
- [ ] **AC-12.16** — Tutte le `description` Tool e `@Guide` in **inglese** (regola CLAUDE.md, grep verifica)

Cross-cutting:

- [ ] **AC-12.17** — `GigiFoundationToolRegistry.allTools.count` >= (Week 3 count) + 5 (4 nuovi tool + nessuna rimozione regressiva)
- [ ] **AC-12.18** — ADR-0010 status `Accepted`, link a `CapabilitySheetView.swift` esplicito

---

## 5. Test E2E sul telefono (verificabili dall'utente)

- **E2E-1 — Web search inline factoid**
  - Pronunciare: *"Cerca capitale del Cile"* (o EN: *"What is the capital of Chile"*)
  - Atteso: Apple FM invoca `WebSearchInlineTool` con `query="capitale del Cile"`. DDG API ritorna `AbstractText: "Santiago is the capital..."`. TTS GIGI parla *"Santiago is the capital and largest city of Chile (source: Wikipedia)"*. **Safari NON si apre**.

- **E2E-2 — Web search inline definizione**
  - Pronunciare: *"What is vitamin B12"*
  - Atteso: `WebSearchInlineTool` → DDG abstract → TTS legge summary in <6s totali.

- **E2E-3 — Web search inline no-answer fallback**
  - Pronunciare: *"asdkjfhalskdjhf"* (query nonsense)
  - Atteso: DDG ritorna `.noAnswer` → TTS dice *"No instant answer found. Try opening Safari for full search."*

- **E2E-4 — Scan document happy path**
  - Pronunciare: *"Scansiona questo documento"* (EN: *"Scan this document"*)
  - Atteso: `ScanDocumentTool` presenta `VNDocumentCameraViewController` fullscreen. Utente fotografa 1 pagina, tap "Save". TTS GIGI dice *"Scanned 1 page, saved as scan-2026-05-12.pdf in Files."*. PDF visibile in Files app.

- **E2E-5 — Scan document permission denied**
  - Negare Camera permission da Settings, ri-pronunciare *"Scan document"*
  - Atteso: TTS dice *"Grant Camera in Settings to scan documents."* — `VNDocumentCameraViewController` NON viene presentato.

- **E2E-6 — News headlines (richiede Shortcut installato)**
  - Pronunciare: *"Read me the top tech news"*
  - Atteso: `GetNewsHeadlinesTool` → apre Shortcut "GIGI News Headlines" con `topic=technology` → ritorna 5 titoli → TTS GIGI li legge.

- **E2E-7 — Repeat last action**
  - 1) Pronunciare *"Set a 5 minute timer"* → timer schedulato
  - 2) Pronunciare *"Repeat"* (o *"Do it again"*)
  - Atteso: `RepeatLastActionTool` → `GigiActionLog.repeatLast()` → re-call `executeRaw("set_timer", {duration: "5 minutes"})` → secondo timer schedulato. TTS conferma *"Timer set."*

- **E2E-8 — Undo reversible action**
  - 1) Pronunciare *"Remind me to call Marco tomorrow at 10"*
  - 2) Reminder creato in Reminders.app, visibile
  - 3) Pronunciare *"Undo that"* (o *"Cancel last action"*)
  - Atteso: `UndoLastActionTool` → invoca inverse hook `set_reminder` → reminder rimosso da Reminders.app → TTS conferma *"Reminder removed."*

- **E2E-9 — Undo non-reversibile**
  - 1) Pronunciare *"Cerca capitale del Cile"* (web_search_inline non ha inverse)
  - 2) Pronunciare *"Undo that"*
  - Atteso: TTS dice *"Last action cannot be undone."*

- **E2E-10 — Cold launch resetta log**
  - 1) Eseguire `set_timer`
  - 2) Force-quit app
  - 3) Riaprire app, pronunciare *"Repeat"*
  - Atteso: TTS *"No previous action to repeat."* — log resettato.

- **E2E-11 — Capability Sheet open + 7 categorie**
  - Aprire Dashboard, tap tab *"Capabilities"*
  - Atteso: lista mostra 7 sezioni collassabili con header testo (System, Social, Productivity, Entertainment, Ambient, Knowledge, Automation). Default solo "Knowledge" aperta (4+ tool visibili).

- **E2E-12 — Capability Sheet tap-to-try**
  - Nella categoria *"Knowledge"*, tap sulla row *"Web Search Inline"* (esempio *"What is the capital of Chile"*)
  - Atteso: l'app naviga al chat tab, la frase *"What is the capital of Chile"* compare nel TextField, viene inviata automaticamente, GIGI risponde inline via TTS.

- **E2E-13 — Capability Sheet badge "Recently used"**
  - Dopo E2E-1 (web_search_inline appena usato), riaprire Capability Sheet
  - Atteso: row *"Web Search Inline"* mostra badge verde **"Recently used"**.

- **E2E-14 — Capability Sheet badge "Not yet tried"**
  - Categoria *"Productivity"*, row *"Scan Document"* (mai usato in questa sessione di test)
  - Atteso: badge blu **"Not yet tried"** visibile sulla row.

- **E2E-15 — Collapse/expand categorie**
  - Tap header "Knowledge" → categoria collassa (rows scompaiono, chevron ruota verso destra)
  - Tap header "Automation" → categoria espande (rows visibili `repeat_last_action`, `undo_last_action`)

---

## 6. Test post-creazione (verifica autonoma — ripetibile mesi dopo)

### 6.1 Verifica via grep

```bash
ROOT="C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/02_GIGI_APP/GIGI"

# 1. GigiWebFetchService esiste e usa DDG
grep -E "api\.duckduckgo\.com" "$ROOT/GigiWebFetchService.swift"
# Output atteso: 1+ match

# 2. 4 nuovi tool registrati
grep -E "let name = \"(web_search_inline|scan_document|get_news_headlines|repeat_last_action|undo_last_action)\"" "$ROOT/GigiFoundationToolRegistry.swift" | wc -l
# Output atteso: 5

# 3. GigiActionLog ring buffer cap 20
grep "capacity = 20" "$ROOT/GigiActionLog.swift"
# Output atteso: 1 match

# 4. Inverse registry ha >=4 hooks
grep -E "\"(set_reminder|set_timer|create_calendar_event|set_focus_mode)\":" "$ROOT/GigiActionLog.swift" | wc -l
# Output atteso: >=4

# 5. CapabilitySheetView esiste con 7 categorie
grep -c "case system\|case social\|case productivity\|case entertainment\|case ambient\|case knowledge\|case automation" "$ROOT/GigiCapabilityCatalog.swift"
# Output atteso: 7

# 6. Dashboard tab "Capabilities" aggiunto
grep -E "Capabilities|sparkles" "$ROOT/DashboardView.swift"
# Output atteso: 1+ match

# 7. Info.plist Camera permission
grep "NSCameraUsageDescription" "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/02_GIGI_APP/GIGI/Info.plist"
# Output atteso: 1 match

# 8. Tutte le tool description in inglese (no italiano)
grep -E "description = \".*(scansion|cerca|ripeti|annulla)" "$ROOT/GigiFoundationToolRegistry.swift"
# Output atteso: 0 match (regola CLAUDE.md)
```

### 6.2 Verifica via xcodebuild

```bash
ssh user297422@FF125.macincloud.com "cd ~/GIGI-armando-rework/02_GIGI_APP && /usr/bin/xcodebuild -scheme GIGI -destination 'generic/platform=iOS' build 2>&1 | grep -E 'error:|BUILD'"
# Output atteso: BUILD SUCCEEDED, 0 error: lines
```

### 6.3 UI visual check

```bash
# Coverage doc esiste
cat "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/docs/research/gate-12-capability-week4-coverage.md" | grep -c "PASS"
# Output atteso: >= 12 (cover almeno 12 dei 15 E2E)

# Screenshot Capability Sheet salvati
ls "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/docs/research/screenshots/" | grep -i "capability"
# Output atteso: >= 3 file PNG
```

### 6.4 Runtime spot-check

Riaccendere iPhone, lanciare app cold, eseguire questa sequenza:
1. Tab Capabilities → verifica 7 sezioni
2. Tap *"What is the capital of Chile"* esempio → web search inline parte
3. Tab Chat → conferma TTS ha risposto con Santiago
4. Tab Capabilities → row Web Search Inline ha badge "Recently used"

---

## 7. Rollback plan

Se Layer C Capability Sheet o uno dei tool si rivela problematico in produzione:

```bash
cd "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework"
git revert <SHA-gate-12>
```

Alternative meno destructive:
- Feature flag `gigi.feature.capability_sheet_tab: bool` in `DashboardView` — quando false, il tab "Capabilities" non viene renderizzato (UI hidden, tool restano funzionali via voce)
- Feature flag `gigi.feature.action_log_repeat_undo: bool` — quando false, `RepeatLastActionTool`/`UndoLastActionTool` sono rimossi da `allTools` e il log smette di registrare
- Per `web_search_inline` problematico: shrink description (no più dispatch da Apple FM) → fallback su `web_search` (Safari open) di Week 1
- Per `scan_document` crash: rimuovere tool da registry, lasciare `GigiActionBridge` handler per chiamata diretta da test

Side effects revert:
- UserDefaults: nessuno nuovo
- Persistenza: nessuna (action log è in-memory)
- File system: PDF già salvati in Files restano (uscono dallo scope app)
- Permission Camera: già concessa rimane (utente può revocare)
- Shortcut "GIGI News Headlines" rimane installato (innocuo)

---

## 8. Files modificati / creati

| Path | Operazione | Righe stimate |
|---|---|---|
| `02_GIGI_APP/GIGI/GigiWebFetchService.swift` | **CREATE** | ~140 |
| `02_GIGI_APP/GIGI/GigiActionLog.swift` | **CREATE** | ~110 |
| `02_GIGI_APP/GIGI/CapabilitySheetView.swift` | **CREATE** | ~260 |
| `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` | MODIFY (5 nuovi Tool struct + category metadata) | +180 |
| `02_GIGI_APP/GIGI/GigiActionBridge.swift` | MODIFY (handler scan_document, get_news_headlines + hook log) | +120 |
| `02_GIGI_APP/GIGI/GigiCapabilityCatalog.swift` | MODIFY (popolare 7 categorie + canonicalExample per tool) | +90 |
| `02_GIGI_APP/GIGI/DashboardView.swift` | MODIFY (nuovo Tab "Capabilities") | +20 |
| `02_GIGI_APP/GIGI/GigiURLCoordinator.swift` (o equivalente) | MODIFY (deep link `gigi://news-result`) | +30 |
| `02_GIGI_APP/GIGI/Info.plist` | MODIFY (`NSCameraUsageDescription` se mancante) | +4 |
| `docs/adr/0010-tool-taxonomy-and-discovery.md` | MODIFY (Proposed → Accepted) o CREATE se assente | +20 / ~120 |
| `docs/research/gate-12-capability-week4-coverage.md` | **CREATE** | ~100 |
| `docs/research/screenshots/capability-sheet-*.png` | **CREATE** (≥3 file) | binary |
| `docs/runbooks/shortcut-news-headlines.md` | **CREATE** (guida user setup Shortcut) | ~40 |

---

## 9. ADR collegati

- **ADR-0008** — Apple FM Tool Calling come Path 2 (già Accepted, GATE 3) — questo gate aggiunge 5 tool al pattern stabilito
- **ADR-0010** — Tool Taxonomy + Discovery (Proposed in piano capability expansion) → **promosso ad Accepted in questo gate**. Documenta:
  - 7 categorie canoniche
  - 3-layer discovery (A onboarding, B conversational, C UI Sheet) — questo gate consegna **C**
  - Action log in-memory (no persistenza in v1.0)
  - `canonicalExample` field richiesto su ogni `ToolEntry`
- **ADR-0009** (Hardware target Apple FM) — invariato, tutti i nuovi tool ereditano `@available(iOS 26, *)`

---

## 10. Note operative

**Branch suggerito**: `feat/gate-12-capability-week4`

**Conventional Commits** consigliati (uno per task):
- `feat(ios): aggiungi GigiWebFetchService + web_search_inline tool (GATE 12.1)`
- `feat(ios): aggiungi scan_document via VisionKit (GATE 12.2)`
- `feat(ios): aggiungi get_news_headlines via Shortcut bridge (GATE 12.3)`
- `feat(ios): aggiungi GigiActionLog + repeat_last_action + undo_last_action (GATE 12.4)`
- `feat(ios): aggiungi CapabilitySheetView Layer C in Dashboard (GATE 12.5)`
- `docs(adr): promote ADR-0010 to Accepted con specifica Layer C UI`

**GATES intermedi (checkpoint interni)** — utili per fermarsi e verificare prima di proseguire:

| Sub-gate | Cosa verifica | Atteso |
|---|---|---|
| **GATE 12.A** — Knowledge inline | `web_search_inline` funzionante via DDG, NO Safari open, fallback `.noAnswer` testato | E2E-1, E2E-2, E2E-3 PASS |
| **GATE 12.B** — Productivity capture | `scan_document` apre VisionKit + permission flow, `get_news_headlines` apre Shortcut e parsa deep link | E2E-4, E2E-5, E2E-6 PASS |
| **GATE 12.C** — Meta actions | Action log registra, repeat ri-esegue, undo invoca inverse hook, cold launch resetta | E2E-7, E2E-8, E2E-9, E2E-10 PASS |
| **GATE 12.D** — Discovery UI | Tab "Capabilities" montato in Dashboard, 7 categorie, tap-to-try invia frase e attiva tool, badge "Recently used"/"Not yet tried" visibili | E2E-11→E2E-15 PASS |

Non si passa al GATE 13 finché tutti e 4 i sub-gate sono PASS + AC-12.1 … AC-12.18 verificati.

**Vincoli ricordati**:
- Tutte le `description` Tool e `@Guide` in **inglese** (CLAUDE.md regola dura)
- DDG API: nessuna API key richiesta — se in futuro rate-limited, fallback configurabile a SearXNG instance pubblica (es. `https://searx.be/search?q=X&format=json`)
- VisionKit richiede Camera permission concessa a runtime — gestire `.notDetermined` con request prompt, `.denied`/`.restricted` con messaggio chiaro
- Action log: ring buffer 20 entries, **NO persistenza** — decisione documentata in ADR-0010
- Layer C UI: SwiftUI, integra **come nuovo Tab nel DashboardView esistente**, **NON aprire una nuova root NavigationStack** (vincolo del gate)
- `canonicalExample` deve essere in inglese e produrre una invocazione tool reale quando inviato in chat

**Riferimenti**:
- Master plan: `docs/plans/gigi-capability-expansion-2026-05-12.md` §6 Week 4 + §5.3 Layer C
- ADR template: `docs/adr/0000-template.md`
- Index gate: `docs/taskplans_new_gigi/INDEX.md` — aggiungere riga GATE 12 dopo merge
