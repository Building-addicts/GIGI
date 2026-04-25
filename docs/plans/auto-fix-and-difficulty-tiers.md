# Auto-fix + Difficulty Tiers + Guided Walkthroughs

**Status**: Draft · **Owner**: Armando · **Phase**: 6 sub-extension (P6.10 → P6.12)

## Requirements Summary

Estendere il flusso diagnostic-driven (Phase 6 P6.1–P6.8) in tre direzioni:

1. **Auto-fix lato server** — uno script per ogni check risolvibile, esposto via `POST /api/setup/autofix`. Banner sticky in `SetupDiagnosticView` "Fix all automatically" che esegue la batch e mostra progress per-step.
2. **Difficulty tiers nel Panel `/setup`** — quiz "Help me choose" + badge per-card che classifica le 4 modalità tunnel per livello tecnico (Easy / Recommended / Local-only / Advanced).
3. **Guided walkthroughs inline** — per ogni check non auto-fixabile, un mini-stepper espandibile dentro la card della DiagnosticView (no fullscreen separate).

## Decisioni utente confermate (2026-04-25)

- **Q1 — secret rotate**: la rotazione di `config_secret_strength` è auto-fixabile MA mostra un confirm popup "Questo ti scollegherà, dovrai rifare il pair", e dopo il fix invalida le connessioni esistenti (effettivo logout); poi l'app guida al re-pair con il nuovo secret.
- **Q2 — Panel UX**: entrambi — quiz "Help me choose" come opzione visibile in cima + badge colorati su ognuna delle 4 card.
- **Q3 — walkthroughs**: inline expandable sotto la card del check failing.
- **Q4 — autofix progress**: visible per-step (Fixing tunnel... ✓ Fixing secret... ✓), non hidden batch.

## Auto-fix matrix (5/10 fixable)

| Check ID | Auto-fixable | Side effects | Implementazione |
|---|---|---|---|
| `claude_cli_installed` | ❌ | — | Walkthrough only (download + install Claude Code) |
| `claude_cli_authenticated` | ⚠️ semi | Apre browser sul PC | Spawna `claude /login`; ritorna `needsUser:true` perché OAuth richiede l'utente |
| `config_secret_strength` | ✅ con confirm | Invalida pair correnti | Genera 32-byte hex, scrive config.json, `needsRepair:true` |
| `tunnel_mode_active` | ✅ | — | Imposta `mode=quick` in config (default sano) |
| `tunnel_running` | ✅ | — | Chiama `cloudflared.startQuick()` o `startNamed()` in base alla modalità |
| `cloudflared_binary` | ✅ | Download ~64MB | Forza `installCloudflared()` |
| `outbound_https` | ❌ | — | Walkthrough (check rete utente) |
| `port_7779_bound` | ✅ raro | Restart server | Diagnostica più che fix; bottone "restart server" |
| `disk_space` | ❌ | — | Walkthrough (libera spazio) |
| `last_request_ago` | N/A | — | Solo informativo |

## Acceptance Criteria

### AC-1 — Backend `/api/setup/autofix`

- [ ] `POST /api/setup/autofix` Bearer-authed, accetta body `{checkIds: string[]}` (oppure `["all"]` per tutti i fixable)
- [ ] Risposta shape:
  ```json
  {
    "ok": true,
    "data": {
      "results": [
        { "id": "tunnel_running",      "fixed": true,  "detail": "started quick tunnel" },
        { "id": "claude_cli_authenticated", "fixed": false, "needsUser": "Browser opened — complete sign-in" },
        { "id": "config_secret_strength",   "fixed": true,  "needsRepair": true, "newSecret": "<masked>" }
      ],
      "summary": { "fixedCount": 2, "needsUserCount": 1, "elapsed_ms": 1240 }
    }
  }
  ```
- [ ] Esegue in serie (un check alla volta) per dare progress chiaro
- [ ] Ogni fixer ha timeout interno 15s (alcuni come binary download possono prendere di più: 60s)

### AC-2 — `checks.js` esporta `autoFixable` flag

- [ ] Ogni `CheckResult` include `autoFixable: boolean` derivato da una mappa statica (non runtime detection)
- [ ] Frontend usa questo flag per popolare il banner "Fix all automatically"

### AC-3 — Banner "Fix all" in DiagnosticView

- [ ] Sticky in cima dopo summary header, visibile solo se ≥ 1 check failing E `autoFixable === true`
- [ ] Mostra count "N issues can be fixed automatically · M need your input"
- [ ] Bottone primario "Fix all automatically"
- [ ] Tap → confirm popup se include `config_secret_strength` (Q1c)
- [ ] Esecuzione in stato `.fixing` con progress per-step (Q4b):
  ```
  Fixing… 1/3
  ✓ tunnel_running
  ⏳ config_secret_strength
  ⏳ cloudflared_binary
  ```
- [ ] Al completamento → toast "✓ N fixed · M still need you", trigger refresh diagnostics dopo 2s

### AC-4 — Re-pair flow dopo secret rotate

- [ ] Se la response autofix include `needsRepair:true`, l'app:
  - Cancella URL+secret dal Keychain
  - Setta `harnessReady = false`
  - Chiude DiagnosticView
  - Apre PairingSheet diretta sullo stesso QR aggiornato lato Panel
- [ ] L'utente fa nuovo scan → restart pair flow normale

### AC-5 — Difficulty badges + quiz nel Panel

- [ ] Ogni card delle 4 modalità tunnel mostra un badge colorato:
  - 🚀 Quick = `Easy` (verde)
  - ☁️ Named = `Recommended` (viola)
  - 🏠 LAN = `Local only` (blu)
  - ⚙️ Manual = `Advanced` (grigio)
- [ ] Sopra la grid delle card, una sezione "Help me choose" espandibile che mostra 4 domande/risposte, ognuna evidenzia la card consigliata
- [ ] Tap su risposta → scrolla alla card + applica un highlight pulse 2s
- [ ] Stato collapsed di "Help me choose" persiste in sessionStorage

### AC-6 — Inline guided walkthroughs

- [ ] Per check non auto-fixabili (5: `claude_cli_installed`, `outbound_https`, `disk_space`, `claude_cli_authenticated` quando `needsUser`, e fallback per altri), espansione card mostra:
  - Hint paragraph (current behavior, immutato)
  - Action button (current behavior, immutato)
  - Nuovo "Show full instructions" link che, se tappato, espande N step strutturati
- [ ] Ogni walkthrough è hardcoded in un dictionary `Walkthroughs.swift` con shape:
  ```swift
  struct Walkthrough {
    let title: String
    let steps: [WalkthroughStep]   // {label, body, copyable?}
  }
  ```
- [ ] Mappa minima v1: 5 walkthroughs (gli stessi check elencati sopra)
- [ ] Step `copyable` mostra un copy-button accanto al body monospace

## Implementation Plan

### Backend (~6h)

**P6.10.1 — `preflight/auto_fixers.js`** · NEW
- Registry `{ [checkId]: async (ctx) => FixResult }` con 6 fixers iniziali
- Helper `runFix(id, ctx)` con timeout per-fixer (15s default, 60s per binary download)
- FixResult shape `{fixed, detail?, needsUser?, needsRepair?}`
- **Stima**: 2h

**P6.10.2 — `api/autofix.js`** · NEW
- `POST /api/setup/autofix` Bearer-authed, idempotent
- Iter `checkIds` in serie, raccoglie results, ritorna report aggregato
- Si registra nel server.js dopo handleDiagnostics
- **Stima**: 1h

**P6.10.3 — `checks.js` aggiungere `autoFixable`** · MODIFY
- Mappa statica `AUTO_FIXABLE = new Set(['config_secret_strength', 'tunnel_mode_active', ...])`
- Ogni check result wraps il valore
- **Stima**: 30min

**P6.10.4 — Panel `setup.html` quiz + badges** · MODIFY
- HTML per "Help me choose" expandable section + 4 domande/risposte
- CSS per badges colorati su ogni card
- JS per highlight pulse al tap su risposta
- **Stima**: 1.5h

**P6.10.5 — `index.html` Panel — link a /setup con quiz**
- Solo aggiornamento copy + link
- **Stima**: 15min

### iOS (~5h)

**P6.11.1 — `DiagnosticsCheck` aggiungere `autoFixable`** · MODIFY
- Decodable extension, default false per backward compat
- **Stima**: 15min

**P6.11.2 — `SetupDiagnosticView` autofix banner** · MODIFY
- Banner sticky con count + bottone
- Confirm popup pre-execution se include secret rotate
- Stato `.fixing` con per-step UI
- Trigger refresh post-completion
- **Stima**: 2h

**P6.11.3 — Re-pair flow post-secret-rotate** · MODIFY
- `GigiHarnessClient` aggiungere `clearPair()` helper
- `SetupDiagnosticView` su `needsRepair:true` chiama clearPair + chiude + apre PairingSheet via callback parent
- **Stima**: 45min

**P6.12.1 — `Walkthroughs.swift`** · NEW
- Dictionary statico di 5 walkthrough (claude_install, claude_auth, outbound_https, disk_space, generic_fallback)
- Step strutturati con metadata copyable
- **Stima**: 1h

**P6.12.2 — Inline walkthrough rendering** · MODIFY DiagnosticView
- Quando expanded e walkthrough disponibile, mostra "Show full instructions" → espande N step
- Per ogni step copyable, copy button
- **Stima**: 1h

### Test gate (~1h)

**P6.13 — Test gate utente** (sostituisce/estende P6.9)
- Fresh install → auto-fix risolve 4/5 issues automaticamente
- Restante (claude_cli_authenticated) mostra walkthrough inline → utente segue → ✓
- Quiz nel Panel guida correttamente alla card giusta in 4/4 scenari
- Secret rotate flow: confirm popup → fix → re-pair richiesto → completa
- USER CHECKPOINT: validazione qualitativa UX

**Totale**: ~13h backend+iOS+test, splittabili in 3 task plan blocks.

## Risks and Mitigations

| Rischio | Probabilità | Impatto | Mitigazione |
|---|---|---|---|
| Auto-fix di `tunnel_mode_active=quick` cambia un setup intenzionale | Media | Medio | Non auto-fixiamo se l'utente ha già scelto una modalità, anche se manual; solo se mode è UNSET |
| Re-pair dopo secret rotate confonde l'utente | Media | Alto | Confirm popup esplicito + transizione visuale chiara da DiagnosticView a PairingSheet |
| Fixer per `claude_cli_authenticated` apre browser sul PC e l'utente è davanti all'iPhone | Alta | Basso | Lo stato `needsUser` lo segnala chiaramente; walkthrough indica "Vai sul PC e completa il login" |
| Auto-fix di `cloudflared_binary` scarica 64MB su rete lenta → timeout | Media | Medio | Timeout esteso a 60s; UI mostra "Downloading… ~30s" |
| Quiz nel Panel diventa rumoroso se utente sa già cosa vuole | Bassa | Basso | Sezione collassata di default, button "Help me choose" |
| Walkthroughs hardcoded vanno fuori sync se backend hint cambia | Media | Basso | Doc nota: walkthroughs sono complementari a hint backend, non sostitutivi; aggiornare entrambi quando si cambia un check |

## Verification Steps

**Pre-condizioni**: harness fresh, `.ipa` re-buildato, iPhone con DiagnosticView aperta.

**Test cases**:
1. ✓ Apertura DiagnosticView con 4 fail → banner "Fix all (3 fixable)" visibile
2. ✓ Tap "Fix all" senza secret rotate nei targets → no confirm popup, esegue, mostra per-step
3. ✓ Tap "Fix all" con secret rotate target → confirm popup → cancel → niente succede
4. ✓ Tap "Fix all" con secret rotate → confirm OK → eseguito → app chiude DiagnosticView, apre PairingSheet
5. ✓ Re-pair completato → DiagnosticView ri-apre con summary fresh
6. ✓ Apri Panel `/setup` → vedi 4 badges + sezione "Help me choose"
7. ✓ Tap "Help me choose" → 4 risposte espanse
8. ✓ Tap risposta "I just want to test" → highlight pulse su card Quick
9. ✓ Card `claude_cli_installed` failing → tap → vedi hint + "Show full instructions" → tap → 3 step con copy actions
10. ✓ Auto-refresh durante autofix sospeso (no race), riprende dopo 2s

## Open Questions / Follow-ups

- **Telemetria autofix success rate**: utile per migliorare gli script. Da considerare quando ci saranno utenti.
- **Multi-platform fixers**: auto-fix di `claude_cli_authenticated` lancia `claude /login` ma su Linux server senza GUI fallisce. Detection del display environment.
- **Undo autofix**: per ora niente — tutti i fix sono o reversibili (riavviare un tunnel) o intentional (rotate secret).
- **Walkthrough multilingua**: italiano? Per ora EN-only per CLAUDE.md policy.
