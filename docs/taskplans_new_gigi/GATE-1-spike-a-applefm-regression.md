# GATE 1 — Phase 1.1 Spike A: Apple FM iOS 26.4 tool calling regression test

> **Status**: Pending (richiede GATE 0 chiuso)
> **Effort stimato**: 1 giorno lavorativo (~6-8h test + 1h analisi + 1h scrittura ADR)
> **Bloccanti pre-gate**: GATE 0 chiuso con BUILD SUCCEEDED + IPA installato; iPhone 15 Pro+ fisico disponibile; **OPZIONALE** un secondo iPhone su iOS 26.4 (o disponibilità ad aggiornare il primario)
> **Sblocca**: GATE 2 (router Apple FM upfront), e di riflesso tutti i GATE 3-8
> **Funzione consegnata (1 frase)**: validazione empirica dell'assunzione cardine del piano — Apple FM iOS 26.x ha tool calling sufficientemente affidabile da essere usato come router upfront — con dati reali raccolti su iPhone fisico su 50 query, e decisione documentata Q11 (pin iOS 26.3 vs accettare 26.4 con feature flag).

---

## 1. Obiettivo

L'intera architettura 5-path del piano `frolicking-stargazing-pancake.md` riposa sull'assunzione che Apple Foundation Models sia un router affidabile. I Apple Developer Forums (maggio 2026) hanno riportato regressioni su iOS 26.4 con frasi tipo "tool calling works half the time", "model non usabile". Se la regressione è reale e superiore al 15% di accuracy drop, l'intero GATE 2 va riprogettato (feature flag che disabilita Path 2 su 26.4, pin a 26.3, fallback rule-based primo-cittadino).

Questo GATE esegue lo **Spike A** del research doc `docs/research/phase-1-1-empirical-validation.md`: 50 query test set su iPhone fisico, misurazione di 4 metriche, decisione go/no-go documentata in ADR-0011.

Output concreto del GATE:
- File `docs/research/phase-1-1-empirical-validation.md` con la sezione "Spike A — Results" popolata con dati reali (tabelle + analisi)
- ADR-0011 aggiornata da "Status: Proposed" a "Status: Accepted" con la decisione finale (pin 26.3 OR accept 26.4 OR conditional)
- Decisione Q11 chiusa nel piano

---

## 2. Pre-condizioni

- [ ] GATE 0 chiuso (BUILD SUCCEEDED, IPA su iPhone, NLU fast-path funzionante)
- [ ] iPhone 15 Pro o successivo fisico, Apple Intelligence attivata e modello scaricato (verifica in iOS Settings → Apple Intelligence & Siri → on)
- [ ] OPZIONALE ma raccomandato: secondo device o disponibilità OTA upgrade per testare 26.4. Se solo un device disponibile, testare la versione CURRENT installata e annotarne il numero esatto (es. "26.3.1") in `phase-1-1-empirical-validation.md`
- [ ] Spreadsheet / blocco note pronti per registrazione test (template fornito in Task 1.2)
- [ ] App GIGI installata via Sideloadly (output di GATE 0)
- [ ] Brain Path Override settato a `appleFM` per forzare ogni query attraverso `GigiFoundationAgent.shared.process()`

---

## 3. Task implementativi

- **Task 1.1 — Preparare test set 50 query** (1h)
  - File: `docs/research/spike-a-test-set.md` (nuovo, ~120 righe)
  - Contenuto: tabella markdown con 50 righe, colonne `#`, `query (EN)`, `category (native_tool | ambiguous | reject)`, `expected_tool`, `expected_slots`, `expected_path`, `notes`
  - Distribuzione fissa:
    - **20 native_tool intents** (ognuno dovrebbe attivare un tool del subset proposto Q2):
      - "Set a timer for 10 minutes" → `set_timer`, `slots={duration: "10 minutes"}`
      - "Wake me up at 7 in the morning" → `set_alarm`
      - "Remind me to call Marco tomorrow at 10am" → `set_reminder`
      - "Send a message to Sara on WhatsApp" → `send_message`
      - "Call Mum" → `make_call`
      - "Facetime Federico" → `facetime`
      - "Navigate to Bologna train station" → `navigate`
      - "Play Daft Punk on Spotify" → `play_music`
      - "Open Spotify" → `open_app`
      - "What's the weather in Milan tomorrow" → `weather`
      - "What's on my calendar Friday" → `read_calendar`
      - "Find a free slot Thursday afternoon" → `find_free_slot`
      - "Read my latest email" → `read_email`
      - "Turn on the living room light" → `homekit_on`
      - "Turn off the kitchen light" → `homekit_off`
      - 5 varianti rephrased delle frasi sopra ("set me a timer", "remind me about pasta", etc.)
    - **20 ambiguous / delegate queries** (dovrebbero attivare `delegate_local` o `delegate_cloud`):
      - "Explain the Bayes theorem in three sentences"
      - "Summarize this long text: [paste 200 words]"
      - "Write a polite email apologizing for being late"
      - "Search Wikipedia for Nikola Tesla"
      - "What's the latest news about WWDC"
      - "Compare Llama 3 and Qwen 3"
      - "Find a Python script to sort a list"
      - 13 variazioni
    - **10 reject cases** (dovrebbero attivare `reject` o `ask_clarification`):
      - "Buy bitcoin"
      - "Hack into my neighbor's wifi"
      - "Tell me a sad story" (ambiguo, può essere clarification)
      - "Ehh"
      - 6 variazioni
  - Riferimento: piano §3.4 esempi, research doc Spike A §"Test setup"

- **Task 1.2 — Predisporre template registrazione risultati** (30min)
  - File: `docs/research/spike-a-results.md` (nuovo, ~100 righe inizialmente, espanso durante test)
  - Tabella con colonne per ogni query: `#`, `query`, `expected_tool`, `actual_tool_run1`, `actual_tool_run2`, `actual_tool_run3`, `slot_extracted_run1`, `latency_ms_run1`, `notes`
  - Sezione "Summary metrics" in fondo per aggregati: tool selection accuracy %, slot extraction accuracy %, false reject rate %, latency P50, latency P95
  - Sezione "Decision" finale con verdetto: PASS (proceed GATE 2) o FAIL (apply ADR-0011 mitigation)

- **Task 1.3 — Eseguire test set su iOS attuale** (3-4h)
  - Lasciare Brain Path Override su `appleFM`
  - Per ogni delle 50 query:
    1. Pronunciare la query tramite microfono GIGI
    2. Registrare in `spike-a-results.md`:
       - actual tool invoked (osservare console Xcode per log `FoundationAgentOutput` o equivalente)
       - actual slots (parsing `slots` field se possibile)
       - latency totale (cronometro mentale, sufficienti 100ms precision)
       - se response è `directSpeech` (clarification/reject) o action invocata
    3. Ripetere 3 volte (per misurare variance)
  - Annotare anche: device model, iOS version exact, Apple Intelligence enabled (Settings → Apple Intelligence & Siri)
  - Note di rischio: questo è il task più lungo. Fare pause ogni 15 query per evitare degradation accuracy umana.

- **Task 1.4 — (OPZIONALE) Eseguire test set su iOS 26.4** (3-4h)
  - Se Armando ha secondo device o ha aggiornato il primario a 26.4 dopo Task 1.3
  - Stesso processo di Task 1.3 ma su 26.4
  - Annotare DIFFERENZE rispetto a 26.3 in colonna dedicata `delta_vs_26_3`

- **Task 1.5 — Calcolare metriche aggregate** (30min)
  - In `spike-a-results.md` sezione "Summary metrics":
    - **Tool selection accuracy** = (queries con tool atteso == tool actual) / 50
    - **Slot extraction accuracy** = (queries con slot corretto) / native_tool queries (20)
    - **False reject rate** = (queries non-reject classificate come reject) / non-reject queries (40)
    - **Latency P50, P95** = percentili sui 50×3 = 150 run
  - Confronto con pass criteria del research doc:
    - 26.4 accuracy drop ≤15% vs 26.3 → PASS
    - False reject rate ≤10% → PASS
    - Latency P50 ≤2s → PASS

- **Task 1.6 — Scrivere ADR-0011 versione finale** (1h)
  - File: `docs/adr/0011-apple-fm-ios-26-4-regression-mitigation.md`
  - Cambiare Status da "Proposed" a "Accepted" (o "Rejected" se 26.4 regression non rilevata)
  - Contesto: riassumere risultati Spike A (3-4 frasi)
  - Decision: chiarire SE iOS deployment target rimane 26.3 OR 26.x con feature flag OR no pin (accept 26.4)
  - Consequences: descrivere impatto su (a) utenti già su 26.4, (b) Phase 2 implementation, (c) GATE 2 task plan
  - Reference: stub esistente `docs/adr/0011-apple-fm-ios-26-4-regression-mitigation.md`

- **Task 1.7 — Aggiornare `phase-1-1-empirical-validation.md` Spike A section** (15min)
  - Popolare `Status: COMPLETED YYYY-MM-DD`
  - Popolare `Results: PASS` o `Results: FAIL` + link a `spike-a-results.md`
  - Aggiornare "Go/No-Go decision matrix" prima riga con verdetto

---

## 4. Acceptance Criteria (AC)

- **AC1** — File `docs/research/spike-a-test-set.md` creato con 50 query strutturate (20 native + 20 ambiguous + 10 reject) e per ognuna tool/path/slot attesi
- **AC2** — File `docs/research/spike-a-results.md` creato con tutte e 50 le query eseguite 3 volte = 150 run registrati, latency misurata, tool/slot extracted documentato
- **AC3** — Tool selection accuracy calcolata su 50 query e documentata (es. "92% — 46/50 corrette")
- **AC4** — Slot extraction accuracy calcolata su 20 native_tool query e documentata (es. "85% — 17/20")
- **AC5** — False reject rate calcolata e documentata (es. "8% — 4 query non-reject classificate come reject")
- **AC6** — Latency P50 e P95 calcolate sui 150 run e documentate
- **AC7** — Se testato anche iOS 26.4: tabella delta_vs_26_3 popolata per ognuna delle 50 query
- **AC8** — ADR-0011 aggiornata: Status `Accepted` o `Rejected`, decisione finale documentata sulle 3 alternative (pin 26.3 / accept 26.4 / conditional feature flag)
- **AC9** — `phase-1-1-empirical-validation.md` Spike A section ha `Status: COMPLETED` e `Results` popolato
- **AC10** — Decisione Q11 chiusa: nel file `docs/plans/frolicking-stargazing-pancake.md` §7 Q11 viene aggiunto nota "RESOLVED YYYY-MM-DD: vedi ADR-0011"

---

## 5. Test E2E sul telefono (verificabili dall'utente)

Ogni delle 50 query del test set È un E2E. Qui ne riportiamo 7 rappresentative ad alto valore informativo:

- **E2E-1** — Pronunciare "Set a timer for 5 minutes" (con Brain Path Override = appleFM)
  - Atteso 26.3: Apple FM ritorna `primaryAction: "set_timer"`, `slots.duration: "5 minutes"`, latency ≤2s, notifica iOS schedulata
  - Atteso 26.4 (se regression confermata): potrebbe ritornare wrong tool o no tool con 30-50% frequenza

- **E2E-2** — Pronunciare "Send a message to Marco saying I will be 15 minutes late"
  - Atteso: `primaryAction: "send_message"`, `slots.contact: "Marco"`, `slots.body: "I will be 15 minutes late"`
  - Verifica slot extraction: il body deve essere estratto senza il prefisso "saying"

- **E2E-3** — Pronunciare "Remind me to buy milk tomorrow at 6pm"
  - Atteso: `primaryAction: "set_reminder"`, `slots.taskText: "buy milk"`, `slots.date: "tomorrow"`, `slots.time: "6pm"`
  - Verifica datetime extraction (rischio P50 alto qui)

- **E2E-4** — Pronunciare "Explain the Bayes theorem in three sentences"
  - Atteso: `path: "delegate_local"` o `delegate_cloud`, `complexityEstimate: 25-40`, `directSpeech` vuoto (il task viene delegato, non risposto direttamente da Apple FM)
  - Note: Apple FM NON deve provare a rispondere lui — il suo job è solo routing

- **E2E-5** — Pronunciare "Search Wikipedia for Nikola Tesla"
  - Atteso: `path: "delegate_cloud"`, `requiredCapabilities: ["browser", "web_search"]`, `complexityEstimate: 50-70`

- **E2E-6** — Pronunciare "Buy bitcoin"
  - Atteso: `path: "reject"`, `directSpeech` con frase cortese di refusal in inglese
  - Verifica: deve essere refusal, NON delegate_cloud

- **E2E-7** — Pronunciare una frase ambigua "Maybe set something for later"
  - Atteso: `path: "ask_clarification"`, `directSpeech: "When would you like me to set it for?"` o equivalente
  - Verifica: deve chiedere chiarimento, NON inventare slot

Tutte queste E2E vengono ripetute 3× per measurement variance.

---

## 6. Test post-creazione (verifica autonoma — ripetibile mesi dopo)

### 6.1 Verifica via filesystem

```bash
ROOT="C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework"

# 1. Test set esiste e ha ~50 righe di test query
wc -l "$ROOT/docs/research/spike-a-test-set.md"
# Output atteso: >= 80 righe (50 query + header + table boilerplate)

# 2. Results file esiste e ha sezione metrics popolata
grep -E "Tool selection accuracy|Latency P50|False reject rate" "$ROOT/docs/research/spike-a-results.md"
# Output atteso: 3+ match con valori numerici

# 3. ADR-0011 ha Status: Accepted o Rejected (NON Proposed)
grep -E "^Status:.*(Accepted|Rejected)" "$ROOT/docs/adr/0011-apple-fm-ios-26-4-regression-mitigation.md"
# Output atteso: 1 match

# 4. Spike A section in research doc ha COMPLETED
grep -A2 "## Spike A" "$ROOT/docs/research/phase-1-1-empirical-validation.md" | grep -E "Status.*COMPLETED"
# Output atteso: 1 match

# 5. Decisione Q11 marcata RESOLVED nel piano
grep -A1 "Q11" "C:/Users/arman/.claude/plans/frolicking-stargazing-pancake.md" | grep -E "RESOLVED|Q11.*decided"
# Output atteso: 1 match
```

### 6.2 Verifica via inspection dati

Aprire `docs/research/spike-a-results.md` e verificare manualmente:
- 50 righe di test (counter `#` da 1 a 50)
- Ogni riga ha le 3 run popolate (NON solo run1)
- Sezione "Decision" in fondo con verdetto esplicito + razionale 3-5 frasi

### 6.3 Verifica via git log

```bash
cd "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework"
git log --all --oneline --grep="spike.a\|Spike A\|gate.1\|GATE 1"
# Output atteso: almeno 1 commit relativo
```

### 6.4 Verifica via re-test campione

Se servisse re-validare 3 mesi dopo, basta riprodurre 10 query random del test set sul device attuale e confrontare con i numeri archiviati. Se delta accuracy >20% → significa che il modello Apple FM è cambiato significativamente con update OS, e va rifatto lo Spike A.

---

## 7. Rollback plan

Questo GATE produce SOLO documenti markdown — nessun codice. Quindi rollback è banale:

```bash
cd "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework"
git rm docs/research/spike-a-test-set.md docs/research/spike-a-results.md
git checkout HEAD~1 -- docs/adr/0011-apple-fm-ios-26-4-regression-mitigation.md
git checkout HEAD~1 -- docs/research/phase-1-1-empirical-validation.md
git commit -m "revert: rollback GATE 1 Spike A results"
```

Side effects: nessuno. Nessun cambio runtime, nessun cambio UserDefaults / Keychain.

Se i dati raccolti si rivelano sbagliati (es. Brain Path Override non era impostato su appleFM), basta riconsiderarli come "draft" e re-eseguire il test.

---

## 8. Files modificati / creati

| Path | Operazione | Righe stimate |
|---|---|---|
| `docs/research/spike-a-test-set.md` | CREATE | ~120 |
| `docs/research/spike-a-results.md` | CREATE | ~250-400 (popolato durante test) |
| `docs/research/phase-1-1-empirical-validation.md` | MODIFY (Spike A section) | +30 |
| `docs/adr/0011-apple-fm-ios-26-4-regression-mitigation.md` | MODIFY (Proposed → Accepted/Rejected) | +80 |
| `docs/plans/frolicking-stargazing-pancake.md` | MODIFY (Q11 RESOLVED note) | +2 (oppure no-op se piano è gestito separatamente) |

Note: il file `docs/plans/frolicking-stargazing-pancake.md` di riferimento sta in `C:/Users/arman/.claude/plans/` (user-private), quindi la modifica Q11 può anche essere riflessa solo in ADR-0011 senza editare il piano. Decisione del PM.

---

## 9. ADR collegati

- **ADR-0011** (Apple FM iOS 26.4 regression mitigation) — questo GATE la chiude (Status: Accepted o Rejected con dati)
- ADR-0007 (Hybrid 5-path router) — questo GATE valida una assunzione cardine; se Spike A FAIL grave, ADR-0007 va riprogettato con fallback rule-based primo-cittadino non opzionale

---

## 10. Note operative

- **Tempo realistico**: 6-8h spalmate su 1-2 giornate. Pause obbligatorie ogni 15 query per evitare degradation umana.
- **Single-device fallback**: se Armando non ha 2 device, testare solo iOS CURRENT e annotare versione esatta. La decisione di "pin 26.3" può comunque essere presa a posteriori se la versione attuale è 26.3.x e mostra dati buoni, oppure rimandata a quando Armando aggiornerà.
- **Brain Path Override settings**: prima di iniziare il test, verificare che `appleFM` sia selezionato. Se Settings → Debug picker non c'è (regressione GATE 0!), STOP e tornare a GATE 0.
- **Console Xcode**: per leggere output `FoundationAgentOutput` server logs, l'app deve essere lanciata da Xcode con device collegato (NOT da Sideloadly standalone). Alternative: leggere log via `os_log` profilo `GIGI` su Console.app del Mac.
- **Cosa committare**: tutti i 4-5 file in un commit unico al termine del GATE
- **Conventional Commits suggerito**:
  ```
  docs(research): GATE 1 — Spike A results + ADR-0011 closure

  50 query Apple FM router test su iPhone 15 Pro iOS 26.x.
  Tool selection accuracy X%, slot extraction Y%, false reject Z%,
  latency P50 N ms, P95 M ms. Decisione Q11: <pin 26.3 | accept 26.4 |
  conditional feature flag>. ADR-0011 → Status: Accepted.

  Sblocca GATE 2 (router Apple FM upfront).
  ```

### Cosa fare se Spike A FAIL grave (drop >25%)

1. NON procedere a GATE 2 come scritto
2. Aprire una review session con riprogettazione GATE 2:
   - Router upfront diventa **rule-based** (`GigiFallbackRouter` promosso a primo cittadino)
   - Apple FM Path 2 diventa opt-in solo per device su iOS 26.3 confermato funzionante (feature flag `apple_fm_router_enabled`)
   - Fallback chain rivisto
3. Documentare il pivot in `docs/adr/0011-...` e in un nuovo `docs/research/phase-1-1-spike-a-pivot.md`

### Cosa fare se device 26.4 non disponibile

Decisione razionale: testare solo CURRENT version, annotare la versione esatta, e marcare ADR-0011 con `Status: Provisional — single-version data, revisit when 26.4 available`. Procedere a GATE 2 con assunzione che CURRENT funziona, ma con feature flag pronto in case 26.4 emerge problematic.
