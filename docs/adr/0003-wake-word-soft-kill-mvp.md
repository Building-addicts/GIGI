# ADR-0003: Wake Word "Hey GIGI" — soft-kill per MVP, riattivabile via flag

- **Status:** Accepted
- **Date:** 2026-05-07
- **Deciders:** @ArmandoBattaglino
- **Tags:** ios, voice, wake-word, mvp, kill-switch

## Context

Il progetto GIGI ha implementato una pipeline wake-word "Hey GIGI" basata su `SFSpeechRecognizer` con riconoscimento on-device (`requiresOnDeviceRecognition = true`), continuamente in ascolto durante Presence Mode. La classe `GigiWakeWordEngine` è ~600 righe e tocca 13 file (audio manager, presence controller, dashboard, settings, sound engine, live activity widget, ecc.).

Durante il path verso il MVP è emerso il vincolo iOS: **iOS non permette ascolto microfono continuo in background per app non-VoIP**. La pipeline funziona solo finché Presence è in foreground o sotto Live Activity attiva, con limiti pratici (CallKit pause, screen-dark restart, ecc.).

L'issue [#102](https://github.com/Building-addicts/GIGI/issues/102) ha decretato la deescalation a v1.1, sostituendo il wake word con tre trigger hardware/software già robusti:
- **Back Tap** (iPhone 14 e precedenti) → Shortcut "Talk to GIGI"
- **Action Button** (iPhone 15 Pro+) → Shortcut "Talk to GIGI"
- **Siri AppIntent** → frase "Hey Siri, talk to GIGI"

Tutti tre aprono GIGI in <1s anche con schermo bloccato, senza ascolto continuo.

Durante l'audit di rework (2026-05-07) il PM ha rilevato che:
- L'engine è già stato gated via `GigiWakeWordEngine.isDisabledForMVP = true` (linea 41) e `GigiAudioManager.startWakeWordListening()` torna early prima di partire.
- La UI di Settings è già stata sostituita da una sezione "🎙️ Talk to GIGI" che spiega i tre trigger e un footer note che chiarisce il pause del wake word.
- Resta una capability row "Wake Word" in `DashboardView` che mostra sempre "inactive" (perché `wakeWordEnabled` UserDefaults è false) — UI rumore non utile.
- Resta tutto il codice engine + sound effect + state machine + observer CallKit, dormiente.

La decisione si pone ora: kill totale della classe, kill soft (gating + UI hide), o status quo.

## Decision

Adottiamo il **kill soft**:

> L'engine `GigiWakeWordEngine` resta nel codebase, gated dalla static const `isDisabledForMVP = true`. Tutti i call site che potrebbero attivarlo (`GigiAudioManager.startWakeWordListening`) hanno già un guard early-return su questa flag.
>
> La UI di Dashboard nasconde la capability row Wake Word quando `isDisabledForMVP == true`. La sezione Settings "🎙️ Talk to GIGI" mantiene la footer copy esplicativa del pause.
>
> **Riattivare in v1.1**: flip `isDisabledForMVP` a `false` + remove la condition guard dalla UI. Zero re-implementazione richiesta — git history conserva il know-how del 2026.

## Alternatives considered

- **A — Kill totale**: cancellare `GigiWakeWordEngine.swift`, rimuovere flag UserDefaults, pulire la state machine. Scartato perché il PM ha indicato l'intenzione di riattivare il wake word in v1.1 e il git revert costerebbe più del 2-3 KB di codice dormiente. La complessità apparente è bassa: l'engine è isolato e ben commentato.
- **C — Status quo**: lasciare la capability row visibile (sempre "inactive"). Scartato per UX — mostrare una feature che non si può attivare confonde l'utente sulla capability row di stato. La rimozione della row è un cambio di una riga, low cost high signal.

## Consequences

### Positive
- ~600 righe di codice dormienti ma git-history-recoverable per v1.1 (basta un flag flip).
- UI Dashboard pulita — l'utente non vede più una "capability" perpetuamente inactive.
- Nessuna re-implementazione richiesta in v1.1 — il know-how (CallKit observer, screen-dark timer, exponential backoff su failure, contextualStrings bias italiani) è preservato.

### Negative / Trade-off
- ~600 righe di codice "morto" in `GigiWakeWordEngine.swift` aumentano la dimensione binaria di pochi KB. Trascurabile.
- Future modifiche alle classi vicine (`GigiAudioManager`, `PresenceSessionController`) devono ricordare che lo stato `.wakeWordListening` è raggiungibile solo se la flag flip avviene — rischio di refactor che lo rompe inavvertitamente. Mitigato dal commento "MVP de-scope kill switch (#102)" già presente in `GigiWakeWordEngine.swift:36-40`.
- Gli sound effect "wakeWord" nel `SoundEngine` restano caricati in memoria (negligibile).

### Neutral / Note
- L'azione di v1.1 è documentata: flip `isDisabledForMVP` a `false` + remove condition guard nella DashboardView. Diventa un mini-commit di ~2 righe.
- Se il piano v1.1 dovesse cambiare e wake word venisse de-scoped definitivamente, questo ADR sarà superseded da uno nuovo che cancella tutto il codice — `git rm GigiWakeWordEngine.swift` + cleanup observer + state machine.

## References

- Issue [#102](https://github.com/Building-addicts/GIGI/issues/102) — wake word deescalation a v1.1
- `02_GIGI_APP/GIGI/GigiWakeWordEngine.swift:36-41` — flag `isDisabledForMVP` con commento incorporato
- `02_GIGI_APP/GIGI/GigiAudioManager.swift:65-66` — guard early-return su `startWakeWordListening`
- `02_GIGI_APP/GIGI/SettingsView.swift:400-462` — sezione "🎙️ Talk to GIGI" sostitutiva
- `02_GIGI_APP/GIGI/DashboardView.swift:78-84` — capability row gated dal flag (questo commit)
- `docs/rework/CAPABILITY_MAP.md` — sezione "CHIRURGIA — Wake Word zombie"
- ADR correlati: ADR-0001 (pairing), ADR-0002 (doppio path Claude)

---

> Una volta `Accepted`, **non si edita più questo file**. Se la decisione cambia,
> si crea un nuovo ADR che la _supersedes_ e si aggiorna lo Status di questo a
> `Superseded by ADR-XXXX`.
