# GATE 8 — Hardening + OSS release v0.1.0

> **Status**: Pending (richiede GATE 7 chiuso)
> **Effort stimato**: 5-7 giorni lavorativi
> **Bloccanti pre-gate**: GATE 7 chiuso (modes UI + setup wizard funzionanti); tutte le 10 AC del piano §8 misurabili; demo video script pronto (vedi piano §11 promessa demo)
> **Sblocca**: lancio v0.1.0, demo pubblico, OSS announcement
> **Funzione consegnata (1 frase)**: GIGI v0.1.0 è OSS-ready — i 10 acceptance criteria AC1-AC10 del piano sono tutti PASS, le 3 failure mode sono coperte, cancel/cookie/login auto-handling stabile, README pubblico + demo video 3-min + GETTING_STARTED + license compliance check + public issue tracker setup + tag git v0.1.0.

---

## 1. Obiettivo

Tutto il sistema 5-path è in piedi (GATE 2-6) con UI modes (GATE 7), ma serve hardening prima del go-live:
- 7 test E2E happy-path automatizzati / documentati
- 3 failure mode test
- Cancel mid-task funzionante cross-path
- Cookie banner / login auto-detect (regex pageText)
- README OSS-ready
- GETTING_STARTED chiaro
- Demo video 3-min ("Tesla → note" pattern)
- License compliance check (audit dependencies)
- Public issue tracker setup (template, labels, CONTRIBUTING aggiornato)
- Cleanup finale: rimuovere fisicamente `selectRelevant_DEPRECATED`, `_legacy/` può restare per traceability
- Tag release v0.1.0

---

## 2. Pre-condizioni

- [ ] GATE 0-7 tutti chiusi
- [ ] Killer demo Tesla→nota stabile (GATE 6 AC8 PASS)
- [ ] Mode switching live funzionante (GATE 7)
- [ ] Setup wizard idempotent
- [ ] Subscription Claude Code attiva per recording demo
- [ ] Equipment per registrazione video 3-min (iPhone + cattura schermo OR ScreenFlow Mac)

---

## 3. Task implementativi

- **Task 8.1 — 7 test E2E happy-path scriptati** (8h)
  - File: `docs/test-plans/e2e-happy-paths.md` (nuovo)
  - I 7 scenari del piano §8:
    1. **Path 1 fast** — "What time is it" → <200ms NLU
    2. **Path 2 Apple FM** — "Remind me to call Marco tomorrow at 10am" → ~2s
    3. **Path 3 Ollama reasoning** — "Explain Bayes in 3 sentences" → 7-12s
    4. **Path 3 Ollama summarize** — "Summarize this 200-word text" → 10-15s
    5. **Path 4 Claude Code reasoning** — "Write an apology email" → 10-20s
    6. **Path 4 Claude Code + browser** — "Search Wikipedia + create note Tesla" → 30-60s (killer demo)
    7. **Mode switching** — Full Power → Local-First → "search web" → graceful refusal
  - Per ognuno: prompt esatto, latency target, success criteria, comportamento atteso
  - Quando possibile, fornire script bash che invoca via API (per regression automation)

- **Task 8.2 — 3 failure mode test** (4h)
  - I 3 failure mode del piano §8:
    1. **Harness offline** — Path 3+4 unavailable, Path 1+2 funzionanti, mode auto degrade
    2. **Apple Intelligence disabled** — fallback rule-based router, Path 2 disabled, Path 1+3+4 funzionano
    3. **Ollama timeout** — auto-fallback Path 4 Claude Code con warning silenzioso
  - Documentare in `docs/test-plans/e2e-failure-modes.md`
  - Verificare cleanup graceful: nessun zombie subprocess, nessun crash UI

- **Task 8.3 — Cancel endpoint cross-path** (4h)
  - File: `02_GIGI_APP/GIGI/GigiHarnessClient.swift` + `03_HARNESS/server/api/ios-agent.js`
  - Endpoint unico `POST /api/ios/agent/cancel` con `{runId}` → routing interno al path corretto:
    - Path 3 Ollama: abort HTTP request via AbortController
    - Path 4 Claude Code: SIGTERM subprocess
    - Path 2 Apple FM: cancel `LanguageModelSession.respond` (Task cancellation Swift Concurrency)
  - iOS-side: long-press mic OR dedicated cancel button visible during streaming
  - Verifica: cancel mid-task → response stop immediately, NO subsequent text chunks

- **Task 8.4 — Cookie banner / login auto-detect** (5h)
  - File: `03_HARNESS/server/claude-runner.js` + custom MCP harness-browser tool
  - Detection regex per pageText comuni:
    - Cookie: `/accept.{0,10}cookies?|i agree|consent/i`
    - Login: `/sign in|log in|create account|password/i`
  - Su cookie detection: Claude Code auto-click "Accept" / "Reject all" (utente preference)
  - Su login detection: emit `confirm_required` event con screenshot + descrizione "Login required for this site. Skip or stop?"
  - Documentare in `docs/runbooks/cookie-login-handling.md`

- **Task 8.5 — README pubblico OSS-ready** (4h)
  - File: `README.md` (root del repo) — rewrite per OSS
  - Sezioni:
    1. **What is GIGI** — 1 paragrafo
    2. **Killer demo video** — link YouTube/Vimeo 3-min
    3. **Quick start (Minimal mode, 5 min setup)** — solo Claude Code
    4. **Full setup (Full Power mode, 30 min)** — Apple FM + Ollama + Claude Code
    5. **Architecture** — link `docs/HOW_GIGI_WILL_WORK.md` + diagramma 5-path
    6. **Hardware requirements** — table iPhone / Mac / RAM
    7. **Supported modes** — 4 modes recap
    8. **Privacy** — disclosure su PCC, Local-First, Cloud
    9. **Contributing** — link CONTRIBUTING.md
    10. **License** — link LICENSE
  - Inglese, tono neutro/welcoming, no jargon italiano

- **Task 8.6 — `docs/GETTING_STARTED.md` aggiornato** (3h)
  - Step-by-step per ognuno dei 4 mode
  - Screenshot dei setup screens iOS
  - Troubleshooting common issues

- **Task 8.7 — Demo video 3-min "Tesla → nota"** (6h)
  - Storyboard:
    - 0:00-0:15 — "What is GIGI" overlay text + tap-to-talk reveal
    - 0:15-0:30 — pronuncia query Tesla
    - 0:30-2:30 — schermo iPhone mostra thought bubbles + screenshot live
    - 2:30-2:50 — app Note iOS si apre, mostra nota creata
    - 2:50-3:00 — outro "Powered by Apple FM + Claude Code. Zero API costs."
  - Voice over inglese OR italiano con subtitle inglese (preferenza Armando)
  - Output: `docs/demo-video.mp4` (hosted YouTube/Vimeo + link in README)

- **Task 8.8 — License compliance audit** (3h)
  - Run `npm audit` su `03_HARNESS/`
  - Verifica licenses di tutte deps:
    - Permittere: MIT, Apache 2.0, BSD, ISC
    - Bloccare: GPL, AGPL (a meno di valutazione legale)
  - Verifica iOS SPM dependencies (rimuovere reliquie GoogleSignIn — già fatto in cleanup)
  - File `LICENSE` root (MIT proposed) — confermare con PM
  - File `THIRD_PARTY_LICENSES.md` con elenco deps + licenses

- **Task 8.9 — Public issue tracker setup** (3h)
  - File: `.github/ISSUE_TEMPLATE/` aggiornati per OSS pubblico (rimuovere refer interni Leo/Fede)
  - `CONTRIBUTING.md` aggiornato per external contributors
  - GitHub labels: `good-first-issue`, `help-wanted`, `bug`, `enhancement`, `documentation`
  - CODEOWNERS aggiornato

- **Task 8.10 — Cleanup `selectRelevant_DEPRECATED`** (1h)
  - File: `02_GIGI_APP/GIGI/GigiToolRegistry.swift`
  - Rimuovere fisicamente il metodo `selectRelevant_DEPRECATED` (verificato in GATE 3 AC14 che nessun caller lo usa più)
  - Rimuovere related dead code
  - `_legacy/` cartella resta come folder reference (storia conservata)

- **Task 8.11 — Tag release v0.1.0** (1h)
  - `git tag -a v0.1.0 -m "GIGI v0.1.0 — first OSS release"`
  - `git push origin v0.1.0`
  - Crea GitHub Release con changelog
  - Announce su Twitter / Hacker News / Reddit r/iOSProgramming (opzionale post-tag)

- **Task 8.12 — Esecuzione 10 test (AC1-AC10) del piano §8** (4h)
  - Documentare in `docs/test-plans/launch-ac-verification.md`

---

## 4. Acceptance Criteria (AC)

Questo GATE deve far PASSARE i 10 AC del piano §8:

- **AC1** — Chi clona Mode Minimal (Claude Code only) → Path 1+4 funzionanti in <15 min setup (verifica con cronometro fresh machine)
- **AC2** — Chi clona Mode Full Power (Apple Intelligence + Ollama + Claude Code) → 5 path attivi in <45 min setup
- **AC3** — Chi clona con iPhone non-Apple-FM → Path 1+3+4 funzionanti, Path 2 disattivato + badge "limited mode"
- **AC4** — Zero API key Anthropic/OpenAI nel `.env.example` (solo subscription Claude Code + Ollama HTTP local) — verifica con grep
- **AC5** — Latency P50 ≤2s su Path 1+2, ≤15s su Path 3, ≤30s su Path 4 reasoning, P95 ≤90s su Path 4 browser
- **AC6** — Cancel mid-task funziona su tutti i path
- **AC7** — Confirm gating mostra screenshot preview prima di azione distruttiva (Path 4 browser)
- **AC8** — Hello-world "Tesla → nota" funziona end-to-end, latency <90s (già verificato in GATE 6)
- **AC9** — Mode switching live (Settings) propaga a router senza restart app (già verificato in GATE 7)
- **AC10** — Cost-aware routing: query "explain X" va a Ollama se attivo, NON a Claude Code (verifica via WS event log)

Plus AC GATE 8-specifici:
- **AC8.1** — 7 test E2E happy-path documentati con PASS results
- **AC8.2** — 3 failure mode test documentati con graceful behavior
- **AC8.3** — Cookie banner auto-accept funziona su 5+ siti test (Google, Wikipedia, Amazon, NYT, BBC)
- **AC8.4** — Login auto-detect emette `confirm_required` su 3+ siti test
- **AC8.5** — README rewrite con sezioni 1-10
- **AC8.6** — Demo video 3-min pubblicato e linkato in README
- **AC8.7** — License audit completato, `THIRD_PARTY_LICENSES.md` esiste
- **AC8.8** — `selectRelevant_DEPRECATED` rimosso fisicamente da codebase
- **AC8.9** — Tag `v0.1.0` esiste su origin
- **AC8.10** — GitHub Release pubblicata con changelog

---

## 5. Test E2E sul telefono (verificabili dall'utente)

I 10 scenari del piano §8 + 3 failure mode:

- **E2E-1 (AC1 verifica)** — Macchina fresh, clone repo, setup Mode Minimal, prima query funzionante in <15 min totale
- **E2E-2 (AC2)** — Stesso ma Full Power in <45 min
- **E2E-3 (AC3)** — iPhone non-Apple-FM, Path 2 badge "limited mode" visible
- **E2E-4 (AC4)** — grep `.env.example` per anthropic|openai → 0 match
- **E2E-5 (AC5)** — 100 query mix, percentile latency verificate
- **E2E-6 (AC6)** — Cancel mid-task su ognuno dei 4 path
- **E2E-7 (AC7)** — Confirm sheet appare per destructive action (Amazon "Place Order")
- **E2E-8 (AC8)** — Tesla → nota end-to-end
- **E2E-9 (AC9)** — Cambia mode mid-session, prossima query rispetta nuovo mode
- **E2E-10 (AC10)** — 10 query reasoning consecutive, log conferma tutte a Ollama (NO Claude Code)

Plus failure mode:
- **E2E-11 (Failure A)** — Disconnect harness → 5 query → Path 1+2 OK, Path 3+4 graceful refusal
- **E2E-12 (Failure B)** — Disable Apple Intelligence → 5 query → fallback router gestisce
- **E2E-13 (Failure C)** — Ollama timeout → query reasoning → auto-fallback Path 4 silenzioso

---

## 6. Test post-creazione (verifica autonoma)

### 6.1 Verifica via grep

```bash
ROOT="C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework"

# 1. selectRelevant_DEPRECATED rimosso fisicamente
grep "selectRelevant_DEPRECATED" "$ROOT/02_GIGI_APP/GIGI/GigiToolRegistry.swift"
# Output atteso: 0 match

# 2. .env.example zero API keys
grep -iE "ANTHROPIC|OPENAI|GROQ|GEMINI" "$ROOT/.env.example" 2>/dev/null
# Output atteso: 0 match (a meno di comment "# do NOT set ANTHROPIC_API_KEY")

# 3. LICENSE esiste
ls "$ROOT/LICENSE"

# 4. THIRD_PARTY_LICENSES.md esiste
ls "$ROOT/THIRD_PARTY_LICENSES.md"

# 5. README rewrite (verifica sezioni)
grep -E "^## " "$ROOT/README.md" | wc -l
# Output atteso: >= 10 (sections)

# 6. Tag v0.1.0 esiste
cd "$ROOT"
git tag --list | grep "v0.1.0"
# Output atteso: v0.1.0

# 7. CONTRIBUTING.md aggiornato per OSS
grep -i "external contributors\|community" "$ROOT/CONTRIBUTING.md"

# 8. Demo video link in README
grep -iE "demo.*video|youtube|vimeo" "$ROOT/README.md"
```

### 6.2 Verifica via setup script fresh-clone

```bash
# Su macchina vergine (VM o WSL fresh):
git clone <repo>
cd gigi
bash scripts/setup-oss-demo.sh
# Output atteso: exit 0 in <15 min totali
```

### 6.3 Verifica via npm audit

```bash
cd "$ROOT/03_HARNESS"
npm audit
# Output atteso: 0 critical, 0 high vulnerabilities
```

### 6.4 Verifica via re-test AC1-AC10

Re-eseguire i 10 scenari E2E del piano §8 e confermare tutti PASS.

---

## 7. Rollback plan

Questo GATE è "polish + release". Se trovati bug critici post-tag v0.1.0:
- Hotfix v0.1.1 con `git revert <SHA-buggy>` + new tag
- NON pull `v0.1.0` da remote (immutable tag)

---

## 8. Files modificati / creati

| Path | Operazione | Righe stimate |
|---|---|---|
| `docs/test-plans/e2e-happy-paths.md` | CREATE | ~200 |
| `docs/test-plans/e2e-failure-modes.md` | CREATE | ~120 |
| `docs/test-plans/launch-ac-verification.md` | CREATE | ~150 |
| `02_GIGI_APP/GIGI/GigiHarnessClient.swift` | MODIFY (unified cancel) | +40 |
| `03_HARNESS/server/api/ios-agent.js` | MODIFY (unified cancel routing) | +60 |
| `03_HARNESS/server/claude-runner.js` | MODIFY (cookie/login auto-detect) | +80 |
| `docs/runbooks/cookie-login-handling.md` | CREATE | ~100 |
| `README.md` | REWRITE | ~250 (was variable) |
| `docs/GETTING_STARTED.md` | REWRITE | ~200 |
| `LICENSE` | CREATE (or verify) | ~20 |
| `THIRD_PARTY_LICENSES.md` | CREATE | ~80 |
| `.github/ISSUE_TEMPLATE/*` | MODIFY (OSS-public) | ~50 |
| `CONTRIBUTING.md` | UPDATE (external contributors) | +60 |
| `02_GIGI_APP/GIGI/GigiToolRegistry.swift` | MODIFY (remove deprecated) | -30 |
| `docs/demo-video.md` | CREATE (storyboard + link) | ~40 |

---

## 9. ADR collegati

- ADR-0001 to ADR-0011: tutti chiusi a questo punto
- Eventuale ADR-0013 "v0.1.0 release scope" se Armando vuole tracciare cosa è IN v0.1.0 vs deferred a v1.1

---

## 10. Note operative

- **Tempo realistico**: 5-7 giorni. Demo video può prendere 1 giorno (recording + editing).
- **Conventional Commits suggeriti**:
  ```
  test(e2e): GATE 8.1 — 7 happy-path scenarios documented
  test(e2e): GATE 8.2 — 3 failure mode scenarios
  feat(harness): GATE 8.3 — unified cancel endpoint cross-path
  feat(harness): GATE 8.4 — cookie banner / login auto-detect
  docs: GATE 8.5 — README OSS rewrite
  docs: GATE 8.6 — GETTING_STARTED v0.1.0
  docs: GATE 8.7 — demo video 3-min storyboard
  chore: GATE 8.8 — license compliance audit
  chore: GATE 8.9 — public issue tracker templates
  refactor(ios): GATE 8.10 — remove selectRelevant_DEPRECATED
  chore: GATE 8.11 — tag v0.1.0
  ```
- **Pre-launch checklist**:
  - [ ] All 10 AC PASS verified by 2 different testers
  - [ ] Demo video reviewed e approved da PM
  - [ ] README reviewed da non-tech person
  - [ ] Setup wizard tested on 3+ different machines (Mac, Linux, Windows+WSL)
  - [ ] License compliance signed off
  - [ ] No console.log() residui (grep)
  - [ ] No TODO P0 outstanding (grep)

### Cosa fare post-v0.1.0

Phase 5 backlog (opt-in, post-MVP, vedi piano §11):
- Codex CLI come Path 6 alternativa Claude Code
- TD-002 memoria unificazione
- Voice quality upgrade (TTS espressive)
- Watchers reactivation (morning briefing, meeting prep)
- SwiftMCP Path 2-fast (se Spike D PASS)

### Comunicazione lancio

- Twitter post da @ArmandoBattaglino
- Hacker News submission (peak time: Tuesday 9-11 AM PT)
- Reddit: r/iOSProgramming, r/MachineLearning, r/LocalLLaMA
- ProductHunt (opzionale)
- Demo recording + link a docs/demo-video.md
