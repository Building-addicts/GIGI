# Kickoff message Leo + Fede (WhatsApp)

> Da copia-incollare in chat. Lingua naturale, friction-zero.
> Ho diviso in sezioni separate da `---` se vuoi mandarle in più messaggi WhatsApp invece che uno solo (a volte i messaggi lunghi vengono troncati).

---

## MESSAGGIO 1 — Setup e obiettivo

Ciao ragazzi 👋

Settimana del lancio. Deadline **venerdì 1 maggio**. Da oggi a giovedì costruiamo, mercoledì 30 alle 16:00 facciamo il QA gate finale, venerdì demo.

Ho passato la giornata a setup-pare TUTTO il workflow per voi. L'idea è: **voi aprite Claude Code, dite "sì", e lui fa tutto il resto**. Niente comandi git, niente UI GitHub, niente PR a mano. Vi serve solo il vostro telefono, un Mac (per build iOS) e Claude Code.

Vi spiego A→Z come funziona, leggete con calma 5 minuti.

---

## MESSAGGIO 2 — Cosa avete da fare

Ognuno di voi ha una lista di issue assegnate sul repo `Building-addicts/GIGI`:

- **Leo (@Leonardo-Corte)** — 19 issue: tutto iOS lato app + Dynamic Island + Talking Session + WhatsApp draft + Active Help + NLU robusta
- **Fede (@fc200490-sketch)** — 20 issue: Preferences + Day Plan + Task extraction live + Resilience + Permission UI + Memory affordance
- **#17 (QA gate) e #18 (Demo)** — condivise tra noi 3 (giovedì/venerdì)

Le issue sono **organizzate gerarchicamente**:
- 13 PARENT epic (tipo "[iOS] Dynamic Island fase Speaking durante TTS")
- 38 SUB-ISSUE granulari (tipo "[Sub #10 · 1/4] Empty speech guard")

Una sub-issue alla volta. Quando chiudete una sub, il bot calcola la % di avanzamento del parent e posta automatica su Discord 📈 (oppure 🏆 se chiude la parent al 100%).

---

## MESSAGGIO 3 — Come ogni issue è fatta (importante)

Ogni issue ora inizia con 3 sezioni human-first:

🎯 **Cosa stiamo facendo (context)** → 1-2 frasi che spiegano dove siamo nel progetto
🔧 **Cosa implementerà il dev** → bullet concreti, NO codice, NO file path
✨ **Risultato atteso** → 1 frase: cosa cambia per l'utente finale

Sotto trovate i dettagli tecnici: file:line da modificare, comando esatto di build verify, Acceptance Criteria, Test E2E utente.

**Leggete sempre prima il blocco 🎯/🔧/✨** per avere il contesto, poi scendete ai dettagli.

---

## MESSAGGIO 4 — Workflow di lavoro (la parte importante)

Quando aprite Claude Code nel repo, succede questo:

1. **SessionStart hook** vi riconosce dal `git config user.name` e vi mostra le vostre issue ordinate per priorità (🔴 P0 → 🟧 P1 → 🟩 P3)
2. Claude vi propone la più urgente: *"Hai 19 issue aperte. La più urgente è #38. Vuoi iniziare?"*
3. Voi rispondete *"sì"* / *"vai"* / *"ok"*
4. Claude **da solo** fa:
   - Crea worktree isolato (`../GIGI-work/issue-38-...`) — il vostro main resta intatto
   - Legge il body completo della issue
   - Vi mostra **il piano** prima di toccare codice — voi confermate
   - Modifica i file specificati
   - Lancia il build verify (per iOS via SSH MacInCloud, configurato nel vostro `CLAUDE.local.md`)
   - Vi chiede di **testare a mano sul telefono fisico** ogni Acceptance Criterion (rispondete `1=sì 2=sì 3=no`)
   - Se tutti gli AC sono VERI → commit + push + apre PR con `Closes #N`
   - Voi dite *"merge"* → lui mergia, pulisce worktree, vi propone la prossima

**Voi quindi dovete solo**: aprire Claude Code, dire sì/vai/merge, e testare a mano sul telefono.

---

## MESSAGGIO 5 — Test E2E obbligatorio (regola dura)

Ogni issue ha una sezione **"Test E2E utente OBBLIGATORIO"** con:
- Setup (es. iPhone fisico, NO simulatore per audio/VAD)
- Steps numerati
- Expected response

Claude vi chiederà esplicitamente VERO/FALSO per ogni AC dopo il build. **NON DITE "sembra ok"**. Testate davvero. Se un AC è falso, Claude apre **automaticamente una sub-issue di tipo `bug`**, P0, mi pinga, e vi chiede se fixare ora o stand-by. Trasparenza totale.

⛔ **NIENTE merge senza tutti gli AC confermati VERO** + IPA fresca installata sul device fisico per iOS.

---

## MESSAGGIO 6 — Cosa vedo io (PM)

Tutto quello che fate viene tracciato automatic su 3 canali:

1. **Issue #19 LIVE FEED** sul repo → ogni passo significativo (start/build_ok/build_fail/AC verified/bug/PR opened/merge) viene postato qui in tempo reale
2. **Discord** (canale `#gigi-dev` che ti faccio vedere) → ricevo notifiche per:
   - Issue aperta/chiusa, PR aperto/mergiato
   - Bug trovato durante test E2E (notifica forte rossa)
   - Progress aggiornato (📈 X% del parent)
   - Health check giornaliero alle 8:00 (sistema operativo? quanti P0 aperti?)
3. **GitHub Project board** → cards si muovono automatic da Backlog → In Progress → In Review → Done in base a PR/branch

Quindi io NON ho bisogno che mi mandiate update manuali. Vi vedo lavorare in real time. Se serve scrivetemi diretto.

---

## MESSAGGIO 7 — Cosa serve sul vostro PC

**Entrambi**:
- Claude Code installato e autenticato
- `gh` CLI installato + autenticato (`gh auth login`)
- Git config con il vostro nome reale (es. `git config --global user.name "Leonardo Corte"`)
- File `CLAUDE.local.md` alla root del repo (gitignored) con i vostri host SSH personali per il Mac e i path dei vostri tool — c'è un template in `CONTRIBUTING.md` § "Template CLAUDE.local.md"

**Per Leo (iOS)**:
- Account MacInCloud o Mac fisico raggiungibile via SSH
- iPhone con Sideloadly configurato (per installare nuove IPA dopo ogni build)

**Per Fede (harness)**:
- Node 20+
- Tunnel (Cloudflare named recommended)
- iPhone per testare anche tu il flusso E2E quando tocchi flussi che impattano l'app

Se manca qualcosa Claude vi avvisa al primo session start.

---

## MESSAGGIO 8 — Cosa NON fare mai

⛔ Lavorare su `main` direttamente — sempre worktree
⛔ Mergiare senza AC confermati VERO sul telefono fisico
⛔ Skippare il build verify ("sembra ok dal codice" non basta)
⛔ Modificare file fuori dallo scope della issue senza chiedere
⛔ Tenere bug trovati per voi — apriteli sempre come sub-issue (Claude lo fa automatic, lasciateglielo fare)

Se Claude vi dice *"questo è fuori scope"* o *"non sono sicuro"* → fidatevi del default *"chiedi"*. Frizione zero ≠ autonomia totale.

---

## MESSAGGIO 9 — Quando avete dubbi

Se durante il lavoro vi succede una di queste:
- AC ambiguo / non capite cosa testare
- Body issue contraddittorio o mancante di dettagli
- Avete trovato un bug fuori scope dalla issue corrente
- Decisione architetturale ambigua (es. "questa libreria o quell'altra?")

→ **Pingatemi diretto su WhatsApp** o postate un comment sulla issue tagging `@ArmandoBattaglino`. Rispondo in giornata. Niente paura di "rompere", preferisco una domanda in più che un fix sbagliato.

---

## MESSAGGIO 10 — Quando partiamo

**Da ora**. Aprite Claude Code, fate session start, vedrete la vostra issue più urgente. Iniziamo a chiudere sub-issue.

Target ipotetico:
- **Lunedì-martedì**: chiudere il 60% delle sub-issue P0 di voi due (no QA, no demo)
- **Mercoledì 30**: ultime sub + QA gate alle 16:00 (tutti e 3, max 2 ore)
- **Giovedì 1**: stability pass + freeze
- **Venerdì 2 maggio**: demo MVP

Per qualsiasi cosa: chat o issue comment.

Andiamo 🚀

— Armando

---

## NOTE OPERATIVE PER ARMANDO (non per la chat)

- Issue #8 "READ FIRST" e #6 "Repo migration" sono unassigned ma sono **note informative** — non hanno bisogno di assignment, possono restare unassigned (o assignate a te per claim)
- LIVE FEED #19 è OPEN ed è alimentato automaticamente — **non chiuderla mai**
- Health check parte domattina alle 8:00 (cron `0 6 * * *` UTC = 8:00 CET)
- Branch protection su `main`: 1 review obbligatoria + check `pr-lint` verde — i ragazzi NON possono mergere senza la tua approval, ti tutela
- Se uno dei due fa qualcosa di rotto: rollback è semplice perché tutto è in feature branch + worktree, niente è mai sul main fino al merge approvato

Backup di sicurezza:
- Tag git pre-lancio già da fare? Non ancora — fallo lunedì mattina prima che inizino: `git tag pre-launch-2026-04-27 && git push origin pre-launch-2026-04-27`
