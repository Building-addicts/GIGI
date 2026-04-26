# Dynamic Island wake-word — debug-console analisi + task plan

Fonte: `debug console xcode.md` (16 256 righe). Goal: quando l'utente dice "Hey GIGI" fuori dall'app, la Dynamic Island deve "scendere come una notifica" per ascoltare → ragionare → parlare.

## 1. Cosa funziona (dai log)

- `startPersistentPill ENTER` → `Activity.request SUCCESS id=BC9F8F46…` (line 49–52). Pill creata. Activity ID stabile per tutta la sessione.
- `Updating content for activity BC9F8F46…` ricorre correttamente: alla detection (219), STT-final (253), wake successivo (438, 1371, 1646, 1846, 1900). La pill **viene** aggiornata.
- WakeWord detection funziona: `GIGI WakeWord: detected 'hey gigi' in 'hey gigi'` (line 216, 1368).
- State machine GigiAudioManager segue il flow atteso: `wakeWordListening → recording → idle → speaking → idle`.
- VAD/STT producono final transcript.

## 2. Cosa NON funziona (root-cause table)

| # | Sintomo (log line) | Root cause | Impatto utente |
|---|---|---|---|
| A | `AURemoteIO.cpp:1710 AUIOClient_StartIO failed (2003329396)` (line 439) → `WakeWord: audio engine error` | WakeWord prova a riavviare audio engine mentre la session è ancora `playAndRecord` ref-counted da SoundEngine/TTS. 2003329396 = `kAudioUnitErr_CannotDoInCurrentContext`. | Wake word brevemente sordo dopo TTS |
| B | `Engine is not running because it was not explicitly started or may have stopped because of an interruption. Cannot play yet!` (461, 1372) | `AVAudioPlayerNode` (SoundEngine earcon) prova a play su engine fermato dalla deactivate post-VAD. Earcon perso. | Earcon "wake" non si sente sempre |
| C | `mBuffers[0].mDataByteSize (0) should be non-zero` (line 465) | `result.speech` è stringa vuota (network error → fallback message vuoto) e `speak("")` viene chiamato; AVSpeech crea utterance vuota. | TTS muto, pill non passa a `.speaking` |
| D | Pill mai in fase `.speaking` con banner risposta | `handleResult` chiama `speak()` poi `finishTurn()` che chiama `completeWithDone` SUBITO, senza aspettare `notifySpeakingFinished`. Pill salta `.speaking` e va dritta a `.done` → torna a `.sleeping`. | Utente non vede "Speaking…" + banner risposta sull'isola |
| E | Network spam (-1004) `192.168.1.45:7779` → bridge errors → speech vuota | Harness server offline. Il client non ha fallback locale per richieste dipendenti. Indipendente dal flow island ma genera path C/D. | Risposta inutile senza Harness |
| F | "Scende come notifica": pill aggiornata MA Dynamic Island già esiste in modalità compact → iOS non triggera l'animazione di "ingresso" perché l'activity è la stessa. | Per ottenere l'animazione "scende", iOS richiede o (i) nuova `Activity.request` o (ii) cambio di `relevanceScore` significativo + presence in lock-screen, o (iii) push update con `AlertConfiguration` (dynamic island Alert). Update silente non ridiscende. | **Goal mancato**: utente non vede pill scendere su "Hey GIGI" |
| G | `Potential Structural Swift Concurrency Issue: unsafeForcedSync called from Swift Concurrent context.` (line 436) | Probabile `MainActor.runUnsafelyOn` o sync access in callback Apple. Da localizzare ma non bloccante per pill. | Warning, possibile crash latente |
| H | Log trunca a 16 256 righe; Xcode console limita ~1000 entries visibili | Apple console buffer. | Difficoltà debug remoto |

## 3. Verità chiave su Dynamic Island (item F)

`Activity.update()` cambia il **content** di una Live Activity esistente ma **non** ne forza la "discesa" / animazione di ingresso. iOS mostra:

- **Compact** (sempre, se attiva) — l'icona/parola accanto al notch
- **Expanded** — solo quando l'utente long-press, o subito dopo `Activity.request()` su nuova activity, o su push con `AlertConfiguration`

Quindi la persistent pill, una volta in `.sleeping`, resta in **compact**. Quando arriva il wake, l'`update()` cambia testo/colore ma NON ri-anima la discesa. Risultato visivo: l'utente non si accorge.

### Soluzione architetturale per item F

Tre opzioni:

1. **Re-request approach** (consigliata): su wake, `end(immediate)` la persistent pill, poi `Activity.request` una nuova activity in `.listening`. iOS anima l'expanded per ~3s. A turno finito, end e re-request persistent in `.sleeping`. Costo: 2 ActivityKit calls per turno. Funziona offline. **Limite iOS**: max ~5 activity richieste in 30s prima di throttle, ma 1 per turno è ben dentro.
2. **Push AlertConfiguration**: richiede APNs + entitlement + push token. Server-side. Overkill per questo use-case.
3. **Accettare compact-only**: cambiare colore/icona drasticamente in compact su `.listening` per dare segnale visivo. Più semplice ma meno "scende come notifica".

Raccomandazione: **opzione 1** — match con la richiesta utente esplicita ("scende come una notifica").

## 4. Task plan ordinato

### P0 — Goal primario: Dynamic Island scende su wake (item F)
- [ ] **T1** — `GigiLiveActivityController`: nuovo metodo `descendForListening()` che:
  1. `end(immediate)` su `monitoringActivity` se attiva
  2. `Activity.request` nuova activity con phase `.listening`, salvandola in `activity` (lo slot turn-scoped già esistente)
  3. Lascia `monitoringActivity = nil` durante il turno
- [ ] **T2** — `GigiWakeWordEngine.handleWakeDetection`: sostituire `beginListening()` con `descendForListening()`
- [ ] **T3** — `finishTurn` flow: dopo `completeWithDone`, ri-aprire la persistent pill (`startPersistentPill` è già idempotente — chiamarla esplicitamente quando turn finisce)

### P0 — Pill in fase .speaking (item D, fix proposto utente)
- [ ] **T4** — `GigiLiveActivityController`: aggiungere `transitionToSpeaking(message:)` (analogo a `transitionToExecuting`)
- [ ] **T5** — `GigiAudioManager`: nuovo callback `onSpeakingFinished: (() -> Void)?` chiamato da `notifySpeakingFinished()` PRIMA del delay/transition logic
- [ ] **T6** — `GigiSmartOrchestrator.handleResult`: dopo `speak(result.speech)` chiamare `transitionToSpeaking(message: banner)` invece di affidarsi a `finishTurn` immediato
- [ ] **T7** — `GigiSmartOrchestrator.finishTurn`: rimuovere `completeWithDone` immediato. Salvare `pendingDoneMessage`. Sottoscrivere `onSpeakingFinished` → quando TTS termina → `completeWithDone(message: pendingDoneMessage)`. Timeout safety 8s nel caso TTS muoia
- [ ] **T8** — Empty-speech path: in `handleResult`, se `result.speech.trimmingCharacters(...).isEmpty`, chiamare `completeWithDone` direttamente (no `speak("")`)

### P1 — TTS engine reliability (items B, C)
- [ ] **T9** — `GigiSpeechService.speak`: `guard !text.trimmed.isEmpty else { return }` — già presente (line 28). Verificare ma early-return previene buffer vuoto
- [ ] **T10** — Empty buffer in log (item C) viene da SoundEngine earcon, non da TTS. Investigare `SoundEngine.play(.taskDone)` quando engine è in stato deactivate

### P1 — Wake-word audio session race (item A)
- [ ] **T11** — `GigiWakeWordEngine`: ritardare `applyPreferredState` di ~600ms dopo `notifySpeakingFinished` per dare tempo a deactivate (già fatto via `presenceFollowUpWindow` 600ms? verificare). Se non basta, aggiungere ref-count check su `GigiAudioSequestrator`

### P2 — Network resilience (item E)
- [ ] **T12** — `GigiHarnessClient`: backoff esponenziale invece di retry continuo, con cutoff dopo N failures
- [ ] **T13** — Banner UX: quando harness offline, mostrare "Offline mode" sulla pill in `.executing` invece di silent fail

### P2 — Concurrency (item G)
- [ ] **T14** — Localizzare `unsafeForcedSync` warning (line 436). Probabile in `Activity.update`/`@MainActor` boundary

## 5. Build & test plan

1. Apply T1–T8 (P0 fixes)
2. Build con xcodebuild su simulator (Dynamic Island disponibile da iPhone 14 Pro+ simulator)
3. Test golden path: app in foreground → background → wake "Hey GIGI" → verificare:
   - Earcon suona
   - Dynamic Island scende espansa in `.listening`
   - STT cattura comando
   - Pill passa a `.thinking` → `.speaking` (con banner) → `.done` (3s) → torna a `.sleeping` persistente
4. Test edge case: harness offline (item E) — pill deve comunque andare a `.done` con messaggio "errore" senza buffer empty crash

## 6. Note critiche prima di codare

- 511 righe (~3% del log) sono state truncate da Xcode tra blocco wake-detection e TTS. **Mancano i log di `LiveActivity transition`, `notifySpeakingStarted`, `notifySpeakingFinished` per il primo turno**. Il root-cause D (pill non a .speaking) è dedotto dal codice, NON confermato dai log. Se utente può ri-runnare con Console.app → Save Log As… (no truncation), confermerebbe.
- Persistent pill ID stabile per intera sessione → conferma che update funziona ma ridiscesa NO (item F).
- Item F è il vero blocker del goal — senza T1/T2/T3 il resto migliora UX ma non risolve "scende come notifica".
