# GIGI Voice Assistant System Analysis

Data analisi: 2026-04-26

## Domanda

Analizzare il sistema voice attuale di GIGI e definire cosa manca per arrivare a una esperienza tipo Siri, ma piu intelligente: wake word "Hey GIGI", Dynamic Island sempre visibile finche l'utente non chiude, conversazione sia dentro l'app sia fuori dall'app, microfono il piu possibile sempre eleggibile senza essere killato da iOS.

## Sintesi classificata

| Rank | Spiegazione | Confidenza | Base |
|---|---|---:|---|
| 1 | Il sistema voice esiste gia come pipeline locale iOS: Presence Mode -> wake word -> VAD/STT -> orchestrator -> AI/tools -> TTS -> ritorno a listening/wake. | Alta | Codice in `PresenceSessionController`, `GigiAudioManager`, `GigiWakeWordEngine`, `GigiVADEngine`, `GigiSmartOrchestrator`. |
| 2 | La Dynamic Island e gia integrata e ha due modelli: activity persistente/presence e activity di turno per far "scendere" l'isola su wake. | Alta | `GigiLiveActivityController` gestisce `monitoringActivity`, `presenceActivity`, `descendForListening()`, `transitionToThinking()`, `transitionToSpeaking()`, `completeWithDone()`. |
| 3 | Il vincolo principale non e il codice, ma iOS: nessuna app terza puo avere una wake word affidabile come Siri a processo morto; si puo solo massimizzare affidabilita con foreground/background audio, Live Activity, AppIntent/Siri Shortcuts, APNS e recovery. | Alta | `GigiQuickTalkIntent.openAppWhenRun = true`, background modes audio/fetch/remote-notification, lifecycle che risincronizza Presence solo quando l'app torna attiva. |
| 4 | Il backend harness e testuale/agentico, non un realtime audio backend sempre-on. L'audio continuo e quasi tutto lato iOS; harness riceve testo via `/api/ios/agent/run` e puo streammare eventi Claude, non audio mic live. | Alta | `GigiHarnessClient.agentRun`, `03_HARNESS/server/api/ios-agent.js`, `ios-integration.md`. |
| 5 | Per l'obiettivo "GIGI personale voice assistant su device" serve consolidare il prodotto attorno a Presence Mode come singolo owner, aggiungere recovery/telemetria/QA device e decidere esplicitamente quale promessa fare quando iOS sospende o killa il processo. | Media | Inferenza dai vincoli e dalla divisione attuale tra Presence, QuickTalk, AppIntent, Live Activity, APNS. |

## Evidenza diretta

- `02_GIGI_APP/GIGI/PresenceSessionController.swift:7` definisce una sessione Presence long-lived con ciclo `start -> wake word / VAD -> STT -> agent -> TTS -> return to sleeping`.
- `02_GIGI_APP/GIGI/PresenceSessionController.swift:66` salva la preferenza "always available" e avvia o ferma la sessione.
- `02_GIGI_APP/GIGI/PresenceSessionController.swift:86` avvia sessione, setta `isPresenceActive = true`, abilita `presenceMode`, ferma la pill persistente vecchia e crea `presenceActivity`.
- `02_GIGI_APP/GIGI/PresenceSessionController.swift:296` non termina la sessione per inattivita quando `alwaysAvailable` e attivo.
- `02_GIGI_APP/GIGI/GigiWakeWordEngine.swift:57` elenca le keyword: `hey gigi`, `ok gigi`, `hi gigi`, `ehi gigi`, `ciao gigi`, `dai gigi`, `gigi`.
- `02_GIGI_APP/GIGI/GigiWakeWordEngine.swift:142` limita il wake word a Presence Mode: se `isPresenceActive` e falso, ferma il monitoring.
- `02_GIGI_APP/GIGI/GigiWakeWordEngine.swift:274` attiva la sessione audio prima di avviare recognition task, poi installa tap su `AVAudioEngine`.
- `02_GIGI_APP/GIGI/GigiWakeWordEngine.swift:561` su wake detection ferma il monitoring, pre-riscalda Bluetooth, aggiorna Live Activity e chiama `GigiSmartOrchestrator.startListening()`.
- `02_GIGI_APP/GIGI/GigiAudioManager.swift:59` dichiara che wake word e permesso solo dentro Presence Mode.
- `02_GIGI_APP/GIGI/GigiAudioManager.swift:141` dopo TTS, in Presence Mode, passa direttamente a recording per una finestra follow-up senza richiedere di nuovo "Hey GIGI".
- `02_GIGI_APP/GIGI/GigiVADEngine.swift:9` descrive la pipeline: capture audio, STT partial, VAD, silence detection, final transcript.
- `02_GIGI_APP/GIGI/GigiVADEngine.swift:263` quando rileva silenzio ferma capture e aspetta STT final, con fallback snapshot dopo 3 secondi.
- `02_GIGI_APP/GIGI/GigiSmartOrchestrator.swift:155` processa il testo, aggiorna Live Activity a thinking, passa al motore agentico e gestisce TTS.
- `02_GIGI_APP/GIGI/GigiSmartOrchestrator.swift:336` QuickTalk dentro app avvia listening via `GigiAudioManager.startRecording()` e Live Activity `beginListening()`.
- `02_GIGI_APP/GIGI/GigiLiveActivityController.swift:73` documenta `descendForListening()` come discesa Dynamic Island su wake: termina activity standby e richiede una nuova activity `.listening`.
- `02_GIGI_APP/GIGI/GigiLiveActivityController.swift:98` usa `AlertConfiguration` su update della nuova activity per attirare attenzione.
- `02_GIGI_APP/GIGI/GigiLiveActivityController.swift:480` crea una Presence Live Activity persistente in stato `.sleeping` con messaggio "Ready - say Hey GIGI".
- `02_GIGI_APP/GIGIWidget/GigiLiveActivityWidget.swift:13` definisce UI Lock Screen e Dynamic Island per `GigiActivityAttributes`.
- `02_GIGI_APP/GIGI/GigiActivityAttributes.swift:33` enumera fasi `listening`, `thinking`, `executing`, `done`, `sleeping`, `speaking`, `muted`, `error`.
- `02_GIGI_APP/GIGI/Info.plist:86` abilita `UIBackgroundModes`: `audio`, `fetch`, `remote-notification`.
- `02_GIGI_APP/GIGI/Info.plist:5` abilita Live Activities e frequent updates.
- `02_GIGI_APP/GIGI/GigiQuickTalkIntent.swift:14` imposta `openAppWhenRun = true`, con commento "mic requires foreground".
- `02_GIGI_APP/GIGI/GIGIApp.swift:25` su scene active risincronizza Presence; `onOpenURL gigi://listen` avvia Presence e listening.
- `02_GIGI_APP/GIGI/GigiHarnessClient.swift:207` invia testo a `/api/ios/agent/run` con `deviceId`, `text`, `stream`.
- `03_HARNESS/server/api/ios-agent.js:13` riceve `/api/ios/agent/run`, mette in coda per device e chiama Claude; se `stream=true` manda eventi su WebSocket.
- `03_HARNESS/docs/api/ios-integration.md:140` documenta APNS register/test e payload di push.

## Inferenze

- Presence Mode e il cuore giusto per l'esperienza richiesta: e l'unico punto che coordina wake word, Dynamic Island, stato audio e sessione sempre disponibile.
- QuickTalk e AppIntent sono utili come ingresso manuale/Siri Shortcut, ma non sostituiscono un wake word always-on perche l'intent apre l'app.
- La Dynamic Island puo restare visibile, ma "scendere" ogni volta richiede creare o aggiornare Live Activity con attenzione; un semplice `Activity.update()` su pill gia compact non basta sempre a generare l'effetto visivo desiderato.
- L'esperienza "come Siri" va definita come "best effort iOS-compliant": funziona quando Presence e attiva e il processo resta vivo con background audio, ma non puo promettere wake word da processo killato o dopo sospensione aggressiva del sistema.
- La parte "piu intelligente" e gia orientata a agenti/tools/memoria/harness, ma la voice UX deve garantire stati chiari: ready, listening, thinking, speaking, muted, error/offline.

## Limiti e incognite

- Non ho verificato su dispositivo fisico in questa analisi. Dynamic Island, background audio e kill behavior vanno validati su iPhone reale, non solo simulator.
- Il repo non prova con test automatici il comportamento iOS background/lock screen; questi scenari richiedono QA manuale/device logs.
- Non e dimostrato dal repo che iOS mantenga il microfono sempre attivo indefinitamente in ogni condizione. Il codice prova a ridurre deactivation in background, ma il sistema operativo resta autoritativo.
- Il file `voice.md` contiene alcune affermazioni potenzialmente precedenti allo stato attuale, per esempio il flow "sempre-on WakeWordEngine" va letto oggi come Presence Mode, non come wake word standalone.

## Architettura target raccomandata

### Principio

Un solo proprietario dell'esperienza sempre disponibile: `PresenceSessionController`.

### Stati prodotto

| Stato | Significato | Owner tecnico |
|---|---|---|
| Ready | GIGI e disponibile, wake word attiva se iOS lo permette | Presence + WakeWord |
| Listening | Microfono attivo dopo wake/tap/follow-up | AudioManager + VAD |
| Thinking | Transcript acquisito, agent loop in corso | SmartOrchestrator + AgentEngine |
| Speaking | TTS in corso, island mostra risposta | SpeechService + AudioManager |
| Follow-up | Dopo TTS, microfono aperto per 8s senza nuova wake word | AudioManager |
| Muted | Sessione visibile ma mic fermo | Presence |
| Error/Offline | Problema audio, permessi, harness, rete | Presence + LiveActivity |
| Closed | Utente preme X/stop: termina Presence e mic | Presence + LiveActivity |

### Flusso ideale fuori app

1. Utente abilita "GIGI always available".
2. Presence crea Live Activity persistente "Ready - say Hey GIGI".
3. WakeWord ascolta solo dentro Presence.
4. Utente dice "Hey GIGI".
5. WakeWord ferma il monitor, prewarm audio, Dynamic Island passa a listening con attenzione.
6. VAD/STT registra il comando.
7. Orchestrator passa a thinking e chiama AI/tools.
8. TTS parla e island mostra speaking.
9. Dopo TTS, GIGI apre follow-up per 8s.
10. Se silenzio, torna a wake-word standby.
11. Se utente preme X/Stop, Presence chiude Live Activity e ferma audio.

## Task plan

### P0 - Stabilizzare la promessa "sempre disponibile"

- [ ] Definire copy prodotto: "GIGI resta disponibile finche Presence e attiva; se iOS sospende l'app, usa tap/Siri Shortcut/notification per riattivare".
- [ ] Audit `PresenceSessionController` come unico owner: nessun altro percorso deve avviare wake word fuori Presence.
- [ ] Aggiungere stato visibile "Background limited" quando l'app rientra dopo sospensione e deve risincronizzare Presence.
- [ ] QA su device: lock screen 5, 15, 30, 60 minuti con Presence attiva; annotare quando wake word resta vivo o viene sospeso.

### P0 - Dynamic Island come superficie principale

- [ ] Verificare su iPhone reale che `descendForListening()` produca l'effetto "scende" su wake fuori app.
- [ ] Aggiungere controllo utente chiaro nella Dynamic Island: Stop/X, Mute/Unmute, Tap to talk.
- [ ] Garantire che a fine turno Presence venga sempre ripristinata dopo una turn activity.
- [ ] Testare throttling ActivityKit: 10 wake ravvicinati, lock screen, background, app foreground.

### P0 - Audio lifecycle e kill resistance

- [ ] Validare che `GigiAudioSequestrator.deactivate()` non lasci sessioni zombie in background.
- [ ] Tracciare metriche: wake engine started/stopped/failed, audio session active/inactive, app lifecycle, interruption, route changes.
- [ ] Aggiungere recovery quando wake engine fallisce: retry con backoff + Live Activity error actionable.
- [ ] Verificare che phone call, AirPods, Bluetooth disconnect e Low Power Mode non generino loop audio.

### P1 - Wake word qualita

- [ ] Misurare false positive su `gigi` singolo; valutare se tenere bare "gigi" o richiedere frasi piu specifiche.
- [ ] Valutare fallback locale dedicato keyword spotting se SFSpeech e instabile, senza introdurre dipendenze finche non c'e evidenza device.
- [ ] Aggiungere calibrazione rumore ambiente e soglie separate per wake vs VAD.

### P1 - Conversazione piu naturale

- [ ] Rendere follow-up post-TTS esplicito in UI: `Listening` per 8s, poi `Ready`.
- [ ] Barge-in: testare mentre GIGI parla; confermare che interrompe TTS e non chiude la pill in `Done`.
- [ ] Normalizzare lingua italiana/inglese: keyword italiane, STT locale, TTS voice e prompt output devono essere coerenti.

### P1 - Intelligenza agentica

- [ ] Separare chiaramente "risposta conversazionale veloce" da "azione/tool" nella pipeline.
- [ ] Se harness e offline, mostrare risposta locale utile invece di errore generico.
- [ ] Usare stream events harness per aggiornare Dynamic Island in `thinking/executing` con caption compatte.
- [ ] Definire quali azioni sono safe senza conferma e quali richiedono confirm in Presence.

### P2 - Recovery fuori app

- [ ] APNS silent/alert: usare solo per risultati asincroni, confirm e recovery, non come wake word.
- [ ] AppIntent/Siri Shortcut: mantenere "Talk to GIGI" come fallback ufficiale quando Presence non e viva.
- [ ] URL `gigi://listen`: confermare che tap su Live Activity riapra ascolto in tutti gli stati.

### P2 - Osservabilita e test

- [ ] Creare matrice test device: foreground, background, locked, Low Power, AirPods, call interruption, network offline, harness offline.
- [ ] Salvare log strutturati per ogni turnId: wake -> listening -> transcript -> thinking -> speaking -> done -> ready.
- [ ] Aggiungere pannello debug iOS per stato Presence/wake/audio/Live Activity.

## Decisioni da prendere prima di implementare

1. Promessa prodotto: "always available finche iOS consente background audio" oppure "sempre con fallback tap/Siri".
2. Wake phrase: accettare `gigi` singolo o solo `hey/ehi/ok GIGI` per ridurre false positive.
3. Dynamic Island: preferire re-request per discesa visiva o compact-only piu stabile.
4. Lingua default: italiano, inglese, o bilingue adattivo.
5. Privacy: come comunicare chiaramente quando il microfono e attivo.

## Conclusione

Il repo e gia vicino a una architettura corretta: Presence Mode, AudioManager, WakeWord, VAD/STT, Live Activity e Orchestrator sono separati abbastanza bene. Il lavoro principale non e "aggiungere voice da zero", ma rendere affidabile e verificata l'esperienza always-available dentro i limiti iOS, con Dynamic Island come superficie persistente e con recovery quando il sistema operativo sospende o termina il processo.
o