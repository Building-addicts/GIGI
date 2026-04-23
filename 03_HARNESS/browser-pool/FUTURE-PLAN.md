# Future Plan — Idee fuori scope

Raccolta di tutto ciò che è emerso durante la progettazione ma che è **fuori dallo scope immediato** dei tre piani attivi (`PLAN.md`, `PLAN-autoplaybook.md`, `PLAN-panel.md`). Da implementare dopo aver stabilizzato quelle basi.

Ogni voce ha: **stato**, **motivazione**, **dipendenze**, **complessità stimata**.

---

## 1. Sistema approvazione operazioni sensibili via Telegram

**Motivazione:** l'utente opera il bot da Telegram e non può cliccare "Allow" ai prompt di permission MCP (scrittura `.claude.json`, operazioni distruttive, file protetti). Oggi si aggira con script workaround tipo `_swap.cjs`.

**Funzionamento ipotizzato:**
- Claude intercetta un tool call sensibile (lista configurabile) → pausa l'esecuzione
- Invia messaggio Telegram tipo "Vuoi che scriva `.claude.json`? [sì] [no]"
- Utente risponde con parola chiave o inline button
- Approvato → Claude prosegue; negato → rollback

**Dipendenze:** bridge Telegram esistente, tool-level interception nel bridge.js
**Complessità:** Media (hook pre-tool-execution + UI button Telegram)
**Scope:** trasversale, non solo browser. Interessa tutti gli MCP.

---

## 2. Hardening `getChatTranscript` auto-consultation

**Motivazione:** helper già esposto dal bridge. Rischio che Claude lo consulti automaticamente quando cerca contesto, spendendo token inutilmente (il transcript letterale è pesante).

**Funzionamento:** documentazione più forte nel system prompt del bridge + eventuale guardrail che richiede flag esplicito `user_requested: true`.

**Dipendenze:** config.json system prompt del bridge
**Complessità:** Bassa (prompting + optional flag)

---

## 3. Autenticazione panel se esposto remoto

**Motivazione:** panel attualmente aperto su porta 7777 in locale senza auth. Se si espone via tunnel (Cloudflare, ngrok) o reverse proxy per uso remoto (es. controllare il bot da fuori casa), serve autenticazione.

**Funzionamento:** basic auth header o token in query/cookie, config in `panel.config.json`.

**Dipendenze:** PLAN-panel.md completato
**Complessità:** Bassa

---

## 4. Mobile responsive view del panel

**Motivazione:** panel attualmente desktop-first. Utile approvare traces pendenti o ribaltare kill switch dal telefono mentre si è fuori.

**Dipendenze:** PLAN-panel.md completato, CSS media queries
**Complessità:** Bassa-media

---

## 5. Notifiche push Telegram dal panel

**Motivazione:** complemento naturale all'integrazione esistente. Quando ci sono traces pendenti approvazione, regressioni rilevate (+30% token), o un playbook si auto-aggiorna, il panel manda notifica al bot Telegram.

**Funzionamento:** event emitter nel panel → chiamata REST al bridge → messaggio Telegram a chat admin.

**Dipendenze:** PLAN-panel.md + bridge Telegram (già esistente)
**Complessità:** Bassa

---

## 6. Estensione panel ad altri MCP (Harness unified control)

**Motivazione:** stesso modello (config JSON + panel UI) è applicabile a tutti gli altri MCP di Harness: TradingView, Gmail, Google Drive, Supabase. Il panel browser diventa "Pannello di controllo Harness" unificato.

**Funzionamento:** tab navigation tipo `Browser | TradingView | Gmail | Drive | ...`, ogni modulo espone endpoint REST standardizzati.

**Dipendenze:** PLAN-panel.md stabile
**Complessità:** Alta (richiede standardizzazione contract fra MCP)

---

## 7. Multi-browser engine (Firefox, WebKit)

**Motivazione:** Playwright supporta nativamente Chromium, Firefox, WebKit. Alcuni siti rendono diversamente, o test cross-browser utili. Oggi usiamo solo Chromium via CDP.

**Funzionamento:** `browser_lease` accetta `engine: 'chromium'|'firefox'|'webkit'`, il server sceglie l'istanza corretta.

**Dipendenze:** profili browser dedicati per engine, setup CDP port per ognuno
**Complessità:** Media

---

## 8. Modalità headless per watcher

**Motivazione:** i watcher periodici (Leo, Tommy) aprono browser visibili che occupano desktop. Per task in background potremmo avere un'istanza headless dedicata.

**Funzionamento:** profilo Chrome headless su CDP port dedicato, `browser_lease({headless: true})` lo sceglie.

**Dipendenze:** profilo nuovo, gestione pool esteso
**Complessità:** Bassa-media

---

## 9. Playwright tracing per debug

**Motivazione:** Playwright ha API nativa `context.tracing.start()` che registra HAR, video, screenshot step-by-step. Utilissimo per post-mortem quando un task fallisce.

**Funzionamento:** flag `trace: true` in `browser_lease` → abilita tracing → output in `logs/playwright-traces/<task_id>.zip` visualizzabile con Playwright trace viewer.

**Dipendenze:** nessuna, API già disponibile
**Complessità:** Bassa

---

## 10. Self-healing selettori

**Motivazione:** se un selettore semantic fallisce (sito cambia DOM), invece di dare errore il sistema prova automaticamente la strategia vision come fallback, completa il task, e **aggiorna il playbook** segnalando la degradazione.

**Funzionamento:** wrapper su `browser_click(selector)` con retry vision se fallisce → log evento in `playbook/<app>.degradation.log` → prossimo distiller ricalcola preferenza.

**Dipendenze:** PLAN-autoplaybook.md completato
**Complessità:** Media

---

## 11. Trace diff tool (UI regression detector)

**Motivazione:** confrontare screenshot tra due esecuzioni dello stesso intent per rilevare cambi visuali del sito (nuovi banner cookie, update UI). Aiuta a capire perché una strategia peggiora.

**Funzionamento:** tab "Trace Diff" nel panel, selezione di 2 trace ID, visualizzazione side-by-side screenshot + diff tool calls.

**Dipendenze:** PLAN-panel.md + traces con screenshot salvati
**Complessità:** Media

---

## 12. Modello vision locale per OCR (riduzione API cost)

**Motivazione:** ogni screenshot costa token Anthropic. Per task ripetitivi su stesse pagine potremmo usare un modello locale (Moondream, Florence, ecc.) per estrarre coordinate bottoni / testo già visto.

**Funzionamento:** cache locale di "questa pagina ha il bottone X a (456, 230)". Hit cache → skip Claude vision. Miss → fallback a Claude.

**Dipendenze:** infrastruttura modello locale (llama.cpp/onnxruntime)
**Complessità:** Alta (fuori dalla sfera Node.js)

---

## 13. Rate limiting per dominio

**Motivazione:** evitare di bombardare di request un singolo sito (rischio IP ban, rate limit API esterne). Utile soprattutto per scraping o watcher frequenti.

**Funzionamento:** config `browser-mcp/rate-limits.json` con `{"example.com": {"max_per_minute": 30}}`. Tool `browser_navigate` e evaluate che triggerano request rispettano il limit.

**Dipendenze:** config + middleware nel dispatcher
**Complessità:** Bassa-media

---

## 14. Cookies / localStorage import-export via panel

**Motivazione:** utile per migrare login tra profili, backup sessioni auth critiche, o clonare stato tra slot. Oggi si fa a mano copiando cartella profilo.

**Funzionamento:** tab "Sessions" nel panel → per istanza → export JSON di cookies + localStorage per dominio. Import scrive back.

**Dipendenze:** PLAN-panel.md + API `context.cookies()`, `page.evaluate(() => localStorage)`
**Complessità:** Bassa-media

---

## 15. Share/export playbook tra utenti

**Motivazione:** un playbook WhatsApp distillato è riutilizzabile. Se ho passato 3 mesi a farlo stabile, potrei condividerlo come "pacchetto" con altri utenti Harness.

**Funzionamento:** export playbook come JSON/zip → import in altro Harness → merge con playbook locale (le preferenze locali vincono su conflitto).

**Dipendenze:** schema playbook stabile, versioning
**Complessità:** Media (serve attenzione a dati sensibili tipo nomi contatti nei selettori)

---

## 16. Internationalization approval detector

**Motivazione:** oggi il detector usa regex italiane (`ok`, `daje`, ecc.). Se Harness va usato in altre lingue serve estensione multilingua.

**Funzionamento:** config `approval-config.json` con patterns per lingua, autodetect lingua dal messaggio.

**Dipendenze:** PLAN-autoplaybook.md completato
**Complessità:** Bassa

---

## 17. LLM-enhanced approval detector

**Motivazione:** messaggi ambigui tipo "sì ma la prossima volta fai X", "va bene ma", "non ho capito bene" sono difficili da classificare con regex. Un LLM-call leggera (Haiku) risolverebbe.

**Funzionamento:** detector tenta regex → se confidence bassa → chiama Claude Haiku con prompt classificatore → restituisce approved/rejected/ambiguous.

**Dipendenze:** PLAN-autoplaybook.md + API key Claude già disponibile nel bridge
**Complessità:** Bassa (già citato come "LLM fallback" ma non implementato)

---

## 18. Sandbox / isolation per script evaluate

**Motivazione:** `browser_evaluate` esegue JS arbitrario. Se Claude genera codice sbagliato può modificare stato della pagina in modo imprevisto. Un sandbox (CSP o iframe isolato) ridurrebbe rischio.

**Dipendenze:** modifica `browser_evaluate` nel server
**Complessità:** Alta (non banale con CDP + contenuti cross-origin)

---

## 19. Replay di traces approvati

**Motivazione:** rieseguire esattamente una sequenza approvata senza passare per Claude (task deterministico ripetuto). Es. "ogni mattina controlla gmail inbox" → replay playbook diretto.

**Funzionamento:** tool `browser_replay(trace_id)` nel server → esegue tool calls in sequenza → report success/fail.

**Dipendenze:** PLAN-autoplaybook.md completato
**Complessità:** Media

---

## 20. Metrica "fragility" per selettori

**Motivazione:** alcuni selettori funzionano spesso ma falliscono ogni tanto (es. DOM riordinato, A/B test del sito). Misurare fragilità aiuta a capire quando un selettore sta per essere obsoleto.

**Funzionamento:** tracking success/fail rate per selettore specifico → flag "warning" quando success scende sotto 0.9 → trigger rigenerazione playbook da traces recenti.

**Dipendenze:** PLAN-autoplaybook.md + logging esteso per selettore
**Complessità:** Bassa-media

---

## Ordine di priorità suggerito (quando si riprenderà)

Criterio: beneficio immediato / rischio / sforzo.

### Prima tranche (alto ROI, basso sforzo)
- **1. Approvazione Telegram** (trasversale, sblocca molti workflow)
- **9. Playwright tracing** (debug immediato, API già pronta)
- **17. LLM-enhanced approval** (qualità auto-playbook)
- **2. Hardening getChatTranscript** (risparmio token)

### Seconda tranche (estensioni panel)
- **3. Auth panel**
- **4. Mobile responsive**
- **5. Notifiche push Telegram**
- **14. Cookies/localStorage export**

### Terza tranche (evoluzione sistema)
- **10. Self-healing selettori**
- **11. Trace diff tool**
- **19. Replay di traces**
- **20. Fragility metric**

### Quarta tranche (ambizioso)
- **6. Panel unificato Harness**
- **7. Multi-browser engine**
- **8. Headless watcher**
- **15. Share playbook**
- **13. Rate limiting per domain**
- **16. i18n approval**

### Sperimentale (ricerca)
- **12. Modello vision locale**
- **18. Sandbox evaluate**

---

## Convenzioni

- Nuove idee emerse durante le sessioni vanno qui se non critiche
- Quando un item viene attivato, taglialo da qui e aprigli un `PLAN-<nome>.md` dedicato
- Se un piano attivo perde scope, il resto torna qui
- Nessun item va perso: "deferred" non è "dimenticato"
