# GIGI v3 — Architettura "True Agent"
### Paper tecnico completo — Aprile 2026 (rev. 2 — peer reviewed)

> **Paradigma v3**: GIGI non è un command parser. È un agente AI che ragiona, pianifica,
> chiama tool, vede i risultati, e decide autonomamente il passo successivo — esattamente
> come un essere umano con accesso illimitato a tutti i tuoi dispositivi, app, e servizi web.

---

## Indice

1. [Visione e obiettivo](#1-visione-e-obiettivo)
2. [Perché la v2 non basta](#2-perche-la-v2-non-basta)
3. [Il cuore del cambiamento: l'Agent Loop](#3-il-cuore-del-cambiamento-lagent-loop)
4. [Stack tecnologico completo](#4-stack-tecnologico-completo)
5. [GigiAgentEngine — il cervello](#5-gigiagentengine--il-cervello)
6. [GigiToolRegistry — i 38 tool](#6-gigitoolregistry--i-38-tool)
7. [Layer audio — VAD, Live, Earcons, Ducking](#7-layer-audio--vad-live-earcons-ducking)
8. [Web Automation — architettura ibrida](#8-web-automation--architettura-ibrida)
9. [Backend: Claude Computer Use](#9-backend-claude-computer-use)
9.BIS. [Harness — Implementazione layer Node](#9bis-harness--implementazione-layer-operativo-node)
10. [Sicurezza e Trust (Confirm Mode + Keychain)](#10-sicurezza-e-trust-confirm-mode--keychain)
11. [Memoria persistente — RAG locale e tipi](#11-memoria-persistente--rag-locale-e-tipi)
12. [Conversazione multi-turn — token budget](#12-conversazione-multi-turn--token-budget)
13. [Gemini Live WebSocket — Barge-in e streaming](#13-gemini-live-websocket--barge-in-e-streaming)
14. [Capability map completa](#14-capability-map-completa)
15. [Flussi end-to-end — esempi reali](#15-flussi-end-to-end--esempi-reali)
16. [Limiti iOS — workaround e deep link](#16-limiti-ios--workaround-e-deep-link)
17. [Modello di costo e Freemium](#17-modello-di-costo-e-freemium)
18. [Struttura file del progetto](#18-struttura-file-del-progetto)
19. [Roadmap implementativa](#19-roadmap-implementativa)
20. [Metriche di successo](#20-metriche-di-successo)
21. [Rework log (living)](#21-rework-log-living) — tracking modifiche dal 2026-05-07 in poi

---

## 1. Visione e obiettivo

**GIGI deve essere Jarvis. Non Siri.**

| Capacità | Siri | GIGI v2 | GIGI v3 |
|---|---|---|---|
| "Chiama Marco" | ✅ con conferma | ✅ senza conferma | ✅ senza conferma |
| "Manda WhatsApp a Marco" | ⚠️ apre app | ⚠️ apre app | ✅ manda senza tap |
| "Prenota da Sakura stasera alle 8" | ❌ | ⚠️ tenta via web | ✅ prenota autonomamente |
| "Ordinami una pizza" | ❌ | ⚠️ apre Deliveroo | ✅ naviga il sito e ordina (con confirm) |
| "Trova slot domani mattina e invita Marco" | ❌ | ❌ | ✅ legge cal → trova → crea evento → manda invite |
| Ricorda chi è Marco | ❌ | ✅ | ✅ + iniettato automaticamente nel contesto |
| Mantiene contesto conversazione | ❌ | ⚠️ testo piatto | ✅ LLM multi-turn strutturato |
| Concatena azioni autonomamente | ❌ | ⚠️ GigiPlanner limitato | ✅ agent loop con parallel execution |
| Vede risultato tool → decide next step | ❌ | ❌ | ✅ functionResponse nel loop |
| Conferma prima di spendere soldi | ❌ | ❌ | ✅ Confirm Mode obbligatorio |

**Obiettivo quantitativo:**
- Latenza voice-to-action: < 800ms per azioni native (local NLU), < 4s per REST, < 200ms per Live
- Zero tap per il 99% dei comandi comuni (escluse conferme di pagamento — deliberate)
- Contesto mantenuto per tutta la durata di una conversazione (budget: 8.000 token)
- Costo medio per sessione: < $0.05 per comandi nativi, < $0.30 per web automation complessa

---

## 2. Perché la v2 non basta

### Il problema fondamentale: one-shot NLU

La v2 funziona così:

```
User speech → NLU (classifica intent) → 1 azione → esegui → parla
```

Questo ha tre problemi critici:

**Problema 1: Nessun feedback loop**
Dopo che un tool viene eseguito, il risultato non torna mai all'LLM. GIGI non
sa se l'azione è riuscita, fallita, o ha prodotto un risultato che richiede
un'azione successiva. Risponde sempre con il messaggio pre-programmato del bridge.

**Problema 2: Nessun ragionamento multi-step autonomo**
`GigiPlanner` esiste ma viene triggerato solo da parole chiave rigide ("organizza", "pianifica").
Il piano è costruito prima dell'esecuzione — se un passo fallisce, non si adatta.
→ **GigiPlanner è deprecato in v3.** L'intelligenza si sposta tutta in GigiAgentEngine.

**Problema 3: History come testo piatto**
```
"--- Conversation history ---
[User] chiama marco
[GIGI] Calling Marco.
Current message: e mandagli anche un messaggio"
```
Gemini non può ragionare su coreference ("lui", "lì", "quello") con la stessa
potenza di un sistema che usa il formato nativo `contents[]` multi-turn.

### La soluzione: Agent Loop con Gemini Function Calling nativo

```
User speech
    → Gemini (con 38 tool dichiarati nativamente)
         ↓ se functionCall (singolo o parallelo)
      esegui tool(s) → risultato reale
         ↓ functionResponse → Gemini vede il risultato
      Gemini decide: altro tool? risposta finale?
         ↓ se altro functionCall → loop (max 5 iterazioni)
         ↓ se testo → TTS in streaming
    → GIGI parla
```

---

## 3. Il cuore del cambiamento: l'Agent Loop

### Gemini Function Calling nativo

Invece di parsare JSON da testo, si dichiarano i tool come schemi strutturati.
Gemini risponde con `functionCall` formali, e si risponde con `functionResponse`.

**Formato richiesta:**
```json
{
  "contents": [
    { "role": "user", "parts": [{ "text": "ordinami una pizza da Domino's" }] }
  ],
  "tools": [{
    "functionDeclarations": [{
      "name": "web_order_food",
      "description": "Ordina cibo da un ristorante via web. USA SOLO se i tool nativi non bastano.",
      "parameters": {
        "type": "object",
        "properties": {
          "restaurant": { "type": "string" },
          "items":      { "type": "string" },
          "platform":   { "type": "string", "enum": ["deliveroo","ubereats","doordash","grubhub","justeat","glovo","auto"] }
        },
        "required": ["restaurant"]
      }
    }]
  }]
}
```

**Risposta functionCall:**
```json
{ "candidates": [{ "content": { "role": "model",
  "parts": [{ "functionCall": { "name": "web_order_food",
    "args": { "restaurant": "Domino's", "platform": "deliveroo" } } }] } }] }
```

**Dopo esecuzione → functionResponse:**
```json
{ "contents": [
    { "role": "user",  "parts": [{ "text": "ordinami una pizza da Domino's" }] },
    { "role": "model", "parts": [{ "functionCall": { "name": "web_order_food", "args": {...} } }] },
    { "role": "user",  "parts": [{ "functionResponse": { "name": "web_order_food",
        "response": { "result": "CONFIRM_REQUIRED: Margherita €8.50 su Deliveroo. Procedo?" } } }] }
] }
```

### Parallel Function Calling

Gemini 2.0 Flash supporta l'emissione di **più functionCall nello stesso turno**.
GigiAgentEngine le esegue tutte in parallelo con `TaskGroup`:

```swift
// Se Gemini emette 3 tool call nello stesso turno → TaskGroup
let results = await withTaskGroup(of: ToolResult.self) { group in
    for call in functionCalls {
        group.addTask { await self.executeToolCall(call) }
    }
    return await group.reduce(into: []) { $0.append($1) }
}
// Tutti i risultati tornano a Gemini in un unico turno
```

**Esempio reale:** "Buonanotte Gigi" → Gemini chiama in parallelo:
- `homekit_scene(scene: "Notte")`
- `set_alarm(time: "7:30", date: "tomorrow")`
- `media_play_pause()`

Tutte e tre partono contemporaneamente → risultato in 1 secondo invece di 3.

### Il loop con safety lock

```swift
func agentLoop(userText: String, history: [GigiContent]) async -> AgentResult {
    var contents = history + [userContent(userText)]
    var executedTools: [String] = []
    let deadline = Date().addingTimeInterval(15.0)  // timeout globale

    for iteration in 0..<5 {  // maxIterations = 5
        guard Date() < deadline else { break }

        let response = await callGeminiWithTools(contents: contents)

        if let calls = response.functionCalls, !calls.isEmpty {
            // Feedback aptico/sonoro ogni iterazione
            emitCognitiveConfirmation(iteration: iteration)

            // Esecuzione parallela
            let results = await executeParallel(calls)
            executedTools.append(contentsOf: calls.map(\.name))

            // Controlla se qualcuno richiede conferma pagamento
            if let confirmNeeded = results.first(where: { $0.requiresConfirm }) {
                return .pendingConfirmation(confirmNeeded)
            }

            contents.append(modelContent(calls: calls))
            contents.append(toolResultsContent(results))

        } else if let text = response.text {
            return AgentResult(speech: text, tools: executedTools, followUp: response.followUp)
        } else {
            break
        }
    }

    // Safety lock: superato maxIterations
    return AgentResult(
        speech: "Sto avendo difficoltà con questo compito — vuoi che provi in un altro modo?",
        tools: executedTools, followUp: false
    )
}
```

### Meta-classifier: tool routing efficiente

Con 38 tool, mandare tutti gli schemi ogni volta costa troppo in token.
Un **Meta-classifier locale** (CoreML o regex leggero) seleziona i **10 tool più probabili**
per la richiesta dell'utente prima di chiamare Gemini:

```swift
func selectRelevantTools(for text: String) -> [FunctionDeclaration] {
    let lower = text.lowercased()
    var selected: [FunctionDeclaration] = []

    // Sempre inclusi (basso costo, alta frequenza)
    selected += [.makeCall, .sendMessage, .askTime, .askDate, .weather]

    // Aggiungi per categoria rilevata
    if lower.contains("music") || lower.contains("play") || lower.contains("spotify") {
        selected += [.playMusic, .mediaPlayPause, .mediaNext]
    }
    if lower.contains("order") || lower.contains("pizza") || lower.contains("food") {
        selected += [.webOrderFood, .computerUse]
    }
    if lower.contains("calendar") || lower.contains("meeting") || lower.contains("slot") {
        selected += [.readCalendar, .readWeekCalendar, .findFreeSlot, .createEvent]
    }
    if lower.contains("home") || lower.contains("light") || lower.contains("goodnight") {
        selected += [.homekitOn, .homekitOff, .homekitScene]
    }
    // ... altri cluster

    return Array(Set(selected)).prefix(10).map { $0 }
}
```

### Streaming della risposta finale

Invece di aspettare il testo completo da Gemini, **inizia lo streaming verso TTS**
non appena arrivano i primi token. L'utente sente GIGI che parla mentre ancora
"pensa" le ultime parole:

```swift
// Gemini REST supporta streaming via SSE
// GigiSpeechService.streamSpeak() accumula token e li pronuncia a chunk
func handleStreamingResponse(_ stream: AsyncThrowingStream<String, Error>) async {
    var buffer = ""
    for try await token in stream {
        buffer += token
        if let boundary = findSentenceBoundary(in: buffer) {
            let sentence = String(buffer[..<boundary])
            buffer = String(buffer[boundary...])
            speech.streamSpeak(sentence)
        }
    }
    if !buffer.isEmpty { speech.streamSpeak(buffer) }
}
```

### Context Caching (Gemini)

La definizione dei 38 tool e il system prompt di GIGI sono **identici in ogni chiamata**.
Gemini supporta il **Context Caching**: si "congela" questa parte nel database Google,
pagando molto meno per i token di input ricorrenti e riducendo il TTFT:

```swift
// Setup (una volta per sessione)
let cacheId = await cloud.createContextCache(
    systemPrompt: GigiFoundationAgent.systemPrompt,
    tools: GigiToolRegistry.all
)

// Ogni chiamata usa il cache_id invece di ritrasmettere tutto
await cloud.callWithFunctions(
    contents: contents,
    cacheId: cacheId   // risparmia ~3000 token per chiamata
)
```

---

## 4. Stack tecnologico completo

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                               UTENTE                                         │
│                    Voce naturale in qualsiasi lingua                         │
└────────────────────────────────┬────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    LAYER AUDIO (GigiAudioManager)                            │
│                                                                               │
│   idle ←→ wakeWordListening ←→ recording ←→ speaking                        │
│                                                                               │
│   Porcupine (on-device wake word "Hey GIGI", multi-intonazione)             │
│   GigiVADEngine (VAD + SFSpeechRecognizer Locale.current, Dynamic Silence)  │
│   GigiRealtimeEngine (Gemini Live WebSocket — full-duplex, barge-in)        │
│   GigiSpeechService (AVSpeechSynthesizer + streaming TTS)                   │
│   Earcons (blip per wake/done/error) + Audio Ducking                        │
└────────────────────────────────┬────────────────────────────────────────────┘
                                 │ testo trascritto
                                 ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    GIGI AGENT ENGINE — CUORE V3                              │
│                                                                               │
│   Meta-classifier locale → seleziona 10 tool rilevanti                      │
│   Gemini 2.0 Flash + Function Calling nativo (Context Cache)                │
│   Agent loop: tool_call(s) → executeParallel → tool_result(s) → loop       │
│   Parallel execution: TaskGroup per functionCall multipli                    │
│   Safety lock: maxIterations = 5, globalTimeout = 15s                       │
│   Confirm Mode: blocca su pagamento, attende "Sì" vocale                    │
│   Streaming response: token → TTS in pipeline                               │
│   Interim Thoughts: feedback aptico/sonoro ogni iterazione                  │
│                                                                               │
│   Fallback: L1 Apple Foundation Models → L2 Gemini REST → L3 NLU locale    │
└─────────┬──────────────────────────────────────┬───────────────────────────┘
          │                                       │
   tool call nativo                        tool call web
          │                                       │
          ▼                                       ▼
┌────────────────────────┐        ┌──────────────────────────────────────────┐
│   DEVICE EXECUTOR       │        │          WEB AUTOMATION LAYER            │
│   GigiActionBridge      │        │                                          │
│                         │        │  GigiWebAgent (on-device, WKWebView)     │
│  • make_call (CallKit)  │        │  User-Agent forzato Desktop              │
│  • send_message         │        │  → WhatsApp Web (sessione cookie)        │
│  • navigate (Maps)      │        │  → TheFork / OpenTable / Resy            │
│  • play_music           │        │  → form semplici + scraping              │
│  • set_reminder         │        │                                          │
│  • create_event         │        │  GigiComputerUse (server-side)           │
│  • set_alarm / timer    │        │  → POST /api/computer-use backend        │
│  • open_app             │        │  → Claude claude-sonnet-4-6 Computer Use │
│  • torch on/off         │        │  → Playwright headless Chromium          │
│  • HomeKit devices      │        │  → Deliveroo / DoorDash / Grubhub       │
│  • weather (wttr.in)    │        │  → UberEats / OpenTable / Resy           │
│  • read/write calendar  │        │  → qualsiasi sito complesso              │
│  • read_news            │        │  → Step finale: SEMPRE confirm_required  │
│  • search_web           │        │                                          │
│  • send_email           │        │  Async Mode: se task > 8s →             │
│  • FaceTime             │        │  "Ci sto lavorando, ti avviso"          │
│  • media controls       │        │  + Silent Push Notification al completamento │
│  • find_free_slot       │        └──────────────────────────────────────────┘
│  • remember / recall    │
└────────────────────────┘        ┌──────────────────────────────────────────┐
                                   │           MEMORIA PERSISTENTE            │
                                   │           GigiMemory (CloudKit)          │
                                   │                                          │
                                   │  RAG locale: NaturalLanguage framework   │
                                   │  → iniezione selettiva (max 5 record)    │
                                   │  Namespace: contact, pref, place,        │
                                   │    routine, context, profile, opinion     │
                                   │  TTL su record context:                  │
                                   │  Relazioni: wife, boss, dog_sitter       │
                                   │  Memoria emotiva: opinion:               │
                                   └──────────────────────────────────────────┘
```

---

## 5. GigiAgentEngine — il cervello

### Struttura principale

```swift
@MainActor
final class GigiAgentEngine {
    static let shared = GigiAgentEngine()

    private let maxIterations = 5
    private let globalTimeout: TimeInterval = 15.0

    struct AgentResult {
        let speech: String
        let executedTools: [String]
        let isFollowUp: Bool
        let costEstimate: Double   // monitoraggio budget API
        let requiresConfirm: ConfirmRequest?
    }

    struct ConfirmRequest {
        let type: ConfirmType       // .payment, .destructive, .sensitive
        let summary: String         // "Margherita €8.50 su Deliveroo"
        let action: String          // tool name da eseguire dopo conferma
        let args: [String: Any]
    }

    enum ConfirmType { case payment, destructive, sensitive }

    func process(text: String) async -> AgentResult
    func confirmAndContinue(_ request: ConfirmRequest) async -> AgentResult
}
```

### GigiTool protocol — Dependency Injection

Ogni tool è un oggetto che conforma a un protocollo, **non** un `switch-case` monolitico.
Aggiungere un nuovo tool = creare un nuovo file, zero modifiche al motore:

```swift
protocol GigiTool {
    var name: String { get }
    var declaration: FunctionDeclaration { get }
    var requiresConfirmation: Bool { get }
    func execute(args: [String: Any]) async -> ToolResult
}

struct ToolResult {
    let value: String
    let requiresConfirm: ConfirmRequest?
    let tokenEstimate: Int   // per budget tracking
}

// Esempio: tool nativo
struct MakeCallTool: GigiTool {
    let name = "make_call"
    let requiresConfirmation = false
    func execute(args: [String: Any]) async -> ToolResult {
        let contact = args["contact"] as? String ?? ""
        let result  = await GigiActionBridge.shared.execute(
            GigiIntent(label: "make_call", confidence: 0.99, params: ["contact": contact])
        )
        return ToolResult(value: result, requiresConfirm: nil, tokenEstimate: 10)
    }
}

// Esempio: tool con conferma obbligatoria
struct WebOrderFoodTool: GigiTool {
    let name = "web_order_food"
    let requiresConfirmation = true   // sempre conferma prima di pagare
    func execute(args: [String: Any]) async -> ToolResult { ... }
}
```

### find_free_slot — Semantic Aware

`find_free_slot` non passa tutti gli eventi a Gemini (troppi token).
Gira un algoritmo Swift locale, e restituisce solo le opzioni disponibili
filtrate per contesto semantico:

```swift
struct FindFreeSlotTool: GigiTool {
    func execute(args: [String: Any]) async -> ToolResult {
        let duration  = Int(args["duration"] as? String ?? "60") ?? 60
        let preferred = args["preferred_time"] as? String ?? ""
        let date      = args["date"] as? String ?? "today"
        let context   = args["context"] as? String ?? ""  // "pranzo", "cena", "riunione"

        // Fetch eventi (EventKit locale)
        let events = await CalendarReader.fetchEvents(for: date)

        // Filtro semantico: se "pranzo" → solo 12:00-14:30
        let allowedRange = semanticRange(for: context, preferred: preferred)

        // Trova gap
        let slots = findGaps(in: events, duration: duration, range: allowedRange)

        // Restituisce sommario compatto — non tutti gli eventi raw
        let summary = slots.isEmpty
            ? "Nessuno slot disponibile per \(date) in fascia \(allowedRange)."
            : "Slot disponibili: " + slots.map(\.formatted).joined(separator: ", ")

        return ToolResult(value: summary, requiresConfirm: nil, tokenEstimate: 30)
    }

    private func semanticRange(for context: String, preferred: String) -> TimeRange {
        switch context.lowercased() {
        case let s where s.contains("pranzo") || s.contains("lunch"):
            return TimeRange(start: "12:00", end: "14:30")
        case let s where s.contains("cena") || s.contains("dinner"):
            return TimeRange(start: "19:00", end: "21:30")
        case let s where s.contains("mattina") || s.contains("morning"):
            return TimeRange(start: "08:00", end: "12:00")
        default:
            return TimeRange(start: preferred.isEmpty ? "09:00" : preferred, end: "18:00")
        }
    }
}
```

### Interim Thoughts — feedback mentre il loop gira

Se il loop supera i 3 secondi (tool web lento), l'Engine emette eventi
che l'UI e il sistema audio raccolgono:

```swift
// Emesso ogni iterazione > 3s
enum InterimEvent {
    case thinking(iteration: Int)       // leggero ping audio + haptic
    case toolStarted(name: String)      // "Sto navigando su Deliveroo..."
    case toolCompleted(name: String, result: String)
    case waitingForConfirmation(ConfirmRequest)
}

// GigiSmartOrchestrator reagisce:
agentEngine.onInterimEvent = { event in
    switch event {
    case .thinking(let i) where i > 0:
        HapticEngine.impact(.light)
        SoundEngine.play(.cognitiveConfirmation)
    case .toolStarted(let name):
        orchestrator.status = "GIGI: \(caption(for: name))..."
    default: break
    }
}
```

---

## 6. GigiToolRegistry — i 38 tool

### Tool nativi iOS

| Tool | Parametri chiave | Note |
|---|---|---|
| `make_call` | `contact, contact_id?` | contact_id per disambiguazione |
| `send_message` | `contact, body, platform, contact_id?` | iMessage/WhatsApp/SMS/Telegram |
| `navigate` | `destination` | Maps |
| `play_music` | `query, app` | MediaPlayer o Spotify deeplink |
| `set_reminder` | `text, date, time` | Reminders |
| `create_event` | `title, date, time, contact` | Calendar |
| `set_alarm` | `time, date` | Clock |
| `set_timer` | `duration` | "10 minuti", "un'ora e mezza" |
| `open_app` | `app` | URL scheme |
| `ask_time` | — | |
| `ask_date` | — | |
| `weather` | `location` | wttr.in |
| `torch_on` / `torch_off` | — | AVCaptureDevice |
| `facetime` / `facetime_audio` | `contact` | |
| `media_play_pause` / `media_next` / `media_previous` | — | |
| `read_calendar` | — | EventKit oggi |
| `read_week_calendar` | — | EventKit settimana (solo sommario, non raw) |
| `find_free_slot` | `duration, preferred_time, date, context` | Algoritmo locale semantic-aware |
| `search_web` | `query` | Safari |
| `read_news` | `query` | RSS + scraping |
| `send_email` | `contact, subject, body` | mailto: |
| `toggle_wifi` | — | → prefs:root=WIFI (deep link Settings) |
| `toggle_bluetooth` | — | → prefs:root=Bluetooth |
| `homekit_on` / `homekit_off` | `accessory` | HMHomeManager |
| `homekit_dim` | `accessory, brightness` | |
| `homekit_temp` | `temperature` | |
| `homekit_scene` | `scene` | |
| `remember` | `key, value` | CloudKit |
| `recall` | `query` | CloudKit + RAG locale |
| `search_groups` | `name` | Cerca tra gruppi WhatsApp/iMessage |

### Tool web automation

| Tool | Parametri chiave | Note |
|---|---|---|
| `web_whatsapp` | `contact, message` | WKWebView Desktop UA |
| `web_book_restaurant` | `restaurant, time, guests, date, platform?` | TheFork, OpenTable, Resy (US) |
| `web_order_food` | `restaurant, items, platform` | Deliveroo, UberEats, DoorDash, Grubhub |
| `web_search_and_read` | `query` | Scraping Google + lettura risultati |
| `computer_use` | `task` | **ULTIMA ISTANZA**: solo se tool sopra non bastano |

### Nota su `computer_use`

La descrizione nel registry deve essere esplicita:
```
"description": "Usa il backend con Claude per controllare il browser.
IMPORTANTE: usa questo tool SOLO se web_whatsapp, web_book_restaurant e
web_order_food non sono applicabili o hanno fallito. È il tool più lento
e costoso (~$0.20 per esecuzione)."
```

### contact_id — disambiguazione

Quando esistono più contatti con lo stesso nome (es. 2 "Marco"), Gemini non deve
inventarsi quale. Usa il campo opzionale `contact_id`:

```
Giro 1: make_call { contact: "Marco" }
functionResponse: { error: "multiple_matches", matches: [
    { id: "contact:marco_fratello", name: "Marco (fratello)" },
    { id: "contact:marco_ufficio",  name: "Marco (ufficio)" }
]}

Giro 2: Gemini genera: "Ho trovato due Marco, quale vuoi chiamare?"
User: "quello dell'ufficio"
Giro 3: make_call { contact: "Marco", contact_id: "contact:marco_ufficio" }
```

---

## 7. Layer audio — VAD, Live, Earcons, Ducking

### GigiAudioManager — state machine (invariata da v2.1)

```
idle → wakeWordListening → recording → speaking → idle
```

> ⚠️ **MVP gating (rework 2026-05-07)** — Lo stato `wakeWordListening` è raggiungibile solo se `GigiWakeWordEngine.isDisabledForMVP == false`. In MVP la flag è `true`, quindi la state machine si riduce di fatto a `idle → recording → speaking → idle`, attivata da Action Button / Back Tap / Siri AppIntent. Riattivazione in v1.1: flip della flag (vedi [ADR-0003](adr/0003-wake-word-soft-kill-mvp.md)).

### Dynamic Silence — timeout adattivo

Il silence timeout non è fisso. Si adatta alla lunghezza del comando rilevato:

```swift
private func adaptiveSilenceThreshold(for partialTranscript: String) -> TimeInterval {
    let wordCount = partialTranscript.split(separator: " ").count
    switch wordCount {
    case 0...2:  return 0.8   // "Torcia on", "Pausa" — risposta istantanea
    case 3...8:  return 1.2   // comando medio
    default:     return 1.8   // dettatura lunga, email, note
    }
}
```

### CoreML Instant Commands — bypass Gemini

Per comandi binari ad altissima frequenza, un **classifier CoreML locale** risponde
in < 50ms **senza toccare Gemini**:

```swift
// Comandi che non richiedono ragionamento
let instantCommands: [String: () -> Void] = [
    "torch_on":         { TorchTool().executeSync() },
    "torch_off":        { TorchTool().executeSync() },
    "media_play_pause": { MediaTool().executeSync() },
    "media_next":       { MediaTool().nextSync() },
]

// CoreML classifica prima di tutto il resto
if let instant = localClassifier.classify(text), let action = instantCommands[instant] {
    action()
    return AgentResult(speech: "", executedTools: [instant], isFollowUp: false)
}
// Altrimenti → GigiAgentEngine
```

### Earcons — feedback sonoro minimalista

Invece di voci per ogni stato, **suoni sintetici** (earcon) per massima efficienza:

| Evento | Suono | Durata |
|---|---|---|
| Wake word rilevata | Blip ascendente (440→880Hz) | 120ms |
| Task completato con successo | Doppio blip (do-mi) | 200ms |
| Errore / riprova | Blip discendente (880→440Hz) | 180ms |
| Thinking (loop iteration) | Leggero pulse ogni 2s | 80ms |
| Confirm richiesto | Trillo breve | 300ms |

```swift
enum EarconEvent { case wakeWord, taskDone, error, thinking, confirmRequired }

final class SoundEngine {
    static func play(_ event: EarconEvent) {
        // AVAudioEngine con buffer sintetizzato — no file audio, zero storage
    }
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}
```

### Audio Ducking

Quando GIGI ascolta, il volume delle altre app (Spotify, YouTube) si abbassa:

```swift
// AVAudioSession con ducking abilitato
try session.setCategory(.playAndRecord,
    mode: .voiceChat,
    options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
```

### AirPods — .allowBluetooth

Critico per il mercato americano: senza `allowBluetooth`, GIGI cerca di parlare
dall'altoparlante del telefono mentre l'utente ha le AirPods:

```swift
options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
```

### Downsampling 44.1kHz → 16kHz per Gemini Live

Il microfono iOS cattura a 44.1kHz (o 48kHz). Gemini Live richiede 16.000 Hz Mono Linear PCM:

```swift
private func downsample(_ buffer: AVAudioPCMBuffer) -> Data {
    let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                     sampleRate: 16000, channels: 1, interleaved: true)!
    let converter = AVAudioConverter(from: buffer.format, to: targetFormat)!
    // ... AVAudioConverter.convert() → Data PCM 16kHz
}
```

Se il sample rate è sbagliato, Gemini non capisce nulla o trascrive rumore.

---

## 8. Web Automation — architettura ibrida

### Strategia a due livelli

```
Tool call richiede web automation
            │
            ├── Sito con selettori stabili (WhatsApp Web, TheFork, OpenTable, Resy)?
            │        └─ YES → GigiWebAgent on-device (WKWebView + JS)
            │
            └── Sito complesso (Deliveroo, DoorDash, UberEats, form dinamici)?
                         └─ YES → GigiComputerUse (backend + Claude claude-sonnet-4-6)
```

### GigiWebAgent — Desktop User-Agent obbligatorio

WhatsApp Web su mobile reindirizza alla versione mobile che blocca l'automazione.
Il WKWebView deve fingersi un browser macOS:

```swift
webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
```

Lo stesso UA viene passato al backend Playwright per evitare l'invalidazione dei cookie
legati all'User-Agent del browser.

### GigiWebAgent — sessione persistente

```swift
final class GigiWebAgent {
    // WKWebView hidden (1x1pt) attachato alla window principale
    // Cookie store persistente → login WhatsApp/TheFork sopravvive ai riavvii
    private let webView: WKWebView
    private let persistentDataStore = WKWebsiteDataStore.default()

    func sendWhatsApp(contact: String, message: String) async -> String {
        try await navigate("https://web.whatsapp.com")
        try await waitForElement("div[title='\(contact)']", timeout: 5)
        try await click("div[title='\(contact)']")
        try await waitForElement("div[contenteditable='true'][data-tab='10']")
        try await type("div[contenteditable='true'][data-tab='10']", text: message)
        try await click("button[aria-label='Invia']")
        return "Messaggio inviato a \(contact)."
    }
}
```

### Async Mode — task lunghi in background

Se un task web supera gli 8 secondi, GIGI libera la sessione audio e continua
a lavorare in background:

```swift
// Se task_time > 8s
speech.speak("Ci sto lavorando, ti avviso quando ho finito.")
GigiAudioManager.shared.startWakeWordListening()

// Il task continua via URLSession background
let session = URLSession(configuration: .background(withIdentifier: "gigi.computeruse"))
// ... completamento → Silent Push → app si risveglia → GIGI parla il risultato
```

### Silent Push Notification per completamento background

```javascript
// Backend Node.js: quando il task finisce
await sendSilentPush(userId, {
    "aps": { "content-available": 1 },
    "gigi_result": { "task_id": "...", "result": "Ordine confermato. Arriva in 30 min." }
});
```

```swift
// App iOS: riceve silent push
func application(_ app: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                 fetchCompletionHandler handler: @escaping (UIBackgroundFetchResult) -> Void) {
    if let result = userInfo["gigi_result"] as? [String: String] {
        speech.speak(result["result"] ?? "Task completato.")
        handler(.newData)
    }
}
```

---

## 9. Backend: Claude Computer Use

> **Nota**: questa sezione descrive un backend **Anthropic-SDK-diretto** (BullMQ + Redis, `anthropic.messages.create` con `computer_20241022` tool). Il sottosistema `03_HARNESS/` (§9.BIS) non è l'implementazione di questo backend — è infrastruttura adiacente che condivide il pool browser Chrome loggato. L'overlap funzionale è parziale.

### Stack

- **Runtime**: Node.js 20+
- **Browser automation**: Playwright (Chromium headless)
- **AI**: Anthropic API — `claude-sonnet-4-6` (**non** Opus — più veloce, meno costoso, stessa precisione spaziale per Computer Use)
- **Job queue**: BullMQ + Redis (limita istanze browser concorrenti, evita OOM)
- **Screenshot**: ridimensionati a 1280×800 (fatturazione Anthropic per pixel)
- **Cookie store**: cifrati AES-256, chiave in AWS Secrets Manager (mai hardcoded)

### Endpoint principale

```javascript
// POST /api/computer-use
app.post('/api/computer-use', authenticate, async (req, res) => {
    const { task, context, userAgent } = req.body;

    // Aggiungi alla job queue (max 5 browser contemporanei)
    const job = await computerUseQueue.add('task', { task, context, userAgent, userId: req.userId });

    // Se il client aspetta → attendi (max 60s)
    // Se supera 8s → risponde subito con job_id, task continua in background
    const result = await Promise.race([
        job.waitUntilFinished(queueEvents),
        new Promise(resolve => setTimeout(() => resolve({ async: true, jobId: job.id }), 8000))
    ]);

    if (result.async) {
        res.json({ status: 'processing', jobId: result.jobId });
    } else {
        res.json(result);
    }
});
```

### Il loop Claude Computer Use

```javascript
async function runComputerUseLoop({ page, task, context, userId }) {
    const messages = [{ role: 'user', content: task }];
    const CONFIRM_STEP_KEYWORDS = ['checkout', 'place order', 'confirm', 'pay', 'submit'];

    for (let step = 0; step < 20; step++) {
        // Screenshot scalato a 1280x800 (risparmio token)
        const screenshot = await page.screenshot({ type: 'jpeg', quality: 70 });
        const base64 = screenshot.toString('base64');

        const response = await anthropic.messages.create({
            model: 'claude-sonnet-4-6',   // veloce, economico, ottimo per Computer Use
            max_tokens: 1024,
            tools: [{ type: 'computer_20241022', name: 'computer',
                       display_width_px: 1280, display_height_px: 800 }],
            messages: [...messages, {
                role: 'user',
                content: [{ type: 'image', source: { type: 'base64',
                    media_type: 'image/jpeg', data: base64 } }]
            }],
            system: `Controlli un browser per conto di GIGI (iOS voice assistant).
                     Task: ${task}. Contesto: ${JSON.stringify(context)}.
                     REGOLE:
                     - Se appare un pop-up di upselling, chiudilo e procedi.
                     - NON cliccare mai "Checkout", "Place Order", "Confirm Order", "Pay" —
                       fermati e restituisci CONFIRM_REQUIRED con il totale e i dettagli.
                     - Se incontri un CAPTCHA complesso, restituisci REQUIRES_HUMAN_INTERVENTION.
                     - Preferisci click precisi su coordinate, non scrivi JavaScript.`
        });

        const toolUse = response.content.find(b => b.type === 'tool_use');
        if (toolUse) {
            // Invia aggiornamento progress (WebSocket o polling)
            await sendProgressUpdate(userId, `Step ${step + 1}: ${describeAction(toolUse.input)}`);
            await executeComputerAction(page, toolUse.input);
            messages.push({ role: 'assistant', content: response.content });
            messages.push({ role: 'user', content: [{ type: 'tool_result', tool_use_id: toolUse.id, content: 'done' }] });
        }

        const textBlock = response.content.find(b => b.type === 'text');
        if (textBlock?.text?.startsWith('CONFIRM_REQUIRED:')) {
            return { success: false, requiresConfirm: true, summary: textBlock.text };
        }
        if (textBlock?.text?.startsWith('REQUIRES_HUMAN_INTERVENTION')) {
            return { success: false, requiresHuman: true };
        }
        if (textBlock || response.stop_reason === 'end_turn') {
            return { success: true, result: textBlock?.text ?? 'Completato.' };
        }
    }

    return { success: false, result: 'Non sono riuscito a completare il task in 20 step.' };
}
```

### CAPTCHA handling

```javascript
// Quando Claude incontra un CAPTCHA:
// Backend → risponde con requiresHuman: true
// iOS → GigiWebAgent apre la stessa URL in WKWebView visibile
// Utente risolve il CAPTCHA manualmente
// iOS → notifica al backend → task riprende da dove era
```

### User-Agent passthrough

```javascript
// Riceve l'UA dall'iPhone e lo imposta su Playwright
// Evita invalidazione cookie legata all'UA diverso
await page.setUserAgent(req.body.userAgent);
await page.context().addCookies(await getUserCookies(req.userId, req.body.userAgent));
```

### BullMQ job queue — limita RAM

```javascript
const computerUseQueue = new Queue('computer-use', { connection: redis });
const worker = new Worker('computer-use', processJob, {
    connection: redis,
    concurrency: 5,      // max 5 browser contemporanei (ogni istanza ~600MB RAM)
    lockDuration: 120000 // task timeout 2 min
});
// Con 5 worker: ~3GB RAM → server da 4GB è sufficiente per early launch
// Scala orizzontalmente con più worker Docker su demand
```

---

## 10. Sicurezza e Trust (Confirm Mode + Keychain)

### Il principio: "Mai spendere senza consenso"

Qualsiasi azione che coinvolge denaro, invio di messaggi a terzi, o operazioni
distruttive richiede **conferma vocale esplicita** da GIGI prima dell'esecuzione.

```
Tool result: CONFIRM_REQUIRED: "Margherita €8.50 su Deliveroo. Procedo?"
    ↓
GigiSpeechService: "Ho preparato la margherita su Deliveroo, sono €8.50. Procedo?"
GigiAudioManager: speaking → recording
    ↓
User: "Sì" / "Vai" / "Procedi"
    ↓
GigiAgentEngine.confirmAndContinue() → esegui step finale
```

### Confirm Mode — categorie

| Tipo | Esempi | Richiede conferma |
|---|---|---|
| `.payment` | ordini cibo, prenotazioni a pagamento | ✅ sempre |
| `.destructive` | cancella evento, elimina promemoria | ✅ sempre |
| `.sensitive` | manda messaggio a gruppo, manda email | ✅ se > 1 destinatario |
| `.standard` | chiama, naviga, timer, musica | ❌ no conferma |

### Keychain per dati sensibili

Le credenziali (token OAuth, cookie cifrati) non vanno mai nei log, mai in UserDefaults:

```swift
final class GigiKeychain {
    static func save(key: String, value: Data) throws {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrAccount as String:      key,
            kSecValueData as String:        value,
            kSecAttrAccessible as String:   kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        // SecItemAdd / SecItemUpdate
    }
    static func load(key: String) throws -> Data { ... }
}

// Cookie backend cifrati: chiave AES generata on-device, salvata in Keychain
// Solo l'utente (Face ID / passcode) può sbloccarli
```

### Privacy by design

- Cookie web salvati **solo su Keychain** dell'iPhone — mai trasmessi a terzi
- Log GIGI: no dati personali (contatti, messaggi) — solo intent label + timestamp
- GigiMemory CloudKit: cifrato da Apple end-to-end (iCloud E2E encryption)
- Backend: API key Anthropic/Gemini solo in variabili d'ambiente del server

### Trust UX — onboarding USA

Nel materiale di marketing e nell'onboarding, i limiti iOS diventano punti di forza:

> *"GIGI è potente ma sicuro. Grazie alla protezione di iOS, non può accedere
> alle notifiche delle altre app, al filesystem, o alle tue password — senza il tuo
> permesso esplicito. I tuoi dati restano sul tuo iPhone e su iCloud personale."*

---

## 11. Memoria persistente — RAG locale e tipi

### Tipi di record

```swift
struct GigiMemoryRecord: Codable {
    var key: String             // "contact:Marco", "pref:ristorante", "opinion:attesa"
    var value: String           // contenuto
    var namespace: Namespace
    var lastUsed: Date
    var useCount: Int
    var source: MemorySource    // .user (esplicito) | .inferred | .routine
    var confidence: Float       // 1.0 per .user, 0.0–1.0 per .inferred
    var expiresAt: Date?        // TTL per namespace context:
    var embedding: [Float]?     // vettore per RAG locale
}

enum Namespace: String, Codable {
    case contact    // "Marco = fratello, +39 333 1234567"
    case pref       // "ristorante_cucina = giapponese"
    case place      // "casa = Via Roma 5, Milano"
    case routine    // "sveglia = 7:30, feriali"
    case context    // "ultimo_ristorante = Sakura" (TTL: 7 giorni)
    case profile    // "nome = Leonardo, lingua = italiano"
    case opinion    // "odio_attesa = >10 minuti per un tavolo"
    case relation   // "wife = Sarah, boss = Marco Bianchi, dog_sitter = Giulia"
}
```

### Namespace `opinion:` — memoria emotiva

```
User: "Odio aspettare più di 10 minuti per un tavolo"
→ GigiMemory.remember(key: "opinion:attesa_ristorante", value: "massimo 10 minuti")

Successivamente, web_book_restaurant vede:
→ memory injection: "opinion:attesa_ristorante = massimo 10 minuti"
→ Gemini: filtra solo ristoranti con disponibilità immediata
→ GIGI: "Ho trovato un tavolo alle 20:15 da Sakura — dicono che siano veloci!"
```

### Namespace `relation:` — relazioni personali (mercato USA)

```
User: "My wife is Sarah"
→ relation:wife = "Sarah"

User: "What's the number of my dog sitter?"
→ recall { query: "dog_sitter" } → "Giulia, +39 333 0000000"

User: "Text my mechanic that I'll pick up the car tomorrow"
→ recall { query: "mechanic" } → "Franco, +39 333 1111111"
→ send_message { contact: "Franco", body: "I'll pick up the car tomorrow" }
```

### RAG locale — iniezione selettiva

Con 500+ record di memoria, iniettare tutto nel prompt è impossibile.
Si usa il **NaturalLanguage framework** di Apple per una **vector search locale**:

```swift
final class GigiVectorStore {
    private let embedder = NLEmbedding.wordEmbedding(for: .english)!

    // Trova i K record più rilevanti per il testo corrente
    func relevantMemories(for text: String, topK: Int = 5) -> [GigiMemoryRecord] {
        let queryEmbedding = embed(text)
        return allRecords
            .map { ($0, cosineSimilarity(queryEmbedding, $0.embedding ?? [])) }
            .sorted { $0.1 > $1.1 }
            .prefix(topK)
            .map(\.0)
    }
}

// Injection nel system prompt: max 5 record
let relevantMemories = vectorStore.relevantMemories(for: userText)
let memoryBlock = relevantMemories.map { "- \($0.key) = \($0.value)" }.joined(separator: "\n")
systemPrompt += "\nUser memory (relevant):\n\(memoryBlock)"
```

### Soft Confirmation per memorie inferite

Quando `confidence < 0.7` → GIGI non usa la memoria silenziosamente, la valida:

```swift
if memory.source == .inferred && memory.confidence < 0.7 {
    speech.speak("Ho notato che chiami spesso Marco verso le 18 — è il tuo contatto di lavoro?")
    // Se utente conferma → memory.source = .user, memory.confidence = 1.0
}
```

### TTL per record context:

```swift
// Record "ultimo_ristorante" scade dopo 7 giorni
record.expiresAt = Date().addingTimeInterval(7 * 24 * 3600)

// Cleanup automatico all'avvio
func cleanup() {
    allRecords.removeAll { r in r.expiresAt.map { $0 < Date() } ?? false }
}
```

### CloudKit Sharing (futuro)

```swift
// Condividi namespace place:casa con membri della famiglia
// Utile per smart home: tutta la famiglia usa GIGI con stesse posizioni
cloudKit.shareRecord(key: "place:casa", with: [familyMemberRecordID])
```

### GigiConversationMemory — persistenza su disco

La history della sessione viene salvata su disco. Se l'utente riapre l'app
entro 30-60 minuti, GIGI riprende la conversazione dal punto giusto:

```swift
final class GigiConversationMemory {
    private let sessionTimeout: TimeInterval = 3600  // 1 ora

    func loadIfRecentSession() -> [GigiContent]? {
        guard let saved = UserDefaults.standard.data(forKey: "gigi_session"),
              let timestamp = UserDefaults.standard.object(forKey: "gigi_session_time") as? Date,
              Date().timeIntervalSince(timestamp) < sessionTimeout
        else { return nil }
        return try? JSONDecoder().decode([GigiContent].self, from: saved)
    }

    func saveSession(_ contents: [GigiContent]) {
        let data = try? JSONEncoder().encode(contents)
        UserDefaults.standard.set(data, forKey: "gigi_session")
        UserDefaults.standard.set(Date(), forKey: "gigi_session_time")
    }
}
```

---

## 12. Conversazione multi-turn — token budget

### Formato `contents[]` strutturato

La v3 usa il formato nativo Gemini multi-turn invece del testo concatenato:

```json
[
  { "role": "user",  "parts": [{ "text": "chiama Marco" }] },
  { "role": "model", "parts": [{ "functionCall": { "name": "make_call", "args": { "contact": "Marco" } } }] },
  { "role": "user",  "parts": [{ "functionResponse": { "name": "make_call",
      "response": { "result": "Chiamata avviata a Marco (+39 333 1234567)." } } }] },
  { "role": "model", "parts": [{ "text": "Calling Marco." }] },
  { "role": "user",  "parts": [{ "text": "e mandagli anche un whatsapp che arrivo tardi" }] }
]
```

Gemini vede esattamente cosa è stato fatto, con quali parametri, e con quale risultato.
Coreference ("mandagli") viene risolta correttamente su "Marco" del turno precedente.

### Token Budget — non contare i turni, conta i token

Il limite non è "20 turni" ma **8.000 token di history** (bilanciamento costo/qualità):

```swift
final class GigiConversationMemory {
    private let maxHistoryTokens = 8000

    func contents(pruningIfNeeded: Bool = true) -> [GigiContent] {
        guard pruningIfNeeded else { return allContents }

        var totalTokens = 0
        var result: [GigiContent] = []

        // Scorri dalla fine (turni più recenti prima)
        for content in allContents.reversed() {
            let tokens = estimateTokens(content)
            if totalTokens + tokens > maxHistoryTokens { break }
            totalTokens += tokens
            result.insert(content, at: 0)
        }

        // Se abbiamo tagliato, aggiungi un sommario dei turni precedenti
        if result.count < allContents.count {
            let summary = await summarizeOldTurns(allContents.dropLast(result.count))
            result.insert(systemContent("Conversazione precedente (riassunto): \(summary)"), at: 0)
        }

        return result
    }

    // I functionResponse lunghi vengono troncati
    private func truncateLongToolResults(_ content: GigiContent) -> GigiContent {
        // functionResponse con > 500 chars → tronca + "[troncato per brevità]"
    }
}
```

### Context Switching — cambio di intenzione

```
User: "Chiama Marco."
User: "Anzi no, mandagli un messaggio."
User: "E aggiungi un appuntamento per domani con lui."
```

Il formato `contents[]` strutturato permette a Gemini di scorrere le `functionCall`
precedenti e identificare l'ultimo oggetto "Contatto" manipolato.
La coreference ("lui") viene risolta senza ambiguità perché ogni tool call
contiene i parametri esatti usati.

### Predictive Tool Pre-warming

Se la conversazione sta chiaramente andando verso una prenotazione, l'Engine
pre-carica in background le memorie di pagamento e preferenze rilevanti:

```swift
func predictNextTool(from history: [GigiContent]) -> [String]? {
    let recentText = history.last?.text?.lowercased() ?? ""
    if recentText.contains("ristoran") || recentText.contains("mangia") {
        // Pre-load memorie pref:ristorante, opinion:attesa, place:casa
        Task { await vectorStore.preload(namespaces: [.pref, .opinion, .place]) }
        return ["web_book_restaurant", "web_order_food"]
    }
    return nil
}
```

---

## 13. Gemini Live WebSocket — Barge-in e streaming

> ⛔ **RIMOSSO nel rework armando-rework (2026-05-07, ADR-0004)**. Tutto il path Gemini Live + Gemini REST è stato sradicato: file `GigiRealtimeEngine.swift` cancellato, classe `GigiAuthManager` cancellata, dipendenza `GoogleSignIn` rimossa, cascade `GigiBrainPipeline` semplificata a `Apple Foundation Models → local NLU`. Cloud reasoning vive ora solo nel harness (Groq/Claude via `GigiHarnessClient`). Sezione mantenuta sotto come archeologia tecnica.

### Architettura Live (storica — non più presente nel codice)

```
AVAudioEngine
  │ PCM 16kHz (downsampled da 44.1kHz via AVAudioConverter)
  ├─→ WebSocket (wss://generativelanguage.googleapis.com/ws/...)
  │      │
  │      ├─ Setup: system prompt + tool declarations + Context Cache ID
  │      │
  │      ├─ Audio chunks in streaming (non aspetta silenzio VAD)
  │      │
  │      └─ Risposta Gemini:
  │           ├─ functionCall → GigiAgentEngine.executeToolCall()
  │           │                     → functionResponse → WebSocket
  │           └─ audio TTS → AVAudioPlayerNode (jitter buffer 80ms)
```

### Full-Duplex — Bypass VAD

Con Live non si aspetta il silenzio. I pacchetti audio vengono inviati in streaming
mentre l'utente parla. Gemini inizia a processare l'intent **mentre l'utente sta ancora parlando**.

```swift
// Input tap: invia ogni buffer direttamente al WebSocket
inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
    guard let self else { return }
    let pcm16 = self.downsample(buffer)  // 44.1kHz → 16kHz
    self.websocket.send(.data(pcm16))
    // Nessuna analisi VAD — Gemini decide da solo quando l'utente ha finito
}
```

### Barge-in — Interruzione istantanea

Se GIGI sta parlando e l'utente riprende a parlare, il WebSocket invia un evento
di interruzione. Il sistema reagisce in < 100ms:

```swift
// GigiRealtimeEngine riceve evento interruzione dal WebSocket
func handleServerContent(_ message: LiveMessage) {
    if message.isInterruption {
        // 1. Ferma audio output istantaneamente
        audioPlayerNode.stop()
        audioPlayerNode.reset()
        pendingAudioBuffers.removeAll()

        // 2. Aggiorna UI
        GigiAudioManager.shared.transitionTo(.recording)

        // 3. Segnala all'orchestrator
        onBargein?()
    }
}
```

### AVAudioPlayerNode con jitter buffer

Per evitare scatti nell'audio streaming in arrivo, un buffer di 80ms:

```swift
class StreamingAudioPlayer {
    private let playerNode = AVAudioPlayerNode()
    private var jitterBuffer: [AVAudioPCMBuffer] = []
    private let minBufferMs: Double = 80

    func receiveChunk(_ data: Data) {
        let buffer = decodeAudioChunk(data)
        jitterBuffer.append(buffer)

        if jitterBuffer.totalDurationMs >= minBufferMs {
            scheduleFromBuffer()
        }
    }
}
```

### Quando usare Live vs REST

| Scenario | Tecnologia | Motivo |
|---|---|---|
| "Accendi la torcia" | L3 NLU locale | Istantaneo, zero costi |
| "Chiama Marco" | L1/L2 Gemini REST | Singola azione, nessun loop |
| Conversazione interattiva con AirPods | Gemini Live | Full-duplex, barge-in |
| "Prenota, poi manda messaggio, poi..." | Gemini REST + Agent Loop | Controllo sequenza |

### Nota costi Gemini Live

Live costa di più (audio token + durata connessione). Strategia:
- **Modalità Conversazione** (pulsante/AirPods): usa Live
- **Comandi secchi**: usa REST o NLU locale

---

## 14. Capability map completa

### Zero tap (nessun cambio app)

| Comando | Stack | Latenza |
|---|---|---|
| "Torcia on" | CoreML locale | < 100ms |
| "Timer 10 minuti" | NLU locale + UNUserNotificationCenter | < 300ms |
| "Svegliami alle 7:30" | REST + EventKit | < 1s |
| "Metti in pausa" | CoreML → MediaPlayer | < 100ms |
| "Chiama Marco" | REST → CallKit | < 800ms |
| "Manda WhatsApp a Marco: ci vediamo alle 8" | REST → GigiWebAgent (WhatsApp Web) | 3–5s |
| "Meteo a Milano" | REST → wttr.in | < 1s |
| "Leggi il mio calendario di oggi" | REST → EventKit | < 1s |
| "Accendi le luci del salotto" | REST → HomeKit | < 1s |
| "Buonanotte Gigi" | REST → HomeKit (parallelo) + Clock + MediaPlayer | 1–2s |
| "Trova slot libero domani mattina" | REST → algoritmo locale | < 2s |
| "Trova slot e crea evento con Marco" | REST loop (3 iter.) | 3–5s |

### Un cambio app

| Comando | Stack | Latenza |
|---|---|---|
| "Naviga a Piazza Duomo" | REST → maps:// | < 800ms |
| "Apri Spotify" | NLU locale → URL scheme | < 300ms |
| "FaceTime con Marco" | REST → facetime:// | < 800ms |
| "Cerca su Google tiramisu recipe" | REST → Safari | < 500ms |
| "Manda email a hr@azienda.com" | REST → mailto: | < 500ms |

### Web automation

| Comando | Stack | Latenza |
|---|---|---|
| "Prenota da Il Grill stasera alle 8 per 2" | REST → GigiWebAgent/Resy | 5–15s |
| "Ordinami una pizza" (con confirm) | REST → GigiComputerUse | 20–40s + confirm |

### Ragionamento e catene

| Scenario | Iterazioni | Latenza |
|---|---|---|
| "Manda msg a tutti quelli nel calendario domani" | read_cal → N×send_msg (parallel) | 5–10s |
| "Se piove domani ricordami ombrello" | weather → (if rain) set_reminder | 2 iter. |
| "Chiama il mio ristorante preferito e prenota" | recall → web_book | 2 iter. |
| "Prenota Uber per aeroporto basandoti sul mio volo" | search_email → maps → computer_use | 3–4 iter. |

---

## 15. Flussi end-to-end — esempi reali

### Scenario A: "Ordinami un panino da Deliveroo" (con Confirm Mode)

```
1. WAKE WORD: "Hey GIGI" → Porcupine → GigiAudioManager: idle → recording

2. STT: "ordinami un panino da Deliveroo" → 0.8s silence (comando corto)
   → GigiAgentEngine.process()

3. META-CLASSIFIER: seleziona tool: [web_order_food, computer_use, ...]

4. AGENT LOOP — iter. 1:
   Gemini: functionCall { name: "web_order_food", args: { restaurant: "Deliveroo", items: "panino" } }
   SoundEngine.play(.thinking)
   Interim: "GIGI: Sto navigando su Deliveroo..."

5. ESECUZIONE: GigiComputerUse.execute(task: "Ordina panino su Deliveroo")
   Claude naviga, trova panino prosciutto €8.50, si ferma PRIMA del checkout
   → result: "CONFIRM_REQUIRED: Panino prosciutto e mozzarella €8.50. Procedo?"

6. CONFIRM MODE:
   GigiSpeechService: "Ho trovato un panino prosciutto e mozzarella per €8.50 su Deliveroo. Procedo?"
   SoundEngine.play(.confirmRequired)
   GigiAudioManager: speaking → recording

7. USER: "Sì"

8. AGENT LOOP — iter. 2:
   GigiAgentEngine.confirmAndContinue() → Claude clicca Checkout → ordine confermato
   functionResponse: "Ordine confermato. Arriva in 28 minuti. Numero ordine: #38291"

9. AGENT LOOP — iter. 3:
   Gemini (testo): "Fatto! Il tuo panino arriva in circa 28 minuti."

10. TTS: "Fatto! Il tuo panino arriva in circa 28 minuti."
    SoundEngine.play(.taskDone)
    GigiAudioManager: speaking → idle → wakeWordListening
```

### Scenario B: "Trova slot domani mattina e invita Marco a pranzo"

```
Iter. 1: Gemini chiama in parallelo:
  - read_week_calendar {} → ["9:00 Meeting", "11:30 Call Sara"]
  - recall { query: "Marco contatto" } → "Marco Rossi, +39 333 1234567"

Iter. 2: Gemini chiama:
  - find_free_slot { duration: "60", date: "tomorrow", context: "pranzo" }
    → algoritmo locale filtra per 12:00-14:30
    → "Slot disponibili: 12:00-13:30"

Iter. 3: Gemini chiama in parallelo:
  - create_event { title: "Pranzo con Marco", date: "tomorrow", time: "12:30" }
  - send_message { contact: "Marco Rossi", body: "Pranzo domani alle 12:30?", platform: "imessage" }

Iter. 4: Gemini (testo):
  "Perfetto! Ho creato 'Pranzo con Marco' per domani alle 12:30 e inviato un messaggio a Marco."

TTS + SoundEngine.play(.taskDone)
Durata totale: ~4 secondi
```

### Scenario C: Conversazione multi-turno con coreference

```
Turno 1:
  User: "manda un messaggio a Marco che arrivo tardi"
  Gemini: make_send_message { contact: "Marco", body: "Arrivo tardi" }
  GIGI: "Messaggio inviato a Marco."

Turno 2:
  User: "e chiamalo anche"  ← "lo" = Marco (risolto da functionCall precedente)
  Gemini vede history → make_call { contact: "Marco" }
  GIGI: "Chiamo Marco."

Turno 3:
  User: "quand'è il suo compleanno?"
  Gemini: recall { query: "compleanno Marco" }
  → "18 marzo" (da memoria) → GIGI: "Il compleanno di Marco è il 18 marzo."
  → se non trovato: "Non ho il compleanno di Marco. Vuoi che glielo chieda nel prossimo messaggio?"
```

### Scenario D: "Prenota un Uber per l'aeroporto basandoti sul mio volo" (Executive Assistant)

```
Iter. 1: Gemini: web_search_and_read { query: "my flight tomorrow in emails" }
  → GigiWebAgent legge Gmail → "Volo AZ1234, Milano-Roma, ore 8:40 da Linate"

Iter. 2: Gemini: navigate { destination: "Linate Airport" } (solo info distanza)
  + recall { query: "casa" } → "Via Roma 5, Milano"
  → Maps API stima: 35 minuti in auto, consiglia partenza ore 7:00

Iter. 3: Gemini: computer_use { task: "Prenota Uber da Via Roma 5 Milano a Linate per le 7:00 di domani" }
  → Claude naviga Uber web → trova corsa €18 → CONFIRM_REQUIRED

Iter. 4: CONFIRM MODE
  GIGI: "Ho trovato un Uber da casa tua a Linate per le 7:00 di mattina, €18. Procedo?"
  User: "Sì" → conferma

Iter. 5: Gemini: set_reminder { text: "Preparare borse", date: "tomorrow", time: "6:30" }

Iter. 6: Gemini (testo): "Perfetto! Uber prenotato per le 7:00, arriverai a Linate con ampio anticipo.
  Ho anche impostato un reminder alle 6:30 per prepararti."

Durata totale: ~45 secondi (attesa utente inclusa)
```

---

## 16. Limiti iOS — workaround e deep link

Questi limiti sono imposti da Apple a livello kernel. Nessuna architettura li aggira.
Ma si possono **comunicare come feature** e **workaroundare con eleganza**:

| Funzione | Limite | Workaround GIGI |
|---|---|---|
| WiFi on/off programmatico | Rimosso iOS 13 | `prefs:root=WIFI` deep link + "Basta un tap" |
| Bluetooth on/off | Solo Settings | `prefs:root=Bluetooth` deep link |
| Screenshot da background | Solo foreground | — |
| Rispondere automaticamente a chiamate | Nessuna API | — |
| Controllare app di terze parti | Process isolation | Web automation via browser |
| Ordine in app delivery | Sandbox | Web automation su sito delivery |
| Notifiche di altre app | Nessuna API | Share Extension (v4) |
| Luminosità/volume programmatico | API rimosse iOS 17+ | `prefs:root=DISPLAY` deep link |

### Deep link Settings — "The Settings Bridge"

```swift
// Invece di fallire silenziosamente
func handleUnsupportedAction(_ intent: String) {
    switch intent {
    case "toggle_wifi":
        speech.speak("Apple non mi permette di farlo direttamente, ma ti ho aperto le impostazioni WiFi.")
        UIApplication.shared.open(URL(string: "prefs:root=WIFI")!)
    case "toggle_bluetooth":
        speech.speak("Ti ho aperto Bluetooth nelle impostazioni.")
        UIApplication.shared.open(URL(string: "prefs:root=Bluetooth")!)
    }
}
```

### Permessi mancanti — gestione elegante

```swift
// Se EventKit/Contacts non è autorizzato
func requestPermissionIfNeeded(for tool: String) -> Bool {
    guard !hasPermission(for: tool) else { return true }
    speech.speak("Vorrei farlo, ma non ho accesso al tuo \(permissionName(for: tool)). Puoi darmelo nelle impostazioni?")
    // Banner con pulsante "Apri impostazioni" che porta direttamente all'app
    return false
}
```

---

## 17. Modello di costo e Freemium

### Costo per categoria di operazione

| Categoria | Costo computazionale | Costo API stimato |
|---|---|---|
| CoreML / NLU locale | Zero | $0.000 |
| Apple Foundation Models L1 | Zero (on-device) | $0.000 |
| Gemini REST (comando singolo) | Molto basso | ~$0.001–0.003 |
| Gemini REST (agent loop 3-5 iter.) | Medio | ~$0.005–0.015 |
| GigiWebAgent on-device | Zero API | $0.000 |
| GigiComputerUse (Claude Sonnet) | Alto | ~$0.08–0.25 per task |

### Strategia Freemium (mercato USA)

```
GIGI FREE (tutti gli utenti):
  ✅ Tutte le azioni native iOS (chiamate, messaggi, calendario, timer, HomeKit, musica)
  ✅ WhatsApp Web (GigiWebAgent on-device)
  ✅ Gemini REST agent loop (fino a 3 iterazioni/giorno per web automation)
  ✅ Memoria base (CloudKit, 100 record)
  ✅ Gemini Live (10 min/giorno)

GIGI PRO — $9.99/mese:
  ✅ GigiComputerUse illimitato (ordini delivery, prenotazioni complesse)
  ✅ Gemini Live illimitato
  ✅ Agent loop senza limiti di iterazione
  ✅ Memoria illimitata + RAG vettoriale
  ✅ costEstimate visibile in app (trasparenza budget)
```

### Monitoraggio costi in-app

```swift
struct AgentResult {
    // ...
    let costEstimate: Double  // es. 0.023 per "prenota ristorante"
}

// Dashboard UI: "Sessione oggi: $0.08 | Mensile: $1.23"
// Aiuta a calibrare il pricing Pro e identificare query costose
```

---

## 18. Struttura file del progetto

```
GIGI/
├── docs/
│   ├── Architecture-Armando-Revision.md   ← questo documento (rev. Armando)
│   ├── PIANO_INTEGRAZIONE_HARNESS.md
│   ├── TEST_E2E.md
│   ├── COMPONENTS.md            ← mappa "quale file fa cosa" per funzione
│   ├── GETTING_STARTED.md
│   ├── TASK_PLAN.md
│   ├── memory/                  ← memoria progetto agenti
│   ├── plans/                   ← piani per fase
│   ├── research/                ← finding tecnici
│   └── archive/                 ← doc storiche superate
│
├── 01_SERVER_MDM/               ← Node.js backend
│   ├── server.js                ← esistente + /api/computer-use
│   ├── computerUse.js           ← NUOVO: loop Claude claude-sonnet-4-6 + Playwright
│   ├── sessionStore.js          ← NUOVO: cookie cifrati AES-256 per utente
│   ├── queue.js                 ← NUOVO: BullMQ + Redis per job queue
│   ├── progress.js              ← NUOVO: WebSocket per aggiornamenti real-time
│   ├── profiles/
│   └── certs/
│
└── 02_GIGI_APP/GIGI/
    │
    ├── Agent/                           ← NUOVI FILE — cuore v3
    │   ├── GigiAgentEngine.swift        ← agent loop + parallel execution + confirm mode
    │   ├── GigiToolRegistry.swift       ← 38 FunctionDeclaration (GigiTool protocol)
    │   └── GigiComputerUse.swift        ← client iOS → backend /api/computer-use
    │
    ├── Brain/                           ← AGGIORNATI
    │   ├── GigiCloudService.swift       ← + callWithFunctions() + Context Cache
    │   ├── GigiFoundationAgent.swift    ← system prompt (rimane)
    │   ├── GigiFoundationSession.swift  ← Apple FM fallback (rimane)
    │   ├── GigiBrainPipeline.swift      ← semplificato: punta a GigiAgentEngine
    │   ├── GigiRealtimeEngine.swift     ← Live: barge-in + jitter buffer + downsampling
    │   └── GigiBrainDiagnostics.swift   ← + status GigiAgentEngine + cost estimate

    ├── Orchestration/                   ← AGGIORNATI
    │   ├── GigiSmartOrchestrator.swift  ← process() → GigiAgentEngine
    │   ├── GigiActionBridge.swift       ← invariato (executor nativo)
    │   ├── GigiActionDispatcher+Native.swift  ← split per leggibilità
    │   ├── GigiActionDispatcher+Web.swift     ← routing tool web
    │   ├── GigiPlanner.swift            ← DEPRECATO (sostituito da agent loop)
    │   └── GigiWebAgent.swift           ← + Desktop UA + nuovi siti US
    │
    ├── Audio/                           ← AGGIORNATI
    │   ├── GigiAudioManager.swift       ← invariato (state machine)
    │   ├── GigiVADEngine.swift          ← + Dynamic Silence adattivo
    │   ├── GigiAudioSequestrator.swift  ← + allowBluetooth + duckOthers
    │   ├── GigiWakeWordEngine.swift     ← invariato
    │   ├── GigiSpeechService.swift      ← + streamSpeak() per streaming TTS
    │   └── SoundEngine.swift            ← NUOVO: earcons sintetici + haptics
    │
    ├── Memory/                          ← AGGIORNATI
    │   ├── GigiConversationMemory.swift ← + contents[] strutturato + token budget + disk persist
    │   ├── GigiMemory.swift             ← + namespace opinion: + relation: + TTL
    │   ├── GigiVectorStore.swift        ← NUOVO: RAG locale NaturalLanguage embedding
    │   └── GigiKeychain.swift           ← NUOVO: Keychain wrapper per dati sensibili
    │
    └── UI/
        ├── MainTabView.swift            ← invariato
        ├── ChatView.swift               ← invariato
        ├── DashboardView.swift          ← + cost estimate indicator
        └── ToolOverlayView.swift        ← NUOVO: progress web automation (trasparente)
```

---

## 19. Roadmap implementativa

### Fase 1 — Agent Loop Core (1–2 settimane) ← MASSIMA PRIORITÀ

| Step | File | Descrizione |
|---|---|---|
| 1.1 | `GigiToolRegistry.swift` | GigiTool protocol + 38 tool declarations |
| 1.2 | `GigiCloudService.swift` | `callWithFunctions(contents:cacheId:)` con native FC |
| 1.3 | `GigiAgentEngine.swift` | Agent loop: parallel execution, safety lock, confirm mode |
| 1.4 | `GigiActionDispatcher+Native.swift` | Split dispatcher, routing tool nativo |
| 1.5 | `GigiActionDispatcher+Web.swift` | Routing tool web |
| 1.6 | `GigiConversationMemory.swift` | `contentsArray()` formato strutturato + token budget |
| 1.7 | `GigiSmartOrchestrator.swift` | `process()` → `GigiAgentEngine.process()` |
| 1.8 | Build + test | Nessuna regressione su comandi nativi |

**Test di accettazione:**
- "Chiama Marco" → funziona (nessuna regressione)
- "Chiama Marco e mandagli anche un messaggio" → esegue entrambi
- "Se c'è pioggia domani metti un reminder" → ragionamento condizionale
- "Buonanotte" → HomeKit + alarm in parallelo

### Fase 2 — Audio UX + Earcons (3 giorni)

| Step | File | Descrizione |
|---|---|---|
| 2.1 | `SoundEngine.swift` | Earcons sintetici (AVAudioEngine) |
| 2.2 | `GigiVADEngine.swift` | Dynamic Silence adattivo |
| 2.3 | `GigiAudioSequestrator.swift` | allowBluetooth + duckOthers |
| 2.4 | `GigiRealtimeEngine.swift` | Downsampling 44.1→16kHz + jitter buffer + barge-in |

### Fase 3 — Memoria RAG + Keychain (1 settimana)

| Step | File | Descrizione |
|---|---|---|
| 3.1 | `GigiVectorStore.swift` | Embedding NaturalLanguage + top-K lookup |
| 3.2 | `GigiMemory.swift` | namespace opinion: + relation: + TTL + soft confirm |
| 3.3 | `GigiKeychain.swift` | Keychain wrapper per cookie e token |
| 3.4 | `GigiConversationMemory.swift` | Persistenza su disco + reload se < 1h |

### Fase 4 — Web Automation On-Device (1 settimana)

| Step | File | Descrizione |
|---|---|---|
| 4.1 | `GigiWebAgent.swift` | WhatsApp Web completo (Desktop UA + cookie) |
| 4.2 | `GigiWebAgent.swift` | Resy + OpenTable per mercato USA |
| 4.3 | `GigiWebAgent.swift` | web_search_and_read (scraping Google) |

### Fase 5 — Backend Claude Computer Use (1–2 settimane)

| Step | File | Descrizione |
|---|---|---|
| 5.1 | `queue.js` | BullMQ + Redis job queue |
| 5.2 | `computerUse.js` | Loop Claude claude-sonnet-4-6 + Playwright + CONFIRM step |
| 5.3 | `sessionStore.js` | Cookie store AES-256, UA passthrough |
| 5.4 | `progress.js` | WebSocket aggiornamenti real-time → iOS |
| 5.5 | `GigiComputerUse.swift` | Client iOS: POST + progress updates + silent push |
| 5.6 | Test | Ordine Deliveroo web end-to-end (sessione loggata) |

### Fase 6 — Context Cache + Streaming TTS (3 giorni)

| Step | Descrizione |
|---|---|
| 6.1 | Gemini Context Cache per system prompt + tool declarations |
| 6.2 | GigiSpeechService.streamSpeak() per TTS in pipeline |
| 6.3 | CoreML Meta-classifier locale per selezione tool |

---

## 20. Metriche di successo

| Metrica | Target v3 | Metodo di misura |
|---|---|---|
| Latenza comandi instant (CoreML) | < 100ms | Instruments |
| Latenza azioni native (REST) | < 800ms | Logging voice-end → action |
| Latenza web automation semplice | < 5s | Logging end-to-end |
| Latenza web automation complessa | < 40s | Logging end-to-end |
| Accuratezza intent (italiano) | > 95% | Test set 100 comandi |
| Accuratezza intent (inglese) | > 97% | Test set 100 comandi |
| Coreference resolution | > 90% | Test set "lui/lei/lì/quello" |
| Agent loop 3+ tool in sequenza | Funziona | Scenario B manuale |
| Parallel execution (3 tool) | Entro max(latenza singoli) + 200ms | Timing test |
| Token bloat (storia 10 turni) | < 8.000 token | Logging |
| Wake word false positive | < 1/ora | Log Porcupine |
| Battery (wake word 8h) | < 3% overhead | Instruments Energy |
| Costo medio sessione Pro | < $0.30 | costEstimate aggregato |
| Uptime backend Computer Use | > 99.5% | Monitoring server |

---

## 9.BIS. Harness — Backend iOS GIGI (post fase 17)

**Cambio ruolo 2026-04-23**: Telegram è stato droppato (fase 17 del piano integrazione).
`03_HARNESS/` è ora **il backend dell'app iOS GIGI**, non più canale Telegram alternativo.

### Architettura runtime

```
iPhone (GigiHarnessClient.swift)
   │  HTTP(S) + WS
   ▼
03_HARNESS/server/server.js  :7779
   ├─ api/ios-router.js       ← Bearer auth + CORS + dispatcher /api/ios/*
   ├─ api/ios-agent.js        ← POST /api/ios/agent/run (Claude CLI --resume)
   ├─ api/ios-memory.js       ← POST put/query/DELETE (memory/store.js)
   ├─ api/ios-computer-use.js ← Anthropic SDK + Playwright via browser-pool/driver.js
   ├─ api/ios-push-register.js← salva device APNS token
   ├─ api/ios-stream.js       ← WebSocket /ws/ios/stream (interim thoughts)
   ├─ claude-runner.js        ← spawn Claude CLI + streaming JSONL
   ├─ queue.js                ← enqueue + cancel + tracking child per device
   ├─ rate-limit.js           ← detection + interrupted recovery
   ├─ memory-snapshot.js      ← /memo serializzato
   ├─ transcript-mirror.js    ← backup JSONL Claude → logs/transcripts/<deviceId>
   ├─ watchers.js             ← worker proattivi + action="push_apns"
   └─ bridge-rpc.js           ← loopback RPC :7778 per panel.js

03_HARNESS/panel.js  :7777   ← admin UI (indipendente), spawna server come child
03_HARNESS/apns/send.js      ← provider APNS via HTTP/2 + JWT ES256 (no deps)
03_HARNESS/memory/store.js   ← API astratta (JSON MVP, LanceDB swap futuro)
03_HARNESS/browser-pool/driver.js ← lease Playwright CDP per computer-use
```

### Decisioni (fase 10-18)

1. **Memory stack**: MVP JSON file store → API stabile `memory/store.js`, swap a LanceDB+BGE-M3 cambiando `MEMORY_BACKEND=lancedb` senza toccare gli endpoint iOS.
2. **Computer-use model**: `claude-opus-4-7` con tool `computer_20241022` (Anthropic SDK diretto, non CLI) via Playwright CDP su Chrome loggato.
3. **Telegram**: dropped completamente (fase 17). No più `tg()`, `bot_token`, `allowed_chat_ids`, `transcribe.js`.
4. **Host**: Mac locale per dev, VPS-ready — tutti i path via env var (`HARNESS_CONFIG`, `HARNESS_LOGS_DIR`, `HARNESS_SHARED_SECRET`, `ANTHROPIC_API_KEY`, `APNS_*`).
5. **Porte**: 7777 admin panel, 7778 RPC loopback, 7779 iOS HTTP+WS.
6. **Auth**: Bearer shared secret in Keychain iOS (`GigiKeychain.Key.harnessSecret`).

### Flussi chiave

**Comando vocale iOS → risposta Claude**:
```
iPhone: STT locale → agent loop → tool = "harness backend"
→ GigiHarnessClient.agentRun(text) → POST /api/ios/agent/run
→ server enqueue(deviceId, runClaude) → spawn claude --resume session
→ (opt) WS stream interim thoughts per dashboard
→ response {result, session_id} → iOS TTS
```

**Watcher proattivo → push APNS**:
```
watchers.js tick (60s) → fire watcher "gigi-morning-briefing"
→ Claude CLI genera JSON {"push":[{title, body}]}
→ watchers.js parse → apns.sendToDevice(deviceId, payload)
→ iOS AppDelegate handler → NotificationCenter `.gigiProactiveNotification`
```

**Confirm pagamento computer-use**:
```
iOS → POST /api/ios/computer-use {task: "ordina pizza"}
→ jobId → server Anthropic loop → CONFIRM_REQUIRED regex match
→ job.status = "awaiting_confirm" + broadcast WS + (futuro: push APNS)
→ iOS mostra card, user tap OK
→ POST /api/ios/computer-use/:jobId/confirm {approved: true}
→ server polling rileva, riprende loop, completa checkout
```

Spec endpoint completa: `03_HARNESS/docs/api/ios-integration.md`.
Piano integrazione (fasi 10-18 eseguite): `docs/PIANO_INTEGRAZIONE_HARNESS.md`.

### Struttura

```
03_HARNESS/
├── telegram-bridge/      ← gateway Telegram ↔ Claude Code (porta 7777 panel)
│   ├── bridge.js         ← processo principale
│   ├── panel.js          ← HTTP server control panel
│   ├── panel-routes.js   ← route HTTP del panel
│   ├── bridge-rpc.js     ← RPC verso bridge
│   ├── watchers.js/json  ← worker periodici (monitor WhatsApp, terminali remoti)
│   └── transcribe.js     ← whisper.cpp per voice note Telegram
├── browser-mcp/          ← server MCP pool browser Chrome loggati
│   ├── server.js         ← MCP server Puppeteer
│   └── server-playwright.js ← variante Playwright
├── memory-upgrade/       ← progettazione nuovo sistema memoria (v4 + multi-user)
└── docs/memory/          ← context.md + memory.md (stato statico + riassunti AI)
```

### Capability Harness

| Capability | Componente | Stato runtime |
|---|---|---|
| Remote brain via Telegram | `bridge.js` | Attivo (CLI claude spawned per turno) |
| Browser pool Chrome loggato | `browser-mcp/server.js` + profili | Attivo (3 istanze CDP 9224-26) |
| Watcher autonomi (cron-like) | `watchers.js` | Attivo (es. leo-wa-terminal, tommy-wa-assistant) |
| Voice note transcription | `transcribe.js` | Interno al bridge |
| Progettazione memoria v4 | `memory-upgrade/` | Solo design, no codice |
| Pannello controllo HTTP | `panel.js` + `panel-routes.js` | Porta 7777 localhost |

### Integrazione app iOS ↔ Harness

**Attualmente nessuna.** Zero chiamate HTTP incrociate. Opzioni future da decidere:
- **Shared memory backend** — iOS `POST /api/memory/*` su harness (richiede spec + endpoint)
- **Delegated browser tasks** — iOS `POST /api/computer-use` su harness per task che richiedono browser loggato (richiede restructure perché harness usa CLI claude, non Anthropic SDK diretto)
- **Confirm push** — harness notifica iOS via APNS quando serve conferma utente (richiede entrambi: APNS + endpoint)
- **Nessuna** — harness rimane canale parallelo autonomo, utente sceglie interfaccia (Telegram vs app)

Decisione pendente. Quando definita → spec in `03_HARNESS/docs/api/ios-integration.md`.

### Piattaforma

Il codice harness è stato sviluppato originariamente su Windows 11 (path hardcoded in `config.example.json`, script `.bat`/`.ps1`). Per il deploy GIGI serve:
- Config.example macOS/Linux parallelo
- Script shell equivalenti a `kill.ps1`/`watchdog.ps1`
- `claude` CLI Unix al posto di `claude.exe`

Vedi `03_HARNESS/CLAUDE.md` per dettagli operativi e regole critiche (non killare il bridge, pool browser pre-loggati, watcher budget).

---

## Note finali — cosa cambia e cosa no

### Invariato dalla v2.1
- Layer audio (GigiAudioManager, GigiWakeWordEngine) — già ottimale
- GigiActionBridge — tutti i 25+ executor nativi iOS
- UI (MainTabView, ChatView, DashboardView) — zero modifiche
- GigiSpeechService — aggiunta solo streamSpeak()

### Deprecato
- `GigiPlanner.swift` — sostituito dal GigiAgentEngine loop nativo

### Il cuore del cambiamento: 3 nuovi file + 2 aggiornati
```
NUOVO:   GigiAgentEngine.swift      ← il loop
NUOVO:   GigiToolRegistry.swift     ← i 38 tool come oggetti GigiTool
NUOVO:   GigiComputerUse.swift      ← bridge → backend Claude
UPDATE:  GigiCloudService.swift     ← + callWithFunctions()
UPDATE:  GigiSmartOrchestrator.swift ← delegare a GigiAgentEngine
```

Il resto dell'app non sa nulla del cambiamento — riceve ancora lo stesso
`AgentResult` che prima riceveva come `GigiAgentResponse`.

---

## 21. Rework log (living)

> Sezione **viva** — aggiornata a ogni commit del rework `armando-rework`.
> Tracciamento delle modifiche fatte dal 2026-05-07 in poi (post-deescalation team, Armando ora unico dev).
> Ogni voce link-a il commit + ADR + file di analisi nel `docs/rework/`.

### Indice rework
- [Capability map iniziale](#capability-map-iniziale-2026-05-07) — audit di partenza, ~160 capability mappate
- [Phase 1 — Kill list](#phase-1--kill-list-2026-05-07) — 16 file dead-code rimossi
- [Phase 2 — Chirurgia](#phase-2--chirurgia-2026-05-07) — consolidamenti che richiedono decisione di prodotto

### Capability map iniziale (2026-05-07)

Commit `455a36e` · file: `docs/rework/`

Audit completo del codebase pre-rework. Output: 5 file di inventario (160 capability totali) + cruscotto decisionale con kill list / chirurgia / non-toccare.

| File | Capability | Scope |
|---|---|---|
| `CAPABILITY_MAP.md` | — | cruscotto decisionale (TL;DR per ogni decisione) |
| `CAPABILITIES_iOS.md` | 56 | app Swift `02_GIGI_APP/` |
| `CAPABILITIES_harness.md` | 38 | harness Node `03_HARNESS/` |
| `CAPABILITIES_infra.md` | 38 | MDM, GH Actions, hooks, scripts, runbooks |
| `CAPABILITIES_crosscut.md` | 30 user-facing | flussi end-to-end iOS+Harness |

### Phase 1 — Kill list (2026-05-07)

Commit `7e4a7f5` · razionale: codice ad alta confidenza con zero call-site verificati via grep.

**iOS (5 file)**:
- `GigiMDNSDiscovery.swift` — Bonjour LAN browser mai attivato (LAN-only mode mai applicato)
- `PermissionConfirmationSheet.swift` — sheet orfano (residuo sub-issue #79)
- `HarnessQRScanner.swift` — duplicato AVFoundation; mantenuto VisionKit `GigiPairScanner`
- `GIGIWidget/GIGIWidget.swift` + `AppIntent.swift` — boilerplate Xcode `Time:/favoriteEmoji`, non registrato in `GIGIWidgetBundle`

**Harness — channel router stack (8 file + 2 edit)**:
- `api/channel-router.js` + `channels/{telegram,whatsapp,channel-interface}.js` + `audio/{stt,tts,normalize}.js` + `identity/user-mapper.js`
- `server.js`: rimosso import + init + handle()
- `config.example.mac.json`: rimossi blocchi `telegram` / `whatsapp`
- Razionale: GIGI è iPhone-only post-MVP. Il file stesso dichiarava `_default disabled`.

**Harness — browser-pool legacy (1 file)**:
- `browser-pool/server.js` (Puppeteer MCP) — soppiantato da `driver.js`. NB: `server-playwright.js` resta vivo, è ancora usato da `claude-runner.js` via `mcp-browser.json`.

**Infra (2 file)**:
- `.github/workflows/setup-post-mvp-status.yml` — workflow_dispatch one-shot già eseguito
- `scripts/setup-project.sh` — bootstrap GitHub Project v2 idempotente già eseguito

⚠️ **Xcode pbxproj**: i 5 `.swift` cancellati restano referenziati in `02_GIGI_APP/GIGI.xcodeproj/project.pbxproj`. Aprire Xcode → file rossi → Cmd-Click → Delete → Remove Reference prima della prossima build su MacInCloud.

### Phase 2 — Chirurgia (2026-05-07)

Consolidamenti che richiedono decisione di prodotto (non puro kill di dead-code). Ogni decisione formalizzata in ADR.

#### Doppio path Claude — boundary esplicito

Commit `0d6ddc1` · ADR: [ADR-0002](adr/0002-claude-dual-path-cli-vs-sdk.md)

**Decisione**: tenere entrambi i path con scope esclusivo.

- `claude-runner.js` (CLI subprocess via subscription Claude Code) → unico canale per voice / agent / orchestration generale.
- `ios-computer-use.js` (Anthropic SDK con API key, billing per-token) → unico canale per computer-use server-side (Playwright loop).

**Vincolo**: nessun altro file può importare `@anthropic-ai/sdk`. Boundary già pulito nel codice — l'ADR lo blinda.

#### Wake Word "Hey GIGI" — soft-kill MVP

Commit `7e587fb` · ADR: [ADR-0003](adr/0003-wake-word-soft-kill-mvp.md)

**Decisione**: kill soft. Engine `GigiWakeWordEngine` resta nel codebase, gated da `static let isDisabledForMVP = true`. La capability row "Wake Word" in `DashboardView` è ora condizionata sul flag (nascosta in MVP). Settings ha già la sezione "🎙️ Talk to GIGI" sostitutiva con copy esplicativa.

**Razionale**: iOS non permette mic continuo background per app non-VoIP. Sostituito da Back Tap / Action Button / Siri AppIntent (issue [#102](https://github.com/Building-addicts/GIGI/issues/102)). Riattivazione v1.1 = flip flag + remove condition guard (~2 righe).

#### Gemini (Live + REST) + Google Sign-In — kill totale

Commit (in arrivo) · ADR: [ADR-0004](adr/0004-uproot-gemini-and-google-signin.md)

**Decisione**: kill totale. ~1200 righe rimosse, dipendenza `GoogleSignIn` SDK eliminata.

File cancellati:
- `GigiRealtimeEngine.swift` (1062 righe — Gemini Live WebSocket full-duplex con barge-in)
- `GigiAuthManager.swift` (134 righe — pure Google Sign-In OAuth wrapper)

Edit principali:
- `GigiBrainPipeline.swift` — cascade da 4 livelli a 2: Apple Foundation Models → local NLU. Rimossi L0 (Gemini Live) e L2 (Gemini REST, che era già un alias verso Groq).
- `GigiSmartOrchestrator.swift` — handler `onStreamingUtteranceComplete` + `onBargein` rimossi, metodo `executeRealtimeToolCall` rimosso, var `usingRealtimeMic` rimossa (era write-only).
- `GigiActionDispatcher.swift` — metodo `executeRealtimeTool` rimosso.
- `GigiCloudService.swift` — alias legacy `processWithGemini` rimosso (puntava già a `processWithGroq`).
- `GIGIApp.swift` — import `GoogleSignIn` + `GigiAuthManager.shared` + `GIDSignIn.handle(url)` rimossi.
- `MainTabView.swift` — `@StateObject auth` rimosso.
- `OnboardingView.swift` — step "Gemini key (optional)" rimosso, `geminiKey` state + save logic rimossi.
- `SettingsView.swift` — campo + `saveGeminiKey()` + `SettingsField.geminiKey` rimossi.
- `GigiConfig.swift` — `geminiAPIKey` getter, `setGeminiAPIKey` setter, e migration helper rimossi.
- `GigiKeychain.swift` — chiave `geminiAPIKey` rimossa.
- `Info.plist` — `CFBundleURLTypes` block "GoogleSignIn" rimosso (URL scheme `com.googleusercontent.apps.*`).
- `Config.example.xcconfig` — `GEMINI_API_KEY` rimosso, `PICOVOICE_ACCESS_KEY` rimosso (Porcupine deprecato), `GROQ_API_KEY` aggiunto come canonical.
- `README_SETUP.md` — riscritto: niente più Gemini Vision, niente più Porcupine wake word.
- `Architecture-Armando-Revision.md §13` — sezione "Gemini Live WebSocket" marcata RIMOSSO con nota archeologica.

⚠️ **Cleanup manuale residuo** (NON bloccante — build passa lo stesso, ma cosmetico):
- Apri Xcode → **Project → Package Dependencies → GoogleSignIn → (-) Remove**. Senza questo step, `Package.resolved` + `project.pbxproj` mantengono la pin GoogleSignIn-iOS (e le 6 dipendenze transitive Google: `app-check`, `appauth-ios`, `googleutilities`, `gtm-session-fetcher`, `gtmappauth`, `promises`). Il framework resta linkato ma non importato — overhead binary minimo.
- Esegui `xcodebuild -resolvePackageDependencies` per rigenerare `Package.resolved` clean.
- I 5 file Swift cancellati nelle phase 1+2 vanno rimossi anche dalle reference `project.pbxproj` (file rossi in Project navigator → Cmd-Click → Delete → Remove Reference). Xcode 26.3 li gestisce graziosamente come warning, ma è cosmetico.

#### GigiDayPlanReasoner — soft-kill MVP

Commit (in arrivo) · ADR: [ADR-0005](adr/0005-day-plan-reasoner-soft-kill-mvp.md)

**Decisione**: kill soft, stesso pattern del Wake Word. `GigiPlannerEngine` (task decomposer del flow agent) **resta vivo e centrale**. `GigiDayPlanReasoner` (day planner, sub 1/4 di parent #15) viene gated da `isDisabledForMVP = true` perché la sub 4/4 (#59) — registrazione del tool `propose_day_plan` in `GigiToolRegistry` — non è mai stata chiusa, quindi nessun caller production lo invoca: gli unici 3 smoke test in `GIGIApp.swift` `#if DEBUG` sono ora commentati.

**Razionale**: la feature "Day Plan capability" è post-MVP. ~300 righe restano dormienti, riattivazione v1.1 = 3 step (flip flag + chiudi sub 4/4 + decommenta smoke test). Naming clash con `GigiPlannerEngine` ora chiarito da ADR.

#### Setup wizard — kill modalità `lan` (mDNS)

Commit (in arrivo)

**Decisione**: la matrix delle modalità tunnel passa da 4 → 3 (`manual`, `quick`, `named`). La modalità `lan` (mDNS advertise `_gigi._tcp.local`) viene rimossa completamente — mai usata in pratica nella demo (richiede iPhone+Mac sulla stessa rete fisica, edge case fuori dal target).

**File toccati**:
- `tunnel/mdns.js` — DELETED (libreria mDNS non più importata da nessuno)
- `api/setup.js` — rimosso import mdns, mdnsHandle, endpoint `/api/setup/lan/start`+`/stop`, riferimenti `lan` in status / saveConfigMode / supported list
- `api/pair.js` — comment update
- `api/ios-status.js` — rimosso `t.lan?.advertisedUrl` da inferPublicUrl
- `preflight/auto_fixers.js` + `checks.js` — rimossi guard su `mode === 'lan'`
- `public/setup.html` — rimossa Card C "Home Wi-Fi only (mDNS)" + bottone trigger
- `public/app.js` — rimosso label "LAN (mDNS)"
- `config.example.json` — rimosso block `tunnel.lan`

**Modalità rimaste** (ognuna ha il suo ADR/doc rilevante):
- `manual` — fallback storico, l'utente paste URL+secret in iOS Settings
- `quick` — Cloudflare Quick Tunnel con URL `*.trycloudflare.com` random (default demo)
- `named` — Cloudflare Named Tunnel con dominio user (stub 501, ancora da implementare in Phase 5.2 — utente vuole tenerlo come placeholder per il futuro)

#### Watchers default — sposta template in `examples/`

Commit (in arrivo)

**Decisione**: `server/watchers.json` produzione torna `{"watchers": []}`. I 2 template pre-esistenti (`gigi-morning-briefing` + `gigi-meeting-prep`, entrambi `enabled: false`) si trasferiscono in `server/examples/watchers.example.json` con un campo `_README` che spiega come attivarli.

**Razionale**: i template presupponevano tool MCP non garantiti (calendar bridge, meteo API, news MCP). Mantenerli nella config produzione confondeva: dev nuovi vedevano le 2 entry e si chiedevano se andassero attivate o no. Spostandoli in `examples/` la separazione è esplicita: produzione = vuoto, esempi = documentazione.

**File toccati**:
- `server/watchers.json` — svuotato a `{"watchers": []}`
- `server/examples/watchers.example.json` — NUOVO, contiene i 2 template + `_README` field con istruzioni di attivazione
- `server/examples/README.md` — NUOVO, codifica la convenzione "template config vanno in examples/ con suffisso .example, non nella config viva"

**Convenzione** (per future modifiche): qualsiasi config template dimostrativo che il team vuole conservare ma NON spedire come default attivo va in `server/examples/` con suffisso `.example.{json,yml}`.

#### `health-check.yml` — TENUTO dopo valutazione (gap monitoring noto)

Commit (in arrivo) — **decisione di non-kill**, documentata per evitare ri-valutazione futura.

**Stato verificato (2026-05-07)**:
- Workflow GitHub `.github/workflows/health-check.yml` gira ogni mattina alle 8:00 CET
- Compila status report (workflow failures ultime 24h, issue P0/blockers/bugs counts, PR aperte) e posta su **Discord** via webhook (`secrets.DISCORD_WEBHOOK`)
- **Gap noto**: monitora solo 5 workflow hardcoded (`pr-lint, discord-notify, auto-timeline, project-status, progress-tracker`) su ~10 attivi nel repo

**Considerato per kill**, ma **tenuto perché**:
- Costo zero (gratis su GitHub Actions free tier, nessun consumo team-license)
- Anche se il team Discord è morto col team, il webhook continua a postare — utile come "log silenzioso" che il PM può consultare on-demand se serve un riassunto giornaliero
- Killare significherebbe ricostruirlo da zero se in futuro torna un team

**Gap monitoring noto e accettato**: i 5 workflow non monitorati possono fallire silenziosamente. Se uno di loro è critico (es. `auto-blocked-label.yml` non monitorato → label `blocked` non più applicate → dashboard rotta), potresti accorgertene solo manualmente. Trade-off accettato: il PM non ha bandwidth per fix questo gap ora, e l'impatto reale è basso visto che il PM è ora unico dev e usa la dashboard solo come reference.

**Quando ri-considerare il fix (opzione 2)**: se torna un team o se un workflow non monitorato genera un incidente. A quel punto, refactor: lista workflow auto-popolata via `gh workflow list` + destinazione cambia da Discord a "apri issue auto su failure" nel repo (più robusto di Discord chat).

**Quando ri-considerare il kill (opzione 1)**: se entro 6 mesi il PM verifica di non aver mai consultato il report Discord generato.

#### Endpoint debug `/api/ios/push/test` + `/api/ios/memory/all` — TENUTI dopo valutazione

Commit (in arrivo) — **decisione di non-kill**, documentata per evitare ri-valutazione futura.

**Stato verificato (2026-05-07)**:
- `POST /api/ios/push/test` (file dedicato `server/api/ios-push-test.js`, ~22 righe) — manda push APNS di test al deviceId. **Zero caller iOS** (nessun client Swift lo invoca).
- `GET /api/ios/memory/all` (funzione `handleAll` dentro `server/api/ios-memory.js`) — dump completo della memoria harness per deviceId. **Zero caller iOS**.

**Considerati per kill**, ma **tenuti perché**:
- Sono **debug tools** standalone via curl, non feature user-facing. Costo runtime zero (dormono finché non chiamati).
- `/push/test` salva ~20 min nel giorno in cui si configura APNS su device nuovo (alternativa: triggerare un watcher per testarlo, più macchinoso).
- `/memory/all` salva ~30 min nel giorno in cui si debug un problema di memoria server-side (alternativa: scrivere script ad-hoc per leggere il JSON).
- Niente manutenzione ongoing (~80 righe totali, semplici, non toccano stack rotto).

**Quando ri-considerare il kill**: se entro 6 mesi nessuno li chiama via curl per debug E se decidi che la memoria harness non sarà mai usata da app (oggi: app usa CloudKit, harness memory inerte). A quel punto, kill safe via `git revert` o nuovo commit.

**NON sono "dimenticati"** — sono tenuti per scelta. Se torni qui pensando "a che servono?" → leggi questa entry prima di toccare.

#### Build verify — Post-Phase 2 (commit `1bb6d63`)

Eseguito 2026-05-07 su MacInCloud (FF125, Xcode 26.3, Build 17C529):

```
Path: ~/GIGI-armando-rework (sync via tar/ssh)
Comando: xcodebuild -project GIGI.xcodeproj -scheme GIGI -configuration Debug \
         -destination 'generic/platform=iOS' \
         CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
Risultato: ** BUILD SUCCEEDED ** (al 2° tentativo dopo fix `GigiToolCall`)
```

**Fix Phase 2 emerso da build verify** (commit `1bb6d63`):
- `GigiToolCall` struct era definito dentro `GigiRealtimeEngine.swift` (cancellato in `8b3cfaa`) ma usato da `GigiActionDispatcher.mapToolCall` + `GigiActionDispatcher+Native` per il path on-device tool dispatch (provider-agnostico).
- Risolto: re-introdotto come prefix in `GigiActionDispatcher.swift` (3 campi `name/args/callId`). No edit pbxproj richiesto perché il file ospitante è già nel target.

**IPA generata**: `_IPA_DROP/GIGI-armando-rework.ipa` (4.2 MB Debug, unsigned — Sideloadly firma in-flight per installazione).

### Codice congelato — index (living)

> **Indice unico** dei pezzi di codice attualmente parcheggiati ma conservati nel codebase per riattivazione futura. Convenzione uniforme: ogni pezzo ha una `static let isDisabledForMVP = true` nella sua classe principale + un ADR che documenta scope, motivazione, e procedura di riattivazione.
>
> Quando torni a guardare il repo dopo mesi e ti chiedi "cosa avevo congelato?", **leggi questa tabella per primo**.

| Capability | Flag | File principale | ADR | Per riattivare |
|---|---|---|---|---|
| **Wake Word "Hey GIGI"** | `GigiWakeWordEngine.isDisabledForMVP` | [GigiWakeWordEngine.swift:41](../02_GIGI_APP/GIGI/GigiWakeWordEngine.swift) | [ADR-0003](adr/0003-wake-word-soft-kill-mvp.md) | flip flag a `false` + remove condition guard nella DashboardView (~2 righe) |
| **Day Plan Reasoner** | `GigiDayPlanReasoner.isDisabledForMVP` | [GigiDayPlanReasoner.swift:75](../02_GIGI_APP/GIGI/GigiDayPlanReasoner.swift) | [ADR-0005](adr/0005-day-plan-reasoner-soft-kill-mvp.md) | flip flag + chiudi sub 4/4 ([#59](https://github.com/Building-addicts/GIGI/issues/59), registra tool `propose_day_plan` in `GigiToolRegistry`) + decommenta i 3 smoke test in `GIGIApp.swift` + decommenta la riga `ProposeDayPlanTool()` in `GigiToolRegistry.all` + riaggiungi `"propose_day_plan"` a `alwaysIncluded` |

#### Verifica veloce: quanti pezzi sono congelati ora?

```bash
grep -rn "isDisabledForMVP\s*=\s*true" 02_GIGI_APP/GIGI/ | wc -l
```

Il numero deve combaciare con le righe in tabella sopra. Se ne trovi di più → qualcuno ha aggiunto un soft-kill senza aggiornare questa tabella + senza scrivere ADR. Convenzione: **niente flag senza ADR + entry in tabella**.

#### Convenzione per aggiungere nuovi pezzi congelati

1. Aggiungi `static let isDisabledForMVP = true` alla classe principale, con commento esplicativo che cita issue + ADR.
2. Tutti i public entry point della classe hanno guard `Self.isDisabledForMVP` early-return.
3. Disabilita / commenta i caller production con riferimento all'ADR.
4. Scrivi ADR `NNNN-<feature>-soft-kill-mvp.md` (copia da `0003` o `0005`).
5. Aggiungi una riga a questa tabella.
6. Aggiungi sotto-sezione in §21 phase corrente con SHA del commit.

### Debiti architetturali (TODO post-rework, living)

> **Indice vivo** dei debiti tecnici / inefficienze emerse durante il rework armando-rework ma **NON affrontate** nello stesso (per scope o perché richiedono refactor non triviali). Diventa lo spazio dove parcheggiamo "questa cosa va rivista" senza dimenticarsene. Non sono bug — sono scelte oggi accettabili che meritano riprogettazione quando ci sarà bandwidth.

#### TD-001 — Meccanismo di tool selection inefficiente

**Stato corrente** (verificato 2026-05-07):
Il `GigiToolRegistry.selectRelevant(for: text)` decide quali tool mandare al modello LLM ad ogni richiesta vocale, con questa logica:

1. **44 tool registrati** in `all`. Ognuno ha un array `tags: [String]` (parole chiave hard-coded, italiano + inglese).
2. **14 tool "always included"** in `alwaysIncluded`: vengono SEMPRE inseriti nel prompt LLM indipendentemente dal contesto (`make_call`, `send_message`, `ask_time`, `ask_date`, `weather`, `torch_on/off`, `set_timer/alarm`, `toggle_wifi/bluetooth`, `media_*`, `read_calendar`, `ask_claude`).
3. **Score per match dei tag**: ogni tool della lista `all` riceve `+10` per ogni `tag` che compare come substring nel testo utente lowercased, `+5` bonus per match esatto di parola.
4. **Top 12 selezionati** dal score sort, mandati come tool declarations al modello LLM.

**Costo concreto stimato**: ~12-18 tool per richiesta × ~120 token ciascuno = ~1.5-2k token solo di tools nel prompt, ad ogni singola voice turn.

**Inefficienze rilevate**:

- **Keyword matching brittle**: i tag sono hard-coded e NON semantici. *"Voglio fissare un appuntamento col dottore"* non matcha `set_reminder` perché il tag set non include "appuntamento" o "dottore". Risultato: si appoggia sui tool always-included e magari sceglie il tool sbagliato.
- **Always-included rigido**: 14 tool entrano SEMPRE. Se l'utente chiede *"che ore sono?"*, il prompt include `weather`, `wifi`, `torch`, `timer`, `alarm`, `media_*`, `calendar` — tutti irrilevanti per quella richiesta. ~1.5k token sprecati.
- **Tag manutenzione manuale**: aggiungere un tool nuovo richiede al dev di scrivere a mano una lista di tag rappresentativa. Facile dimenticarsene, facile essere inconsistenti tra developer.
- **Nessuna learning loop**: il sistema non impara quali tool vengono effettivamente chiamati su quali frasi. Tool che falliscono spesso non vengono down-weight-ati. Tool mai chiamati non vengono dropped.
- **Nessuna cache**: la stessa frase ricorrente (*"che ore sono?"*) ricompila la selezione ogni volta da zero, anche se il risultato è deterministicamente lo stesso.

**Miglioramenti possibili** (ranking effort/impact):

1. **🟢 Quick win (~2 ore)**: drop `alwaysIncluded` per tool veramente specifici (`weather`, `wifi`, `torch`, `media_*`). Tieni only `make_call`, `send_message`, `ask_claude` come fallback universali. Risparmio: ~50% token wasted on irrilevanti.
2. **🟡 Medio (~1 settimana)**: migra il scoring da keyword tag → **embedding semantico**. Pre-calcola embedding ogni tool description al boot (~50ms one-shot). A runtime, embed la query utente, retrieve top-K per cosine similarity. Apple Foundation Models o un piccolo CoreML embedder fanno il lavoro on-device gratis. Risultato: scoring molto più resiliente a variazioni linguistiche.
3. **🔴 Grosso (~2 settimane)**: **two-stage selection**. Stage 1: micro-modello classifica la richiesta in 1 dei ~8 domini (call/message/calendar/media/home/web/cloud/info). Stage 2: solo i tool del dominio selezionato passano al modello principale. Riduce tool per request a ~3-5. Scaling-friendly: aggiungere il 100° tool non degrada le performance.
4. **Bonus**: cache LRU della selezione per N frasi più frequenti (es. ultime 50). Hit rate atteso >70% in uso reale (le voice turn sono molto ripetitive).

**Note**: il #1 è il primo da fare — è low-risk, high-value, no breaking change. Gli altri sono refactor sostanziali da pianificare.

#### TD-002 — Memoria GIGI: 3 layer scollegati da unificare

**Stato corrente** (verificato 2026-05-07):
La "memoria utente" di GIGI vive oggi in **3 sottosistemi paralleli** che NON si parlano:

1. **`GigiMemory.swift`** (iOS, ~417 righe)
   - Backend: CloudKit `iCloud.com.killsiri.GIGI` (private database) + RAM cache write-through
   - Schema: `Dictionary<String, String>` con prefix-keys (`contact:`, `routine:`, `pref:`, `place:`, `person:`)
   - Fallback graceful: local-only mode su Sideloadly (bundle ID rifirmato) / simulatore / free Apple ID
   - **È quello che usi oggi** — i tool `remember`/`recall` lo chiamano

2. **`GigiVectorStore.swift`** (iOS, ~259 righe, sidecar)
   - Indice vettoriale parallelo aggiornato ad ogni `GigiMemory.remember()`
   - Scopo: recall semantico (es. *"chi è il familiare di Anna?"* → trova `contact:marco fratello di anna` per significato)
   - **Sperimentale** — non wired ai tool production, classificato in capability map come kill-candidate

3. **`03_HARNESS/memory/store.js` + `backends/json-store.js`** (Node, ~100 righe)
   - File JSON locale sul Mac, uno per `userId` (= deviceId iPhone)
   - Esposto via 4 endpoint HTTP (`/api/ios/memory/{put,query,delete,all}`)
   - **Zero caller iOS** — l'app non lo usa, va su CloudKit
   - Costruito come infrastruttura per uso futuro (multi-device sync? watcher context? unclear)
   - Factory pattern con branch `lancedb` broken (file `lancedb-store.js` non esiste)

**Problemi della frammentazione attuale**:

- **Sovrapposizione concettuale**: tutti e 3 dicono di salvare "memoria utente". Quale è la sorgente di verità?
- **Scollegamento funzionale**: il harness non sa cosa l'utente ha salvato in CloudKit. Se un watcher proattivo vuole *"ricordagli del compleanno di Marco"*, non ha accesso a `contact:marco` perché vive solo su iPhone.
- **Vector store dormiente**: il sidecar è completamente isolato dal flow tool, non viene mai interrogato per recall.
- **3 schema diversi**: prefix-keys (iOS), JSON entries con tags (harness), embedding vectors (sidecar). Niente shared contract.
- **Decisioni puntuali rischiose**: cambiare uno dei 3 layer senza una visione unitaria genera debito (es. la Q8 del rework — kill della factory harness — sarebbe una patch chirurgica isolata che non risolve la frammentazione).

**Direzione progettuale ideale** (da definire):

Unificare i 3 layer in un'**architettura della memoria coerente** con questi possibili principi:

- **Una sola sorgente di verità** per la memoria utente (probabilmente CloudKit, perché è dove l'utente si aspetta di trovarla cross-device).
- **Sync bidirezionale iOS ↔ harness** quando l'utente è online (così i watcher proattivi possono leggere il context utente).
- **Vector search integrato**, non sidecar. Embedding + retrieval come parte dello stack standard di `recall()`.
- **Schema condiviso** (probabilmente schema iOS prefix-keys come canonical).
- **Layered cache**: RAM in app, JSON locale sul harness come cache offline, CloudKit come sorgente.

**Quando affrontare**:

**Alla fine del rework armando-rework**, dopo aver chiuso le altre domande aperte (subagent gap, health-check, ecc.). Razionale del PM (@ArmandoBattaglino, 2026-05-07): patch isolate sui sotto-layer (es. opzione 1/2/3 della Q8) sono spreco — meglio aspettare e fare un design coerente in una phase dedicata, dopo che il resto del repo è pulito.

**Implicazione operativa**: per ora **NON tocchiamo** la factory `memory/store.js`, il branch `lancedb` broken, o i 2 example config con `"upgrade_target": "lancedb"`. Convivono col loro stato attuale. Verranno toccati nella phase "Unificazione memoria" come parte di un design unitario.

---

### Convenzione per future modifiche

Ogni commit del rework deve aggiungere una riga sotto la phase corrente di questa sezione 21, con:
- SHA breve del commit
- 1 riga di summary
- Link ADR se la decisione è strutturale

Quando una phase è chiusa (tutti i todo del cruscotto `CAPABILITY_MAP.md` evasi), aggiungere una nuova `### Phase N` sotto.

---

*GIGI v3 — Paper tecnico — Aprile 2026 — Rev. 2 (peer reviewed)*
*Rework — Maggio 2026 — Armando Battaglino (solo dev) + Claude Code*
