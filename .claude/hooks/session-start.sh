#!/usr/bin/env bash
# SessionStart hook — saluta il dev all'apertura di Claude Code in repo,
# legge le sue issue aperte, e gli inietta nel context una proposta di partenza.
#
# Output va a stdout → diventa system message visibile a Claude.
# Tieni breve (<500 token) per non saturare context.

set -u

ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
MAPPING="$ROOT/.claude/dev-mapping.json"

# ─── Layer 1: Auto-sync main ───────────────────────────────────
# fetch silenzioso (no errore se network down) + pull --ff-only se safe.
# Non tocca worktree o branch diversi da main: solo se il dev è sul main locale
# pulito, lo aggiorniamo. Mostriamo al dev quanti commit nuovi ci sono.
SYNC_MSG=""
CLEANUP_MSG=""
if [ -d "$ROOT/.git" ] || [ -f "$ROOT/.git" ]; then
  # Fetch in background (timeout 5s per evitare hang offline)
  ( timeout 5 git -C "$ROOT" fetch origin --prune --quiet 2>/dev/null ) || true

  # ─── Cleanup pass: worktree orphani + branch locali ghost ───────
  # 1. Rimuovi worktree orphani (dir cancellata a mano dal dev)
  git -C "$ROOT" worktree prune 2>/dev/null || true

  # 2. Trova branch locali il cui remote è "gone" (cancellato dopo merge)
  #    NON cancella automatic — segnala al Claude del dev che propone azione.
  GONE="$(git -C "$ROOT" for-each-ref --format='%(refname:short)|%(upstream:track)' refs/heads 2>/dev/null \
    | grep '|.*gone' | cut -d'|' -f1 | tr '\n' ' ')"
  if [ -n "$GONE" ]; then
    CLEANUP_MSG="🧹 Branch locali obsoleti (remote già cancellato dopo merge): ${GONE}— per pulire dimmi 'pulisci branch'"
  fi

  CURRENT_BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  if [ "$CURRENT_BRANCH" = "main" ]; then
    # Pull solo se working dir clean (no modifiche non committate)
    if git -C "$ROOT" diff --quiet HEAD 2>/dev/null && git -C "$ROOT" diff --quiet --cached 2>/dev/null; then
      BEFORE="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo "")"
      ( timeout 5 git -C "$ROOT" pull origin main --ff-only --quiet 2>/dev/null ) || true
      AFTER="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo "")"
      if [ -n "$BEFORE" ] && [ -n "$AFTER" ] && [ "$BEFORE" != "$AFTER" ]; then
        AHEAD="$(git -C "$ROOT" rev-list --count "$BEFORE..$AFTER" 2>/dev/null || echo "?")"
        LAST_MSG="$(git -C "$ROOT" log -1 --pretty='%s' 2>/dev/null | cut -c1-60)"
        SYNC_MSG="📥 main aggiornato: ${AHEAD} nuovi commit (ultimo: \"${LAST_MSG}\")"
      fi
    else
      SYNC_MSG="⚠️ main locale ha modifiche non committate — skip auto-pull, gestisci a mano"
    fi
  else
    # Dev su branch diverso (probabilmente worktree). Calcola behind rispetto a origin/main.
    BEHIND="$(git -C "$ROOT" rev-list --count HEAD..origin/main 2>/dev/null || echo "0")"
    if [ "$BEHIND" -gt 5 ] 2>/dev/null; then
      SYNC_MSG="⚠️ Sei su \"$CURRENT_BRANCH\" (worktree?) e main è avanti di $BEHIND commit. Considera: cd al main repo + git pull. Se hai PR aperta, valuta git merge origin/main qui per evitare conflitti grossi."
    fi
  fi
fi

# 1. Identifica il dev da git config user.name
GIT_NAME="$(git -C "$ROOT" config user.name 2>/dev/null || echo "")"
[ -z "$GIT_NAME" ] && exit 0

# Trova python (Python 3) — su Windows/Git Bash a volte è `python`
PY=""
for cand in python python3; do
  if command -v "$cand" >/dev/null 2>&1; then
    PY="$cand"
    break
  fi
done

if [ -z "$PY" ] || [ ! -f "$MAPPING" ]; then
  # Fallback grezzo: niente python o niente mapping → identifica solo per nome
  cat <<EOF
[GIGI session-start] Ciao ${GIT_NAME}. Setup non completo (manca python o dev-mapping). Skip onboarding automatico.
EOF
  exit 0
fi

# 2. Lookup nel mapping (case-insensitive substring match) — tutto python
LOOKUP="$(GIT_NAME_ENV="$GIT_NAME" MAPPING_ENV="$MAPPING" PYTHONIOENCODING=utf-8 "$PY" - <<'PYEOF'
import json, os, sys
name = os.environ.get('GIT_NAME_ENV', '').lower()
mapping_path = os.environ.get('MAPPING_ENV', '')
try:
    with open(mapping_path, encoding='utf-8') as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
for entry in data.get('mapping', []):
    if entry['match'].lower() in name:
        # Print: handle|role|fullName
        print(f"{entry['handle']}|{entry['role']}|{entry.get('fullName','')}")
        sys.exit(0)
PYEOF
)"

if [ -z "$LOOKUP" ]; then
  # Dev non riconosciuto dal mapping → istruzione Claude di chiedere esplicitamente
  cat <<EOF
[GIGI session-start] Dev NON riconosciuto

\`git config user.name\` riporta: "$GIT_NAME"
Il dev-mapping (.claude/dev-mapping.json) non ha match per questo nome.

ISTRUZIONI per Claude in questa sessione:

1. Quando il dev scrive il primo messaggio, chiedigli esplicitamente:
   "Ciao! Non ti riconosco dal git config. Sei uno di questi?
    (a) Armando Battaglino · @ArmandoBattaglino · PM
    (b) Leonardo Corte    · @Leonardo-Corte    · iOS lead
    (c) Federico          · @fc200490-sketch   · Harness lead
    Rispondi a/b/c."

2. Una volta che il dev risponde:
   - Esegui: \`git config --global user.name "<Nome Cognome>"\` con nome canonico
     (es. "Armando Battaglino" / "Leonardo Corte" / "Federico")
   - Esegui: \`git config --global user.email "<email>"\` se non già settato
   - Comunica al dev: "Settato. Riapri Claude Code per partire con il workflow corretto."

3. Dopo che il dev riapre, il SessionStart hook lo riconoscerà e mostrerà le sue issue.

⚠️ NON proseguire con worktree/branch/PR finché il dev non è identificato correttamente — i timeline post non funzionerebbero.
EOF
  exit 0
fi

HANDLE="$(echo "$LOOKUP" | cut -d'|' -f1)"
ROLE="$(echo "$LOOKUP" | cut -d'|' -f2)"
FULL_NAME="$(echo "$LOOKUP" | cut -d'|' -f3)"
[ -z "$FULL_NAME" ] && FULL_NAME="$GIT_NAME"

# 3. Verifica gh CLI disponibile + autenticato
if ! command -v gh >/dev/null 2>&1; then
  cat <<EOF
[GIGI session-start] Ciao $FULL_NAME ($ROLE). \`gh\` CLI non installato — non posso mostrarti le issue. Installa da https://cli.github.com poi riapri Claude Code.
EOF
  exit 0
fi

if ! gh auth status >/dev/null 2>&1; then
  cat <<EOF
[GIGI session-start] Ciao $FULL_NAME ($ROLE). \`gh\` non è autenticato. Esegui: \`gh auth login\` poi riapri Claude Code.
EOF
  exit 0
fi

# ─── Verifica CLAUDE.local.md (workflow personale del dev) ───
LOCAL_MD="$ROOT/CLAUDE.local.md"
HAS_LOCAL_MD="false"
[ -f "$LOCAL_MD" ] && HAS_LOCAL_MD="true"

# 4. Recupera issue aperte assegnate al dev + PR aperte del repo (condivise tra tutti)
ISSUES_JSON="$(gh issue list --repo Building-addicts/GIGI \
  --assignee "$HANDLE" --state open --limit 30 \
  --json number,title,labels 2>/dev/null)"

if [ -z "$ISSUES_JSON" ]; then
  ISSUES_JSON="[]"
fi

# Le PR aperte sono visibili a tutti i dev — non filtrate per author. Top 2 per relevance.
PRS_JSON="$(gh pr list --repo Building-addicts/GIGI --state open --limit 20 \
  --json number,title,author,reviewDecision,statusCheckRollup 2>/dev/null)"

if [ -z "$PRS_JSON" ]; then
  PRS_JSON="[]"
fi

# 5. Format con python — dashboard a 3 colonne (Actionable / Waiting / PR Review).
#    Forza UTF-8 per emoji su Windows.
FORMATTED="$(ISSUES_JSON_ENV="$ISSUES_JSON" PRS_JSON_ENV="$PRS_JSON" HANDLE_ENV="$HANDLE" \
  PYTHONIOENCODING=utf-8 "$PY" - <<'PYEOF'
import json, os, sys

try:
    issues = json.loads(os.environ.get('ISSUES_JSON_ENV', '[]'))
except Exception:
    issues = []

try:
    prs = json.loads(os.environ.get('PRS_JSON_ENV', '[]'))
except Exception:
    prs = []

handle = os.environ.get('HANDLE_ENV', '')

def priority_score(issue):
    labels = [l['name'] for l in issue.get('labels', [])]
    if 'release-blocker' in labels: return 0
    for i, p in enumerate(['priority:P0','priority:P1','priority:P2','priority:P3']):
        if p in labels: return 1 + i
    return 99

def is_blocked(issue):
    """Issue è blocked se ha label 'blocked' esplicita.
    (Marker comment <!-- BLOCKING:N,M --> verrà aggiunto in futuro se serve — costoso fetchare comment per ogni issue.)"""
    labels = [l['name'] for l in issue.get('labels', [])]
    return 'blocked' in labels

def render_issue_line(issue, with_blocked_hint=False):
    labels = [l['name'] for l in issue.get('labels', [])]
    pri_label = next((l for l in labels if l.startswith('priority:')), '')
    pri_emoji = {'priority:P0':'🔴','priority:P1':'🟧','priority:P2':'🟨','priority:P3':'🟩'}.get(pri_label, '⚪')
    blocker = '🚨' if 'release-blocker' in labels else ''
    bug = '🐛' if 'bug' in labels else ''
    title = issue['title'][:75]
    line = f"  {pri_emoji}{blocker}{bug} #{issue['number']} — {title}"
    if with_blocked_hint:
        line += "  ⏸️ blocked"
    return line

def render_pr_status(pr):
    review = pr.get('reviewDecision') or ''
    if review == 'CHANGES_REQUESTED':
        return '🔴 changes requested'
    if review == 'APPROVED':
        return '✅ approved'
    checks = pr.get('statusCheckRollup') or []
    if any(c.get('conclusion') == 'FAILURE' for c in checks):
        return '🔴 CI failing'
    if checks and all((c.get('conclusion') == 'SUCCESS' or c.get('status') == 'COMPLETED') for c in checks):
        return '✅ CI green'
    return '⏳ pending'

def render_pr_line(pr):
    title = pr['title'][:55]
    author = (pr.get('author') or {}).get('login', '?')
    is_mine = '👤 ' if author == handle else ''
    return f"  {is_mine}PR #{pr['number']} — {title} (by @{author}) [{render_pr_status(pr)}]"

# Sort issue per priority, poi numero
issues.sort(key=lambda i: (priority_score(i), i['number']))

# Categorize: actionable vs waiting
actionable = [i for i in issues if not is_blocked(i)][:3]
waiting    = [i for i in issues if     is_blocked(i)][:3]

# PR rilevanti: prima quelle del dev attuale, poi le altre. Max 2.
prs_sorted = sorted(prs, key=lambda p: (0 if (p.get('author') or {}).get('login') == handle else 1, -int(p['number'])))
prs_top    = prs_sorted[:2]

# Render output
out_lines = []
if actionable:
    out_lines.append("🟢 ACTIONABLE NOW")
    for i in actionable:
        out_lines.append(render_issue_line(i))
if waiting:
    if out_lines: out_lines.append("")
    out_lines.append("🟡 WAITING (blocked by dependency)")
    for i in waiting:
        out_lines.append(render_issue_line(i, with_blocked_hint=True))
if prs_top:
    if out_lines: out_lines.append("")
    out_lines.append("🔴 PR IN REVIEW (shared, all devs)")
    for p in prs_top:
        out_lines.append(render_pr_line(p))

for line in out_lines:
    print(line)
print(f"__ISSUE_COUNT__={len(issues)}")
print(f"__ACTIONABLE_FIRST__={actionable[0]['number'] if actionable else ''}")
PYEOF
)"

# Estrai metadata dalle marker line
ISSUE_COUNT="$(echo "$FORMATTED" | grep -oE '^__ISSUE_COUNT__=[0-9]+$' | tail -1 | cut -d= -f2)"
FIRST_ACTIONABLE="$(echo "$FORMATTED" | grep -oE '^__ACTIONABLE_FIRST__=[0-9]*$' | tail -1 | cut -d= -f2)"
ISSUE_LINES="$(echo "$FORMATTED" | grep -v '^__ISSUE_COUNT__=' | grep -v '^__ACTIONABLE_FIRST__=')"

# 6. Componi messaggio di benvenuto + istruzioni di workflow
echo "[GIGI session-start] — context per Claude"
echo ""
[ -n "$SYNC_MSG" ] && { echo "$SYNC_MSG"; echo ""; }
[ -n "$CLEANUP_MSG" ] && { echo "$CLEANUP_MSG"; echo ""; }
echo "Dev identificato: $FULL_NAME ($ROLE) · GitHub: @$HANDLE"
if [ "$HAS_LOCAL_MD" = "false" ]; then
  echo ""
  echo "⚠️  CLAUDE.local.md NON presente. Quando il dev inizia a lavorare su task iOS,"
  echo "    proponigli di crearlo dal template in CONTRIBUTING.md §\"Template CLAUDE.local.md\""
  echo "    (contiene host SSH MacInCloud, drop folder IPA, comandi build) — NECESSARIO per il build verify."
fi
echo ""

if [ "$ISSUE_COUNT" = "0" ] || [ -z "$ISSUE_COUNT" ]; then
  cat <<EOF
Issue aperte assegnate: 0.

ISTRUZIONI per Claude in questa sessione:
- Quando il dev scrive il primo messaggio, salutalo per nome.
- Digli: "Ciao $FULL_NAME 👋 Non hai issue aperte assegnate al momento. Vuoi che controlliamo il Project board cosa è disponibile? https://github.com/orgs/Building-addicts/projects/1"
EOF
else
  FIRST_DISPLAY="${FIRST_ACTIONABLE:-N}"
  cat <<EOF
Dashboard ($ISSUE_COUNT issue assegnate · max 3+3+2 righe):

$ISSUE_LINES

ISTRUZIONI VINCOLANTI per Claude in questa sessione:

1. Quando il dev scrive il primo messaggio, SALUTALO per nome e mostragli la prima issue ACTIONABLE (🟢):
   "Ciao $FULL_NAME 👋 Hai $ISSUE_COUNT issue assegnate. La prossima actionable è #${FIRST_DISPLAY}. Vuoi che la facciamo? (rispondi 'sì')"

   Le issue in 🟡 WAITING sono bloccate da dipendenze — non proporle finché il blocker non è risolto.
   Le PR in 🔴 PR REVIEW sono per visibilità condivisa: il dev può commentarle / fare review se vuole, ma non sono "issue da iniziare".

2. Se il dev dice "sì" / "vai" / "ok": segui il DEV WORKFLOW in CLAUDE.md §"Workflow per dev (vibe-coder mode)". Passi:
   a. Crea worktree: git worktree add ../GIGI-work/issue-<N>-<slug> -b feat/issue-<N>-<slug> main
   b. cd ../GIGI-work/issue-<N>-<slug>
   c. gh issue view <N> --repo Building-addicts/GIGI per leggere body completo
   d. Mostra il piano al dev e chiedi conferma prima di toccare codice
   e. Esegui i changes specificati nel body issue
   f. Build verify (comando exact dentro la issue)
   g. CHIEDI al dev di confermare VERO/FALSO per ogni Acceptance Criterion (test E2E utente OBBLIGATORIO)
   h. Se un AC è FALSO: APRI SEMPRE sub-issue con label 'bug', parent #N, ping @ArmandoBattaglino. Poi chiedi al dev se fixare ora.
   i. Quando tutti gli AC sono VERI: commit + push + gh pr create con 'Closes #<N>' nel body
   j. Quando il dev dice "merge": verifica check verdi + approval @ArmandoBattaglino, poi gh pr merge --squash, cleanup worktree, pull main, suggerisci prossima.

3. **TIMELINE LIVE FEED su issue #19** — DELEGA al subagent timeline-poster (Haiku, costo minimo).
   Tool Agent con subagent_type="timeline-poster", prompt="dev=<handle>, issue=<N>, event=<start|build_ok|build_fail|ac_verified|bug|pr_opened|merge|standby>, details=<1 riga>".
   Eventi: start, build_ok, build_fail, ac_verified, bug, pr_opened, merge, standby.
   ⛔ Niente delegazione = PM cieco. Delega SEMPRE prima del passo successivo. NON scrivere il commento col modello principale (spreco token).

4. **SUB-ISSUE BUG (AC fallito) — DELEGA al subagent bug-tracker** (Haiku).
   Tool Agent con subagent_type="bug-tracker", prompt="parent_issue=<N>, ac_number=<X>, ac_description=<...>, dev_handle=<handle>, dev_words=<parole>, suspected_files=<lista>, pr_num=<num>, area=<area>".
   Lui esegue 3 azioni atomiche: sub-issue assegnata dev+Armando, comment parent, comment #19.
   Solo dopo successo subagent, comunichi al dev e gli chiedi se fixare ora o stand-by.

5. NON FARE MAI:
   - Mergiare senza tutti gli AC confermati VERO dal dev (test su device fisico per iOS)
   - Skippare build verify
   - Lavorare su main directly (sempre worktree)
   - Aprire PR senza Acceptance Criteria confermati
   - Saltare il commento timeline su #19

6. Se dubbio: chiedi al dev. Frizione 0 ma sicurezza massima.
EOF
fi
