# 🛡 PM Dashboard — Armando

> Bookmark questa pagina. Tutti i link che ti servono al risveglio in un posto solo.

## 🟢 Live Feed — cosa stanno facendo i dev ADESSO

**Issue #19 LIVE FEED** → https://github.com/Building-addicts/GIGI/issues/19

**Imposta watch "All Activity"** su questa issue:
1. Apri la issue #19
2. Click su **Subscribe** (in alto a destra) → **All activity**
3. Da qui in poi: ogni commento di Claude/dev → notifica push GitHub Mobile + email

## 📋 Project board

**Settimana lancio MVP**: https://github.com/orgs/Building-addicts/projects/1

View utili:
- **Per dev** → vedi chi sta facendo cosa: https://github.com/orgs/Building-addicts/projects/1/views/2
- **This week** (Roadmap) → timeline iteration: https://github.com/orgs/Building-addicts/projects/1/views/3
- **Board** (kanban) → https://github.com/orgs/Building-addicts/projects/1/views/1

## 🐛 Bug aperti in tempo reale

Tutti i bug aperti (sub-issue automatiche da AC falliti):
https://github.com/Building-addicts/GIGI/issues?q=is:issue+is:open+label:bug

## 📤 PR in attesa di review

Tutti i PR aperti che aspettano la tua review:
https://github.com/Building-addicts/GIGI/pulls?q=is:pr+is:open

CODEOWNERS ti auto-tagga sui PR per area Docs/Infra/CLAUDE.md/MVP_SCOPE.

## 🔥 Issue release-blocker da chiudere prima di venerdì

https://github.com/Building-addicts/GIGI/issues?q=is:issue+is:open+label:release-blocker

## 📊 Activity feed del repo (real-time stream)

https://github.com/Building-addicts/GIGI/activity

Ogni commit, PR, issue compare qui in cronologia.

## 📱 GitHub Mobile

Installa GitHub Mobile su iPhone se non l'hai. Setup notifiche:
- App GitHub → Settings → Notifications → **Issues & PRs** → Enabled
- Subscribe a #19 (LIVE FEED) come "All activity"
- Watch del repo intero in modalità **Custom**: solo Issues + PRs + Releases

## ⚙️ Quick actions di emergenza (admin override)

| Cosa | Come |
|---|---|
| Mergiare un PR senza review (emergenza) | Sei admin → puoi forzare con `gh pr merge <num> --squash --admin` |
| Riassegnare una issue | `gh issue edit <num> --add-assignee <handle>` |
| Aggiungere label `release-blocker` post-freeze | `gh issue edit <num> --add-label release-blocker` |
| Vedere ultimi commit | `git log --oneline -20` |
| Vedere tutto il lavoro in corso (CLI) | `gh issue list --state open --label live-status` o `gh pr list` |

## 📝 Contesto della settimana

- **Goal**: `docs/MVP_SCOPE.md` — demo convincente di GIGI "Siri ma personale e agentic" venerdì 1 maggio
- **Demo Day**: venerdì 1 maggio
- **Stato Phase 1 (Claude Bridge)**: P1.1-P1.6 ✅ verificati 25/04
- **Stato Phase 4 (QR pairing)**: ✅ commit `ca8a599`

## 🆘 Se Leo o Fede sono bloccati

Loro pingano `@ArmandoBattaglino` su:
- Issue diretta (commento)
- Issue #19 LIVE FEED (commento con `⏸️ standby`)
- Sub-issue bug (auto-tag sul body)

In ogni caso ti arriva notifica.

---

*Doc autogenerato il 2026-04-27. Aggiornami se i flussi cambiano.*
