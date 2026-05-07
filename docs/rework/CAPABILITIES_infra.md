# CAPABILITIES — Infra (MDM + GitHub Actions + Claude tooling)

Inventario di tutto ciò che vive fuori da `02_GIGI_APP/` (iOS) e `03_HARNESS/` (Node).
Repo source: `C:\Users\arman\Desktop\PROGETTI VIBE CODING\GIGI FOLDER\GIGI-main`.

Schema entry: **What** / **Files** / **Calls** / **Called by** / **Status** / **Removability** / **Note**.

---

## 1. `01_SERVER_MDM/` — Profilo MDM iOS

### CAP-MDM-01 · GIGI Automation MDM profile

- **What**: profilo `.mobileconfig` firmato che concede entitlement supervised (UIAccessibility, screen capture) per computer-use on-device. Installazione manuale via Apple Configurator 2 / Xcode / AirDrop.
- **Files**: `01_SERVER_MDM/gigi_profile_signed.mobileconfig` (binary signed), `01_SERVER_MDM/README.md` (istruzioni install/sign), `01_SERVER_MDM/.gitignore`.
- **Calls**: nessuno (file statico). Procedura sign documentata usa `openssl smime` + cert Apple Developer.
- **Called by**: utente finale che installa manualmente; OTA HTML flow in `public/index.html` punta a `https://killsiri.xyz/profiles/gigi_access_pro.mobileconfig` (file diverso, non quello in repo) tramite `vercel.json` headers.
- **Status**: **legacy/dormant**. Il pairing iPhone↔harness è migrato a QR code in commit `ca8a599` (Phase 4 ✅, vedi `docs/runbooks/pair-iphone.md`). Il profilo MDM **non** è coinvolto nel flow di pairing harness — serve solo se/quando si vorrà abilitare automation full-screen iOS-side (computer-use vision loop). **Non è ancora attivo** in MVP scope (vedi MVP scope = voice agent, non computer-use).
- **Removability**: **NON rimuovere** — capability future-ready, file binary <100KB, README chiaro. Da archiviare se a fine MVP non si attiva computer-use.
- **Verdict MDM server**: **legacy / dormant** — non è mai stato un "server" runtime, è uno static asset + procedura manuale. Sopravvive alla migrazione QR perché copre un caso d'uso ortogonale (automation supervised, non pairing).

### CAP-MDM-02 · OTA install landing page

- **What**: pagina HTML statica per OTA install (profilo accessibility + IPA via `itms-services://`).
- **Files**: `public/index.html`, `public/deploy/manifest.plist`, `vercel.json` (Content-Type headers per `.mobileconfig`/`.plist`/`.ipa`), `.vercelignore`.
- **Called by**: deploy Vercel su `killsiri.xyz`. Linka URL hardcoded `https://killsiri.xyz/profiles/gigi_access_pro.mobileconfig` e `https://killsiri.xyz/deploy/manifest.plist`.
- **Status**: **vivo** ma orfano dal main flow QR. Resta per dev distribution legacy o test sideload.
- **Removability**: **probabile dead** post-QR. Verificare se ancora referenziato in `docs/GETTING_STARTED.md`.

---

## 2. `.github/workflows/` — GitHub Actions (10 workflow)

### CAP-GHA-01 · `pr-lint.yml`

- **What**: valida titolo PR (Conventional Commits via `amannn/action-semantic-pull-request@v5`) + body (`Closes #N`, sezioni `## What`/`## Why`/`## Test plan` con almeno un checkbox). Posta o aggiorna PR comment "✅ PR Lint passed" / "❌ PR Lint failed".
- **Trigger**: `pull_request: [opened, edited, synchronize, reopened]`.
- **Calls**: `actions/github-script@v7`, `amannn/action-semantic-pull-request@v5`.
- **Status**: **vivo, attivo** (referenziato in `health-check.yml` come workflow monitorato).
- **Removability**: NO — gating PR.

### CAP-GHA-02 · `discord-notify.yml`

- **What**: webhook Discord rich embed per 7 trigger: comment su #19, bug aperto, release-blocker label, PR aperto/mergiato, issue chiusa/riaperta. Usa `secrets.DISCORD_WEBHOOK`.
- **Trigger**: `issue_comment`, `issues`, `pull_request`.
- **Calls**: `curl` + `jq` per payload JSON Discord.
- **Status**: **vivo, attivo**.
- **Removability**: NO.

### CAP-GHA-03 · `auto-timeline.yml`

- **What**: posta automaticamente eventi server-side su issue **#19 LIVE FEED** (PR opened/merged/closed/sync, bug opened, issue closed) **+** appende riga strutturata su `docs/memory/ACTIVITY_LOG.md` e committa su main con `secrets.PROJECT_TOKEN`. Retry rebase 3x per race condition.
- **Trigger**: `pull_request [opened, closed, ready_for_review, synchronize]`, `issues [opened, closed]`.
- **Status**: **vivo, attivo**. Sostituisce la chiamata AI (Haiku) che era nel hook `activity-log-summarize.sh` (ora deprecata).
- **Note**: a livello UX **duplica parzialmente** discord-notify (entrambi reagiscono a PR opened/merged + bug + issue closed) ma serve scopo diverso (timeline GitHub vs Discord embed).

### CAP-GHA-04 · `auto-blocked-label.yml`

- **What**: regex su body+ultimi 5 comment di una issue per pattern `Blocked by #N / Depends on #N / Waiting on/for #N / Aspetto #N / Stand-by finché #N`. Se almeno 1 ref è OPEN → applica label `blocked`.
- **Trigger**: `issues [opened, edited]`, `issue_comment [created, edited]`.
- **Status**: **vivo, attivo** (documentato in CLAUDE.md "Convention blocking dependency").

### CAP-GHA-05 · `auto-unblock.yml`

- **What**: sister di sopra. Su `issues:closed`, ricerca tutte le issue con label `blocked`, ri-esegue regex; se nessun altro ref OPEN rimane → rimuove label + posta clearance comment.
- **Trigger**: `issues [closed]`.
- **Status**: **vivo, attivo**.

### CAP-GHA-06 · `auto-clear-pr-blocking-marker.yml`

- **What**: scan PR open per marker HTML `<!-- BLOCKING:N,M -->` nei comment; se tutte le issue listate sono closed, posta `✅ All blocking issues resolved`.
- **Trigger**: `issues [closed]`.
- **Status**: **vivo, attivo**.

### CAP-GHA-07 · `progress-tracker.yml` (Matrioska)

- **What**: su sub-issue chiusa, GraphQL query parent (`issue.parent.number`) + count subIssues CLOSED/total. Posta progress `📈 N/M (P%)` su parent + #19. Se 100% → emoji 🏆 + auto-chiude la parent.
- **Trigger**: `issues [closed]` (skip #19).
- **Status**: **vivo, attivo**.

### CAP-GHA-08 · `project-status.yml`

- **What**: auto-move card Project v2 (`PVT_kwDOEKlBHc4BV0Bd`, status field `PVTSSF_lADOEKlBHc4BV0BdzhRNDOI`) su 10+ transizioni: issue opened→Backlog, assigned→Todo, closed→Done, reopened→Backlog, branch `feat/issue-N-*`→In Progress, PR opened/ready→In review, PR merged→Done, PR closed unmerged→Todo, label `post-mvp` add/remove → Post-MVP/Todo. Usa `secrets.PROJECT_TOKEN`.
- **Trigger**: `pull_request`, `create` (branch), `issues [opened, closed, reopened, assigned, labeled, unlabeled]`.
- **Status**: **vivo, attivo**.

### CAP-GHA-09 · `setup-post-mvp-status.yml`

- **What**: bootstrap one-shot. Crea l'option "Post-MVP" sul Project Status field se non esiste + backfill issue con label `post-mvp`.
- **Trigger**: `workflow_dispatch` (manuale).
- **Status**: **dormant** (one-shot già eseguito presumibilmente). Resta per disaster recovery.
- **Removability**: archiviabile dopo MVP.

### CAP-GHA-10 · `health-check.yml`

- **What**: cron 6:00 UTC (8:00 CET). Conta workflow OK ultime 24h + issue counts (open, P0, blockers, bug) + PR counts. Posta su Discord embed verde/rosso. Lista hardcoded workflow monitorati: `pr-lint.yml, discord-notify.yml, auto-timeline.yml, project-status.yml, progress-tracker.yml`.
- **Trigger**: `schedule: cron 0 6 * * *` + `workflow_dispatch`.
- **Status**: **vivo, attivo**.
- **Note**: la lista workflow monitorati **non include** auto-blocked / auto-unblock / auto-clear / progress-tracker / setup-post-mvp / health-check stesso → **gap di monitoring**.

---

## 3. `.github/ISSUE_TEMPLATE/` + PR template + CODEOWNERS

### CAP-GHT-01 · Issue templates

- **Files**: `bug.md`, `feature.md`, `parent-epic.md`, `sub-issue.md`, `config.yml` (disabilita blank issue, link Discussions).
- **Status**: vivo. Tutti referenziati in CLAUDE.md.

### CAP-GHT-02 · `PULL_REQUEST_TEMPLATE.md`

- **What**: template PR con sezioni `What / Why (Closes #) / How / Test plan / Checklist / Screenshots`. È quello validato da `pr-lint.yml`.
- **Status**: vivo.

### CAP-GHT-03 · `CODEOWNERS`

- **What**: review automatica per path. Default `@ArmandoBattaglino`. Path-specific: `/03_HARNESS/` → `@fc200490-sketch @ArmandoBattaglino`, `/02_GIGI_APP/` → `@Leonardo-Corte @ArmandoBattaglino`, `/01_SERVER_MDM/` → `@ArmandoBattaglino`, `/.claude/`+`/.github/` → `@ArmandoBattaglino`, ADR → Armando+Leo.
- **Status**: vivo.

---

## 4. `.claude/hooks/` — Claude Code hooks

### CAP-HOOK-01 · `session-start.sh`

- **What**: SessionStart hook. (1) Layer 1 auto-sync main (fetch + ff-only pull se branch=main+clean). (2) Cleanup: `git worktree prune` + segnala branch locali "gone". (3) Identifica dev da `git config user.name` + `dev-mapping.json` (Python case-insensitive substring). (4) Verifica `gh` auth + `CLAUDE.local.md`. (5) Fetcha issue assegnate + PR aperte via `gh`. (6) Stampa dashboard 3 colonne (🟢 ACTIONABLE / 🟡 WAITING / 🔴 PR REVIEW) + istruzioni vincolanti per Claude.
- **Calls**: `git`, `gh issue/pr list`, `python` inline.
- **Called by**: `.claude/settings.json` `SessionStart` hook.
- **Status**: **vivo, attivo**.

### CAP-HOOK-02 · `activity-log.sh` (Stop hook)

- **What**: Stop hook. Pre-filter veloce (anti-ricorsione `GIGI_LOG_HOOK_SUPPRESS`, `stop_hook_active`, transcript tail per side-effect Edit/Write/Bash). Se attività rilevata: spawn `activity-log-summarize.sh` in background con `nohup`/`disown`.
- **Called by**: `.claude/settings.json` `Stop` hook.
- **Status**: **vivo, attivo**.

### CAP-HOOK-03 · `activity-log-summarize.sh`

- **What**: background worker. **No-AI** (commenta storia: prima chiamava `claude -p --model haiku`, disabilitato 2026-04-28). Compose riga deterministica `branch + file modificati + ultimo commit` su `docs/memory/ACTIVITY_LOG.md` + autocommit (solo su branch ≠ main).
- **Called by**: `activity-log.sh` background spawn.
- **Status**: **vivo, attivo (no-AI)**.

---

## 5. `.claude/scripts/` — Script fire-and-forget per Claude

### CAP-SCRIPT-01 · `post-timeline.sh`

- **What**: posta comment formattato `[HH:MM] @dev · #N\n<emoji> details` su issue #19 LIVE FEED. 8 eventi: start/build_ok/build_fail/ac_verified/bug/pr_opened/merge/standby. **Zero AI**.
- **Called by**: `merge-pr.sh`, `reject-pr.sh`, e (per design) main Claude del dev tramite `nohup ... &`.
- **Status**: **vivo, attivo**.
- **Note**: CLAUDE.md indica "delega al subagent timeline-poster". **Subagent NON esiste in repo** (vedi sotto). Fallback diretto allo script funziona.

### CAP-SCRIPT-02 · `track-bug.sh`

- **What**: 3 azioni atomiche su AC fallito → (1) crea sub-issue assegnata dev+@ArmandoBattaglino label `bug,priority:P0,type:fix,area:<area>`, (2) comment parent, (3) comment #19. **Zero AI**.
- **Status**: **vivo**.
- **Note**: idem — CLAUDE.md indica subagent `bug-tracker`, **NON esiste**.

### CAP-SCRIPT-03 · `test-pr.sh` (PM PR review L3)

- **What**: 6-step. (1) fetch metadata PR. (2-3-4) delega 4 funzioni `lb_*` a `.claude/local-build.sh` (per-dev gitignored): `lb_sync_branch`, `lb_build_ios`, `lb_package_ipa`, `lb_cleanup`. (5) genera `review-checklists/pr-N.md` con sezioni L1-L5 (auto-spuntati L1+L3, manuali L4 smoke iPhone + L5 AC del PM). (6) verdetto + cleanup.
- **Called by**: `/routine-pr` skill, comando diretto del PM.
- **Status**: **vivo**.

### CAP-SCRIPT-04 · `merge-pr.sh`

- **What**: merge controllato. 3 safeguard: (1) checklist file deve esistere, (2) tutti i checkbox L1-L5 spuntati (parsing awk/grep), (3) decisione finale "TUTTI L1-L5 ✓" deve essere [x]. Approve PR + `gh pr merge --squash --delete-branch` (`--admin` opzionale). Post #19 + archive checklist in `.merged/`.
- **Status**: **vivo**.

### CAP-SCRIPT-05 · `reject-pr.sh`

- **What**: `gh pr review --request-changes` con body strutturato (motivo + checkbox falliti dalla checklist + hint dev). Post #19 standby + archive checklist in `.rejected/` + cleanup IPA via `lb_cleanup`.
- **Status**: **vivo**.

### CAP-SCRIPT-06 · `analyze-prs.sh`

- **What**: produce JSON ordinato di tutte le PR open con TIER 1-4 (urgent/high/med/low), chain detection (`Sub #N · X/Y`), blocks list, risk (low/med/high da diff size + check status). Logica heuristics su title + body keyword.
- **Called by**: `/routine-pr` STEP 2 smart prioritization.
- **Status**: **vivo**.

### CAP-SCRIPT-07 · `local-build.sh.example` (template)

- **What**: template gitignored per `.claude/local-build.sh`. 4 funzioni hook che `test-pr.sh` source-a: `lb_sync_branch / lb_build_ios / lb_package_ipa / lb_cleanup`. 3 esempi: Windows+SSH MacInCloud (Armando), Mac locale (Leo), harness-only no-iOS (Fede).
- **Status**: **vivo, template**.

---

## 6. `.claude/agents/` o equivalente

**Non esiste**. Cercato `.claude/agents/`, nessun file. Cercato glob `**/agents/**/*.md` → solo `03_HARNESS/docs/memory/agents/researcher.md` (off-scope, è un agent del harness Node, non un Claude Code subagent).

I subagent **`timeline-poster`** e **`bug-tracker`** referenziati in CLAUDE.md (workflow dev) come delegati Haiku **non sono mai stati materializzati**. Le call `Agent({subagent_type: "timeline-poster", ...})` falliscono → fallback documentato in CLAUDE.md è chiamare direttamente `post-timeline.sh` / `track-bug.sh`. **Capability gap**: la documentazione dice "delega al subagent (costo Haiku minimo)" ma di fatto si esegue lo shell script col main model che orchestra (più costoso ma funzionante).

---

## 7. Config Claude Code

### CAP-CFG-01 · `.claude/settings.json`

- **What**: registra `SessionStart` hook → `session-start.sh`, `Stop` hook → `activity-log.sh`. Schema da `json.schemastore.org`.
- **Status**: **vivo, attivo**. Tutti gli hook referenziati esistono.

### CAP-CFG-02 · `.claude/dev-mapping.json`

- **What**: mappa `git config user.name` → GitHub handle + role. 3 dev: Armando (PM), Leonardo (iOS lead), Federico (Harness lead). Match case-insensitive substring.
- **Called by**: `session-start.sh`.
- **Status**: vivo.

### CAP-CFG-03 · `.claude/commands/routine-pr.md`

- **What**: skill PM-only `/routine-pr` con gating (verifica `git config user.name` contiene "Armando"). Orchestra: analyze-prs → walk-through guidato per ogni PR (test-pr → review checklist L4/L5 → merge/reject).
- **Status**: vivo.

### CAP-CFG-04 · `settings.local.json`

- **Status**: **non esiste** in worktree (gitignored per design). OK.

---

## 8. Top-level scripts

### CAP-TOP-01 · `start-harness.sh`

- **What**: 5-line launcher. Exec `03_HARNESS/server/start-all.sh`. Off-scope per questo audit (harness).
- **Status**: vivo.

### CAP-TOP-02 · `bin/*.bat` (Windows launcher)

- **Files**: `1_START_ALL.bat / 2_STOP_ALL.bat / 3_STATUS.bat / 4_OPEN_SETUP.bat / 5_OPEN_PAIR_QR.bat / 6_LOGS.bat / README.md`.
- **What**: launcher Windows per harness + panel + cloudflared (porte 7779/7777). 1 = start, 2 = kill node+cloudflared, 3 = status check, 4-5 = open browser localhost, 6 = tail bridge.log.
- **Status**: vivo, doc dettagliata in `bin/README.md`.
- **Removability**: NO — è la UX "doppio click" dell'utente Windows.

### CAP-TOP-03 · `scripts/setup-project.sh`

- **What**: bootstrap GitHub Project v2 idempotente. Crea/trova "GIGI — Lancio v1" + 3 custom field (Priority, Effort, Area) + linka repo. Resto (views, iteration, workflow) è manuale browser.
- **Calls**: `gh project list/create/view/field-list/field-create/link`.
- **Status**: **dormant**. One-shot; eseguito presumibilmente. Resta per disaster recovery o re-bootstrap di un Project clone.

---

## 9. `docs/runbooks/` — 6 file

| File | TL;DR (1 riga) |
|---|---|
| `build-ipa.md` | Build IPA con Sideloadly per testare fix `.swift` su device fisico (post ogni modifica iOS) |
| `deploy-harness.md` | Deploy harness Node dal PC dell'utente a un VPS sempre acceso |
| `pair-iphone.md` | Primo setup pairing iPhone↔harness (o re-pair dopo redeploy tunnel) — flow QR Phase 4 |
| `qa-checklist.md` | Checklist test E2E obbligatori pre-release / pre-demo |
| `session-start-dashboard.md` | Spiegazione output del SessionStart hook + come marcare issue per finire in colonna giusta |
| `talk-to-gigi-universal-shortcut.md` | Setup Apple Shortcuts `gigi-talk-to-gigi-v3` |

---

## Risposte alle domande chiave

### MDM server vivo o morto post-QR?

**Verdict: legacy / dormant ma non morto.** Mai è stato un "server" runtime — è uno static `.mobileconfig` + procedura manuale di sign+install. Il pairing harness↔iPhone è interamente migrato a QR (`docs/runbooks/pair-iphone.md`, commit `ca8a599`); MDM **non era mai parte del pairing**. Sopravvive come capability future per abilitare automation supervised iOS-side (computer-use vision loop), che però non è in MVP scope. La pagina OTA `public/index.html` linka un `.mobileconfig` host esterno (`killsiri.xyz`) probabilmente orfano post-QR — candidato a cleanup separato.

### Action attive vs inutilizzate

**Tutte e 10 le actions sono attive su trigger reale**, eccetto:

- `setup-post-mvp-status.yml` — **one-shot dormant** (`workflow_dispatch` solo). Già eseguito presumibilmente. Archiviabile post-MVP.
- `health-check.yml` — vivo, ma la sua **lista hardcoded di workflow monitorati** (5 nomi) **manca** auto-blocked/unblock/clear/progress-tracker/setup-post-mvp/health-check stesso → falso senso di sicurezza.

### Hook Claude Code referenziati?

Sì, tutti: `session-start.sh` (SessionStart), `activity-log.sh` (Stop), e `activity-log-summarize.sh` (chiamato in background da activity-log.sh). Nessun hook orfano.

### Script duplicati / dead

- **Subagent stub mancanti**: `timeline-poster` + `bug-tracker` documentati in CLAUDE.md ma `.claude/agents/` **non esiste**. Le shell script `post-timeline.sh`/`track-bug.sh` sono il fallback di fatto — non duplicati ma documentazione disallineata.
- **Discord posting**: 2 path concorrenti che reagiscono agli stessi eventi (PR opened/merged, bug, issue closed/reopened):
  1. `discord-notify.yml` → embed Discord diretto
  2. `auto-timeline.yml` posta su #19 → `discord-notify.yml` cattura `issue_comment` su #19 → secondo embed Discord
  
  Non è un duplicato bug ma **double-fire** intenzionale (timeline narrativo + event embed). Rumore Discord da valutare.
- **Activity log**: 2 fonti (`auto-timeline.yml` server-side, `activity-log-summarize.sh` local Stop hook). Documentato in CLAUDE.md come "due fonti automatiche", non è un bug.

### Top-level dead

- `public/index.html` + `public/deploy/manifest.plist` + `vercel.json` — OTA install flow su `killsiri.xyz`. **Possibilmente orfano** post-QR pairing. Da verificare se ancora linkato in onboarding utente.
- `scripts/setup-project.sh` — one-shot già eseguito, può vivere come docs.
