# Auto-Playbook — Piano separato

Sistema di apprendimento automatico dei playbook browser dalle sessioni approvate. Invece di scriverli a mano, il server registra ogni task browser, rileva l'approvazione dell'utente, e un distiller periodico estrae i pattern ricorrenti e li scrive come playbook canonico.

Documento separato da `PLAN.md` perché è un sistema a sé, integrabile ma non obbligatorio.

## Obiettivo

Passare da "playbook scritti a mano" a "playbook che si scrivono da soli" man mano che l'utente usa il bot. Più task fai su WhatsApp, più il playbook WhatsApp diventa ricco e stabile. Zero manutenzione manuale.

**Esteso per supportare due strategie parallele** (vedi `PLAN.md`):
- **Vision-first** — screenshot + click per coordinate
- **Semantic-first** — ARIA tree + locators DOM

Il distiller registra quale strategia ha portato all'approvazione utente, per quale dominio, per quale tipo di task. Nel tempo impara la preferenza e la suggerisce di default.

## Pipeline

### 1. Logger (nel server MCP)
Hook nel dispatcher di `server-playwright.js`. Per ogni chiamata `browser_*` scrive in `browser-mcp/logs/traces/<task_id>.jsonl`:
```json
{"ts": 1729000000, "tool": "browser_click_at", "args": {"x": 456, "y": 230}, "result_preview": "...", "page_url": "https://web.whatsapp.com/", "instance": "main", "strategy": "vision"}
```

**Campo `strategy` (nuovo):** `"vision"` | `"semantic"` | `"mixed"`. Determinato automaticamente:
- Uso di `browser_click_at`, `browser_type_at`, `browser_scroll_at`, `browser_screenshot` → `vision`
- Uso di `browser_snapshot`, `browser_find`, `browser_read_chat`, `browser_click(selector)` → `semantic`
- Combinazione nello stesso task → `mixed`

Il `task_id` è il lease attivo (se presente) o un hash del primo tool call della sequenza. Append-only.

### 2. Detector di approvazione
Hook nel bridge Telegram quando riceve un nuovo messaggio dall'utente. Confronta con l'ultimo `task_id` aperto e classifica:

- **Approvato** (esplicito): messaggio contiene `ok`, `perfetto`, `daje`, `ottimo`, `confermato`, `bene`, `yes`, `ottimo lavoro`
- **Approvato** (implicito): utente cambia topic senza correggere → assumi successo dopo timeout (es. 60s)
- **Rifiutato**: messaggio contiene `no`, `rifai`, `sbagliato`, `non così`, `non è`, `correggi`
- **Ambiguo**: fallback LLM-call leggera a Haiku per classificare

Scrive risultato in `logs/traces/<task_id>.meta.json`.

### 3. Trace store
File consolidato `browser-mcp/logs/approved-traces.jsonl`:
```json
{
  "task_id": "abc",
  "approved": true,
  "app_domain": "web.whatsapp.com",
  "user_intent": "manda messaggio a Morgana",
  "strategy": "vision",
  "token_cost_est": 4200,
  "tool_call_count": 6,
  "tool_calls": [...],
  "final_path": [...]
}
```
Solo traces approvati vengono promossi qui. Il `final_path` è filtrato dei dead-end (vedi punto 5).

**Campi per A/B analysis:**
- `strategy`: vincente approvata
- `token_cost_est`: stima token totali del task
- `tool_call_count`: numero chiamate

Permette al distiller di calcolare statistiche: "su WhatsApp, strategy `semantic` media 1.8k token / 6 tool call, strategy `vision` media 4.2k / 8 tool call → preferire semantic".

### 4. Distiller (job cron)
Watcher nel bridge (`telegram-bridge/watchers.json`) schedulato ogni 1h. Esegue `browser-mcp/distiller.js`:

- Raggruppa traces per `app_domain`
- Per ogni gruppo, calcola statistiche per strategia:
  - Media token spesi per task (vision vs semantic)
  - Media tool call per task
  - Tasso di approvazione
- Per la strategia **semantic** (quando vincente):
  - Estrae selettori ricorrenti (soglia: ≥3 traces distinti)
  - Parametrizza variabili (es. `"Morgana"` → `<contact>`)
  - Deduplica pattern simili
- Per la strategia **vision** (quando vincente):
  - Estrae sequenze di `screenshot → click_at → screenshot` ricorrenti
  - Registra **regioni di pagina** con coordinate relative (es. "sidebar contatti: colonna sinistra 0-400px") invece di coordinate assolute
  - Annotazioni tipo "su WhatsApp, input messaggio è in basso a destra del viewport"
- Aggiorna:
  - `browser-mcp/playbooks/<app>.json` (canonico, contiene entrambe le strategie)
  - `browser-mcp/playbooks/<app>.md` (leggibile, mostra la strategia consigliata con evidenza statistica)
  - `browser-mcp/playbooks/<app>.strategy.json`: `{"preferred": "semantic", "reason": "1.8k vs 4.2k tokens media", "confidence": 0.85}`

### 5. Filtro dead-end
Problema: un task approvato può contenere 3 `evaluate` sbagliati prima del selettore giusto. Non vogliamo salvarli.

Filtro: ignora tool call il cui risultato ha causato retry immediato con tool simile o è stato seguito da un `evaluate` diagnostico. Euristica: mantieni solo la catena di tool call dalla fine verso l'inizio che ha portato all'approvazione, saltando quelli scartati.

Alternativa più forte: confrontare traces multipli dello stesso intent → tenere solo i tool call in **comune** tra le varianti.

### 6. Consumo
Claude, all'inizio di un task browser, legge `playbooks/<app>.md` (indicato in `docs/memory/context.md`). Il playbook contiene:

1. **Strategia consigliata** per quel dominio (vision/semantic/mixed) con motivazione statistica
2. **Selettori stabili** se semantic è vincente
3. **Regioni di interesse** (coordinate relative) se vision è vincente
4. **Sequenze atomiche** approvate (es. "send_message su WhatsApp: 4 step tipici")
5. **Token cost storico** per ogni sequenza (vedi 6.1)

Claude può ignorare la strategia consigliata se il contesto suggerisce altro (es. task contiene canvas → forza vision anche se playbook suggerisce semantic).

### 6.1 Token cost nel playbook
Ogni voce salvata nel playbook include il costo token storico, così Claude e utente vedono subito "quanto costa davvero". Esempio in `playbooks/whatsapp.md`:

```markdown
## send_message (contact, text)

**Strategia consigliata:** semantic (confidence 0.87)
**Costo medio:** 780 token — 6 tool call — 2.1s
**Campione:** 12 traces approvati (ultimi 14 giorni)
**Range:** min 520t / max 1.2k t

### Sequenza semantic
1. `browser_click('#pane-side span[title="<contact>"]')`
2. `browser_wait_selector('#main footer div[contenteditable="true"]')`
3. `browser_click('#main footer div[contenteditable="true"]')`
4. `browser_evaluate('document.execCommand("insertText", false, "<text>")')`
5. `browser_press('Enter')`
6. `browser_evaluate('[...document.querySelectorAll("#main .message-out")].pop().innerText')`

### Alternativa vision (se semantic fallisce)
**Costo medio:** 3.1k token — 8 tool call
1. `browser_screenshot()`
2. `browser_click_at(x≈200, y≈<hash-of-contact-in-sidebar>)`
3. ...
```

Il formato JSON canonico include:
```json
{
  "intent": "send_message",
  "params": ["contact", "text"],
  "strategies": {
    "semantic": {
      "avg_tokens": 780,
      "avg_calls": 6,
      "sample_size": 12,
      "success_rate": 0.92,
      "steps": [...]
    },
    "vision": {
      "avg_tokens": 3100,
      "avg_calls": 8,
      "sample_size": 4,
      "success_rate": 1.0,
      "steps": [...]
    }
  },
  "preferred": "semantic"
}
```

### 6.2 Rolling statistics
Il distiller ricalcola la media ad ogni esecuzione usando solo gli ultimi **N traces** (default 20) o ultimi **M giorni** (default 30), ignorando outlier (>2σ). Così se un sito cambia e i costi salgono, il playbook si aggiorna velocemente senza inerzia storica eccessiva.

### 6.3 Scoring efficienza (token + tempo)
Ogni trace ora include anche `duration_ms` (tempo totale dalla prima tool call all'ultima). Il distiller calcola uno **score di efficienza** per ogni sequenza:

```
score = w_tokens * tokens_normalized + w_time * duration_normalized
```

Default pesi: `w_tokens = 0.7`, `w_time = 0.3` (token costano più del tempo, ma il tempo conta per UX). Configurabili in `browser-mcp/distiller.config.json`.

**Normalizzazione:** per ogni gruppo `(app_domain, intent)`:
- `tokens_normalized = tokens / median(tokens_all_traces_in_group)`
- `duration_normalized = duration_ms / median(duration_ms_all_traces_in_group)`

Score < 1 = sopra la mediana (migliore). Score > 1 = peggiore.

### 6.4 Selezione automatica della strategia vincente

Quando il distiller ha **2+ traces** dello stesso `(domain, intent)` eseguiti con **strategie diverse** (es. una con screenshot, una senza), applica:

1. Filtra solo traces approvati degli ultimi 30 giorni
2. Per ogni strategia calcola: media token, media tempo, success rate, score aggregato
3. **Strategia vincente =** minor score aggregato, con almeno 3 campioni e success_rate ≥ 0.8
4. Se una strategia ha <3 campioni, resta "candidata" (non viene scartata, ma non è ancora preferita)
5. Scrive in `playbooks/<app>.strategy.json`:
```json
{
  "intent": "send_message",
  "preferred": "semantic",
  "confidence": 0.91,
  "reason": "semantic: 780t/2.1s (score 0.62) vs vision: 3100t/3.4s (score 1.48) — 12 vs 4 samples",
  "updated_at": "2026-04-18T17:52:00Z"
}
```

### 6.5 Confronto esplicito A/B nel playbook markdown

Il playbook mostra entrambe le strategie affiancate, non solo la vincente, così Claude può decidere di deviare se il contesto lo suggerisce:

```markdown
## send_message (contact, text)

| Strategia | Token medi | Tempo medio | Success | Campioni | Score |
|-----------|-----------|-------------|---------|----------|-------|
| **semantic** ✓ | 780 | 2.1s | 92% | 12 | 0.62 |
| vision | 3100 | 3.4s | 100% | 4 | 1.48 |

**Consigliata:** semantic (4x più economica, stesso risultato).
**Quando deviare:** se selettore DOM cambia o c'è ambiguità visiva.
```

### 6.6 Feedback loop continuo

Ogni nuovo trace approvato aggiorna lo score. Se una strategia prima "vincente" peggiora (sito cambia, bug regressione), viene **scalzata** automaticamente dalla rivale al ricalcolo successivo. Playbook sempre allineato allo stato di fatto.

## Nodi critici

1. **Approvazione implicita** — serve timeout + euristica "cambia topic = approvato". Tollera falsi positivi (il peggio è un playbook un po' sporco, si auto-corregge col volume).

2. **Parametrizzazione** — riconoscere che `"Morgana"` e `"Dudek"` nello stesso slot argomento sono la stessa variabile. Richiede:
   - Intent clustering (user_intent simile → confronto)
   - Diff posizionale dei tool call
   - Promozione automatica a `<param>`

3. **Shape playbook** — doppia rappresentazione:
   - `playbooks/<app>.json`: canonico, parsabile dal distiller
   - `playbooks/<app>.md`: rigenerato ad ogni update, consumato da Claude

4. **Scope per dominio** — un sito può avere sottosezioni con DOM diverso (`mail.google.com/mail/` vs `mail.google.com/compose/`). Il distiller raggruppa per path prefix quando ha senso.

5. **Privacy** — i traces contengono nomi contatti, contenuto messaggi. Staying in local filesystem, ma considerare:
   - Troncamento di `result_preview` (max 200 char)
   - Hash dei valori parametrizzati nelle statistiche
   - Gitignore obbligatorio su `logs/traces/` e `logs/approved-traces.jsonl`

## Architettura file

```
browser-mcp/
├── server-playwright.js        ← hook logTrace() nel dispatcher
├── distiller.js                ← nuovo: legge traces → scrive playbooks
├── approval-detector.js        ← nuovo: usato dal bridge
├── playbooks/
│   ├── whatsapp.json          ← auto-generato
│   ├── whatsapp.md            ← auto-generato
│   ├── gmail.json
│   └── gmail.md
└── logs/
    ├── traces/
    │   ├── <task_id>.jsonl
    │   └── <task_id>.meta.json
    └── approved-traces.jsonl

telegram-bridge/
├── watchers.json              ← aggiunge job distiller hourly
└── bridge.js                  ← hook post-message → approval-detector
```

## Roadmap

### Fase A — Logging base
- [ ] Hook `logTrace()` in `server-playwright.js` dispatcher
- [ ] Scrittura `logs/traces/<task_id>.jsonl`
- [ ] Gitignore su `logs/traces/`

### Fase B — Approvazione
- [ ] Modulo `approval-detector.js` con regex + timeout
- [ ] Hook nel bridge post-message
- [ ] Scrittura `.meta.json`

### Fase C — Distiller v1 (selettori, no param)
- [ ] `distiller.js` che raggruppa e deduplica selettori
- [ ] Output `playbooks/<app>.md` semplice (lista selettori ricorrenti)
- [ ] Watcher hourly

### Fase D — Parametrizzazione
- [ ] Intent clustering
- [ ] Diff tool calls → promozione variabili
- [ ] Output strutturato JSON + MD

### Fase E — Filtro dead-end
- [ ] Euristica retry detection
- [ ] Opzionalmente: multi-trace intersection

## Stato

**Deferred.** Sistema interessante ma non critico. Prima completare Fase 1-2 di `PLAN.md` (implementazione tool vision + semantic + guardrail). Una volta che entrambe le strategie sono utilizzabili e si accumulano traces, questo piano diventa ad alto valore perché è ciò che **sceglie automaticamente la strategia vincente** per dominio.

Nota: se implementato, vale per tutti i task browser, non solo WhatsApp. Il ritorno sull'investimento cresce col volume di sessioni. Inoltre, è l'unico modo sostenibile di gestire due strategie parallele senza dover decidere manualmente ogni volta.
