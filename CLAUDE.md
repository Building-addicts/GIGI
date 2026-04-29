# GIGI — CLAUDE.md (team-shared)

> File committato, letto da ogni Claude/agente che apre il repo. Indice + regole, **non** manuale.
> Contesto dev privato (host SSH personali) → `CLAUDE.local.md` (gitignored).
> Sub-cartelle hanno il proprio CLAUDE.md (es. `03_HARNESS/CLAUDE.md`).

## TL;DR

Assistente vocale "True Agent" su iPhone (Swift/SwiftUI) che delega task a un harness Node.js sul PC. L'harness orchestra Claude (CLI + SDK), tiene memoria, fa push APNS, espone HTTP+WS via Cloudflare Tunnel.

## Dove guardare per cosa

| Devi… | Apri |
|---|---|
| **Scope MVP del lancio (cosa serve venerdì)** | **`docs/MVP_SCOPE.md`** |
| Capire l'architettura V3 | `docs/ARCHITETTURA_V3.md` |
| Piano integrazione harness | `docs/PIANO_INTEGRAZIONE_HARNESS.md` |
| Test E2E | `docs/TEST_E2E.md` |
| Onboarding utente / pairing / sideload | `docs/GETTING_STARTED.md` |
| Stato e task | `docs/TASK_PLAN.md` (autoritativo) |
| Backend Node (run, env, porte, endpoint) | `03_HARNESS/CLAUDE.md` + `03_HARNESS/README.md` |
| Spec API iOS↔harness | `03_HARNESS/docs/api/ios-integration.md` |
| Stack, vincoli, goal | `docs/memory/PROJECT.md` |
| Focus corrente | `docs/memory/CONTEXT.md` |
| Decisioni architetturali | `docs/adr/` (numerate, immutabili) |
| Cronologia attività (auto) | `docs/memory/ACTIVITY_LOG.md` (alimentato server-side da `auto-timeline.yml` su PR/issue events + opzionale local hook `Stop` no-AI) |
| Procedure ripetitive (build, deploy, pair) | `docs/runbooks/` |
| Ricerche tecniche | `docs/research/`, `docs/plans/` |
| Come contribuire (umano) | `CONTRIBUTING.md` |
| Review automatica per path | `.github/CODEOWNERS` |
| Quale file fa cosa (per funzione) | `docs/COMPONENTS.md` |
| Indice cartella docs | `docs/README.md` |
| **PM dashboard (Armando)** | `docs/PM_DASHBOARD.md` |
| **Live feed lavoro real-time** | issue [#19](https://github.com/Building-addicts/GIGI/issues/19) |
| **Kickoff message Leo+Fede** | `docs/KICKOFF_LEO_FEDE.md` (per Armando, da copiare in chat) |
| **Template issue (header 🎯/🔧/✨)** | `.github/ISSUE_TEMPLATE/{feature,sub-issue,parent-epic,bug}.md` |

## Layout monorepo

```
01_SERVER_MDM/  Node — profili MDM iOS
02_GIGI_APP/    Swift/SwiftUI — app iOS + Siri ext
03_HARNESS/     Node — Claude sessions, memoria, computer-use, APNS
docs/           TUTTI i doc project-level (architettura, piano, E2E, components,
                onboarding, task plan, memory/, plans/, research/, archive/)
```

Run rapido harness: `./start-harness.sh` → dettagli in `03_HARNESS/README.md`.

## Memoria progetto — checklist agente

**Session start:**
1. `docs/memory/PROJECT.md`, `CONTEXT.md`
2. `docs/TASK_PLAN.md` per piano dettagliato
3. CLAUDE.md della sub-cartella se applicabile (es. `03_HARNESS/CLAUDE.md`)
4. `ACTIVITY_LOG.md` **NON serve leggerlo** — è alimentato automaticamente dall'hook e serve solo a te per ispezione manuale

**Session end:**
1. Decisione architetturale presa → nuovo file `docs/adr/NNNN-titolo.md` (formato in `docs/adr/0000-template.md`)
2. Cambio focus → aggiorna `CONTEXT.md`
3. Procedura operativa nuova/cambiata → aggiungi/aggiorna `docs/runbooks/<nome>.md`
4. Tutto il resto (cronologia attività, file toccati, riassunto turno) → due fonti automatiche per `ACTIVITY_LOG.md`:
   - **Server-side (sempre attiva, no AI)**: `auto-timeline.yml` appende su ogni evento PR/issue, indipendente dall'IDE del dev
   - **Local hook (opzionale, no AI)**: hook `Stop` di Claude Code appende riga grezza con branch + file modificati + ultimo commit message

Niente memorie per-agente: l'utente è solo, agenti paralleli rari, `ACTIVITY_LOG.md` automatico è la sola fonte cronologica.

## Regole operative

- **Bug** → chiama subito **debugger**. Root cause prima del fix. Se rivela un'assunzione sbagliata, aggiorna `DECISIONS.md`.
- **Loop / task ricorrente** → **NON** `ScheduleWakeup`. Crea watcher in `03_HARNESS/server/watchers.json` (chiedi sempre frequenza polling). Dettagli in `03_HARNESS/CLAUDE.md` §"Regola: loop → watcher".
- **iOS build verify** → ogni task che modifica `.swift` DEVE essere seguito da xcodebuild filtrato per errori prima di dichiararsi completo. Workflow di build (host, comandi) personale → `CLAUDE.local.md` di ciascun dev.
- **Mai dichiarare "fix iOS testato"** senza nuovo IPA installato sul device fisico. Simulatore non copre audio/VAD.
- **Convenzioni:** Swift = SwiftUI-first, `@MainActor` su ViewModel, naming `Gigi*`. Node = v20+, ES modules, no TS, route `ios-*`. Commit: Conventional Commits.
- **🌍 Lingua — regola dura:**
  - **TUTTO ciò che è user-facing nell'app DEVE essere in INGLESE.** L'app è per mercato worldwide. Include: stringhe UI (Text, Label, Button, alert), TTS output di GIGI, copy onboarding, error message visibili all'utente, push notification, Dynamic Island label, accessibility hints, App Store metadata.
  - **Italiano consentito solo nel "backstage":** doc interni (`docs/`), commenti codice, commit message, body issue/PR, log harness, ADR, `CLAUDE.md`, comunicazione team.
  - **Inglese tecnico:** spec API (request/response field, error code), nomi variabili/funzioni/classi, log structured (`logger.info("user_speech_detected", ...)`).
  - Se aggiungi una stringa user-facing in italiano per "fretta": va trattata come bug, sub-issue P1 immediata.
  - LLM prompt (system + user templates) → **inglese** (l'utente parla inglese a GIGI nella demo internazionale; il fatto che noi 3 testiamo in italiano è secondario).

## Workflow per dev (vibe-coder mode) ⭐

> **Questa sezione è LETTA dal Claude del dev**. Sono istruzioni vincolanti su come Claude deve guidare il dev attraverso una settimana di issue assegnate.

### Principio di design — frizione zero

Il dev (Leo, Fede) **non interagisce direttamente con git, GitHub UI, branch, PR**. Apre Claude Code, dice "sì/vai/ok" alle proposte, e Claude fa tutto sotto. PM (Armando) interviene **solo** per review PR + decidere casi ambigui.

### Format issue obbligatorio — header 🎯/🔧/✨

**Tutte** le issue (parent epic + sub-issue + feature standalone) iniziano con 3 sezioni human-first:

```markdown
## 🎯 Cosa stiamo facendo (context)
1-2 frasi italiano, no jargon. Dove siamo nel progetto e PERCHÉ questa issue esiste.

## 🔧 Cosa implementerà il dev
3-5 bullet concreti, NO file path, NO codice. Cosa cambia funzionalmente.

## ✨ Risultato atteso (cosa cambia per l'utente / per la pipeline)
1 frase concreta lato utente finale (per UI-facing) o cosa SBLOCCA (per infra).
```

Sotto questo blocco, i dettagli tecnici (Target files, Changes, Build verify, AC, Test E2E, Merge conditions). Quando crei una nuova issue **usa SEMPRE** uno dei template in `.github/ISSUE_TEMPLATE/`. Mai issue vuote.

Il **Test E2E utente** deve rispecchiare letteralmente il "Risultato atteso" come AC#1 — dev e PM verificano la stessa promessa.

### Flusso completo per ogni issue (da seguire alla lettera)

#### 1. Onboarding sessione (auto via SessionStart hook)
All'apertura, l'hook ti dà già:
- nome del dev + handle GitHub (da `.claude/dev-mapping.json`)
- **dashboard a 3 colonne** delle issue assegnate + PR aperte del repo
- istruzioni vincolanti (riassunte qui)

Il dashboard si compone di 3 sezioni (max 3+3+2 = 8 righe totali):

| Colonna | Cosa mostra | Quando proporla al dev |
|---|---|---|
| 🟢 **ACTIONABLE NOW** | Issue open senza dipendenze attive — ordinate per priorità (release-blocker → P0→P3) | Sempre. Proponi la prima al dev |
| 🟡 **WAITING** | Issue con label `blocked` esplicita — bloccate da dipendenze | Skip. Mostra ma NON proporre come "iniziamo" |
| 🔴 **PR IN REVIEW** | Tutte le PR aperte del repo (visibili a tutti i dev) — `[👤 PR #N]` per le PR del dev attuale | Per visibilità + eventuale review. Non sono "issue da iniziare" |

**Tu (Claude del dev)** saluti per nome e proponi la **prima issue in 🟢 ACTIONABLE**. Esempio:
> "Ciao Leo 👋 Hai 4 issue assegnate. La prossima actionable è #9 — Dynamic Island descent. Vuoi iniziare? (rispondi 'sì')"

Se 🟢 è vuoto (tutte le issue del dev sono blocked), comunicalo:
> "Tutte le tue issue sono bloccate da dipendenze. Vuoi vedere la lista 🟡 waiting per un check rapido?"

**Convention per finire in colonna giusta**:
- Per mettere issue in 🟡 WAITING: aggiungi label `blocked` (manuale dal PM/dev)
- Per togliere da 🟡: rimuovi label `blocked` quando dipendenza è risolta
- Marker comment `<!-- BLOCKING:N,M -->` su PR è già in uso per blocking comments (vedi #127), ma NON viene parsato dal session-start (sarebbe troppo costoso fetchare comment di ogni issue). Per ora basta label esplicita.

Vedi `docs/runbooks/session-start-dashboard.md` per troubleshoot.

#### 2. Avvio lavoro (su "sì" del dev)

```bash
# Slug per il branch: numero issue + 2-3 parole chiave del titolo, lowercase, dash
SLUG="issue-<N>-<short-slug>"   # es: issue-9-di-descend
WORKTREE="$CLAUDE_PROJECT_DIR/../GIGI-work/$SLUG"

# ⭐ LAYER 2 SYNC: pull main fresh PRIMA di creare worktree
# Garantisce che il worktree parta dall'ultimo main mergiato dal PM
cd "$CLAUDE_PROJECT_DIR"
git checkout main
git pull origin main --ff-only

# Worktree isolato — main resta intatto, no conflitti tra issue parallele
git worktree add "$WORKTREE" -b "feat/$SLUG" main
cd "$WORKTREE"

# Leggi il body completo della issue
gh issue view <N> --repo Building-addicts/GIGI
```

Mostra al dev il **piano** estratto dal body della issue:
- File che modificherai (citati nel body)
- Cambi principali (lista numerata)
- Comando build verify che eseguirai
- Acceptance Criteria che il dev dovrà verificare a mano dopo

**ASPETTA conferma del dev prima di toccare codice**.

#### 3. Sviluppo
- Modifica solo i file dichiarati nel body issue
- Se devi toccare file NON dichiarati: chiedi al dev "questa modifica esce dallo scope, OK?"
- Commit incrementali in italiano + Conventional Commits, es. `feat(ios): aggiungi descendForListening (Refs #9)`

#### 4. Build verify
- iOS: lancia il comando `xcodebuild` esatto specificato nella issue (richiede SSH MacInCloud — ogni dev configura nel suo `CLAUDE.local.md`)
- Node: `npm test` o test specifico
- **Se BUILD FAILED**: NON proseguire. Mostra l'errore, proponi fix, riprova.

#### 5. Test E2E utente — OBBLIGATORIO
**Niente shortcut su questo step.**

Mostra al dev la checklist degli Acceptance Criteria del body issue, in formato:
```
Devi testare manualmente sul device. Conferma VERO/FALSO per ognuno:
[ ] AC #1: <descrizione>
[ ] AC #2: <descrizione>
[ ] AC #3: <descrizione>

Rispondi: "1=sì, 2=sì, 3=no" (o varianti)
```

**Aspetta la risposta esplicita del dev**. Niente "sembra ok" generico.

#### 6. Quando un AC è FALSO

**APRI SEMPRE una sub-issue** (regola non-negoziabile, anche se il dev dice "lo fixo subito"):

```bash
gh issue create --repo Building-addicts/GIGI \
  --title "[BUG] #<N> AC#<X> — <breve descrizione>" \
  --label "bug,priority:P0,type:fix,area:<area>" \
  --assignee "<dev_handle>" \
  --body "$(...body con: parent linked, AC fallito, parole esatte del dev, file probabili coinvolti, commit/PR di tentativo...)"
```

Il body deve includere:
- `Parent: #<N>`
- Quote esatta della parola del dev ("pill resta su Thinking")
- File ipotizzati coinvolti
- Link al PR in lavorazione (se aperto)
- `cc @ArmandoBattaglino` per ping PM

Comunica al dev:
> "🐛 Tracciato come #<X> (parent: #<N>, label `bug`, P0). PM avvisato.
>  Vuoi che lo fixi ora su questo PR? (sì = lavoro / no = lascio in stand-by)"

#### 7. PR (quando tutti gli AC sono VERI)

```bash
git push -u origin "feat/$SLUG"

# Crea PR — body usa il template auto-precompilato di .github/PULL_REQUEST_TEMPLATE.md
# Aggiungi sempre `Closes #<N>` per chiudere automaticamente al merge
gh pr create --repo Building-addicts/GIGI \
  --title "<Conventional Commits style>" \
  --body "Closes #<N>

## What
<...>

## Why
<...>

## Test plan
- [x] AC #1 verificato dal dev su device fisico
- [x] AC #2 verificato dal dev
- [x] Build verify: BUILD SUCCEEDED
"
```

Comunica al dev:
> "PR #<num> aperto. @ArmandoBattaglino taggato per review.
>  Vuoi iniziare la prossima (#<altra>) in un altro worktree mentre aspetti? Rispondi 'sì' o 'aspetto'."

#### 8. Merge (su "merge" del dev)

```bash
# Verifica check verdi + approval esplicito @ArmandoBattaglino
gh pr view <num> --json reviewDecision,statusCheckRollup
# Procedi solo se reviewDecision == "APPROVED" e tutti gli statusCheckRollup sono SUCCESS

gh pr merge <num> --squash --delete-branch

# Cleanup completo (locale + worktree + ref remoti)
cd "$CLAUDE_PROJECT_DIR"
git worktree remove "$WORKTREE"
git branch -D "feat/$SLUG"             # ← branch locale (squash crea commit diverso, serve -D)
git fetch origin --prune               # ← rimuove ref morti su origin
git pull origin main --ff-only         # ← aggiorna main locale
```

> "Mergiato e pulito. Vuoi prossima issue (#<altra>)? Rispondi 'sì'."

### Timeline commenti su #19 (LIVE FEED) — visibilità PM real-time

A ogni passo significativo del lavoro, **DELEGA al subagent `timeline-poster`** (Haiku, costo minimo). Non scrivere il commento direttamente col modello principale (spreco di token).

Usa il tool Agent:
```
Agent({
  subagent_type: "timeline-poster",
  prompt: "dev=<handle>, issue=<N>, event=<start|build_ok|build_fail|ac_verified|bug|pr_opened|merge|standby>, details=<una riga>"
})
```

Equivalente a:
```bash
gh issue comment 19 --repo Building-addicts/GIGI --body "[$(date '+%H:%M')] @<git_user_handle> · #<issue_num>
<emoji> <una riga di stato>"
```

Eventi da loggare (uno per uno, mai in bulk):

| Quando | Emoji | Esempio body |
|---|---|---|
| Inizio lavoro issue | 🚀 | `🚀 Inizio #9 (worktree feat/issue-9-di-descend)` |
| Build OK | ✅ | `✅ Build SUCCEEDED su #9` |
| Build fallito | ❌ | `❌ Build FAILED su #9 — error in <file:line>, indago` |
| Test E2E AC passa | 🟢 | `🟢 #9 AC1+AC2 verificati dal dev su iPhone 15 Pro` |
| **Bug trovato** (sub-issue creata) | 🐛 | `🐛 #9 AC#3 fallito → sub-issue #43 aperta. cc @ArmandoBattaglino` |
| PR aperto | 📤 | `📤 PR #44 per #9 aperto, attesa review` |
| Merge | 🎉 | `🎉 #9 mergiato. Worktree pulito.` |
| Pausa / blocco | ⏸️ | `⏸️ #9 in stand-by per <motivo>` |

**Niente commento → PM cieco. Sempre commento prima di passare al passo successivo.**

### Notifica forte PM su sub-issue bug (regola rinforzata)

Quando un AC è FALSO, **DELEGA al subagent `bug-tracker`** (Haiku, costo minimo). Lui esegue le 3 azioni atomiche:
1. Sub-issue creata (assegnata a dev + Armando, `cc @ArmandoBattaglino` nel body)
2. Comment sulla issue parent (cc Armando)
3. Comment su #19 LIVE FEED

Usa il tool Agent:
```
Agent({
  subagent_type: "bug-tracker",
  prompt: "parent_issue=<N>, ac_number=<X>, ac_description=<...>, dev_handle=<handle>, dev_words=\"<parole esatte del dev>\", suspected_files=[<lista>], pr_num=<num o vuoto>, area=<ios|harness|mdm|docs|infra>"
})
```

Solo dopo che il subagent torna successo, comunichi al dev:
> "🐛 Tracciato come #X (parent: #N, label `bug`, P0). Vuoi fixare ora o lasciare in stand-by?"

### Sync main durante worktree lungo (Layer 3 — anti-conflict)

Se il dev sta lavorando su un worktree da >2 ore, **prima di aprire la PR** controlla quanto main è avanti:

```bash
# Dentro al worktree del dev
git fetch origin main
BEHIND=$(git rev-list --count HEAD..origin/main)
echo "Worktree dietro main di $BEHIND commit"
```

Soglie di azione:
- `BEHIND ≤ 5` → procedi normalmente, conflict trascurabile
- `BEHIND 6-15` → comunica al dev: *"⚠️ main si è mosso di N commit dal worktree start. Faccio `git merge origin/main` qui per integrare prima della PR? (sì = sicuro, NO force push)"*. Se il dev dice sì, esegui:
  ```bash
  git merge origin/main
  # se conflitti: risolvi con il dev, poi git add . && git commit
  ```
- `BEHIND >15` → blocco strong: *"main è significativamente avanti. Pause + chiama @ArmandoBattaglino per decidere se mergiare ora o finire la sub-issue su questo branch e accettare conflitti su PR."*

**⛔ MAI usare `git rebase main`** anche se sembra "più pulito" — i 6 rischi (force push, history rewrite, multi-round conflicts, lost commits, force push warning su PR GitHub, anti-pattern Git) sono peggiori del merge commit visibile. Lo squash merge alla chiusura della PR appiattisce comunque tutto in 1 commit su main, quindi il merge commit del worktree non sopravvive.

### Processo di review PR (PM only — `/routine-pr`)

Per il PM (Armando) esiste una **skill dedicata** `/routine-pr` che guida la sessione di review delle PR aperte. Garanzie built-in:

- **Smart prioritization**: TIER 1-4, chain dependencies, blocks, risk → ordine ottimale
- **5 livelli di test** (L1 CI auto, L2 code review, L3 build verify auto, L4 smoke iPhone, L5 AC manuali)
- **Safeguard**: `merge-pr.sh` rifiuta se `review-checklists/pr-N.md` ha checkbox non spuntati
- **Universale**: comandi build/SSH/scp delegati a `.claude/local-build.sh` (per-PM, gitignored — copia da `local-build.sh.example`)

**Setup una volta**:
```bash
cp .claude/local-build.sh.example .claude/local-build.sh
# adatta le 4 funzioni lb_sync_branch / lb_build_ios / lb_package_ipa / lb_cleanup
# al tuo ambiente (Windows+SSH, Mac locale, ecc.)
```

**Uso**:
```
/routine-pr           # entrare in routine guidata
# o uso diretto degli script:
bash .claude/scripts/test-pr.sh <N>      # fetch + build + IPA + checklist
bash .claude/scripts/merge-pr.sh <N>     # merge controllato (richiede checklist completata)
bash .claude/scripts/reject-pr.sh <N> "<motivo>"  # request changes strutturato
```

Worktree: il PM **non usa worktree** durante review (lavora sempre su main del repo principale, sync read-only via `gh pr` + SSH delegate). I worktree sono solo per i dev che scrivono codice.

### Step Report obbligatorio prima del merge (regola "matrioska")

Ogni sub-issue chiusa è **un avanzamento esplicito** verso il completamento della parent, e ogni parent verso il lancio MVP. Il merge non è "ok finito" — è un **passo celebrato**.

Prima di chiamare `gh pr merge`, il main Claude del dev DEVE:

1. **Generare uno Step Report narrativo** (3-5 righe in italiano), con queste 3 sezioni esatte:
   - **Cosa abbiamo implementato**: 1 paragrafo concreto, no jargon
   - **Cosa è ora possibile** che prima non era: 1 frase
   - **Prossimo passo logico**: nome della prossima sub-issue da prendere o "parent ora al X%, manca Y"
   
2. **Postare lo Step Report come comment sul PR** (non sostituire il body, AGGIUNGERE comment) prima del merge:
   ```
   gh pr comment <num> --body "## Step Report
   
   **Cosa abbiamo implementato**: ...
   
   **Cosa è ora possibile**: ...
   
   **Prossimo passo**: ...
   "
   ```

3. **Dopo il merge** (auto via `Closes #N`):
   - L'Action `progress-tracker.yml` posta automaticamente sulla parent issue il progress aggiornato (X/Y sub chiuse, %)
   - Se parent al 100%: posta 🏆 EPIC COMPLETATA + auto-chiude la parent
   - Tutto questo finisce su Discord via auto-timeline + Discord notify (zero lavoro extra del dev)

4. **Comunica al dev** in chat l'incremento:
   - "Sub-issue #X chiusa, parent #Y ora al Z%. Vuoi prendere la prossima sub (#W)?"

### Esempio Step Report

> ## Step Report
>
> **Cosa abbiamo implementato**: il metodo `descendForListening()` su `GigiLiveActivityController` che termina la pill standby e richiede una nuova activity in stato `.listening` con `AlertConfiguration`. È un building block puro — non lo chiama ancora nessuno.
>
> **Cosa è ora possibile**: la sub-issue 2/4 può ora wirearlo al wake event in `GigiWakeWordEngine`, sbloccando il primo pezzo visibile della Dynamic Island descent.
>
> **Prossimo passo**: aprire la sub #25 (2/4) — wire `descendForListening()` al callback wake. Parent #9 ora al 25% (1/4).

### Suggerimento `/clear` (NON regola obbligatoria, solo soft tip)

Se ti accorgi spontaneamente che la chat è molto lunga (es. hai fatto >10 tool calls significativi, hai chiuso 3+ issue, senti il context "denso"), **puoi** suggerire al dev di fare `/clear` per ripartire pulito.

**Linguaggio naturale**, non rigido:
> "Sento la chat un po' lunga, se vuoi pulire con `/clear` ripartiamo freschi. Ma non è urgente — continua pure."

⚠️ **NON eseguire `/clear` da solo**, mai. Solo proposta passiva. Il dev decide.
⚠️ **NON imporre soglie** — ogni `/clear` rilancia il SessionStart hook che ricarica context, e ricaricare ogni 5 minuti drena la quota subscription dei dev. Suggerisci solo se DAVVERO senti che ne vale la pena.

### Regole non-negoziabili (DO NOT BREAK)

1. **Mai** lavorare su `main` direttamente. Sempre worktree dedicato.
2. **Mai** mergiare senza tutti gli AC confermati VERO esplicitamente dal dev su device fisico.
3. **Mai** chiudere il loop AC-fail senza creare la sub-issue prima + 3 notifiche (vedi sopra).
4. **Mai** skippare il build verify ("sembra ok dal codice" non basta).
5. **Mai** modificare file fuori dallo scope della issue senza chiedere al dev.
6. **Mai** fare commit/push/PR/merge senza spiegare al dev cosa stai per fare.
7. **Mai** completare un passo senza commento timeline su #19.

### Test sicurezza autonomia

Se il dev ti dice qualcosa di rischioso/ambiguo (es. "fai tu", "decidi tu"), il default è **chiedere chiarimento**, non procedere a indovinare. Frizione zero ≠ autonomia totale.

### Mappa file rilevanti per questo workflow

**Hooks Claude Code:**
- `.claude/hooks/session-start.sh` — onboarding sessione (riconosce dev, mostra issue)
- `.claude/hooks/activity-log.sh` + `activity-log-summarize.sh` — log automatico turno via Haiku
- `.claude/dev-mapping.json` — name git → GitHub handle
- `.claude/settings.json` — registrazione hook

**Script fire-and-forget (Haiku, no token main):**
- `.claude/scripts/post-timeline.sh` — comment su #19 LIVE FEED (8 eventi)
- `.claude/scripts/track-bug.sh` — 3 azioni atomiche su AC fallito (sub-issue + comment parent + comment #19)

**GitHub Actions (`.github/workflows/`):**
- `pr-lint.yml` — verifica conventional commits + AC checklist nel PR body
- `discord-notify.yml` — webhook Discord rich embed (issue/PR/bug/progress)
- `auto-timeline.yml` — cross-post eventi GitHub su #19
- `project-status.yml` — muove card su Project board (Backlog→In Progress→Done)
- `progress-tracker.yml` — % matrioska parent + 🏆 auto-close al 100%
- `health-check.yml` — cron 8:00 CET, posta su Discord stato sistema

**Template GitHub:**
- `.github/ISSUE_TEMPLATE/feature.md` — feature singola
- `.github/ISSUE_TEMPLATE/parent-epic.md` — epic con sub-issue
- `.github/ISSUE_TEMPLATE/sub-issue.md` — granularità X/Y di parent #N
- `.github/ISSUE_TEMPLATE/bug.md` — bug report
- `.github/ISSUE_TEMPLATE/config.yml` — disabilita blank issue
- `.github/PULL_REQUEST_TEMPLATE.md` — template PR
- `.github/CODEOWNERS` — review automatica per path

---

## Stato corrente (2026-04-27)

**Settimana lancio MVP** — deadline **venerdì 1 maggio 2026**. Code freeze mercoledì 30 ore 16:00 (QA gate #17), demo venerdì.

Board GitHub: 51 issue strutturate + linkate native:
- **13 PARENT epic** (#10-#18 + #76-#79) con header 🎯/🔧/✨
- **38 SUB-ISSUE** granulari (#38-#75) linkate ai rispettivi parent
- **#17** = QA gate (7 sub) · **#18** = demo script + storyboard (5 sub)

Distribuzione: Leo 19 issue (iOS app + Dynamic Island + WhatsApp + NLU + Active Help), Fede 20 (Preferences + Day Plan + Resilience + Permission UI + Memory), condivise #17/#18.

Foundation pre-lancio: Phase 1 Claude bridge ✅ (2026-04-25), Phase 4 QR pairing ✅ (`ca8a599`). Blocker U0 storico (sideload + Tailscale on-device) risolto.

Per dettaglio sub-issue: `gh issue list --repo Building-addicts/GIGI`. Per PM dashboard: `docs/PM_DASHBOARD.md` + LIVE FEED [#19](https://github.com/Building-addicts/GIGI/issues/19).
