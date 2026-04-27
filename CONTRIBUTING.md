# Contributing to GIGI

Benvenuto. Questo documento è per **te dev** (umano) — `CLAUDE.md` invece è per gli agenti AI. Se cerchi onboarding utente finale → `docs/GETTING_STARTED.md`.

## Setup ambiente (5 min)

1. Clona il repo
2. Node.js v20+ installato (`node --version`)
3. Per harness:
   ```bash
   cd 03_HARNESS/server
   npm install
   cp config.example.mac.json config.json   # o .json su Windows
   # Edita config.json o crea .env con HARNESS_SHARED_SECRET, ANTHROPIC_API_KEY, APNS_*
   ```
4. Per app iOS: Xcode 15+ con SDK iOS 17+. Build via `02_GIGI_APP/GIGI.xcodeproj`.
5. Crea il tuo `CLAUDE.local.md` (gitignored) con il tuo workflow personale (host SSH/Mac, drop folder IPA, ecc.).
6. Lancia harness: `./start-harness.sh` dalla root.

## Layout repo

Vedi `CLAUDE.md` §"Dove guardare per cosa". TL;DR:

- `01_SERVER_MDM/`, `02_GIGI_APP/`, `03_HARNESS/` — i tre componenti
- `docs/` — TUTTI i doc project-level (architettura, runbook, ADR, ricerche)
- `.github/` — CODEOWNERS + template PR/issue
- `.claude/` — config + hook agenti

## Convenzioni codice

### Swift (`02_GIGI_APP/`)

- SwiftUI-first; `@MainActor` su ViewModel; UIKit solo se inevitabile (es. VisionKit)
- Naming `Gigi*` per moduli dominio-specifici
- Singleton `static let shared` quando serve, mai per logica testabile
- Docstring `///` o `// MARK:` in cima ai file critici (1 riga, "cosa fa")

### Node (`03_HARNESS/`, `01_SERVER_MDM/`)

- v20+, ES modules quando possibile, no TypeScript
- Naming `ios-*` per route lato iOS
- No deps inutili (l'harness ha già `ws`, `@anthropic-ai/sdk`, `playwright-core`, `puppeteer-core`)

### Lingua

- Doc utente-facing e commenti: **italiano**
- Spec API tecniche condivise (es. `03_HARNESS/docs/api/ios-integration.md`): **inglese**
- ADR: italiano OK (siamo team italiano)

## Flusso PR

1. **Branch**: `feat/<scope>` o `fix/<scope>` da `main`
2. **Commit**: [Conventional Commits](https://www.conventionalcommits.org/) — `feat(harness):`, `fix(ios):`, `docs:`, `refactor:`, `chore:`
3. **PR**: usa il template `.github/PULL_REQUEST_TEMPLATE.md` (what / why / test plan)
4. **Review**: CODEOWNERS auto-assegna i reviewer per path
5. **Merge**: solo dopo build verde + 1 review approvata
6. **Squash** preferito per feature PR (1 commit per feature in `main`)

## Decisioni architetturali

Se la tua PR introduce una scelta tecnica con impatto futuro (libreria, pattern, API contract), **prima** apri un ADR:

```
docs/adr/NNNN-<titolo>.md
```

Copia da `docs/adr/0000-template.md`. Quando il team accetta (Status: Accepted), il file è **immutabile**: cambi futuri = nuovo ADR che _supersedes_ il vecchio.

Esempio: `docs/adr/0001-pairing-cloudflare-tunnel-mvp.md`.

## Procedure ripetitive

Operazioni che fai più di 2 volte → estraile in `docs/runbooks/<nome>.md` come checklist passo-passo. Non narrativa.

Già documentati: `build-ipa.md`, `pair-iphone.md`, `deploy-harness.md`.

## Bug protocol

1. Apri issue con template `.github/ISSUE_TEMPLATE/bug.md`
2. Riproduci → root cause prima del fix
3. Se la causa rivela un'assunzione sbagliata → nuovo ADR che la _corregge_
4. Fix → PR → test (per iOS: nuovo IPA + verifica device)
5. Per fix iOS, **mai** chiudere il PR senza nuovo IPA testato sul device fisico

## Test

- iOS: `xcodebuild` filtrato per `error:|BUILD SUCCEEDED|BUILD FAILED`
- Harness: `npm test` in `03_HARNESS/server/` (suite minima per ora — espandila)
- E2E: `docs/TEST_E2E.md` per scenari cross-componente

Non dichiarare "testato" senza:
- Build verde
- Per fix UI/iOS: screenshot o video del device

## AI agent workflow

Quando lavori con Claude Code (o altri agenti):
- Apri il repo nella root → l'agente legge `CLAUDE.md` automaticamente
- Per workflow personali (host SSH ecc.) il tuo `CLAUDE.local.md` (gitignored) si aggiunge
- L'hook `Stop` appende riassunto turno a `docs/memory/ACTIVITY_LOG.md` via Haiku 4.5 (richiede `ANTHROPIC_API_KEY` nel tuo env)
Niente memorie per-agente nel repo. La memoria progetto vive in `docs/memory/PROJECT.md` + `CONTEXT.md` + ADR + runbook.

## Cosa NON fare

- ❌ Committare `.env`, certs, chiavi APNS, Bearer token, `CLAUDE.local.md`
- ❌ Aprire PR enormi multi-feature — split
- ❌ Skippare hook git (`--no-verify`) — se fallisce, fixa la causa
- ❌ Force push su `main`
- ❌ Aggiungere file Markdown duplicati (es. README inglese parallelo a un doc italiano esistente)
- ❌ Mantenere PROGRESS.md / CHANGELOG.md / CODE_MAP.md fatti a mano — il tracker + git + IDE coprono già

## Template `CLAUDE.local.md` (gitignored, personale)

Crea il tuo `CLAUDE.local.md` alla root del repo (è già in `.gitignore`). Ti serve per dire al **tuo** Claude Code dove buildare e come deployare nel tuo specifico setup.

```markdown
# CLAUDE.local.md — workflow personale di <NOME>

> Questo file è gitignored. Contiene host SSH, drop folder e scorciatoie
> personali. Non condividerlo.

## Build iOS

Sostituisci coi tuoi parametri.

- **Host SSH Mac**: `<USER>@<HOST>` (es. `user297422@FF125.macincloud.com`)
- **Path repo sul Mac**: `~/GIGI/`
- **Drop folder IPA per Sideloadly**: `C:/Users/<TUO_USER>/Desktop/GIGI/bug/GIGI.ipa`

### Comando build verify (per Claude del dev)

```bash
ssh <USER>@<HOST> "cd ~/GIGI/02_GIGI_APP && /usr/bin/xcodebuild \
  -project GIGI.xcodeproj -scheme GIGI -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | grep -E 'error:|BUILD SUCCEEDED|BUILD FAILED' | head -40"
```

### Comando packaging IPA

```bash
ssh <USER>@<HOST> '
  APP=$(find ~/Library/Developer/Xcode/DerivedData -name "GIGI.app" -type d | head -1)
  rm -rf /tmp/Payload && mkdir /tmp/Payload && cp -R "$APP" /tmp/Payload/
  cd /tmp && zip -qr /tmp/GIGI.ipa Payload
'
scp <USER>@<HOST>:/tmp/GIGI.ipa "<DROP_FOLDER>/GIGI.ipa"
```

## Notes for Claude del dev

Quando lavori su file `.swift` in questa repo:
1. Push del file modificato sul Mac via `scp` (oppure `git push` + `ssh ... 'cd ~/GIGI && git pull'`)
2. Esegui il comando build verify sopra
3. Se BUILD SUCCEEDED, packaging IPA + scp al drop folder
4. Avvisami: "IPA pronta per Sideloadly in <DROP_FOLDER>"

⚠️ Il workflow MacInCloud è LENTO. Se hai opzioni più veloci (Mac locale, TestFlight), preferiscile.
```

Salvalo e prosegui. Il `CLAUDE.local.md` viene letto dal tuo Claude Code in aggiunta a `CLAUDE.md`. Loro insieme dicono al modello sia la regola comune di team sia la tua specifica configurazione.

---

## Vedi anche

- `CLAUDE.md` — context per agenti AI
- `docs/README.md` — indice cartella docs
- `docs/GETTING_STARTED.md` — onboarding utente finale (non dev)
- `docs/ARCHITETTURA_V3.md` — architettura "True Agent" V3
- `docs/adr/` — decisioni storiche
- `docs/runbooks/` — procedure ripetitive
