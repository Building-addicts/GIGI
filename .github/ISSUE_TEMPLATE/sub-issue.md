---
name: Sub-issue (granularità di un parent)
about: Step granulare di un parent epic — usare il body completo stile TASK_PLAN_V3
title: "[Sub #N · X/Y] <verbo + oggetto in 1 riga>"
labels: ''
assignees: ''
---

<!--
  Questo template è per le sub-issue (granularità X/Y di un parent #N).
  Le 3 sezioni in apertura (🎯 / 🔧 / ✨) sono OBBLIGATORIE: anche un dev
  che non conosce il parent deve capire in 30 secondi cosa farà.

  Sostituisci ogni placeholder. NON lasciare commenti HTML in chiaro.
-->

> **Sub-issue di #N** (titolo parent) — granularità X/Y

## 🎯 Cosa stiamo facendo (context)

<!-- 1-2 frasi. Dove sta questa sub nel parent (es. "step 2/4 del parent #N"),
     cosa fa il parent in generale, cosa è già stato fatto nelle sub precedenti
     (es. "la sub 1/4 ha creato il metodo helper, ora lo colleghiamo all'evento wake").
     Deve essere LEGGIBILE da un dev che non conosce il progetto. -->

## 🔧 Cosa implementerà il dev

<!-- 3-5 bullet concreti, italiano human-first. NO file path, NO codice nei bullet.
     Cosa cambierà nel codice in termini funzionali.
     Esempio:
     - Aggiunge una chiamata a descendForListening() dentro il flusso di wake
     - Rimuove la vecchia Activity.update() che non scendeva
     - Garantisce thread @MainActor per evitare race condition -->

- ...

## ✨ Risultato atteso (cosa cambia per l'utente / per la pipeline)

<!-- 1 frase concreta.
     Per sub UI-facing → cosa vede l'utente.
     Per sub infrastrutturali (es. "wire helper") → cosa diventa possibile
     NEL PROSSIMO step grazie a questa.
     Esempio: "Sblocca la sub 3/4: il metodo returnToSleeping() può ora
     essere wired al callback di fine turno." -->

---

## Output atteso (technical)

<!-- Versione tecnica del "Risultato atteso", con dettagli per il dev. -->

## Target files & anchors

| File | Anchor / line | Cosa cambia |
|------|---------------|-------------|
| `path/to/file.swift` | `func methodName()` ~L120 | ... |

## Changes (numbered)

1. ...
2. ...
3. ...

## Build verify

```bash
# Comando esatto. Per iOS via SSH MacInCloud:
ssh user@host "cd ~/GIGI/02_GIGI_APP && xcodebuild -project GIGI.xcodeproj \
  -scheme GIGI -configuration Debug -destination 'generic/platform=iOS' \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 \
  | grep -E 'error:|BUILD SUCCEEDED|BUILD FAILED' | head -20"
```

Atteso: `BUILD SUCCEEDED`.

## Acceptance Criteria — VERO/FALSO esplicito

- [ ] AC#1 — <descrizione testabile, deve rispecchiare il "Risultato atteso" sopra>
- [ ] AC#2 — ...
- [ ] AC#3 — ...

## Test E2E utente OBBLIGATORIO

**Setup**:
- Device: iPhone fisico (no simulatore per audio/VAD)
- Versione IPA: nuova, post-build

**Steps**:
1. ...
2. ...
3. ...

**Expected response**: <cosa l'utente deve OSSERVARE — ricalca il "Risultato atteso">

## Merge conditions

1. Build verify: BUILD SUCCEEDED
2. Tutti gli AC confermati VERO dal dev su device fisico
3. Test E2E eseguito e expected response osservata
4. Step Report postato come comment sul PR
5. Approval @ArmandoBattaglino

## 💡 Spunti opzionali per il dev

<!-- 3-5 categorie di spunti che il dev può prendere o ignorare:
     - Pattern alternativi
     - Edge case da considerare
     - Refactor opportunistici
     - Logging/telemetry ipotetici
     - UX improvements minori -->

## Riferimenti

- Parent: #N
- ADR: ...
- Doc: ...
