# Panel Control — Piano UI di controllo

Terzo piano, da implementare **dopo** `PLAN.md` e `PLAN-autoplaybook.md`. Estensione del pannello web `telegram-bridge/panel.js` (porta 7777) per dare all'utente controllo totale su tutto il sistema browser: strategie, playbook, scoring, traces, metriche, kill switch.

Obiettivo: l'utente non deve mai aprire file di config a mano o grep-pare log. Tutto visibile e modificabile da UI.

## Stato attuale

Pannello `panel.js` esistente su porta 7777 (vedi `telegram-bridge/panel.js`). Attualmente mostra stato bridge, sessioni, statistiche base. Da estendere con sezione dedicata "Browser".

## Filosofia

- **Leggibile a colpo d'occhio**: dashboard in home, dettagli in drill-down
- **Modificabile senza redeploy**: ogni variabile via UI → scrive su JSON di config, il server legge a runtime
- **Kill switch sempre disponibile**: disabilitare auto-playbook, disabilitare vision, forzare semantic — tutto reversibile in un click
- **Audit trail**: ogni modifica da UI loggata con timestamp per poter fare rollback

---

## Sezioni del pannello "Browser"

### 1. Dashboard overview
Home della sezione browser. Una pagina, tutto visibile.

- **Stato istanze**: main/slot1/slot2 → colore verde/giallo/rosso, lease attivo, URL tab attiva
- **Token spesi oggi/settimana/mese**: totale + breakdown per app domain
- **Strategia vincente per dominio**: tabella `{domain, preferred_strategy, confidence, last_update}`
- **Alert**: regressioni rilevate (costi saliti del >30% rispetto alla mediana storica), traces pending approvazione, playbook obsoleti
- **Leaderboard**: top 10 operazioni più costose del mese

### 2. Strategia (override globali e per dominio)

Controllo strategia a 3 livelli, in ordine di precedenza:
1. **Override task-specifico** (passato nel tool call)
2. **Override per dominio** (configurato qui)
3. **Default globale** (configurato qui)

UI:
- Radio button default globale: `auto | vision | semantic | off`
- Tabella domini: per ogni dominio noto, dropdown strategia + toggle "usa auto-playbook preferred"
- Bottone "Reset a auto-playbook preferred" per singola riga
- Bottone emergency: **"Forza vision everywhere"** e **"Forza semantic everywhere"** (kill switch)

Config: scrive `browser-mcp/strategy-overrides.json`:
```json
{
  "default": "auto",
  "domains": {
    "web.whatsapp.com": {"strategy": "semantic", "lock": false},
    "tradingview.com": {"strategy": "vision", "lock": true}
  }
}
```
`lock: true` = ignora auto-playbook preferred, usa sempre quello forzato.

### 3. Playbook viewer/editor

Elenco file `browser-mcp/playbooks/*.md` + `*.json` con:
- **Preview** del markdown rendered (tabelle, sequenze)
- **Editor inline** per modifica manuale (textarea → save → scrive file)
- **Versioning**: snapshot prima di ogni save in `playbooks/_history/<file>.<ts>.bak`
- **Badge**: "auto-generated" vs "manual" vs "edited after auto"
- **Bottone "Rigenera"** per singolo playbook (trigger distiller solo su quell'app)

### 4. Traces browser

Lista trace files in `browser-mcp/logs/traces/`:

- Tabella filtrabile: `task_id | app | intent | strategy | tokens | duration | approved | timestamp`
- Filtro per: dominio, strategia, stato approvazione, range date
- Click su riga → dettaglio con sequenza completa tool_calls (JSON viewer)
- Bottoni riga: **Approve** / **Reject** / **Mark as template** (diventa trace-pilota per distiller)
- Bottone "Exporta CSV" per analisi esterna
- Bottone "Delete" singolo o bulk (per ripulire trace di test)

### 5. Approvazione pendenti

Sezione dedicata per traces in attesa di approvazione esplicita (quelli non classificati dal detector automatico).

- Lista con preview delle tool call e user intent
- Per ognuno: **Approve** / **Reject** / **Skip** (marca come ambiguo, ignora nel distiller)
- Opzionale: preview screenshot se era strategia vision
- Bulk actions

### 6. Scoring & config distiller

Variabili numeriche del distiller, tutte editabili:

| Parametro | Default | Descrizione |
|---|---|---|
| `w_tokens` | 0.7 | Peso token nello score |
| `w_time` | 0.3 | Peso durata nello score |
| `rolling_window_n` | 20 | Ultimi N traces per media |
| `rolling_window_days` | 30 | Ultimi M giorni per media |
| `outlier_sigma` | 2.0 | Soglia outlier (σ dalla media) |
| `min_samples_for_preferred` | 3 | Min campioni per eleggere strategia vincente |
| `min_success_rate` | 0.8 | Min success rate per eleggere |
| `distiller_cron` | `0 * * * *` | Schedule cron |
| `auto_approval_timeout_ms` | 60000 | Timeout "cambia topic = approvato" |

UI: form con slider/input. Save → scrive `browser-mcp/distiller.config.json`. Bottone "Reset defaults".

### 7. Approval detector config

Regex e keyword per classificazione automatica messaggi utente:

- Lista editable **approval_patterns**: `ok`, `perfetto`, `daje`, `ottimo`, ...
- Lista editable **rejection_patterns**: `no`, `rifai`, `sbagliato`, ...
- Toggle: usa LLM fallback su Haiku per casi ambigui (sì/no)
- Test box: inserisci un messaggio e vedi la classificazione live

Config: `browser-mcp/approval-config.json`.

### 8. Metriche e grafici

Sezione analytics, con grafici temporali.

- **Token/giorno** per dominio (line chart)
- **Tool call/task** per strategia (bar chart)
- **Success rate** per strategia per dominio (stacked bar)
- **Tempo medio task** trend
- **Distribuzione score** istogramma
- Time range selector: 24h / 7g / 30g / all

Dati letti da `logs/ab-results.jsonl` e `logs/token-usage.log`.

### 9. Kill switches & reset

Bottoni rossi, con conferma:

- **Disabilita auto-playbook** (disattiva distiller, torna a playbook statici)
- **Disabilita vision tools** (Claude non può chiamare `browser_click_at` ecc.)
- **Disabilita semantic tools** (Claude non può chiamare `browser_snapshot` ecc.)
- **Pulisci traces > 30 giorni**
- **Reset playbook auto-generati** (rigenera da zero da traces)
- **Reset preferenze strategia** (tutte auto)

### 10. Audit log modifiche UI

Tab separato che mostra ogni modifica fatta dall'utente via panel:
- Timestamp
- Cosa è cambiato (diff JSON)
- Chi (non critico in single-user, ma utile per debug)
- Bottone "Rollback" per singola modifica

File: `browser-mcp/logs/panel-audit.log` (JSONL).

---

## Architettura tecnica

### Backend (estensione `panel.js`)
- Nuovi endpoint REST sotto `/api/browser/*`:
  - `GET /api/browser/overview` — dashboard
  - `GET/POST /api/browser/strategy` — overrides
  - `GET/POST /api/browser/playbooks/:app` — read/write playbook
  - `GET /api/browser/traces` — lista con filtri
  - `GET /api/browser/traces/:id` — dettaglio
  - `POST /api/browser/traces/:id/approve` — approvazione
  - `GET/POST /api/browser/config/distiller` — scoring config
  - `GET/POST /api/browser/config/approval` — detector config
  - `GET /api/browser/metrics` — aggregate per grafici
  - `POST /api/browser/kill/:switch` — kill switch
  - `GET /api/browser/audit` — log modifiche

### Frontend
- Single Page App minimale, vanilla JS o lightweight (Alpine.js, htmx). Nessun bundler.
- Tabs: Overview | Strategy | Playbooks | Traces | Approvals | Config | Metrics | Kill | Audit
- Tabella sortabile/filtrabile client-side per traces (fino a 5k righe, oltre serve paginazione)
- Chart via Chart.js (script tag, no build)
- Polling refresh 5s su overview e traces

### Storage config
Tutto in file JSON leggibili a mano (non database):
```
browser-mcp/
├── strategy-overrides.json
├── distiller.config.json
├── approval-config.json
├── panel-ui.config.json      ← preferenze UI (tab aperto, filtri, ecc.)
└── logs/
    ├── panel-audit.log
    ├── ab-results.jsonl
    └── token-usage.log
```

Il server MCP e il distiller leggono questi file **al volo** ad ogni chiamata/tick, non serve restart.

---

## Interazione con gli altri piani

- **PLAN.md**: il panel espone le strategie A/B/ibrida, i tool semantici e vision, i risultati del test comparativo. Dopo l'implementazione dei tool in server-playwright.js, il panel li rende visibili e configurabili.
- **PLAN-autoplaybook.md**: il panel è l'interfaccia umana al sistema auto-playbook. Approvazione manuale, scoring, viewer dei traces, editor dei playbook auto-generati, trigger distiller.
- **Nessuna dipendenza circolare**: il panel è lettore/scrittore di config e file prodotti dagli altri due sistemi. Può essere sviluppato in parallelo una volta che gli altri due hanno schema file stabile.

---

## Stato

**Pianificato, da implementare per ultimo.** Ordine consigliato:
1. Completare Fase 1-2 di `PLAN.md` (tool vision + semantic + guardrail)
2. Fase A-C di `PLAN-autoplaybook.md` (logger + detector + distiller v1)
3. Questo piano (panel control) — quando ci sono dati veri da mostrare e config vere da modificare

Prima di quel punto, il panel sarebbe vuoto o mostrerebbe solo scheletri.

---

## Roadmap esecutiva

### Fase P1 — Backend endpoint base
- [ ] `GET /api/browser/overview` con stato istanze e summary
- [ ] `GET /api/browser/traces` + `GET /api/browser/traces/:id`
- [ ] `GET /api/browser/playbooks` + `GET /api/browser/playbooks/:app`

### Fase P2 — UI read-only
- [ ] Tab Overview, Traces, Playbooks funzionanti (solo view)
- [ ] Filtri/sort traces client-side
- [ ] Preview playbook markdown rendered

### Fase P3 — Scrittura config
- [ ] Endpoint POST per strategy-overrides, distiller.config, approval-config
- [ ] Form UI con save
- [ ] Audit log di ogni modifica

### Fase P4 — Approvazioni e traces actions
- [ ] Approve/Reject traces via UI
- [ ] Rigenera singolo playbook
- [ ] Bulk actions su traces

### Fase P5 — Metriche e grafici
- [ ] Endpoint `/api/browser/metrics` con aggregati
- [ ] Chart.js embedded in tab Metrics

### Fase P6 — Kill switch e audit
- [ ] Tutti i kill switch funzionanti con conferma
- [ ] Tab Audit con rollback

---

## Note aperte

Tutte le estensioni ulteriori (auth se esposto remoto, mobile responsive, notifiche push Telegram, estensione ad altri MCP come pannello Harness unificato) sono tracciate in `FUTURE-PLAN.md`.
