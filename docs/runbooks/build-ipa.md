# Runbook — Build IPA (sideload Sideloadly)

> Quando ti serve: dopo OGNI modifica `.swift` in `02_GIGI_APP/GIGI/` per testare il fix sul telefono.
> Tempo: ~3 min.
> Owner: chiunque tocchi Swift.

## Perché serve

L'IPA installata sul telefono è frozen al momento dell'ultimo build. Modificare il file
sul tuo working tree NON aggiorna l'app sul device. Senza nuovo IPA, ogni "fix testato"
è una bugia. Vedi `docs/memory/PROJECT.md` §Vincoli noti.

## Prerequisiti (una tantum)

- Mac (locale o remoto via SSH) con Xcode + command-line tools
- Sideloadly installato sul tuo PC
- iPhone trusta il tuo Apple ID (`Impostazioni → Generali → VPN & Device Management`)
- Repo presente sulla Mac (clone o `scp` del file modificato)

I dettagli del **tuo host SSH personale** vivono nel tuo `CLAUDE.local.md` (gitignored).
Qui restano i comandi sanitizzati: sostituisci `<MAC_HOST>`, `<MAC_USER>`, `<MAC_REPO>`
coi tuoi.

## Procedura

### 1. Sincronizza il file modificato sulla Mac

```bash
scp "<repo_locale>/02_GIGI_APP/GIGI/<File>.swift" \
    <MAC_USER>@<MAC_HOST>:<MAC_REPO>/02_GIGI_APP/GIGI/<File>.swift
```

Se hai modificato più file, considera `git push` + `git pull` sulla Mac invece dello scp.

### 2. Rebuild filtrato per errori (sulla Mac)

```bash
ssh <MAC_USER>@<MAC_HOST> \
  "cd <MAC_REPO>/02_GIGI_APP && /usr/bin/xcodebuild -project GIGI.xcodeproj \
   -scheme GIGI -configuration Debug -destination 'generic/platform=iOS' \
   CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 \
   | grep -E 'error:|BUILD SUCCEEDED|BUILD FAILED' | head -40"
```

Atteso: `BUILD SUCCEEDED`. Se `error:` → fissa prima di proseguire.

### 3. Packaging IPA (sulla Mac)

```bash
ssh <MAC_USER>@<MAC_HOST> '
  APP=$(find ~/Library/Developer/Xcode/DerivedData -name "GIGI.app" -type d | head -1)
  rm -rf /tmp/Payload && mkdir /tmp/Payload && cp -R "$APP" /tmp/Payload/
  cd /tmp && zip -qr /tmp/GIGI.ipa Payload
'
```

### 4. Pull IPA in zona Sideloadly

```bash
scp <MAC_USER>@<MAC_HOST>:/tmp/GIGI.ipa "<path/al/tuo/drop_folder>/GIGI.ipa"
```

### 5. Sideload sul device

1. Apri Sideloadly su PC
2. Connetti iPhone via USB
3. Drop `GIGI.ipa` nella finestra Sideloadly
4. Sign-in Apple ID + **Start**
5. Sblocca iPhone se richiede

### 6. Verifica installazione

Sull'iPhone, apri GIGI. Se il fix non si vede, NON debuggare il codice prima di:

```bash
ssh <MAC_USER>@<MAC_HOST> "grep '<pattern_del_fix>' <MAC_REPO>/02_GIGI_APP/GIGI/<File>.swift"
```

Se il `grep` non trova la modifica, l'IPA è di una versione vecchia → rifai dal punto 1.

## Errori noti

| Sintomo | Causa | Fix |
|---|---|---|
| `BUILD FAILED: Code signing required` | Mancano i flag NO | Riapplica i 3 flag CODE_SIGN_* del comando |
| `GIGI.app non trovato` | DerivedData pulita | Build completa una volta dentro Xcode GUI poi ripeti CLI |
| Fix non visibile in app | IPA vecchia | Verifica via `grep` step 6 prima di toccare codice |

## Vedi anche

- `CLAUDE.md` §Memoria progetto checklist
- `docs/memory/PROJECT.md` §Vincoli noti
- `docs/runbooks/pair-iphone.md`
