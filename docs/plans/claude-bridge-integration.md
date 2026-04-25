# Claude Bridge Integration in GIGI

**Status**: Draft · **Owner**: Armando · **Scope**: iOS app + harness wiring

## Requirements Summary

Integrare Claude (via harness backend) come secondo cervello disponibile all'interno dell'app GIGI, mantenendo Groq come router principale. L'utente interagisce con GIGI normalmente; Groq decide quando delegare a Claude esponendo un tool `ask_claude`. Pensieri e tool call di Claude streaming in tempo reale nella chat. Toggle opzionale in Settings per forzare tutte le richieste via Claude.

**Modello architetturale scelto** (dalla conversazione di planning):
- **Default**: Groq primary router + tool `ask_claude` per escalation automatica
- **UI pensieri**: inline italic/grey messages (Opzione A — stream in chat)
- **Force-Claude**: toggle in Settings (persistente in Keychain)
- **Dati iPhone per Claude**: ibrido — Phase 1 push context upfront, Phase 3 pull via WebSocket reverse-bridge
- **Fallback harness unreachable**: errore chiaro in chat (no silent fallback a Groq). Opzione in Settings per abilitare auto-fallback.

## Acceptance Criteria

### AC-1 — Escalation automatica Groq → Claude
- [ ] Dopo aver detto "Analizza il mio calendario della settimana e suggerisci 3 slot da 1h per fare sport", Groq chiama `ask_claude` entro 3 secondi
- [ ] L'app mostra banner "💭 Chiedo a Claude..." in chat
- [ ] Claude riceve il task via `POST /api/ios/agent/run` con `stream=true`
- [ ] Pensieri arrivano via WebSocket ed appaiono come bolle italic/grey nella chat entro 500ms dall'emit dal harness
- [ ] Risposta finale arriva in ≤ 60s (p95), TTS la pronuncia

### AC-2 — UI thought streaming (Opzione A)
- [ ] Ogni evento `claude_event` con `type=thought` aggiunge un messaggio alla `GigiConversationMemory` con role `.thinking`
- [ ] Messaggi `.thinking` renderizzati in `ChatView` con: italic, grey `.white.opacity(0.6)`, prefix `💭`, font `.caption2`
- [ ] Messaggio finale con `type=speech` renderizzato come bolla normale (role `.gigi`)
- [ ] Scroll automatico ad ogni nuovo messaggio

### AC-3 — Force-Claude toggle (Settings)
- [ ] Nuova sezione "Brain Mode" in `SettingsView.swift` con `Toggle("Force Claude for all requests")`
- [ ] Stato persistito in `GigiKeychain` con chiave `forceClaude` (string "1"/"0")
- [ ] Quando attivo: `GigiAgentEngine.process` salta la chiamata a Groq e invoca direttamente `GigiHarnessClient.agentRun`
- [ ] Quando attivo + harness non raggiungibile: errore "Harness non raggiungibile. Disattiva Force Claude o accendi il server" in chat
- [ ] Secondo toggle `Toggle("Auto-fallback to Groq if Claude fails")` opt-in (default OFF)

### AC-4 — Context injection (Phase 1 push model)
- [ ] Il payload di `agentRun` include un blocco `context` con: profilo utente, prossimi 7 giorni calendario, ultime 10 memorie rilevanti, localizzazione corrente
- [ ] Claude system prompt nel harness espone `context` come "user snapshot"
- [ ] Test: "Cosa ho in programma domani?" via ask_claude → Claude risponde senza dover chiedere dati aggiuntivi all'iPhone

### AC-5 — Harness error handling
- [ ] Se `GigiHarnessClient.agentRun` ritorna `.failure(.notConfigured)`: messaggio "Configura URL+secret in Settings → Harness"
- [ ] Se ritorna `.failure(.transport)`: messaggio "Harness irraggiungibile. Verifica che il server sia acceso"
- [ ] Se ritorna `.failure(.badResponse(status))`: messaggio "Harness errore HTTP \(status)"
- [ ] Errore sonoro `SoundEngine.play(.error)` + pulizia stato `isThinking = false`

### AC-6 — Voice flow
- [ ] Dopo wake-word + trascrizione, se Groq chiama `ask_claude`: il flow voice continua normalmente
- [ ] TTS legge solo il messaggio finale (non i pensieri), per evitare audio verboso
- [ ] `GigiAudioManager.startWakeWordListening()` riavviato solo dopo la risposta finale, non dopo ogni thought

## Implementation Steps

### Phase 1 — MVP: wire-up escalation automatica (stima: 4-6 ore)

**Step 1 — Nuovo tool `AskClaudeTool`** · file: `02_GIGI_APP/GIGI/GigiToolRegistry.swift`
- Aggiungi struct `AskClaudeTool: GigiTool` prima di riga 1102 (class GigiToolRegistry)
  - `name = "ask_claude"`
  - `tags = ["analizza", "ricerca", "prenota", "trova", "computer", "deep", "complex"]`
  - `declaration` con parametri: `task: String` (required), `context: String?`
  - `execute` delega a un nuovo `GigiClaudeBridge.shared.run(task:)` (vedi Step 3)
- Aggiungi `AskClaudeTool()` all'array `all` (riga 1105-1119)

**Step 2 — Estensione ruoli messaggio** · file: `02_GIGI_APP/GIGI/GigiConversationMemory.swift`
- In `GigiMessage.Role` (riga 7): aggiungi `case thinking` e `case toolEvent`
- Nuova funzione `addThought(_ text: String)` che appende messaggio con role `.thinking`
- Nuova funzione `addToolEvent(name: String, status: String)` per render eventi di tool

**Step 3 — Nuovo coordinatore `GigiClaudeBridge`** · file NUOVO: `02_GIGI_APP/GIGI/GigiClaudeBridge.swift`
- `@MainActor final class GigiClaudeBridge`, singleton
- Proprietà: `private var stream: GigiHarnessStream?`
- `func run(task: String, context: String?) async -> ToolResult`:
  1. Build context blob (vedi Step 7)
  2. Connetti `GigiHarnessStream` se non già connesso
  3. Chiama `GigiHarnessClient.shared.agentRun(text: taskWithContext, stream: true)`
  4. Nel callback WebSocket: per ogni evento `claude_event` con:
     - `type=thought`: chiama `memory.addThought(event.content)`
     - `type=tool_start`: chiama `memory.addToolEvent(name: event.tool, status: "running")`
     - `type=tool_result`: aggiorna il messaggio toolEvent con `status: "done"`
     - `type=speech` o `type=done`: completa con il testo finale, ritorna `ToolResult.success`

**Step 4 — Rendering thoughts** · file: `02_GIGI_APP/GIGI/ChatView.swift` (line ~250+ `MessageBubble`)
- In `MessageBubble.body`: aggiungi branch per `message.role == .thinking`:
  ```swift
  case .thinking:
      HStack { Text("💭 \(message.text)").font(.caption2).italic().foregroundColor(.white.opacity(0.6)); Spacer() }
          .padding(.horizontal, 20)
  ```
- Per `.toolEvent`: simile ma con icona `gearshape.fill` + stato

**Step 5 — Handler in `GigiAgentEngine`** · file: `02_GIGI_APP/GIGI/GigiAgentEngine.swift` (line ~165-215, gestione `functionCalls`)
- Prima di `executeParallel(response.functionCalls)`: intercetta chiamate a `ask_claude`
- Esegui `await GigiClaudeBridge.shared.run(task:, context:)` sequenzialmente (non parallel — il bridge è lungo)
- Propaga il risultato come `ToolResult` normale nel `toolResultTuples`

**Step 6 — Prompt update per Groq** · file: `02_GIGI_APP/GIGI/GigiFoundationAgent.swift` (line 184+ `agentToolPrompt`)
- Aggiungi alla lista CAPABILITIES:
  ```
  ask_claude       → Delegate to Claude for complex reasoning, web research,
                     computer-use browsing, analysis of large data.
                     Use when: user asks for analysis, research, booking,
                     or any task too complex for direct tool calls.
                     (task = full description of what Claude should do;
                      context = optional extra info)
  ```
- Aggiungi DECISION HEURISTICS:
  ```
  - If action fits a direct tool (make_call, navigate, homekit_*) → use that tool
  - If user asks "analyze", "find", "book", "research", "figure out" → ask_claude
  - If user asks multi-step task (>3 sub-tasks) → ask_claude
  ```

**Step 7 — Context blob (Phase 1 push)** · nuovo metodo in `GigiClaudeBridge.swift`
- `private func buildContextSnapshot() async -> String`:
  1. Carica `GigiUserProfile.shared.load()` → nome/email/preferenze
  2. `ReadWeekCalendarTool().execute(...)` → prossimi 7 giorni come JSON
  3. Ultime 10 entries da `GigiMemory.shared.recentMemories(limit: 10)` → key/value pairs
  4. Posizione corrente via `CLLocationManager` (se autorizzato)
- Formato: blocco testo in system prompt-style, ~500-2000 tokens max

**Step 8 — Configurazione WebSocket URL fix** · verifica: `02_GIGI_APP/GIGI/GigiHarnessClient.swift:356`
- Conferma che `makeWebSocketURL()` funzioni col setup attuale (`http://192.168.1.67:7779` → `ws://192.168.1.67:7779/ws/ios/stream`)
- Test manuale: connessione WebSocket senza task (solo ping)

### Phase 2 — Force-Claude toggle (stima: 1-2 ore)

**Step 9 — Keychain key** · file: `02_GIGI_APP/GIGI/GigiKeychain.swift`
- Aggiungi `forceClaude` e `claudeAutoFallback` all'enum `Key`

**Step 10 — UI toggle** · file: `02_GIGI_APP/GIGI/SettingsView.swift` (aggiungi dopo `harnessSection`)
- Nuova `brainModeSection`:
  ```swift
  @State private var forceClaude = ...loadBool("forceClaude")
  @State private var autoFallback = ...loadBool("claudeAutoFallback")

  Section {
      Toggle("Force Claude for all requests", isOn: $forceClaude)
      Toggle("Auto-fallback to Groq if Claude fails", isOn: $autoFallback)
  } header: { Text("🧠 Brain Mode") }
  ```
- Su `.onChange` salva in Keychain

**Step 11 — Bypass Groq in process()** · file: `02_GIGI_APP/GIGI/GigiAgentEngine.swift` (riga 57+)
- All'inizio di `process(text:)`:
  ```swift
  if GigiKeychain.loadBool("forceClaude") {
      let result = await GigiClaudeBridge.shared.run(task: text, context: nil)
      return AgentResult(speech: result.value, ...)
  }
  // ...existing Groq flow
  ```

### Phase 3 — Reverse bridge pull model (stima: 6-8 ore — DEFER)

**Step 12 — Protocol design**
- WebSocket messages harness → iOS:
  - `{type: "iphone_query", queryId: UUID, method: "contacts.find", params: {name: "Marco"}}`
  - `{type: "iphone_query_result", queryId: UUID, result: {phone: "+39..."}}`
- Metodi disponibili: `contacts.find`, `calendar.query`, `memory.query`, `location.current`, `homekit.list`

**Step 13 — iOS query handler** · file NUOVO: `02_GIGI_APP/GIGI/GigiReverseBridge.swift`
- Riceve query dal WebSocket, dispatcha a handler nativi, risponde con `iphone_query_result`

**Step 14 — Harness Claude tools** · files: `03_HARNESS/server/api/ios-agent.js`, potenziale MCP server
- Registra MCP tools che il Claude CLI può chiamare: `ios_contacts_find`, `ios_calendar_query`, ecc.
- Ogni tool invia `iphone_query` via WebSocket, aspetta `iphone_query_result`, ritorna il risultato al CLI

*Phase 3 è rimandabile: con Phase 1 context push, Claude ha già dati sufficienti per la maggior parte dei task.*

## Risks and Mitigations

| Rischio | Probabilità | Impatto | Mitigazione |
|---|---|---|---|
| Groq non chiama `ask_claude` quando dovrebbe (sub-ottimale routing) | Alta | Medio | Prompt engineering iterativo; log decisioni per review; AC-1 test con 5 query tipiche |
| Thought stream causa lag UI (troppi messaggi in chat) | Media | Basso | Debounce a 200ms per messaggi `.thinking`; limita a 20 thoughts max prima di collapse |
| Harness non raggiungibile durante voice interaction (PC spento) | Alta | Alto | AC-5 errore chiaro; in futuro aggiungere health check proattivo prima di escalate |
| WebSocket disconnect a metà task lungo | Media | Alto | `GigiHarnessStream` già fa reconnect con backoff; aggiungere resume-from-session |
| Context blob > 100KB causa timeout network mobile | Bassa | Medio | Cap a 2000 tokens (~8KB); log size; truncate calendario a 7gg anziché 30gg |
| Sideload + force-Claude: user vede errore ma non capisce | Media | Basso | Error message include azione: "Verifica harness su PC" |
| Claude interpreta task user-profile e lo modifica senza consenso | Bassa | Alto | Non esporre ancora write tools via reverse bridge; solo read in Phase 1-2 |

## Verification Steps

**Dev environment**:
1. Harness acceso localmente su `192.168.1.67:7779`, secret configurato
2. iPhone sulla stessa Wi-Fi del PC, URL+secret in Settings → Harness → Save, stato verde ✓

**Test manuali Phase 1**:
1. ✓ "Ciao GIGI, come stai?" → risposta diretta da Groq, zero escalation
2. ✓ "Chiama mamma" → tool `make_call` locale, zero escalation
3. ✓ "Analizza il mio calendario della settimana e trovami slot per sport" → escalation a Claude, 3+ thought bubble visibili, risposta finale < 60s
4. ✓ "Prenotami un tavolo a Nobu per domani alle 20" → escalation, Claude esegue computer-use Playwright (se configurato)
5. ✓ Spegni harness, prova (3) → errore chiaro "Harness non raggiungibile"
6. ✓ Riaccendi, prova (3) → funziona

**Test manuali Phase 2**:
7. ✓ Settings → Brain Mode → attiva Force Claude → "Che ora è?" → va direttamente a Claude (anche per query semplici)
8. ✓ Disattiva → stesso query → Groq risponde immediatamente con `ask_time`

**Test automatici** (future, opzionale):
- Unit test su `GigiClaudeBridge.buildContextSnapshot()` → output contiene profilo + calendario
- Integration test mock `GigiHarnessClient.agentRun` → verifica routing e error handling

## Open Questions / Follow-ups

- **Costi Claude**: `ask_claude` usa la subscription Claude Pro/Max dell'utente (via CLI). Va monitorato: 1 escalation può consumare tokens significativi. Log `costEstimate` in `AgentResult`.
- **Privacy context**: il context blob include calendario e contatti. Per utenti privacy-conscious, considerare toggle "share iPhone data with Claude" (default ON per user power, OFF per privacy).
- **Localization**: pensieri in inglese (Claude default) vs italiano. Il prompt del harness può forzare italiano via `system_prompt` config.
- **Phase 3 trigger**: rimandiamo finché Phase 1-2 non sono stabili e testate. Valutare necessità reale dopo 2-4 settimane d'uso.

## Dependencies

- Nessuna dipendenza esterna nuova
- Usa tutto quello già in place: `GigiHarnessClient`, `GigiHarnessStream`, harness backend
- Nessuna modifica al `project.pbxproj` manuale grazie a `PBXFileSystemSynchronizedRootGroup`

---

**Appendix A — Flow diagram Phase 1**

```
iPhone                             Harness (PC)                  Claude CLI
──────                             ────────────                  ──────────
User: "trova slot sport"
  │
  ├─ Groq API call
  │   └─ function_call: ask_claude(task, context)
  │
  ├─ GigiClaudeBridge.run()
  │   ├─ build context blob
  │   └─ POST /api/ios/agent/run  ────►  enqueue → spawn claude
  │                                            │
  │       WebSocket events  ◄───  broadcast   │
  ├─ addThought("Looking at calendar...")      │
  ├─ addThought("Found Tue 7am free...")       │
  │                                       ◄──── claude output
  ├─ addGigi("Ti propongo: Mar 7-8, Giov 18-19...")
  │
  └─ TTS speaks final answer
```

**Appendix B — Esempio context blob**

```
USER SNAPSHOT
=============
Name: Armando Battaglino
Email: efactorygroupsrl@gmail.com
Preferences: usa italiano, ristoranti giapponesi

CALENDAR (next 7 days)
=======================
Mon 2026-04-25: 9:00-11:00 Meeting team, 14:30-15:00 Dentista
Tue 2026-04-26: 10:00-12:00 Review codice
...

RECENT MEMORIES
===============
- pref:sport = corsa o palestra
- place:palestra = Virgin Active Milano Centro
- contact:coach = Marco Rossi, +39...

LOCATION
========
Current: Milano, Italy (45.4642, 9.1900)
```
