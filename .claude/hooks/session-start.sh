#!/usr/bin/env bash
# SessionStart hook — saluta il dev all'apertura di Claude Code in repo,
# legge le sue issue aperte, e gli inietta nel context una proposta di partenza.
#
# Output va a stdout → diventa system message visibile a Claude.
# Tieni breve (<500 token) per non saturare context.

set -u

ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
MAPPING="$ROOT/.claude/dev-mapping.json"

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

[ -z "$LOOKUP" ] && exit 0

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

# 4. Recupera issue aperte assegnate al dev
ISSUES_JSON="$(gh issue list --repo Building-addicts/GIGI \
  --assignee "$HANDLE" --state open --limit 30 \
  --json number,title,labels 2>/dev/null)"

if [ -z "$ISSUES_JSON" ]; then
  ISSUES_JSON="[]"
fi

# 5. Format con python (sort per priorità, top 8). Forza UTF-8 per emoji su Windows.
FORMATTED="$(ISSUES_JSON_ENV="$ISSUES_JSON" PYTHONIOENCODING=utf-8 "$PY" - <<'PYEOF'
import json, os, sys
try:
    issues = json.loads(os.environ.get('ISSUES_JSON_ENV', '[]'))
except Exception:
    issues = []

def priority_score(issue):
    labels = [l['name'] for l in issue.get('labels', [])]
    if 'release-blocker' in labels: return 0
    for i, p in enumerate(['priority:P0','priority:P1','priority:P2','priority:P3']):
        if p in labels: return 1 + i
    return 99

issues.sort(key=lambda i: (priority_score(i), i['number']))

emoji_map = {
    'priority:P0': '🔴',
    'priority:P1': '🟧',
    'priority:P2': '🟨',
    'priority:P3': '🟩',
}

lines = []
for issue in issues[:8]:
    labels = [l['name'] for l in issue.get('labels', [])]
    pri_label = next((l for l in labels if l.startswith('priority:')), '')
    pri_emoji = emoji_map.get(pri_label, '⚪')
    blocker = '🚨' if 'release-blocker' in labels else ''
    bug = '🐛' if 'bug' in labels else ''
    title = issue['title'][:80]
    lines.append(f"  {pri_emoji}{blocker}{bug} #{issue['number']} — {title}")

print('|||'.join(lines))
print(len(issues))
PYEOF
)"

ISSUE_COUNT="$(echo "$FORMATTED" | tail -1)"
ISSUE_LINES="$(echo "$FORMATTED" | head -n -1 | tr '|||' '\n' | sed 's/^|*//')"

# 6. Componi messaggio di benvenuto + istruzioni di workflow
echo "[GIGI session-start] — context per Claude"
echo ""
echo "Dev identificato: $FULL_NAME ($ROLE) · GitHub: @$HANDLE"
echo ""

if [ "$ISSUE_COUNT" = "0" ] || [ -z "$ISSUE_COUNT" ]; then
  cat <<EOF
Issue aperte assegnate: 0.

ISTRUZIONI per Claude in questa sessione:
- Quando il dev scrive il primo messaggio, salutalo per nome.
- Digli: "Ciao $FULL_NAME 👋 Non hai issue aperte assegnate al momento. Vuoi che controlliamo il Project board cosa è disponibile? https://github.com/orgs/Building-addicts/projects/1"
EOF
else
  cat <<EOF
Issue aperte assegnate ($ISSUE_COUNT totali, top 8 per priorità):
$ISSUE_LINES

ISTRUZIONI VINCOLANTI per Claude in questa sessione:

1. Quando il dev scrive il primo messaggio, SALUTALO per nome e mostragli la prima issue in cima:
   "Ciao $FULL_NAME 👋 Hai $ISSUE_COUNT issue aperte. La più urgente è #N. Vuoi che la facciamo? (rispondi 'sì')"

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

3. **TIMELINE LIVE FEED su issue #19** — A ogni passo significativo (start lavoro, build OK/FAIL, AC verificato, bug trovato, PR aperto, merge), POSTA un commento su #19:
   gh issue comment 19 --repo Building-addicts/GIGI --body "[<HH:MM>] @<dev_handle> · #<N>
   <emoji> <stato in 1 riga>"
   Emoji: 🚀 inizio · ✅ build ok · ❌ build fail · 🟢 AC verificati · 🐛 bug → sub-issue · 📤 PR · 🎉 merge · ⏸️ standby
   ⛔ Niente commento = PM cieco. Posta SEMPRE prima del passo successivo.

4. **SUB-ISSUE BUG — notifica PM forte** (3 azioni obbligatorie tutte insieme):
   a. Crea sub-issue assegnata sia al dev sia ad ArmandoBattaglino (via gh issue create con --assignee), body che termina con: "cc @ArmandoBattaglino — bug urgente trovato in test E2E"
   b. Comment sulla issue parent: "Sub-issue (numero) aperta per AC fallito. cc @ArmandoBattaglino"
   c. Comment su #19 LIVE FEED (vedi sopra, emoji bug)
   Solo dopo le 3 azioni comunichi al dev.

5. NON FARE MAI:
   - Mergiare senza tutti gli AC confermati VERO dal dev (test su device fisico per iOS)
   - Skippare build verify
   - Lavorare su main directly (sempre worktree)
   - Aprire PR senza Acceptance Criteria confermati
   - Saltare il commento timeline su #19

6. Se dubbio: chiedi al dev. Frizione 0 ma sicurezza massima.
EOF
fi
