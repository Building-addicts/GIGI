#!/usr/bin/env bash
# Analizza tutte le PR open del repo e produce JSON ordinato per priorità.
# Logica:
#   - TIER 1 URGENT: build break fixes, hotfix, security
#   - TIER 2 HIGH:   demo-critical (parent in MVP scope) + chain root (1/N)
#   - TIER 3 MED:    standalone feature
#   - TIER 4 LOW:    refactor, cleanup, doc
#
# Per ogni PR calcola:
#   - urgency_tier
#   - chain_position (es. "Sub #15 · 2/4" → 2)
#   - chain_root_pr (la PR del root della catena, se esiste)
#   - blocks (lista di altre PR che dipendono da questa)
#   - risk (low/medium/high in base a diff size + check status)
#
# Output: JSON array su stdout, ordinato per priorità (TIER 1 → 4).

set -u

REPO="Building-addicts/GIGI"

# Carica tutte le PR open
PRS_JSON=$(gh pr list --repo "$REPO" --state open --limit 50 \
  --json number,title,body,headRefName,author,additions,deletions,changedFiles,statusCheckRollup,reviewDecision,createdAt 2>/dev/null)

if [ -z "$PRS_JSON" ] || [ "$PRS_JSON" = "[]" ]; then
  echo "[]"
  exit 0
fi

# Pass via stdin (PRS_JSON può essere troppo grande per argv su Windows)
PRS_JSON="$PRS_JSON" PYTHONIOENCODING=utf-8 python - <<'PYEOF'
import json, os, sys, re

prs = json.loads(os.environ['PRS_JSON'])

def detect_chain(pr):
    """Estrae chain root issue + posizione X/N dal title o body."""
    text = pr['title'] + '\n' + (pr.get('body') or '')
    m = re.search(r'[Ss]ub\s*#?(\d+)\s*[·\-:.]\s*(\d+)\s*[/\-]\s*(\d+)', text)
    if m:
        return {
            'parent_issue': int(m.group(1)),
            'position': int(m.group(2)),
            'total': int(m.group(3))
        }
    return None

def detect_urgency(pr):
    """Tier 1-4 in base a title + body."""
    t = pr['title'].lower()
    b = (pr.get('body') or '').lower()

    # TIER 1 URGENT
    if any(kw in t for kw in ['fix(ci)', 'fix: build', 'main build', 'hotfix', 'security', 'urgent', 'broken']):
        return 1
    if 'build break' in b or 'main is broken' in b:
        return 1
    if t.startswith('fix(') and 'broken' in b:
        return 1

    # TIER 4 LOW
    if t.startswith('chore') or t.startswith('docs'):
        return 4
    if t.startswith('refactor') or t.startswith('test'):
        return 4

    # TIER 2 HIGH (demo-critical: chain root or parent in MVP scope)
    chain = detect_chain(pr)
    if chain and chain['position'] == 1:
        return 2
    if any(kw in b for kw in ['mvp', 'demo', 'release-blocker', 'priority:p0', 'scena s']):
        return 2

    # TIER 3 MED default
    return 3

def detect_check_status(pr):
    checks = pr.get('statusCheckRollup', [])
    fail = sum(1 for c in checks if (c.get('conclusion') or c.get('state', '')).upper() in ('FAILURE', 'FAIL'))
    pending = sum(1 for c in checks if (c.get('conclusion') or c.get('state', '')).upper() in ('PENDING', 'IN_PROGRESS'))
    success = sum(1 for c in checks if (c.get('conclusion') or c.get('state', '')).upper() == 'SUCCESS')
    if fail > 0: return 'fail'
    if pending > 0: return 'pending'
    if success > 0: return 'green'
    return 'unknown'

def detect_risk(pr):
    """Risk in base a diff size + check status + scope."""
    total_lines = pr.get('additions', 0) + pr.get('deletions', 0)
    files = pr.get('changedFiles', 0)
    check = detect_check_status(pr)

    if check == 'fail':
        return 'high'
    if total_lines > 400 or files > 10:
        return 'high'
    if total_lines > 100 or files > 5:
        return 'medium'
    return 'low'

# Build chain map (parent_issue → list of PRs in chain)
chains = {}
for pr in prs:
    chain = detect_chain(pr)
    if chain:
        chains.setdefault(chain['parent_issue'], []).append({
            'pr_number': pr['number'],
            'position': chain['position'],
            'total': chain['total']
        })

for k in chains:
    chains[k].sort(key=lambda x: x['position'])

# Per ogni PR, calcola "blocks" (altre PR che la richiedono)
def get_blocks(pr_num, chain):
    if not chain:
        return []
    parent = chain['parent_issue']
    pos = chain['position']
    blocked = [p for p in chains.get(parent, []) if p['position'] > pos]
    return [b['pr_number'] for b in blocked]

# Compose output
results = []
for pr in prs:
    chain = detect_chain(pr)
    tier = detect_urgency(pr)
    check_status = detect_check_status(pr)
    risk = detect_risk(pr)
    blocks = get_blocks(pr['number'], chain) if chain else []

    # Reasoning leggibile
    reasoning_parts = []
    if tier == 1:
        reasoning_parts.append('🚨 URGENT — fix build/hotfix che sblocca tutto')
    elif tier == 2:
        if chain and chain['position'] == 1:
            reasoning_parts.append(f'🔥 HIGH — root catena Sub #{chain["parent_issue"]} (sblocca {chain["total"]-1} sub seguenti)')
        else:
            reasoning_parts.append('🔥 HIGH — demo-critical')
    elif tier == 3:
        reasoning_parts.append('📦 MEDIUM — standalone')
    else:
        reasoning_parts.append('💤 LOW — refactor/cleanup')

    if chain:
        reasoning_parts.append(f'catena {chain["position"]}/{chain["total"]} di #{chain["parent_issue"]}')
    if blocks:
        reasoning_parts.append(f'blocca PR: {", ".join(f"#{b}" for b in blocks)}')
    if check_status == 'fail':
        reasoning_parts.append('⚠️ check FAIL (verificare se è regex bug noto o reale)')
    elif check_status == 'pending':
        reasoning_parts.append('⏳ check pending')
    if risk == 'high':
        reasoning_parts.append(f'🔴 risk HIGH ({pr.get("additions",0)+pr.get("deletions",0)} righe, {pr.get("changedFiles",0)} file)')

    results.append({
        'pr': pr['number'],
        'title': pr['title'],
        'author': pr['author']['login'],
        'branch': pr['headRefName'],
        'tier': tier,
        'chain': chain,
        'blocks': blocks,
        'check_status': check_status,
        'risk': risk,
        'lines': pr.get('additions', 0) + pr.get('deletions', 0),
        'files': pr.get('changedFiles', 0),
        'reasoning': ' · '.join(reasoning_parts),
    })

# Sort: tier asc, then chain position asc, then PR number asc
results.sort(key=lambda r: (
    r['tier'],
    r['chain']['parent_issue'] if r['chain'] else 9999,
    r['chain']['position'] if r['chain'] else 0,
    r['pr']
))

print(json.dumps(results, indent=2, ensure_ascii=False))
PYEOF
