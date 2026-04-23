# Playwright — Piano di Miglioramento

Evoluzione del server `server-playwright.js` per ridurre token spesi, accelerare i task browser e renderli robusti. Due strategie parallele da testare e confrontare: **vision-first** (screenshot + click per coordinate) e **semantic-first** (ARIA tree + locators). Entrambe convivono nel server MCP, l'utente sceglie a runtime o lascia decidere a Claude.

## Stato attuale

Server MCP `server-playwright.js` v2.2.0 connesso via CDP a 3 istanze Chrome (main/slot1/slot2). Tool surface Puppeteer-compatibile (17 tool). Pool lease file-locked cross-process.

### Fatto
- [x] Migrazione Puppeteer → Playwright (CDP connect, context-based pages)
- [x] Fix bug `browser_evaluate` con IIFE (prova espressione, fallback body su SyntaxError)
- [x] Tracking esplicito `activePage` per istanza (map `lastActive`, aggiornato da navigate/new_tab/switch_tab)

## Costo attuale — baseline

| Scenario | Token stimati | Note |
|---|---|---|
| Task mirato (8 tool call, selettori noti) | 400-600 | ottimale |
| Task esplorativo DOM (dump + evaluate) | 20-40k | worst case attuale |
| Screenshot via MCP (`type: image`) | ~1.5-3k | **corretto**: tariffazione immagine, non base64 text |
| ARIA snapshot (futuro) | ~0.5-2k | con `root_selector` |
| `browser_text` body completo | 5-15k | Gmail inbox, WhatsApp sidebar |

**Correzione importante:** stimavo in precedenza 30-80k token per screenshot — errore. Il server ritorna `{type: 'image', data, mimeType}` che Claude processa come immagine nativa (~1.5-3k token per PNG standard), non come base64 text. Questo cambia la strategia: screenshot è competitivo con ARIA snapshot per costo e universalmente migliore per copertura (canvas, shadow DOM, siti mal scritti).

Obiettivo: portare anche i task esplorativi sotto i 3k token con entrambe le vie.

---

## Strategia A — Vision-first (screenshot + click by coordinates)

**Idea:** Claude guarda la pagina con vision, ragiona sulle posizioni, clicca per coordinate. Zero DOM, zero selettori, zero playbook manuali.

### Tool necessari
- [x] `browser_screenshot` (già presente)
- [ ] `browser_click_at(x, y)` — nuovo. Usa `page.mouse.click(x, y)` di Playwright. Supporta `button: 'left'|'right'|'middle'` e `count: n`.
- [ ] `browser_type_at(x, y, text)` — nuovo. Click coordinate + type. Utile su input senza selector ovvio.
- [ ] `browser_scroll_at(x, y, delta)` — nuovo. `page.mouse.wheel(dx, dy)` per scrollare sezioni specifiche (sidebar, panel).

### Pro
- **Universale**: funziona su canvas (TradingView!), SVG, shadow DOM, siti mal scritti
- **Zero manutenzione**: nessun playbook da aggiornare quando un sito cambia
- **Naturale per l'utente**: "clicca su quel bottone" → Claude vede e clicca
- **Costo comparabile**: ~1.5-3k token per screenshot

### Contro
- **Liste lunghe**: screenshot mostra solo il viewport. Per inbox 100 email serve scroll.
- **Testo esatto**: vision legge testo bene ma non perfetto. Per valori numerici, link, date preferire DOM.
- **Stabilità coordinate**: se il layout cambia, coordinate cambiano. Ma lo screenshot successivo mostra lo stato nuovo, quindi si auto-corregge.

### Uso tipico
```
browser_screenshot()  → Claude vede il layout
browser_click_at(x=456, y=230)  → clicca su "Morgana" nella sidebar
browser_screenshot()  → verifica chat aperta
browser_type_at(x=800, y=950, text="A che ora?")
browser_press(Enter)
```
Totale: 3 screenshot + 2 click + 1 press + 1 type = ~6-10k token per task completo.

---

## Strategia B — Semantic-first (ARIA tree + locators)

**Idea:** evitare screenshot, lavorare su DOM strutturato. Meglio quando il testo esatto conta, su liste lunghe, o su pagine ben accessibili.

### Tool necessari
- [ ] `browser_snapshot` — `page.accessibility.snapshot()` con `root_selector`, `max_depth`, `interesting_only`. Peso 0.5-2k.
- [ ] `browser_find(query, role?, max=3)` — wrapper `getByRole`/`getByText` → ritorna selettore stabile pronto per click.
- [ ] `browser_read_chat(app, contact, n)` — helper app-specifico, una chiamata invece di 4-5.

### Pro
- **Testo preciso**: copia esatta di numeri, link, timestamp
- **Liste complete**: vedi tutti gli elementi anche fuori viewport
- **Selettori stabili**: meno sensibile a layout change
- **Molto compatto** su app ARIA-compliant (Gmail, WhatsApp, molti SaaS)

### Contro
- **Fallisce su canvas/SVG**: TradingView inusabile
- **Shadow DOM**: Pie/Just Eat parzialmente invisibile
- **Siti mal scritti**: `<div onclick>` senza role → "generic" inutile

---

## Strategia C — Ibrida (da testare come default)

Combinare A e B in base al contesto. Euristica iniziale:

1. **Prima esplorazione** di una pagina sconosciuta → `browser_screenshot` (vision)
2. **Azione mirata** (click bottone visibile) → `browser_click_at` da coordinate lette sullo screenshot
3. **Lista lunga o testo preciso** → `browser_snapshot` + `browser_find`
4. **Canvas/custom elements** → sempre screenshot
5. **Input testo** → DOM se selettore noto, coordinate+type altrimenti

Il sistema auto-playbook (piano separato) registra quale strategia viene approvata per ogni tipo di task e impara la preferenza.

---

## Priorità 1 — Guardrail output (difensivo, valido per tutte le strategie)

- [ ] `browser_evaluate` tronca a 2k default, flag `full:true` per sforare (attualmente 20k)
- [ ] `browser_screenshot` con parametro `quality` (jpeg/webp) per ridurre payload quando full_page
- [ ] Logging token-per-call in `browser-mcp/logs/token-usage.log` JSONL: `{ts, tool, strategy, input_chars, output_tokens_est}`
- [ ] `browser_text` senza selector → default a `main, [role="main"], #main, body` con troncamento a 4000 char

---

## Priorità 2 — Strategia A (vision) implementazione

- [ ] Aggiungere `browser_click_at(x, y, button?, count?)` a `server-playwright.js`
- [ ] Aggiungere `browser_type_at(x, y, text)` che fa click_at + type
- [ ] Aggiungere `browser_scroll_at(x, y, delta_y)` via `mouse.wheel`
- [ ] Flag `annotate: true` in `browser_screenshot` che disegna griglia coordinate sovrapposta (utile per debug — vedi esattamente i pixel)
- [ ] Documentare strategia A in `browser-mcp/README.md`

---

## Priorità 3 — Strategia B (semantic) implementazione

- [ ] `browser_snapshot` via `page.accessibility.snapshot()`, con `root_selector` e `interesting_only`
- [ ] `browser_find(query, role)` con Playwright locators, max 3 risultati, selettore in output
- [ ] `browser_read_chat(app, contact, n)` helper WhatsApp/Telegram
- [ ] Documentare strategia B

---

## Priorità 4 — Playbook manuali (ridotti)

Con vision disponibile, i playbook diventano opzionali. Li manteniamo solo dove danno vantaggio netto (operazioni ripetitive ad alta frequenza):

- [ ] `playbooks/whatsapp.md` — solo i selettori super-stabili (input, ultimo messaggio)
- [ ] `playbooks/tradingview.md` — rimando ai tool `mcp__tradingview__*` dedicati
- [ ] Altri solo su richiesta

---

## Priorità 5 — A/B test comparativo con scoring efficienza

Ogni task registra metriche standardizzate per confronto oggettivo:

- [ ] Modalità forzata via flag in `browser_*`: `strategy: 'vision' | 'semantic' | 'auto'`
- [ ] Stesso task eseguito nelle due modalità, confronto:
  - **Token spesi** (somma input+output stimato da caratteri / 4)
  - **Durata** (`duration_ms` dalla prima tool call all'ultima)
  - **Tool call totali**
  - **Successo** (approvato dall'utente)
- [ ] Risultati in `browser-mcp/logs/ab-results.jsonl` con schema:
```json
{
  "ts": 1729000000,
  "app_domain": "web.whatsapp.com",
  "intent": "send_message",
  "strategy": "semantic",
  "tokens_est": 780,
  "duration_ms": 2100,
  "tool_calls": 6,
  "approved": true
}
```

### Formula di scoring
```
score = 0.7 * (tokens / median_tokens) + 0.3 * (duration / median_duration)
```
Score < 1 = meglio della mediana; score > 1 = peggio. Pesi in `browser-mcp/distiller.config.json`.

### Selezione vincitore automatica
Quando esistono ≥2 traces dello stesso `(domain, intent)` con strategie diverse, il sistema auto-playbook (vedi `PLAN-autoplaybook.md` §6.4) sceglie la più efficace. Requisiti:
- almeno 3 campioni per strategia
- success rate ≥ 0.8
- score aggregato minimo

La strategia vincente viene salvata in `playbooks/<app>.strategy.json` e Claude la legge all'inizio del task. Se una vincente peggiora nel tempo, viene scalzata automaticamente (feedback loop continuo).

### Dashboard
- [ ] Sezione in `panel.js` (porta 7777) con:
  - Tabella per `(app, intent)`: tokens/tempo/calls medi per strategia
  - Strategia preferita corrente e confidence
  - Leaderboard "operazioni più costose del mese"
  - Grafico temporale token/call per vedere regressioni
- [ ] Dashboard nel pannello `panel.js` (porta 7777) che mostra confronto

---

## Roadmap esecutiva aggiornata

### Fase 1 — Subito
- [ ] Guardrail (`evaluate` truncate, logging token-per-call)
- [ ] Implementare `browser_click_at`, `browser_type_at`, `browser_scroll_at`
- [ ] Aggiornare il system prompt del bridge per suggerire strategia vision come default su pagine sconosciute

### Fase 2 — Breve
- [ ] Implementare `browser_snapshot`, `browser_find`
- [ ] Playbook WhatsApp minimo
- [ ] Modalità A/B con flag `strategy` e logging comparativo

### Fase 3 — Medio
- [ ] `browser_read_chat`, `browser_send_message` atomici (usando la strategia vincente su base statistiche A/B)
- [ ] Dashboard A/B su panel.js
- [ ] Integrazione con piano auto-playbook: il distiller impara la strategia preferita per dominio

### Fase 4 — Cleanup
- [ ] Rimuovere `puppeteer-core` da `browser-mcp/package.json` (dopo 2 settimane di stabilità Playwright)
- [ ] Rinominare `server.js` → `server-legacy-puppeteer.js`
- [ ] Rinominare `server-playwright.js` → `server.js`
- [ ] Ripristinare path in `.claude.json` (richiede workaround `_swap.cjs`)

---

## Metriche di successo

- Task WhatsApp "manda messaggio a X":
  - Vision-only: ≤10 tool call, ≤10k token
  - Semantic-only: ≤8 tool call, ≤2k token
  - Hybrid approvata dall'utente: ≤8 tool call, ≤3k token
- Task "capisci pagina X sconosciuta":
  - Vision: ≤3k token (uno screenshot + reasoning)
  - Semantic: ≤2k token (uno snapshot mirato)
- Zero screenshot full page "accidentali" (tutti annotati in log con strategy)
- Dopo 1 mese di A/B: sapere quale strategia vince per dominio e task type

---

## Note aperte

- **Auto-playbook** (`PLAN-autoplaybook.md`): registra strategia + tool call approvati, il distiller sceglie per te nel tempo. Esteso per supportare entrambe le strategie.
- **Panel control** (`PLAN-panel.md`): interfaccia UI per configurare tutto.
- **Altre idee fuori scope** (`FUTURE-PLAN.md`): approvazione Telegram, hardening getChatTranscript, auth panel, multi-browser, self-healing selettori, replay traces, ecc. Consultare il file dedicato.
