# GIGI v3 — Task Plan Implementativo
> Stato: 🔴 = todo | 🟡 = in progress | ✅ = done

---

## FASE 0 — Cleanup workspace

- [x] **0.1** Eliminare `GigiPlanner.swift` ✅
- [x] **0.2** Eliminare `GigiCore.swift` ✅
- [x] **0.3** Eliminare `GigiEntityExtractor.swift` ✅
- [x] **0.4** Eliminare `GigiImplicationEngine.swift` ✅
- [x] **0.5** Eliminare `GigiPersonality.swift` ✅
- [x] **0.6** Eliminare `GigiGatewayRunner.swift` ✅
- [x] **0.7** Eliminare `WakeGigiIntent.swift` ✅
- [x] **0.8** Eliminare `GigiAppIntents.swift` ✅
- [x] **0.9** Eliminare `GigiAppShortcutsProvider.swift` ✅
- [x] **0.10** Eliminare `GigiShortcutGenerator.swift` ✅
- [x] **0.11** Eliminare `GigiSpotlightManager.swift` ✅
- [x] **0.12** Eliminare `GigiRoutineDetector.swift` ✅
- [x] **0.13** Eliminare `GigiProactive.swift` ✅
- [x] **0.14** Eliminare script root: `add_files.rb`, `clean_pbxproj.rb`, `clean_pbxproj2.rb`, `diff.patch`, `proxy.py`, `test_ws.py` ✅
- [x] **0.15** Eliminare script app: `test.swift`, `add_porcupine.py`, `add_spotlight.rb`, `add_widget_extension.rb`, `remove_porcupine.rb`, `update_pbxproj.rb` ✅
- [x] **0.16** pbxproj usa `PBXFileSystemSynchronizedBuildFileExceptionSet` — folder sync automatico, nessun edit manuale necessario ✅
- [ ] **0.17** Verificare build pulita in Xcode (zero errori da file rimossi)

---

## FASE 1 — Agent Loop Core ← PRIORITÀ MASSIMA

### 1.1 — Creare `GigiToolRegistry.swift`

- [ ] **1.1.1** Definire protocollo `GigiTool`:
  ```swift
  protocol GigiTool {
      var name: String { get }
      var declaration: FunctionDeclaration { get }
      var requiresConfirmation: Bool { get }
      func execute(args: [String: Any]) async -> ToolResult
  }
  ```
- [ ] **1.1.2** Definire struct `ToolResult`:
  ```swift
  struct ToolResult {
      let value: String
      let requiresConfirm: ConfirmRequest?
      let tokenEstimate: Int
  }
  ```
- [ ] **1.1.3** Definire struct `FunctionDeclaration` (nome, description, parameters JSON schema)
- [ ] **1.1.4** Implementare i **25 tool nativi iOS** come struct conformi a `GigiTool`:
  - `MakeCallTool` — `make_call(contact, contact_id?)`
  - `SendMessageTool` — `send_message(contact, body, platform, contact_id?)`
  - `NavigateTool` — `navigate(destination)`
  - `PlayMusicTool` — `play_music(query, app)`
  - `SetReminderTool` — `set_reminder(text, date, time)`
  - `CreateEventTool` — `create_event(title, date, time, contact)`
  - `SetAlarmTool` — `set_alarm(time, date)`
  - `SetTimerTool` — `set_timer(duration)`
  - `OpenAppTool` — `open_app(app)`
  - `AskTimeTool` — `ask_time()`
  - `AskDateTool` — `ask_date()`
  - `WeatherTool` — `weather(location)`
  - `TorchOnTool` / `TorchOffTool` — `torch_on()` / `torch_off()`
  - `FaceTimeTool` / `FaceTimeAudioTool` — `facetime(contact)` / `facetime_audio(contact)`
  - `MediaPlayPauseTool` / `MediaNextTool` / `MediaPreviousTool` — media controls
  - `ReadCalendarTool` — `read_calendar()` — EventKit oggi
  - `ReadWeekCalendarTool` — `read_week_calendar()` — sommario settimana (non raw)
  - `FindFreeSlotTool` — `find_free_slot(duration, preferred_time, date, context)` — algoritmo locale semantic-aware (vedere §5 architettura)
  - `SearchWebTool` — `search_web(query)` — apre Safari
  - `ReadNewsTool` — `read_news(query)` — RSS + scraping
  - `SendEmailTool` — `send_email(contact, subject, body)` — mailto:
  - `ToggleWifiTool` — `toggle_wifi()` — deep link prefs:root=WIFI
  - `ToggleBluetoothTool` — `toggle_bluetooth()` — deep link prefs:root=Bluetooth
  - `HomekitOnTool` / `HomekitOffTool` — `homekit_on(accessory)` / `homekit_off(accessory)`
  - `HomekitDimTool` — `homekit_dim(accessory, brightness)`
  - `HomekitTempTool` — `homekit_temp(temperature)`
  - `HomekitSceneTool` — `homekit_scene(scene)`
  - `RememberTool` — `remember(key, value)` — CloudKit
  - `RecallTool` — `recall(query)` — CloudKit + RAG
  - `SearchGroupsTool` — `search_groups(name)`
- [ ] **1.1.5** Implementare i **5 tool web automation** come struct conformi a `GigiTool`:
  - `WebWhatsAppTool` — `web_whatsapp(contact, message)`
  - `WebBookRestaurantTool` — `web_book_restaurant(restaurant, time, guests, date, platform?)` — `requiresConfirmation = true`
  - `WebOrderFoodTool` — `web_order_food(restaurant, items, platform)` — `requiresConfirmation = true`
  - `WebSearchAndReadTool` — `web_search_and_read(query)`
  - `ComputerUseTool` — `computer_use(task)` — `requiresConfirmation = true`, description esplicita "USA SOLO se altri tool non bastano, costa ~$0.20"
- [ ] **1.1.6** Creare `GigiToolRegistry` singleton con `var all: [any GigiTool]` e metodo `selectRelevant(for text: String) -> [any GigiTool]` (meta-classifier regex, max 10 tool, sempre inclusi: makeCall, sendMessage, askTime, askDate, weather)
- [ ] **1.1.7** Implementare `FindFreeSlotTool.semanticRange(for:preferred:)` con casi: pranzo 12:00–14:30, cena 19:00–21:30, mattina 08:00–12:00, default 09:00–18:00

### 1.2 — Aggiornare `GigiCloudService.swift` ✅

- [x] **1.2.1** `GigiContent(role, parts: [GigiPart])` ✅
- [x] **1.2.2** `GigiPart` custom Encodable — esattamente 1 campo, nil non serializzati ✅
- [x] **1.2.3** `GigiLLMResponse(text?, functionCalls: [FunctionCallBlock], finishReason)` + `FunctionCallBlock.asArgs` ✅
- [x] **1.2.4** `callWithFunctions(systemInstruction:contents:tools:cacheId:)` — build JSON via JSONEncoder, cacheId rimuove system+tools dal payload ✅
- [x] **1.2.5** `createContextCache` — POST cachedContents, TTL 1h, graceful nil se sotto soglia ✅
- [x] **1.2.6** `parseLLMResponse` — estrae text + functionCall multipli (parallel calls) ✅
- [x] **1.2.7** timeout 10s `withThrowingTaskGroup` ✅
- [x] **1.2.8** `processWithGemini` e `classifyIntent` invariati ✅
- [x] `JSONAny: Codable` per args (string/number/bool/array/object) ✅
- [x] `GigiCloudError.missingAPIKey` ✅

### 1.3 — Creare `GigiAgentEngine.swift` ✅

- [ ] **1.3.1** Definire struct `AgentResult`:
  ```swift
  struct AgentResult {
      let speech: String
      let executedTools: [String]
      let isFollowUp: Bool
      let costEstimate: Double
      let requiresConfirm: ConfirmRequest?
  }
  ```
- [ ] **1.3.2** Definire struct `ConfirmRequest` (type: ConfirmType, summary: String, action: String, args: [String: Any])
- [ ] **1.3.3** Definire enum `ConfirmType` (.payment, .destructive, .sensitive)
- [ ] **1.3.4** Implementare `func process(text: String) async -> AgentResult` — entry point principale
- [ ] **1.3.5** Implementare `agentLoop(userText:history:) async -> AgentResult` con:
  - `maxIterations = 5`
  - `globalTimeout = 15.0s` (deadline = Date() + 15s, check ogni iterazione)
  - Chiamata a `GigiToolRegistry.shared.selectRelevant(for: text)` per meta-classifier
  - Chiamata a `GigiCloudService.shared.callWithFunctions(contents:tools:cacheId:)`
  - Se risposta ha `functionCalls` → `executeParallel(calls)` → append model content + tool results → loop
  - Se risposta ha `text` → ritorna `AgentResult(speech: text, ...)`
  - Se supera maxIterations → ritorna safety lock message: "Sto avendo difficoltà con questo compito — vuoi che provi in un altro modo?"
- [ ] **1.3.6** Implementare `func executeParallel(_ calls: [FunctionCallBlock]) async -> [ToolResult]` con `withTaskGroup`:
  ```swift
  let results = await withTaskGroup(of: ToolResult.self) { group in
      for call in calls {
          group.addTask { await self.executeToolCall(call) }
      }
      return await group.reduce(into: []) { $0.append($1) }
  }
  ```
- [ ] **1.3.7** Implementare `func executeToolCall(_ call: FunctionCallBlock) async -> ToolResult` — lookup tool in GigiToolRegistry, chiama `tool.execute(args:)`
- [ ] **1.3.8** Dopo ogni iterazione con functionCalls: chiamare `emitCognitiveConfirmation(iteration:)` → HapticEngine.impact(.light) se iteration > 0
- [ ] **1.3.9** Gestione `requiresConfirm`: se un ToolResult ha `requiresConfirm != nil` → ritorna immediatamente `AgentResult.pendingConfirmation`
- [ ] **1.3.10** Implementare `func confirmAndContinue(_ request: ConfirmRequest) async -> AgentResult` — riprende il loop dal punto di conferma
- [ ] **1.3.11** Implementare `var onInterimEvent: ((InterimEvent) -> Void)?` callback per UI
- [ ] **1.3.12** Definire enum `InterimEvent` (.thinking(iteration), .toolStarted(name), .toolCompleted(name, result), .waitingForConfirmation(ConfirmRequest))
- [ ] **1.3.13** Implementare `costEstimate` tracking: somma `tokenEstimate` di ogni ToolResult × costo token Gemini stimato
- [ ] **1.3.14** Inizializzare `cacheId` alla prima chiamata (lazy), riutilizzarlo per tutta la sessione

### 1.4 — Creare `GigiActionDispatcher+Native.swift`

- [ ] **1.4.1** Spostare da `GigiActionDispatcher.swift` tutta la logica tool nativi (make_call, send_message, navigate, play_music, set_reminder, create_event, set_alarm, set_timer, open_app, ask_time, ask_date, weather, torch, facetime, media controls, read_calendar, read_week_calendar, find_free_slot, search_web, read_news, send_email, toggle_wifi, toggle_bluetooth, homekit_*, remember, recall, search_groups)
- [ ] **1.4.2** Ogni case chiama `GigiActionBridge.shared.execute(GigiIntent(...))` con intent label + params corrispondenti al tool name
- [ ] **1.4.3** Gestione `contact_id` per disambiguazione: se `execute` ritorna `"multiple_matches:..."` → parsare il JSON di match → ritornare `ToolResult` con errore strutturato che Gemini può usare per chiedere chiarimento
- [ ] **1.4.4** Extension `GigiActionDispatcher` (non nuovo tipo) per mantenere l'interfaccia esistente

### 1.5 — Creare `GigiActionDispatcher+Web.swift`

- [ ] **1.5.1** Spostare/creare routing per web tool: web_whatsapp → GigiWebAgent.shared.sendWhatsApp
- [ ] **1.5.2** web_book_restaurant → GigiWebAgent.shared.bookRestaurant
- [ ] **1.5.3** web_order_food → GigiComputerUse.shared.execute(task:)
- [ ] **1.5.4** web_search_and_read → GigiWebAgent.shared.searchAndRead
- [ ] **1.5.5** computer_use → GigiComputerUse.shared.execute(task:)
- [ ] **1.5.6** Ogni call web emette `.toolStarted(name)` su GigiAgentEngine.onInterimEvent

### 1.6 — Aggiornare `GigiConversationMemory.swift`

- [ ] **1.6.1** Aggiungere `var contentsArray: [GigiContent]` (formato nativo Gemini multi-turn invece di stringa concatenata)
- [ ] **1.6.2** Implementare `func addUserTurn(_ text: String)` → append `GigiContent(role: "user", parts: [.text(text)])`
- [ ] **1.6.3** Implementare `func addModelTurn(calls: [FunctionCallBlock])` → append `GigiContent(role: "model", parts: calls.map { .functionCall($0) })`
- [ ] **1.6.4** Implementare `func addToolResults(_ results: [(name: String, result: String)])` → append `GigiContent(role: "user", parts: results.map { .functionResponse($0) })`
- [ ] **1.6.5** Implementare `func addModelSpeech(_ text: String)` → append `GigiContent(role: "model", parts: [.text(text)])`
- [ ] **1.6.6** Implementare `func contents(pruningIfNeeded: Bool) -> [GigiContent]` con token budget 8.000:
  - Scorri dall'ultima all'inizio, somma `estimateTokens(content)`
  - Se supera 8.000 → taglia i più vecchi
  - Se tagliati > 0 → prepend `systemContent("Conversazione precedente (riassunto): ...")`
- [ ] **1.6.7** Implementare `private func estimateTokens(_ content: GigiContent) -> Int` — approssimazione: 1 token ≈ 4 chars
- [ ] **1.6.8** Implementare `private func truncateLongToolResults(_ content: GigiContent) -> GigiContent` — functionResponse > 500 chars → tronca + "[troncato per brevità]"
- [ ] **1.6.9** Implementare `func saveSession()` — `JSONEncoder` → `UserDefaults` + timestamp
- [ ] **1.6.10** Implementare `func loadIfRecentSession() -> [GigiContent]?` — carica se timestamp < 1h fa

### 1.7 — Aggiornare `GigiSmartOrchestrator.swift`

- [ ] **1.7.1** Aggiungere `private let agentEngine = GigiAgentEngine.shared`
- [ ] **1.7.2** Sostituire `process(text:)` per chiamare `GigiAgentEngine.shared.process(text:)` invece di `GigiBrainPipeline`
- [ ] **1.7.3** Gestire `AgentResult.requiresConfirm != nil`: chiamare `speech.speak(request.summary)`, settare `pendingConfirmRequest`, passare a stato `.recordingForConfirm`
- [ ] **1.7.4** Gestire turno di conferma utente ("sì/vai/procedi") → `GigiAgentEngine.shared.confirmAndContinue(pendingConfirmRequest!)`
- [ ] **1.7.5** Wiring `GigiAgentEngine.onInterimEvent` → `self.status = "GIGI: \(caption(for: name))..."` + haptic
- [ ] **1.7.6** Implementare `func caption(for toolName: String) -> String` — mappa tool name → testo UI italiano ("Sto navigando su Deliveroo...", "Sto cercando slot...")
- [ ] **1.7.7** Dopo `AgentResult` → `memory.saveSession()` + `memory.addModelSpeech(result.speech)` + `speech.speak(result.speech)`
- [ ] **1.7.8** Aggiornare `showGatewayInstallPrompt` logic: non più necessario in v3 (rimuovere se non usato)

### 1.8 — Test accettazione Fase 1

- [ ] **1.8.1** "Chiama Marco" → chiama, nessuna regressione
- [ ] **1.8.2** "Chiama Marco e mandagli anche un messaggio" → esegue entrambi in sequenza
- [ ] **1.8.3** "Buonanotte Gigi" → homekit_scene + set_alarm + media_play_pause in parallelo (TaskGroup)
- [ ] **1.8.4** "Se c'è pioggia domani metti un reminder" → weather → (condizionale) set_reminder (2 iterazioni)
- [ ] **1.8.5** Multi-turn coreference: "chiama Marco" → "e mandagli un messaggio" → "lo" risolto correttamente
- [ ] **1.8.6** Superamento maxIterations → risposta safety lock
- [ ] **1.8.7** Superamento globalTimeout (15s) → risposta safety lock

---

## FASE 2 — Audio UX + Earcons

### 2.1 — Creare `SoundEngine.swift`

- [ ] **2.1.1** Definire enum `EarconEvent` (.wakeWord, .taskDone, .error, .thinking, .confirmRequired)
- [ ] **2.1.2** Implementare `static func play(_ event: EarconEvent)` con `AVAudioEngine` + buffer sintetizzato — zero file audio
- [ ] **2.1.3** Earcon wakeWord: tono ascendente 440→880Hz, 120ms
- [ ] **2.1.4** Earcon taskDone: doppio blip (do-mi), 200ms
- [ ] **2.1.5** Earcon error: tono discendente 880→440Hz, 180ms
- [ ] **2.1.6** Earcon thinking: leggero pulse ogni 2s, 80ms
- [ ] **2.1.7** Earcon confirmRequired: trillo breve, 300ms
- [ ] **2.1.8** Implementare `static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle)` per haptic
- [ ] **2.1.9** Wiring in GigiSmartOrchestrator: wake word detected → `.wakeWord`, task done → `.taskDone`, error → `.error`
- [ ] **2.1.10** Wiring in GigiAgentEngine.onInterimEvent: `.thinking(i > 0)` → `SoundEngine.play(.thinking)` + `SoundEngine.impact(.light)`

### 2.2 — Aggiornare `GigiVADEngine.swift`

- [ ] **2.2.1** Implementare `func adaptiveSilenceThreshold(for partialTranscript: String) -> TimeInterval`:
  - 0–2 parole → 0.8s
  - 3–8 parole → 1.2s
  - 9+ parole → 1.8s
- [ ] **2.2.2** Sostituire silence timeout fisso con `adaptiveSilenceThreshold` — aggiornare ogni volta che arriva un partial result
- [ ] **2.2.3** Test: "torcia on" → risposta entro 0.8s silenzio; dettatura lunga → aspetta 1.8s

### 2.3 — Aggiornare `GigiAudioSequestrator.swift`

- [ ] **2.3.1** Aggiungere `.allowBluetooth` e `.allowBluetoothA2DP` alle options del `setCategory(.playAndRecord, mode: .voiceChat, options: [...])`
- [ ] **2.3.2** Aggiungere `.duckOthers` per ducking Spotify/YouTube durante ascolto
- [ ] **2.3.3** Test con AirPods: GIGI parla dall'AirPod, non dall'altoparlante

### 2.4 — Aggiornare `GigiRealtimeEngine.swift`

- [ ] **2.4.1** Implementare `private func downsample(_ buffer: AVAudioPCMBuffer) -> Data`:
  - Target format: PCM Int16, 16.000Hz, 1 canale, interleaved
  - Usare `AVAudioConverter(from: buffer.format, to: targetFormat)`
  - Ritorna `Data` PCM 16kHz
- [ ] **2.4.2** Sostituire invio buffer grezzo con `downsample(buffer)` → `websocket.send(.data(pcm16))`
- [ ] **2.4.3** Implementare `handleServerContent(_ message: LiveMessage)` con gestione interruzione:
  - Se `message.isInterruption` → `audioPlayerNode.stop()`, `audioPlayerNode.reset()`, `pendingAudioBuffers.removeAll()`
  - `GigiAudioManager.shared.transitionTo(.recording)`
  - chiamare `onBargein?()`
- [ ] **2.4.4** Implementare `StreamingAudioPlayer` con jitter buffer 80ms:
  - `private var jitterBuffer: [AVAudioPCMBuffer] = []`
  - Accumula chunks finché `totalDurationMs >= 80`
  - Poi `scheduleFromBuffer()`
- [ ] **2.4.5** Esporre `var onBargein: (() -> Void)?` — GigiSmartOrchestrator lo wira per interrompere TTS locale

---

## FASE 3 — Memoria RAG + Keychain

### 3.1 — Creare `GigiVectorStore.swift`

- [ ] **3.1.1** Import `NaturalLanguage`
- [ ] **3.1.2** Inizializzare `private let embedder = NLEmbedding.wordEmbedding(for: .english)!`
- [ ] **3.1.3** Implementare `func embed(_ text: String) -> [Float]` — usa `embedder.vector(for:)` su ogni parola, media i vettori
- [ ] **3.1.4** Implementare `func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float`
- [ ] **3.1.5** Implementare `func relevantMemories(for text: String, topK: Int = 5) -> [GigiMemoryRecord]`:
  - Calcola `embed(text)`
  - Mappa ogni record: `(record, cosineSimilarity(queryEmbedding, record.embedding ?? []))`
  - Ordina desc, prendi i primi `topK`
- [ ] **3.1.6** Implementare `func preload(namespaces: [Namespace])` — pre-carica in memoria i record dei namespace richiesti (async)
- [ ] **3.1.7** Aggiungere `var allRecords: [GigiMemoryRecord]` (sincronizzato con GigiMemory.shared)

### 3.2 — Aggiornare `GigiMemory.swift`

- [ ] **3.2.1** Aggiungere namespace `opinion` e `relation` a enum `Namespace`
- [ ] **3.2.2** Aggiungere campo `expiresAt: Date?` a `GigiMemoryRecord`
- [ ] **3.2.3** Aggiungere campo `embedding: [Float]?` a `GigiMemoryRecord`
- [ ] **3.2.4** Aggiungere campo `confidence: Float` e `source: MemorySource` (.user, .inferred, .routine) a `GigiMemoryRecord`
- [ ] **3.2.5** Implementare TTL per namespace `.context`: `record.expiresAt = Date() + 7 * 24 * 3600` al momento del salvataggio
- [ ] **3.2.6** Implementare `func cleanup()` — rimuove record con `expiresAt < Date()`, chiamato all'avvio app
- [ ] **3.2.7** Implementare soft confirmation per record `.inferred` con `confidence < 0.7`:
  - Invece di usare silenziosamente → speech.speak("Ho notato che... è corretto?")
  - Se confermato → `record.source = .user`, `record.confidence = 1.0`
- [ ] **3.2.8** Al `remember(key:value:)`: calcolare embedding via `GigiVectorStore.shared.embed(value)`, salvarlo in `record.embedding`
- [ ] **3.2.9** Implementare `relation:` shortcuts: "my wife is Sarah" → `relation:wife = "Sarah"`, "my boss is Marco Bianchi" → `relation:boss = "Marco Bianchi"`
- [ ] **3.2.10** Implementare `opinion:` parsing: "odio aspettare più di 10 minuti" → `opinion:attesa_ristorante = "massimo 10 minuti"`

### 3.3 — Aggiornare `GigiKeychain.swift`

- [ ] **3.3.1** Verificare che esista `static func save(key: String, value: Data) throws` con `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- [ ] **3.3.2** Verificare che esista `static func load(key: String) throws -> Data`
- [ ] **3.3.3** Aggiungere `static func delete(key: String) throws`
- [ ] **3.3.4** Aggiungere `static func saveString(_ string: String, key: String) throws` / `static func loadString(key: String) throws -> String`
- [ ] **3.3.5** Usare GigiKeychain in GigiCloudService per salvare/caricare token OAuth (non UserDefaults)
- [ ] **3.3.6** Usare GigiKeychain in GigiWebAgent per salvare cookie cifrati per sessione WhatsApp Web

### 3.4 — Aggiornare `GigiConversationMemory.swift` (disco)

- [ ] **3.4.1** `saveSession()` → `JSONEncoder().encode(contentsArray)` → `UserDefaults` + `Date()` (già pianificato in 1.6.9)
- [ ] **3.4.2** `loadIfRecentSession()` → check timestamp < `sessionTimeout` (3600s), decode e ripristina `contentsArray`
- [ ] **3.4.3** Chiamare `loadIfRecentSession()` in `GigiSmartOrchestrator.init()` se sessione recente trovata

---

## FASE 4 — Web Automation On-Device

### 4.1 — Aggiornare `GigiWebAgent.swift`

- [ ] **4.1.1** Aggiungere `WKWebView` hidden (1×1pt) con `WKWebsiteDataStore.default()` per cookie persistenti
- [ ] **4.1.2** Settare User-Agent desktop: `"Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"` via `webView.customUserAgent`
- [ ] **4.1.3** Implementare helper `func navigate(_ url: String) async throws`
- [ ] **4.1.4** Implementare helper `func waitForElement(_ selector: String, timeout: TimeInterval) async throws`
- [ ] **4.1.5** Implementare helper `func click(_ selector: String) async throws` via `webView.evaluateJavaScript`
- [ ] **4.1.6** Implementare helper `func type(_ selector: String, text: String) async throws`
- [ ] **4.1.7** Implementare `func sendWhatsApp(contact: String, message: String) async -> String`:
  - navigate `https://web.whatsapp.com`
  - waitForElement `div[title='\(contact)']` timeout 5s
  - click contatto → waitForElement input → type → click send
  - Ritorna "Messaggio inviato a \(contact)."
- [ ] **4.1.8** Implementare `func bookRestaurant(restaurant: String, time: String, guests: Int, date: String, platform: String) async -> String`:
  - Supportare TheFork, OpenTable, Resy
  - Ritornare `CONFIRM_REQUIRED: ...` se arriva a pagamento
- [ ] **4.1.9** Implementare `func searchAndRead(query: String) async -> String` — Google + lettura primo risultato rilevante

### 4.2 — Creare `GigiComputerUse.swift`

- [ ] **4.2.1** Definire struct `ComputerUseRequest` (task: String, context: [String: Any], userAgent: String)
- [ ] **4.2.2** Definire struct `ComputerUseResponse` (success: Bool, result: String?, requiresConfirm: Bool, summary: String?, jobId: String?)
- [ ] **4.2.3** Implementare `func execute(task: String) async -> ComputerUseResponse`:
  - POST a `{GigiConfig.backendURL}/api/computer-use` con `ComputerUseRequest`
  - Timeout 8s → se risposta `{ status: "processing", jobId }` → salva `jobId` per tracking asincrono
  - Se risposta completa → parse `ComputerUseResponse`
- [ ] **4.2.4** Implementare `func pollJobStatus(jobId: String) async -> ComputerUseResponse` — GET `/api/computer-use/status/:jobId`
- [ ] **4.2.5** Gestione silent push: in `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` (GIGIApp.swift) → se `userInfo["gigi_result"]` → `GigiSpeechService.shared.speak(result["result"])`
- [ ] **4.2.6** Progress updates: WebSocket o polling ogni 3s mentre `jobId` in corso → aggiorna `GigiSmartOrchestrator.status`

---

## FASE 5 — Backend Claude Computer Use

### 5.1 — `01_SERVER_MDM/queue.js` (NUOVO)

- [ ] **5.1.1** Setup BullMQ con Redis: `new Queue('computer-use', { connection: redis })`
- [ ] **5.1.2** Worker con `concurrency: 5` (max 5 browser contemporanei, ~600MB RAM ciascuno)
- [ ] **5.1.3** `lockDuration: 120000` (2 min timeout per task)
- [ ] **5.1.4** Export `{ computerUseQueue, queueEvents }`

### 5.2 — `01_SERVER_MDM/computerUse.js` (NUOVO)

- [ ] **5.2.1** Implementare `runComputerUseLoop({ page, task, context, userId })`:
  - Loop max 20 step
  - Screenshot `1280×800`, JPEG quality 70 (risparmio token)
  - Chiamata `anthropic.messages.create` con model `claude-sonnet-4-6`, tool `computer_20241022`
  - System prompt: regole su NO checkout senza confirm, chiudi upsell popup, restituisci CONFIRM_REQUIRED con totale
  - Se `toolUse` → `executeComputerAction(page, toolUse.input)` → `sendProgressUpdate(userId, ...)`
  - Se text inizia con `CONFIRM_REQUIRED:` → return `{ success: false, requiresConfirm: true, summary }`
  - Se text inizia con `REQUIRES_HUMAN_INTERVENTION` → return `{ success: false, requiresHuman: true }`
  - Se `end_turn` → return `{ success: true, result: textBlock.text }`
- [ ] **5.2.2** Implementare `executeComputerAction(page, input)` — gestisce `click`, `type`, `screenshot`, `key`, `scroll`
- [ ] **5.2.3** CAPTCHA handling: se `requiresHuman: true` → iOS apre GigiWebAgent con stessa URL visibile all'utente → utente risolve → notifica al backend → task riprende

### 5.3 — `01_SERVER_MDM/sessionStore.js` (NUOVO)

- [ ] **5.3.1** Salvare cookies per userId cifrati AES-256 (chiave da `process.env.COOKIE_ENCRYPTION_KEY`)
- [ ] **5.3.2** `async function getUserCookies(userId, userAgent)` — ritorna cookies decifrati per Playwright
- [ ] **5.3.3** `async function saveUserCookies(userId, cookies, userAgent)` — cifra e salva
- [ ] **5.3.4** Chiave di cifratura in variabile d'ambiente, mai hardcoded

### 5.4 — `01_SERVER_MDM/progress.js` (NUOVO)

- [ ] **5.4.1** WebSocket server su path `/ws/progress`
- [ ] **5.4.2** `function sendProgressUpdate(userId, message)` — invia a tutti i client connessi con `userId`
- [ ] **5.4.3** iOS `GigiComputerUse.swift` si connette al WS durante esecuzione job asincrono

### 5.5 — Aggiornare `01_SERVER_MDM/server.js`

- [ ] **5.5.1** Aggiungere `POST /api/computer-use` con middleware `authenticate`
- [ ] **5.5.2** Aggiungere alla queue → `Promise.race([job.waitUntilFinished(), setTimeout 8000])` → se async risponde `{ status: 'processing', jobId }`
- [ ] **5.5.3** Aggiungere `GET /api/computer-use/status/:jobId`
- [ ] **5.5.4** Passare `userAgent` da request a Playwright: `await page.setUserAgent(req.body.userAgent)`
- [ ] **5.5.5** Silent push notification al completamento job asincrono: `{ "aps": { "content-available": 1 }, "gigi_result": { "task_id", "result" } }`

### 5.6 — Test end-to-end Fase 5

- [ ] **5.6.1** Ordine Deliveroo web su sessione loggata (simulato): task → conferma → ordine
- [ ] **5.6.2** Task > 8s → risposta async `jobId` → iOS riceve silent push → GIGI parla risultato
- [ ] **5.6.3** CAPTCHA: backend → `requiresHuman` → iOS apre WKWebView → utente risolve → task riprende

---

## FASE 6 — Context Cache + Streaming TTS + Meta-classifier

### 6.1 — Context Caching Gemini

- [ ] **6.1.1** In `GigiCloudService.createContextCache`: POST a `v1beta/cachedContents` con system prompt + tool declarations (già in 1.2.5)
- [ ] **6.1.2** In `GigiAgentEngine`: lazy init `cacheId` alla prima `process()`, riutilizzare per tutta sessione
- [ ] **6.1.3** Se Context Cache scade (TTL default 1h) → ricrearlo automaticamente
- [ ] **6.1.4** Log risparmio stimato: "Cache hit: ~3000 token saved"

### 6.2 — Streaming TTS

- [ ] **6.2.1** Aggiungere `func streamSpeak(_ text: String)` a `GigiSpeechService` — accoda il testo per TTS senza aspettare la frase completa
- [ ] **6.2.2** In `GigiCloudService.callWithFunctions`: implementare variante SSE streaming via `URLSession` data task con `didReceive data`
- [ ] **6.2.3** Implementare `handleStreamingResponse(_ stream: AsyncThrowingStream<String, Error>)`:
  - Accumula token in buffer
  - Trova sentence boundary (`.`, `!`, `?`, `,` dopo N chars)
  - Chiama `speech.streamSpeak(sentence)` a ogni boundary
  - Flush buffer residuo a fine stream
- [ ] **6.2.4** Wiring: GigiAgentEngine usa streaming solo per risposta finale (non durante tool execution)

### 6.3 — CoreML Meta-classifier per instant commands

- [ ] **6.3.1** Definire `instantCommands: [String: () -> Void]`:
  - `"torch_on"` → `TorchTool().executeSync()`
  - `"torch_off"` → `TorchTool().executeSync(off: true)`
  - `"media_play_pause"` → `MediaTool().executeSync()`
  - `"media_next"` → `MediaTool().nextSync()`
- [ ] **6.3.2** In `GigiAgentEngine.process()`: prima di tutto il resto, tentare `localClassifier.classify(text)` — se match in `instantCommands` → esegui + ritorna `AgentResult(speech: "", executedTools: [instant], ...)`
- [ ] **6.3.3** `localClassifier`: inizialmente regex semplice (< 3 parole, parola chiave esatta), poi CoreML model se disponibile

---

## FASE 7 — UI

### 7.1 — Creare `ToolOverlayView.swift`

- [ ] **7.1.1** SwiftUI view trasparente (overlay su app principale) — visibile solo durante web automation
- [ ] **7.1.2** Mostrare: nome tool corrente, step progress ("Step 3 di 20"), spinner animato
- [ ] **7.1.3** Se `confirmRequired`: card centrata con summary (es. "Panino prosciutto €8.50 su Deliveroo"), pulsante "Procedi" e "Annulla"
- [ ] **7.1.4** Binding a `GigiSmartOrchestrator.status` e a `pendingConfirmRequest`
- [ ] **7.1.5** Aggiungere a `MainTabView.swift` come `.overlay(ToolOverlayView())`

### 7.2 — Aggiornare `DashboardView.swift`

- [ ] **7.2.1** Aggiungere sezione "Costi sessione": "Oggi: $\(costToday)" | "Mese: $\(costMonth)"
- [ ] **7.2.2** Aggregare `AgentResult.costEstimate` da ogni sessione in `UserDefaults`
- [ ] **7.2.3** Mostrare indicatore visivo se costo giornaliero > $0.10 (warning colore)

---

## FASE 8 — Fix UIKit / Build

- [x] **8.1** `GigiWakeWordEngine.swift` — aggiunto `import UIKit` (fix `UIScreen` compile error) ✅

---

## FASE 9 — Integrazione Harness (`03_HARNESS/`)

Il sottosistema Node è stato assorbito nel repo GIGI. Vedi `Architecture Armando Revision.md` §9.BIS per contesto.

### 9.0 — Git / layout

- [x] **9.0.1** Rimuovere `.git` nested di `03_HARNESS/` (1 commit, in sync, zero lavoro locale) ✅
- [x] **9.0.2** Aggiornare path refs stale (`Harness/` → `03_HARNESS/`) in docs harness ✅
- [x] **9.0.3** Aggiungere sezione 9.BIS ad `Architecture Armando Revision.md` ✅
- [x] **9.0.4** Aggiornare `INVENTARIO_COMPLETO.md` con contenuto harness ✅

### 9.1 — Bootstrap Mac

- [ ] **9.1.1** Creare `03_HARNESS/telegram-bridge/config.example.mac.json` con path Unix (`~/.local/bin/claude`, `/Applications/Google Chrome.app/...`)
- [ ] **9.1.2** Creare `03_HARNESS/telegram-bridge/kill.sh` equivalente a `kill.ps1`
- [ ] **9.1.3** Creare `03_HARNESS/telegram-bridge/start.sh` equivalente a `start.bat`
- [ ] **9.1.4** `cd 03_HARNESS/telegram-bridge && npm install` — verifica zero errori
- [ ] **9.1.5** `cd 03_HARNESS/browser-mcp && npm install` — verifica zero errori
- [ ] **9.1.6** Smoke test: `node bridge.js` parte, panel raggiungibile `http://localhost:7777`

### 9.2 — Decisione use case integrazione (BLOCCANTE)

Prima di qualsiasi codice runtime: scegliere lo use case tra:
- **A** Zero-code (repo/docs unificati, nessuna chiamata HTTP incrociata) — già coperto da 9.0
- **B** Telegram-only (harness canale autonomo, iOS non lo chiama mai)
- **C** Shared memory (`POST /api/memory/*` da iOS)
- **D** Delegated browser (`POST /api/computer-use` da iOS — richiede restructure harness perché oggi usa CLI claude, non Anthropic SDK)
- **E** Confirm push (harness → APNS → iOS)

Task 9.3–9.5 sotto si attivano solo se C/D/E scelti. Se A o B: chiudere fase 9 qui.

### 9.3 — (condizionale C/D/E) Spec API iOS ↔ Harness

- [ ] **9.3.1** Scrivere `03_HARNESS/docs/api/ios-integration.md` (endpoint, payload, auth, errori)
- [ ] **9.3.2** Validare spec con mapping 1:1 ai tool iOS coinvolti

### 9.4 — (condizionale) Client iOS

- [ ] **9.4.1** `GigiHarnessClient.swift` — HTTP via URLSession
- [ ] **9.4.2** `HARNESS_BASE_URL` + secret da Keychain
- [ ] **9.4.3** Aggiornare tool coinvolti (`GigiComputerUse` per D, `GigiMemory` per C, ecc.)

### 9.5 — (condizionale) Endpoint server

- [ ] **9.5.1** Estendere `panel-routes.js` con endpoint scelti
- [ ] **9.5.2** Middleware auth Bearer
- [ ] **9.5.3** Integrazione con browser-mcp (se D) / storage memoria (se C)

### 9.6 — (condizionale) E2E test

- [ ] **9.6.1** Scenario completo iOS → harness → risposta
- [ ] **9.6.2** Latenza end-to-end
- [ ] **9.6.3** Cleanup/no leak

---

## Metriche di accettazione finale

| Metrica | Target | Test |
|---|---|---|
| Latenza instant (torch/media) | < 100ms | Instruments |
| Latenza azioni native (REST) | < 800ms | Log voice-end → action |
| Web automation semplice | < 5s | Log end-to-end |
| Web automation complessa | < 40s | Log end-to-end |
| Accuratezza intent italiano | > 95% | 100 comandi test |
| Coreference resolution | > 90% | Test "lui/lei/lì/quello" |
| Parallel execution (3 tool) | max(single) + 200ms | Timing test |
| Token history 10 turni | < 8.000 | Log token count |
| Costo medio sessione Pro | < $0.30 | costEstimate aggregato |

---

*Task plan generato: 2026-04-21 — basato su Architecture Armando Revision.md rev.2*
