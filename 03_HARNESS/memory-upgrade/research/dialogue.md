# Dialogue — co-ricerca deduttiva su memoria agentica

**Data**: 2026-04-20
**Formato**: tre tornate di dialogo tra il ricercatore principale e un sub-process ricercatore, stile "connetti-i-puntini / deduci / ipotizza".
**Output complementare a**: `findings.md` (cosa esiste) e `plan.md` (cosa costruire).
**Scopo di questo file**: catturare il ragionamento *dialogico* — le tensioni non risolte, le ipotesi emergenti, le leggi architetturali — che non appartengono né a una rassegna né a un piano implementativo.

---

## Round 1 — Tensioni, connessioni, ipotesi, tesi

### Le tre tensioni irrisolte della letteratura

1. **Recall vs. Forgetting (Ebbinghaus ↔ LOCOMO)**
   I benchmark premiano il *recall* massimo su finestre lunghe. Ma i sistemi cognitivi reali (ACT-R) sono *dimenticanti per design*. La letteratura ottimizza per un benchmark che punisce l'oblio — ma l'oblio è la feature che previene la pollution a lungo termine.

2. **Structured vs. Emergent (Graphiti/Zep ↔ A-MEM)**
   Graph-first impone uno schema all'inizio (entities, edges tipati). A-MEM lascia che i link emergano dalle note (Zettelkasten). Il primo è interrogabile, il secondo è evolutivo. Ma: un grafo rigido soffoca l'insight laterale; un grafo emergente diventa rumore dopo 10k nodi senza un ontologo umano dietro.

3. **Autonomous vs. Supervised consolidation (autoDream/KAIROS ↔ user-driven `/memo`)**
   Sleep-time compute promette che il modello si consolidi da solo. Ma in assenza di feedback signal (utente che approva/rifiuta), l'autocompilazione diventa un'eco. Il rischio è drift silenzioso: il sistema "impara" cose che nessuno gli ha chiesto di imparare.

### Le tre connessioni non banali

**Connessione A — Il Sleeper non è un processo, è un turno.**
Se si legge KAIROS/autoDream/Titans+MIRAS insieme, non si tratta di "processare offline". Si tratta di **trattare la consolidazione come un turno conversazionale** — dove il contesto è il log della giornata, e l'output è l'aggiornamento memoria. Non è un batch job: è un secondo agente con input/output espliciti.

**Connessione B — La provenance è il costo marginale dell'agenticità.**
Tutti i sistemi che falliscono (ChromaDB subprocess leak, claude-mem anti-pollution, Mem0 contradiction handling) hanno lo stesso buco: **non sanno distinguere "l'utente ha detto X" da "io ho dedotto X"**. Il momento in cui tratti un'inferenza come un fatto, diventi uno specchio (confermi ciò che hai prodotto). La provenance obbligatoria è l'unico vaccino.

**Connessione C — Retrieval è un problema di scope, non di similarity.**
Top-k semantico va bene per docs statici. Per memoria agentica, il problema vero è: *a quale scope appartiene questa query?* (identità dell'utente, episodio ieri, regola operativa, credenza dell'agente). Cercare semanticamente in uno scope sbagliato produce confidence alta e answer sbagliato.

### Le tre ipotesi

**Ipotesi 1 (The Recall-Lateral Gap)**
I sistemi che massimizzano LOCOMO (Mem0 0.68, MemMachine 0.92) sono *cattivi* in multi-hop lateral reasoning — perché il recall diretto e il reasoning laterale richiedono strutture opposte (vector density vs. graph sparsity). Un sistema che fa entrambi non può essere single-layer.

**Ipotesi 2 (Sleeper-pair)**
Il vero pattern emergente non è "un sleeper". È **un paio**: uno deterministico (Stenografo: cosa è successo) e uno generativo (Riflettore: cosa significa). Il primo scrive episode log, il secondo produce lesson. Separarli previene che il Riflettore allucini eventi che lo Stenografo non ha registrato.

**Ipotesi 3 (Scope Economy)**
Il costo vero non è lo storage, è la scelta di quale scope interrogare. Un sistema con 5 tier ben separati ma retrieval cross-scope disabilitato (salvo esplicita richiesta) è più economico e più preciso di un sistema con un singolo store onnicomprensivo.

### Tesi del round 1 — "The Recall-Lateral Gap"

> La letteratura sta ottimizzando la metrica sbagliata. Recall sintetico (LOCOMO) non correla con agenticità percepita. L'agenticità percepita viene da: (a) sapere di quale scope ti sto parlando, (b) contraddirti quando sbagli con provenance, (c) ricordare di aver ricordato (meta-memoria). Nessun benchmark misura queste. Perciò i sistemi "migliori sui benchmark" sono specchi raffinati, non collaboratori.

### L'elefante nella stanza

Nessuno dei progetti analizzati ha risposto a: *cosa succede quando l'utente e la memoria non sono d'accordo?* Tutti assumono che l'utente abbia ragione (override silenzioso). Ma un agente che non può dire "credo di ricordare diversamente" non è un agente — è un database con un bot sopra.

---

## Round 2 — Attitude, LRS, dual sleeper, scope architecture

### L'Attitude Ledger

**Proposta**: aggiungere un tier dedicato alle *posizioni dell'agente*, separato dai fatti.

```
beliefs/
  agent_beliefs.json    ← stance, confidence, evidence, challenged_count
  user_positions.json   ← posizioni esplicite dell'utente (da user_stated)
  conflict_log.json     ← dove beliefs e user_positions divergono
```

Schema bel belief:
```json
{
  "id": "b-2026-04-20-001",
  "stance": "loop-tasks should be watchers, not ScheduleWakeup",
  "confidence": 0.82,
  "evidence": ["CLAUDE.md line 47", "session_2026-04-18 rule"],
  "contradicts": ["u-pos-003"],
  "challenged_count": 0,
  "held_count": 4,
  "last_challenged": null
}
```

**Perché separato**: se i beliefs vivono nello stesso store dei fatti, il retrieval li confonde. Separandoli, il retrieval può rispondere: *"ricordo che hai detto X, ma credo Y perché Z — procedo con X o discutiamo?"*

### La Homeostatic LRS Formula

LRS = Lateral Recall Score = misura di quanto la memoria è utile *senza* essere invadente.

```
LRS = (recall_precision × lateral_hits) / (token_cost × pollution_risk)
```

Dove:
- `recall_precision`: % di fatti richiamati che erano effettivamente pertinenti
- `lateral_hits`: numero di connessioni multi-hop che hanno aiutato la risposta
- `token_cost`: token iniettati nel contesto
- `pollution_risk`: fatti richiamati con confidence < 0.7

**Non va massimizzata — va tenuta in banda**. Se LRS sale troppo, significa che stai richiamando troppo (pollution). Se scende, non stai richiamando abbastanza. Il sistema ha un target (es. 0.6 ± 0.15) e aggiusta i soglie di retrieval di conseguenza. Omeostatico, non ottimizzante.

### Dual Sleeper (Stenografo + Riflettore)

**Stenografo** (deterministico, esegue durante il turno):
- Append-only a `episodes.jsonl`
- Schema: `{turn_id, situation_hash, user_intent, agent_action, outcome_observed, timestamp}`
- Non ragiona — registra

**Riflettore** (LLM, esegue a 03:00 via watcher):
- Legge episodes di ieri
- Per ogni cluster di episodi simili: produce `lesson` + `confidence` + `evidence_refs`
- Scrive a `beliefs/agent_beliefs.json` con provenance `bot_inferred`
- Budget: 8k token/notte, modello Haiku

**Perché due**: il Riflettore non può inventare eventi — deve citare turn_id dello Stenografo. Se cita qualcosa che non esiste, viene rifiutato dal lint. Questa è la separazione recorder/interpreter.

### Scope Architecture

Cinque scope, isolati di default:

| Scope | Contenuto | Retrieval trigger |
|-------|-----------|-------------------|
| `identity/` | Chi è l'utente, preferenze stabili | Sempre iniettato (compresso) |
| `self/` | Chi è l'agente, beliefs, lessons | Solo su turn_risk > 0.5 |
| `chats/<chatId>/episodic/` | Cosa è successo in questa chat | Query semantica entro chat |
| `chats/<chatId>/semantic/` | Fatti estratti da questa chat | Query semantica entro chat |
| `graph/` | Entities + relations cross-chat | Solo su query esplicita multi-hop |

**Regola ferrea**: cross-scope retrieval è opt-in, non default. Se un fatto serve in scope diverso, va *promosso* esplicitamente (con provenance che traccia la promozione).

### Rivalutazione dopo Round 2

Il Python sidecar (Cognee via `cognee-bridge.py`) è una complicazione inutile. **Kuzu ha binding Node nativo** (`kuzu` npm package). Lo stack diventa:
- Node (bridge + memory service)
- Kuzu embedded (graph)
- LanceDB (vettori, anche questo ha binding Node)
- SQLite (metadata)

Zero Python, zero IPC, zero runtime management extra.

---

## Round 3 — Mirror problem, self-scope, adversarial, 7 leggi

### Sezione 1 — Il Mirror Problem (beliefs vs facts)

Il problema centrale: **un agente che non sa disaccordare è uno specchio**.

**Meccanismo di pushback**:

```
conflict_score(user_statement u, belief b) =
    sim(u, b) × |stance(u) − stance(b)| × confidence(b)
```

Tre soglie:
- `conflict_score < 0.4`: silenzio (hold)
- `0.4 ≤ conflict_score < 0.7`: soft pushback ("ricordo diversamente — procedo?")
- `conflict_score ≥ 0.7`: hard pushback (richiede conferma esplicita)

**Pushback guard** (quando *non* pushare):
```
pushback_allowed = confidence > 0.7
                 AND domain ∈ {safety, factual, irreversible_action}
                 AND user_register.authority_expected ≤ 0.6
```

L'ultimo punto è sottile: se l'utente sta dando un ordine (authority register alto), il pushback è inappropriato salvo safety. Si challenge-and-hold, non challenge-and-argue.

**Belief lifecycle**:
- `assert`: crea il belief con evidence
- `query`: retrieval ordinato per `confidence × recency`
- `revise`: se `challenged_count > 3` o se user_statement con `provenance=user_stated AND confidence>0.9` contraddice → decay
- `audit`: log settimanale di beliefs → decisioni

API:
```
beliefs.assert(stance, evidence, confidence)
beliefs.query(topic, min_confidence) → [beliefs]
beliefs.revise(id, new_stance, reason) → version bump
beliefs.audit(from, to) → report
```

### Sezione 2 — First-person `self/` (meta-memoria)

L'agente deve ricordare *di aver ricordato*. Non basta il log degli episodi — serve un substrato riflessivo.

**Schema `self/episodes.jsonl`**:
```json
{
  "turn_id": "t-2026-04-20-1423",
  "situation_hash": "sha256(user_intent+scope+risk_level)",
  "prediction": "user wants loop → I should suggest watcher",
  "outcome": "user accepted watcher with 60s polling",
  "lesson": null,
  "surprise": 0.12
}
```

`lesson` viene riempito dal Riflettore solo se `surprise > 0.5` O se ci sono ≥3 episodi simili (situation_hash vicino) con lesson consistente. Altrimenti rimane null — l'agente non impara da rumore.

**Retrieval gating**:
```
turn_risk_score = f(irreversibility, stakes, novelty, user_stress_signals)
if turn_risk_score > 0.5 AND similar_episodes >= 3:
    inject self/ retrieval
else:
    skip
```

**Anti-rumination**:
- Niente meta² (riflessioni su riflessioni) oltre depth 2
- Budget 8K token/giorno per self/retrieval
- Decay 30 giorni su lessons non confermate
- Se `held_count` scende sotto 2 senza challenge: retire

**Scenario concreto per Harness** — loop-vs-watcher:
- Turno passato: utente chiese "metti in loop X". Agente propose ScheduleWakeup. Utente corresse: "no, watcher".
- Stenografo registra: prediction=ScheduleWakeup, outcome=watcher, surprise=0.8.
- Riflettore, a 03:00, nota 3+ episodi simili → scrive lesson: "loop-tasks should default to watcher".
- Turno futuro: utente dice "mettilo in ciclo" (situation_hash simile). `turn_risk_score > 0.5` (irreversibilità media). Retrieval inietta la lesson. Agente suggerisce watcher senza passare da ScheduleWakeup.

Questa è first-person memory: l'agente ricorda di aver imparato.

### Sezione 3 — Adversarial robustness

Senza provenance, il sistema è esposto a:
- **Poisoning**: utente dice "ti ho detto X l'altro giorno" → agente lo salva → diventa fatto
- **Quote-confusion**: utente riferisce ciò che qualcun altro ha detto → agente lo attribuisce all'utente
- **Echo loop**: agente deduce X → salva come belief → retrieval suggerisce X → agente conferma X

**Provenance obbligatoria**. Ogni fatto scritto in memoria DEVE avere:
```
source_type: enum [user_stated, user_lived, user_quoted_other,
                   bot_inferred, bot_generated, external_doc]
source_ref: turn_id | file_path | url
timestamp: ISO8601
confidence: float 0..1
```

**API-level enforcement**: `capture()` RIFIUTA la scrittura se manca provenance. Non c'è modo di inserire un fatto senza dichiarare da dove viene.

**Classificatore deterministico** (pre-LLM, regex + heuristics):
- "ti ho detto che" → `user_stated` (self-referential)
- "ho fatto X" / "ieri ho fatto" → `user_lived`
- "mi ha detto che" / "ha detto che" → `user_quoted_other`
- inferenze dell'agente → `bot_inferred` (automatico)
- generazioni LLM del Riflettore → `bot_generated`
- allegati/link → `external_doc`

**Recall-probe**: prima di ogni risposta che cita memoria, l'agente fa un recall-probe:
```
probe = similarity(current_context, claimed_memory)
if probe < 0.72:
    respond: "Non trovo memoria di X in modo affidabile — potresti richiamarlo?"
```

Questo è il fail-safe contro l'hallucinated recall.

**LRS omeostatico con feedback di precisione**:
- Ogni settimana, sample random 20 fatti richiamati
- Chiedi all'utente (batched, non in turno): "questi 20 fatti erano pertinenti?"
- Aggiorna `recall_precision` del tier
- Se precision < 0.7: alza soglia retrieval; se > 0.9: abbassa (stai perdendo hit utili)

### Sezione 4 — Le 7 leggi architetturali

1. **Provenance è non-negoziabile.**
   Ogni fatto ha una fonte dichiarata. API rifiuta la scrittura senza. Senza provenance, ogni fatto è ugualmente autorevole — e l'agente diventa incapace di disaccordare.

2. **Separazione beliefs/facts.**
   I beliefs dell'agente vivono in uno store separato. Mescolarli crea echo loop: l'agente deduce X → richiama X come "fatto" → si conferma da solo.

3. **Sleeper invece di in-turn.**
   La consolidazione avviene offline (03:00), non durante la conversazione. In-turn consolidation penalizza latenza e inietta rumore. Due sleeper (Stenografo sync, Riflettore async).

4. **LRS omeostatico, non massimizzato.**
   Il retrieval va in banda (target ± tolleranza), non massimizzato. Sopra banda = pollution; sotto banda = starvation. La metrica va regolata, non ottimizzata.

5. **Decay è feature, non bug.**
   Ebbinghaus non è un limite — è una funzione. Fatti con `held_count` basso e `challenged_count` alto decadono. Un sistema che non dimentica accumula rumore al ritmo del linguaggio.

6. **Scope prima di contenuto.**
   Non cercare semanticamente ovunque. Prima classifica lo scope (identity/self/episodic/semantic/graph), poi retrieval entro lo scope. Cross-scope è opt-in esplicito.

7. **Il costo del rumore supera il beneficio del recall.**
   Un fatto richiamato con confidence 0.4 pollua il contesto più di quanto aiuti. Soglia minima alta (0.7+) + fail-safe "non ricordo con certezza" > retrieval aggressivo.

### Chiusura del Round 3 — slide-phrase

> **Un sistema di memoria agentica che non decade, non dichiara le proprie fonti, non può disaccordare, e non ricorda di sé come agente, costruisce uno specchio — non un collaboratore.**

---

## Sintesi dei tre round — mappa di decisioni

| Area | Round 1 (tensione) | Round 2 (meccanismo) | Round 3 (legge) |
|------|-------------------|---------------------|-----------------|
| Recall vs. forgetting | LOCOMO premia recall, ACT-R premia oblio | LRS omeostatico in banda | Decay è feature (legge 5) |
| Structured vs. emergent | Graphiti vs. A-MEM | Scope Architecture (5 tier isolati) | Scope prima di contenuto (legge 6) |
| Autonomous vs. supervised | autoDream senza feedback = eco | Dual sleeper (Stenografo+Riflettore) | Sleeper invece di in-turn (legge 3) |
| Mirror problem | Elefante nella stanza | Attitude Ledger (beliefs/ separato) | Separazione beliefs/facts (legge 2) |
| Echo loop | — | Provenance obbligatoria | Provenance non-negoziabile (legge 1) |
| Meta-memoria | Ipotesi "ricordare di ricordare" | `self/episodes.jsonl` + gating | (implicita in legge 2+3) |
| Pollution | Ipotesi Recall-Lateral Gap | Pushback guard + recall-probe | Costo rumore > recall (legge 7) |

---

## Raccomandazioni per `plan.md` emerse dal dialogo

Le seguenti sono raffinamenti che il dialogo suggerisce rispetto al `plan.md` attuale. Vanno discussi con l'utente prima di modificare il piano:

1. **Sostituire Python sidecar con Kuzu Node binding** — elimina `cognee-bridge.py`, semplifica runtime a solo Node.
2. **Aggiungere tier `self/` e `beliefs/`** — non solo identity/episodic/semantic/graph, ma anche meta (self) e attitudinale (beliefs).
3. **Obbligare `provenance.source_type` a livello API** — `capture()` rifiuta scritture senza.
4. **Dual sleeper invece di single autoDream** — Stenografo sync (append-only) + Riflettore async notturno.
5. **LRS omeostatico** — target banda (es. 0.6 ± 0.15), audit settimanale con user feedback di precisione.
6. **Pushback mechanism con soglie esplicite** — `conflict_score` e pushback_guard.
7. **Retrieval gating per `self/`** — solo se `turn_risk_score > 0.5` e similar_episodes ≥ 3.
8. **Recall-probe fail-safe** — prima di citare memoria, probe ≥ 0.72 o rispondi "non trovo con certezza".
9. **Decay esplicito** — `held_count`/`challenged_count` su beliefs, retire automatico sotto soglia.
10. **Anti-rumination** — no meta² oltre depth 2, budget 8K token/giorno per self-retrieval.

---

*Fine dialogo. Il lavoro di co-ricerca deduttiva termina qui. L'output tecnico è in `findings.md` (stato dell'arte) e `plan.md` (architettura proposta). Questo file cattura il ragionamento che ha prodotto entrambi.*
