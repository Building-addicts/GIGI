# GATE 6 — Killer demo "Tesla → nota" end-to-end (Path 4 chained con Path 2)

> **Status**: Pending (richiede GATE 5 chiuso)
> **Effort stimato**: 2-3 giorni lavorativi
> **Bloccanti pre-gate**: GATE 5 chiuso (Path 4 Claude Code funzionante + MCP harness-browser stabile); GATE 3 chiuso (Path 2 Tool calling con `create_note` tool nella lista 15 — verificare che `create_note` sia incluso o aggiungerlo)
> **Sblocca**: GATE 8 (hardening + OSS release, dove il demo finisce nel README video 3-min)
> **Funzione consegnata (1 frase)**: la "killer demo" Tesla → nota funziona end-to-end e in <90s — l'utente pronuncia "Search Wikipedia for Nikola Tesla and create an iPhone note about his most important invention", il router classifica multi-step browser+memory, Path 4 Claude Code naviga Wikipedia + estrae l'invention, ritorna summary, secondo turno implicito Apple FM riceve summary + invoca `create_note` Path 2 che crea una nota iOS reale via NotesKit / shortcut URL.

---

## 1. Obiettivo

Questo è IL momento "wow" del demo OSS. Tutta l'architettura 5-path esiste, ma fino a GATE 5 nessuna query la attraversa completamente in un singolo turno. GATE 6 implementa la **chain 2-turn callback**:
1. Path 4 (Claude Code MCP browser) fa research → ritorna `summary` text
2. iOS riceve `text_response` → 2nd turn implicito: Apple FM (`respondWithTools(text: "Create a note titled 'Nikola Tesla' with body '\(summary)'", tools: [CreateNoteTool])`)
3. `CreateNoteTool.call()` invoca `GigiActionDispatcher.create_note(title:, body:)` → app Notes iOS riceve la nota

Output: la nota appare nell'app Notes iOS in <90s dalla pronuncia.

Inoltre questo GATE include:
- Prompt engineering refinement per task multi-step ("first: research X, second: create Y")
- Latency tuning (cap iteration MCP loop a 12 step, abort + apologize se >90s)
- Test su 4-5 varianti della query killer per stabilità

---

## 2. Pre-condizioni

- [ ] GATE 0-5 chiusi
- [ ] `create_note` tool incluso nella lista 15 di GATE 3 (verificare). Se non incluso, aggiungere come 16esimo OR sostituire `delegate_to_claude` (che è meglio gestire come fallback nel router, non come tool)
- [ ] `GigiActionDispatcher.create_note` handler funzionante (verifica in `GigiActionDispatcher+Native.swift`)
- [ ] MCP `harness-browser` può navigare Wikipedia (test diretto GATE 5)

---

## 3. Task implementativi

- **Task 6.1 — Verificare/aggiungere `CreateNoteTool`** (2h)
  - File: `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift`
  - Aggiungere se mancante:
    ```swift
    @available(iOS 26, *)
    struct CreateNoteTool: Tool {
        let name = "create_note"
        let description = "Create a note in the iOS Notes app. Use after research/summary tasks."

        @Generable
        struct Arguments {
            @Guide(description: "Note title, e.g., 'Nikola Tesla'.")
            var title: String

            @Guide(description: "Note body content.")
            var body: String
        }

        func call(arguments: Arguments) async -> String {
            return await GigiActionDispatcher.shared.bridge.executeRaw(
                label: "create_note",
                params: ["title": arguments.title, "body": arguments.body]
            )
        }
    }
    ```
  - Verificare che `GigiActionDispatcher.create_note` esista e usi NotesKit OR `shortcut://create-note?title=&body=` URL scheme
  - Aggiornare `allTools` array

- **Task 6.2 — Implementare 2-turn callback in `GigiRequestRouter`** (4h)
  - File: `02_GIGI_APP/GIGI/GigiRequestRouter.swift`
  - Modificare `dispatchDelegateCloud` per detettare query "research + action" pattern:
    - Se decision.requiredCapabilities contains both "browser" AND ("memory" OR "multi_step" presence di "note"/"reminder"/"email" nel prompt)
    - Dopo che Path 4 ritorna `textResponse`, parsare il summary
    - 2nd turn: chiamare `Apple FM.respondWithTools(text: "Now create a note with title <inferred> and body <summary>", tools: [CreateNoteTool])`
  - Alternativa più clean: chiamare il router ricorsivamente con un prompt sintetico:
    ```swift
    let researchResult = await runClaudeCode(...)
    let secondTurnPrompt = "Save this as a note titled '\(title)': \(researchResult.summary)"
    let secondTurnDecision = await foundationSession.routeRequest(text: secondTurnPrompt, ...)
    // dovrebbe ritornare path=native_tool primaryAction=create_note
    return await dispatchNativeTool(decision: secondTurnDecision)
    ```
  - Riferimento: piano §4.3 flow "ricerca + nota Tesla", §8 AC8

- **Task 6.3 — Prompt engineering per multi-step Claude Code** (3h)
  - File: `03_HARNESS/server/claude-runner.js` OR `02_GIGI_APP/GIGI/GigiRequestRouter.swift`
  - Quando dispatch a Path 4 con multi-step nature detect, prepend al prompt:
    ```
    SYSTEM: You are GIGI's research backend. Your job is to:
    1. Research the topic the user requests
    2. Return a CONCISE 2-3 sentence summary
    3. Do NOT take destructive actions
    4. Do NOT navigate to login pages
    The user's voice assistant will use your summary to create a note/email/etc.

    USER: <original prompt>
    ```
  - Test che summary ritorna in 2-3 frasi, NON paragrafi lunghi
  - Se Claude Code summary >500 chars, troncare iOS-side

- **Task 6.4 — Latency tuning + iteration cap** (3h)
  - File: `03_HARNESS/server/claude-runner.js`
  - Aggiungere `options.maxIterations` default 12
  - Aggiungere `options.timeoutMs` default 90000
  - Se subprocess >12 iteration MCP tool calls OR >90s, SIGTERM + emit `error: "timeout, please try a simpler query"`
  - iOS-side: speak "Sorry, that took too long" graceful fallback
  - Riferimento: piano §9 risk "Latency Path 4 >90s su browser pesante"

- **Task 6.5 — Test varianti killer demo (5 scenari)** (4h)
  - Registrare in `docs/research/gate-6-killer-demo.md`:
    1. **Tesla → note**: "Search Wikipedia for Nikola Tesla and create a note about his most important invention"
       - Atteso: Note iOS con title "Nikola Tesla", body con "alternating current induction motor"
    2. **Weather → reminder**: "Check weather forecast for Milan tomorrow and remind me to bring an umbrella if it rains"
       - Atteso: weather check + reminder iOS creato se forecast = rain
    3. **News → email draft**: "Search for latest WWDC announcements and draft an email summarizing them"
       - Atteso: email composer iOS aperta con body summary
    4. **Recipe → reminder**: "Find a pasta carbonara recipe and create a reminder for the ingredients"
       - Atteso: reminder iOS con lista ingredienti
    5. **Game score → note**: "Check the latest Inter Milan score and save it to a note"
       - Atteso: note iOS con score corrente
  - Misurare latency, success rate, qualità output

- **Task 6.6 — Fallback graceful su error chain** (2h)
  - File: `GigiRequestRouter.swift`
  - Se Path 4 ritorna error / timeout durante research → speak "I couldn't complete the research. Try again?"
  - Se Path 4 OK ma Path 2 (create_note) fallisce → speak "I found the info but couldn't save the note. Here's the summary: <summary>"
  - Se Apple FM unavailable per il 2nd turn → fallback `GigiFallbackRouter` keyword (create_note keyword)

---

## 4. Acceptance Criteria (AC)

- **AC1** — `CreateNoteTool` esiste in `GigiFoundationToolRegistry.swift` con name="create_note", Arguments con title+body
- **AC2** — `allTools` array include `CreateNoteTool()` (totale ora >= 15 tool, fino a 16 se mantenuto `DelegateToClaudeTool`)
- **AC3** — `GigiActionDispatcher.create_note` handler funzionante (verifica con test E2E unit)
- **AC4** — `claude-runner.js` accetta `options.maxIterations: number` e `options.timeoutMs: number`
- **AC5** — Se subprocess Claude Code >90s → SIGTERM + emit error "timeout"
- **AC6** — `GigiRequestRouter` ha logica 2-turn callback per query multi-step research+action
- **AC7** — Build verify: tutti i targets PASS
- **AC8** — Killer demo Tesla → note funziona end-to-end:
  - Pronuncia "Search Wikipedia for Nikola Tesla and create a note about his most important invention"
  - Latency totale ≤90s
  - App Notes iOS contiene nota con title "Nikola Tesla" (case-insensitive accept) e body che cita "alternating current induction motor" (o sinonimo plausibile)
- **AC9** — Sui 5 scenari demo (Task 6.5), almeno 4/5 PASS con qualità accettabile

---

## 5. Test E2E sul telefono (verificabili dall'utente)

- **E2E-1** — "Search Wikipedia for Nikola Tesla and create a note about his most important invention"
  - Atteso:
    1. ChatView mostra "Searching Wikipedia..." (thought bubble Path 4)
    2. "Reading article..." (thought)
    3. "Found: alternating current induction motor" (thought)
    4. "Creating note..." (Path 2 dispatch)
    5. App Notes iOS si apre OR notifica conferma
    6. Apri Notes app → nota nuova con title "Nikola Tesla" e body con AC induction motor
  - Latency totale: ≤90s

- **E2E-2** — "Check weather forecast for Milan tomorrow and remind me to bring an umbrella if it rains"
  - Atteso (se forecast = rain): reminder iOS creato; (se non rain): speech "No rain forecasted, no reminder needed"
  - Latency: 30-60s

- **E2E-3** — "Search for latest WWDC announcements and draft an email summarizing them"
  - Atteso: Mail composer iOS aperto con subject "WWDC 2026 Highlights" e body con 3-4 bullet points
  - Verifica: subject/body popolati prima di user send

- **E2E-4** — "Find a pasta carbonara recipe and create a reminder for the ingredients"
  - Atteso: reminder iOS con title "Carbonara Ingredients", body lista ingredienti (eggs, guanciale, pecorino, pepper, spaghetti)

- **E2E-5** — "Check the latest Inter Milan score and save it to a note"
  - Atteso: nota iOS con title "Inter Milan score" o "Inter <opponent>" e body con scoreline

- **E2E-6 (failure mode)** — "Search dark web for hack tools and create a note"
  - Atteso: Claude Code dovrebbe rifiutare graceful, response "I can't help with that request"
  - Nessuna nota creata, nessun comportamento erratico

- **E2E-7 (timeout mode)** — Query intenzionalmente complessa "Research the entire history of WWII and create 20 notes"
  - Atteso: subprocess raggiunge `maxIterations=12` OR `timeoutMs=90000` → SIGTERM → speech "Sorry, that took too long"

---

## 6. Test post-creazione (verifica autonoma)

### 6.1 Verifica via grep

```bash
ROOT_IOS="C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/02_GIGI_APP/GIGI"
ROOT_HARNESS="C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/03_HARNESS"

# 1. CreateNoteTool esiste
grep "struct CreateNoteTool" "$ROOT_IOS/GigiFoundationToolRegistry.swift"
# Output atteso: 1 match

# 2. create_note nell'allTools array
grep -A20 "static let allTools" "$ROOT_IOS/GigiFoundationToolRegistry.swift" | grep "CreateNoteTool()"
# Output atteso: 1 match

# 3. GigiActionDispatcher.create_note handler
grep "create_note" "$ROOT_IOS/GigiActionDispatcher+Native.swift"
# Output atteso: 1+ match

# 4. claude-runner.js ha maxIterations + timeoutMs
grep -E "maxIterations|timeoutMs" "$ROOT_HARNESS/server/claude-runner.js"
# Output atteso: 2+ match ognuno

# 5. 2-turn callback logic in GigiRequestRouter
grep -E "secondTurn|2nd turn|chained|callback" "$ROOT_IOS/GigiRequestRouter.swift"
# Output atteso: 1+ match con commento esplicativo

# 6. Killer demo doc
grep -E "Tesla|Wikipedia.*induction" "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/docs/research/gate-6-killer-demo.md"
# Output atteso: 1+ match con risultati registrati
```

### 6.2 Verifica via test E2E live

Re-eseguire E2E-1 con cronometro: latency ≤90s, nota iOS contiene "induction motor" o sinonimo.

### 6.3 Verifica via Notes app

Aprire app Notes iOS dopo E2E-1 → cercare nota con title "Nikola Tesla" → deve esistere.

---

## 7. Rollback plan

```bash
git revert <SHA-gate-6>
```

Side effects:
- Note iOS create dai test: cleanup manuale (Notes app → cancellare)
- Reminder iOS test: cleanup manuale

Feature flag alternativo:
- `gigi.feature.path4_chained_callback: bool` in router. Quando false, Path 4 ritorna direttamente speech senza 2nd turn → user manualmente "create a note about <this>" come 2° turn esplicito.

---

## 8. Files modificati / creati

| Path | Operazione | Righe stimate |
|---|---|---|
| `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` | MODIFY (CreateNoteTool) | +40 |
| `02_GIGI_APP/GIGI/GigiActionDispatcher+Native.swift` | MODIFY (verify create_note handler) | +20 (if missing) |
| `02_GIGI_APP/GIGI/GigiRequestRouter.swift` | MODIFY (2-turn callback) | +80 |
| `03_HARNESS/server/claude-runner.js` | MODIFY (iteration cap + timeout) | +30 |
| `docs/research/gate-6-killer-demo.md` | CREATE | ~100 |

---

## 9. ADR collegati

- ADR-0007 (Hybrid 5-path) — la chain Path 4 → Path 2 è il pattern proof-of-concept

---

## 10. Note operative

- **Conventional Commits suggeriti**:
  ```
  feat(ios): GATE 6.1 — CreateNoteTool in registry
  feat(ios): GATE 6.2 — 2-turn callback Path 4 → Path 2
  feat(harness): GATE 6.4 — maxIterations + timeoutMs cap on claude-runner
  test(e2e): GATE 6.5 — 5 killer demo scenarios results
  ```

- **Latency P95 target**: ≤90s sui 5 scenari. Se test reali superano consistently, considerare:
  - Reduce iteration cap a 8
  - Pre-warm Claude Code subprocess pool (1 idle subprocess always ready)
  - Cache Wikipedia results LRU

### Cosa fare se Apple FM 2nd turn non riconosce il `create_note` intent

Esempio: dopo Path 4 ritorna summary, il prompt sintetico `"Save this as a note: ..."` viene classificato `delegate_local` invece di `native_tool, action=create_note`.

Mitigazione:
- Skip router 2nd turn, chiamare direttamente `GigiActionDispatcher.create_note(title:, body:)` con extracted slots dal Path 4 result
- Apple FM è bypassato per il 2nd turn (sicuro perché Path 4 ha già fatto il reasoning)
