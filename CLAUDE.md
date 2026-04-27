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
| Cronologia attività (auto) | `docs/memory/ACTIVITY_LOG.md` (alimentato dall'hook `Stop`) |
| Procedure ripetitive (build, deploy, pair) | `docs/runbooks/` |
| Ricerche tecniche | `docs/research/`, `docs/plans/` |
| Come contribuire (umano) | `CONTRIBUTING.md` |
| Review automatica per path | `.github/CODEOWNERS` |
| Quale file fa cosa (per funzione) | `docs/COMPONENTS.md` |
| Indice cartella docs | `docs/README.md` |
| **PM dashboard (Armando)** | `docs/PM_DASHBOARD.md` |
| **Live feed lavoro real-time** | issue [#19](https://github.com/Building-addicts/GIGI/issues/19) |

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
4. Tutto il resto (cronologia attività, file toccati, riassunto turno) → l'hook `Stop` appende automaticamente a `ACTIVITY_LOG.md` via Haiku 4.5

Niente memorie per-agente: l'utente è solo, agenti paralleli rari, `ACTIVITY_LOG.md` automatico è la sola fonte cronologica.

## Regole operative

- **Bug** → chiama subito **debugger**. Root cause prima del fix. Se rivela un'assunzione sbagliata, aggiorna `DECISIONS.md`.
- **Loop / task ricorrente** → **NON** `ScheduleWakeup`. Crea watcher in `03_HARNESS/server/watchers.json` (chiedi sempre frequenza polling). Dettagli in `03_HARNESS/CLAUDE.md` §"Regola: loop → watcher".
- **iOS build verify** → ogni task che modifica `.swift` DEVE essere seguito da xcodebuild filtrato per errori prima di dichiararsi completo. Workflow di build (host, comandi) personale → `CLAUDE.local.md` di ciascun dev.
- **Mai dichiarare "fix iOS testato"** senza nuovo IPA installato sul device fisico. Simulatore non copre audio/VAD.
- **Convenzioni:** Swift = SwiftUI-first, `@MainActor` su ViewModel, naming `Gigi*`. Node = v20+, ES modules, no TS, route `ios-*`. Lingua: italiano nei doc/commenti, inglese nelle spec API tecniche. Commit: Conventional Commits.

## Workflow per dev (vibe-coder mode) ⭐

> **Questa sezione è LETTA dal Claude del dev**. Sono istruzioni vincolanti su come Claude deve guidare il dev attraverso una settimana di issue assegnate.

### Principio di design — frizione zero

Il dev (Leo, Fede) **non interagisce direttamente con git, GitHub UI, branch, PR**. Apre Claude Code, dice "sì/vai/ok" alle proposte, e Claude fa tutto sotto. PM (Armando) interviene **solo** per review PR + decidere casi ambigui.

### Flusso completo per ogni issue (da seguire alla lettera)

#### 1. Onboarding sessione (auto via SessionStart hook)
All'apertura, l'hook ti dà già:
- nome del dev + handle GitHub (da `.claude/dev-mapping.json`)
- lista delle sue issue aperte assegnate, ordinate per priorità (release-blocker → P0 → P1 → P2 → P3)
- istruzioni vincolanti (riassunte qui)

**Tu (Claude del dev)** saluti per nome e proponi la **prima** issue in cima. Esempio:
> "Ciao Leo 👋 Hai 4 issue aperte. La più urgente è #9 — Dynamic Island descent. Vuoi iniziare? (rispondi 'sì')"

#### 2. Avvio lavoro (su "sì" del dev)

```bash
# Slug per il branch: numero issue + 2-3 parole chiave del titolo, lowercase, dash
SLUG="issue-<N>-<short-slug>"   # es: issue-9-di-descend
WORKTREE="$CLAUDE_PROJECT_DIR/../GIGI-work/$SLUG"

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

# Cleanup worktree
cd "$CLAUDE_PROJECT_DIR"
git worktree remove "$WORKTREE"
git pull origin main
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

- `.claude/hooks/session-start.sh` — onboarding sessione
- `.claude/hooks/activity-log.sh` + `activity-log-summarize.sh` — log automatico turno
- `.claude/dev-mapping.json` — name git → GitHub handle
- `.claude/settings.json` — registrazione hook
- `.github/PULL_REQUEST_TEMPLATE.md` — template PR
- `.github/CODEOWNERS` — review automatica per path

---

## Stato corrente (2026-04-27)

Phase 1 (Claude bridge MVP) → P1.1–P1.6 ✅ verificati 2026-04-25. Phase 4 (QR pairing) ✅ commit `ca8a599`. Blocker U0: sideload nuovo IPA + Tailscale per test on-device. Granulare → `docs/TASK_PLAN.md`, focus → `docs/memory/CONTEXT.md`.
