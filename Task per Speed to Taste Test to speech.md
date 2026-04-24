# Task per Speed to Taste Test to Speech

Documento di brainstorming e task plan per la parte voice di GIGI: Quick Talk, Presence Mode con Dynamic Island, Telegram Voice e WhatsApp Voice.

## Visione

GIGI non deve sembrare solo una chat dentro un'app. Deve sembrare una presenza vocale raggiungibile in modi diversi:

- premi e parli;
- GIGI resta nella Dynamic Island durante una sessione;
- dici "GIGI" dentro una sessione attiva e lei si sveglia;
- mandi un vocale su Telegram o WhatsApp e lei risponde con testo o voce;
- usi Action Button, Shortcut, widget o chat esterne come punti di ingresso.

L'esperienza ideale:

```text
Utente attiva GIGI
-> GIGI appare o resta presente
-> "Ciao, come posso aiutarti?"
-> utente parla
-> GIGI ascolta, pensa, risponde a voce
-> torna disponibile
```

## Idee emerse

### 1. Quick Talk

Modalita rapida tipo walkie-talkie.

```text
Tieni premuto Action Button / Shortcut / controllo rapido
-> GIGI ascolta
Rilasci o finisci di parlare
-> GIGI risponde
```

Valore:

- e il modo piu semplice per dare valore subito;
- non richiede una sessione lunga;
- riduce attrito;
- funziona bene come MVP;
- crea la pipeline base audio -> STT -> agente -> TTS.

Possibili nomi:

- Quick Talk
- Hold to Talk
- Push to GIGI
- Walkie

Nome scelto: Quick Talk.

### 2. Presence Mode con Dynamic Island

GIGI resta presente durante la giornata o durante una sessione lunga.

```text
Mattina:
Utente: "GIGI resta con me"
GIGI: "Ci sono."
Dynamic Island: GIGI dorme

Durante la giornata:
Utente: "GIGI"
GIGI: "Dimmi."
Utente parla
GIGI pensa
GIGI risponde
GIGI torna a dormire
```

Stati previsti:

- dorme;
- ascolta;
- pensa;
- parla;
- muto;
- errore;
- in pausa.

Valore:

- GIGI diventa una presenza, non solo un'app;
- la Dynamic Island mostra lo stato reale;
- l'utente capisce sempre se GIGI sta ascoltando, pensando o parlando;
- si possono aggiungere mute, stop e resume dalla UI espansa.

### 3. GIGI su Telegram Voice

Canale opzionale da settings.

```text
Settings
-> Chatta con GIGI
-> Telegram
-> apre chat Telegram
-> utente manda vocale
-> GIGI risponde con testo o vocale
```

Valore:

- facile da provare;
- ottimo per validare agente vocale fuori dall'app;
- utile per utenti che gia vivono su Telegram;
- consente iterazione veloce sul backend.

### 4. GIGI su WhatsApp Voice

Canale opzionale da settings, da fare dopo Telegram.

```text
Settings
-> Chatta con GIGI
-> WhatsApp
-> apre chat o numero GIGI
-> utente manda vocale
-> GIGI risponde
```

Valore:

- canale molto naturale per utenti normali;
- trasforma GIGI in un contatto;
- utile per onboarding e uso quotidiano.

Da fare dopo Telegram perche WhatsApp Business API ha piu setup, regole e vincoli.

## Architettura Base

GIGI deve avere un solo cervello e piu canali.

```text
Audio/Input
-> Normalizzazione
-> STT
-> Agent Runtime
-> Tool / Memory / Policy conferme
-> Risposta
-> TTS/Testo
-> Canale
```

Canali:

```text
1. iOS Quick Talk
2. iOS Presence Mode + Dynamic Island
3. Telegram Voice
4. WhatsApp Voice
```

Scelta tecnica centrale:

Quick Talk, Presence Mode, Telegram e WhatsApp devono essere quattro adapter sopra lo stesso Agent Runtime. Non devono diventare quattro assistenti diversi.

## Moduli iOS

- `QuickTalkController`: entry point da Action Button, Shortcut, widget/control, deep link.
- `PresenceSessionController`: sessione lunga, mute, timeout, riattivazione, conflitti input/output.
- `AudioCaptureService`: microfono, buffering, VAD, cancellazione, interruzione.
- `WakeWordEngine`: wake word interna attiva solo dentro Presence Mode.
- `SpeechService`: STT locale/cloud, streaming parziale, transcript finale.
- `TTSService`: sintesi risposta, stop immediato, ducking audio.
- `AgentClient`: invio utterance al backend, stream eventi, retry.
- `SessionStore`: cronologia breve, stato conversazione, ultimo intent, pending confirmation.
- `LiveActivityController`: ActivityKit + Dynamic Island per listening/thinking/speaking/muted/error.
- `CommandRouter`: mapping intent prioritari verso azioni native, web, memoria, automazioni.

## Moduli Backend

- `Channel Gateway`: endpoint iOS, webhook Telegram, webhook WhatsApp.
- `Audio Ingest Service`: download media e conversione audio.
- `STT Service`: trascrizione batch per Telegram/WhatsApp, streaming o near-real-time per iOS.
- `Agent Runtime`: orchestratore unico con prompt, tool registry, policy conferme, memoria breve e lunga.
- `Session State Service`: sessioni per `userId + channel + deviceId`.
- `TTS Service`: generazione audio risposta, cache breve, formato canale-specifico.
- `Message Dispatcher`: risposta testuale/vocale su iOS, Telegram Bot API, WhatsApp Business Cloud API.
- `Observability`: log strutturati, metriche latenza, STT success rate, intent accuracy, fallimenti tool.

## Session State

Stati comuni:

- `idle`
- `listening`
- `transcribing`
- `thinking`
- `confirming`
- `acting`
- `speaking`
- `muted`
- `interrupted`
- `error`

Ogni sessione deve salvare:

- `sessionId`
- `userId`
- `channel`: `ios_quicktalk`, `ios_presence`, `telegram`, `whatsapp`
- `deviceId`, `chatId` o numero telefono
- `lastTranscript`
- `shortMemory`
- `pendingConfirmation`
- `activeToolCall`
- `lastAssistantMessage`
- `audioMode`: `none`, `listening`, `speaking`, `muted`
- `createdAt`
- `lastSeenAt`
- `expiresAt`

Presence Mode mantiene una sessione viva. Quick Talk crea sessioni brevi e richiudibili.

## Pipeline Audio

### iOS Quick Talk

```text
Action Button / Shortcut / Widget
-> QuickTalkController
-> AVAudioEngine
-> VAD
-> STT
-> Agent Runtime
-> risposta testo
-> TTS
-> playback
```

### iOS Presence Mode

```text
Presence entry point
-> PresenceSessionController
-> audio loop controllato
-> WakeWord / VAD
-> STT parziale/finale
-> Agent Runtime
-> TTS
-> ritorno listening/dorme
```

### Telegram Voice

```text
Telegram Bot webhook
-> voice message OGG/Opus
-> download file
-> normalizzazione audio
-> STT batch
-> Agent Runtime
-> risposta testo o voice note
```

### WhatsApp Voice

```text
WhatsApp webhook
-> media id
-> download media
-> normalizzazione audio
-> STT batch
-> Agent Runtime
-> risposta testo o audio
```

## Dynamic Island / Live Activity

La Dynamic Island deve essere il pannello operativo di Presence Mode, non solo decorazione.

Stati compatti:

- presenza attiva;
- microfono/ascolto;
- muto;
- speaking pulse.

Stati espansi:

- stato corrente: ascolto, penso, rispondo, muto;
- pulsante mute/unmute;
- pulsante stop;
- ultimo transcript breve o sintesi stato;
- errore recuperabile.

Eventi da riflettere:

- `presence.started`
- `audio.listening`
- `audio.muted`
- `agent.thinking`
- `tts.speaking`
- `session.interrupted`
- `session.timeout`
- `session.ended`
- `session.error`

## Settings Prodotto

Sezione proposta:

```text
Voice access

[ ] Presence Mode
    Tieni GIGI disponibile nella Dynamic Island

[ ] Wake word
    Frase: GIGI

[ ] Quick Talk
    Usa Action Button / Shortcut per parlare subito

External chat

Telegram
[Connetti]

WhatsApp
[Apri chat]
```

## Milestone 0: Fondazioni

Obiettivo: definire il contratto comune per tutti i canali.

Task:

1. Definire i 4 casi d'uso principali: Quick Talk, Presence, Telegram Voice, WhatsApp Voice.
2. Formalizzare gli stati conversazione.
3. Definire modello comando: intent, confidence, required confirmation, tool target.
4. Definire schema sessione comune.
5. Definire metriche: latenza STT, latenza agente, intent success, errore canale, completamento task.
6. Definire criterio "task completato": risposta corretta, azione eseguita o fallback esplicito.
7. Creare matrice comandi prioritari.

Done:

- esiste una specifica unica per session state, comandi, metriche e stati;
- ogni milestone successiva usa lo stesso contratto.

Rischi:

- stati impliciti e diversi tra canali;
- conferme non uniformi;
- metriche non confrontabili tra iOS, Telegram e WhatsApp.

## Milestone 1: Quick Talk MVP

Obiettivo: comando vocale rapido funzionante end-to-end.

Architettura:

```text
Action Button / Shortcut / Widget
-> QuickTalkController
-> AudioCapture
-> STT
-> AgentClient
-> Agent Runtime
-> risposta testuale
-> TTS
```

Task:

1. Creare `QuickTalkController`.
2. Aggiungere trigger da app.
3. Aggiungere trigger da Shortcut/App Intent compatibile Action Button.
4. Creare schermata listening minimale.
5. Implementare acquisizione audio con VAD.
6. Integrare STT con transcript finale.
7. Inviare transcript al backend.
8. Ricevere risposta testuale dall'agente.
9. Implementare TTS della risposta.
10. Aggiungere stop manuale.
11. Aggiungere interruzione durante TTS.
12. Gestire errori microfono, STT, rete, agente.
13. Salvare cronologia locale ultimi comandi.
14. Testare 10 comandi reali.

Done:

- 10 comandi vocali eseguiti da trigger rapido;
- ogni comando produce transcript, risposta e TTS;
- stop e interruzione non lasciano sessioni bloccate.

Rischi:

- latenza percepita troppo alta;
- STT incompleto su frasi brevi;
- trigger Action Button da progettare tramite Shortcut/App Intent.

## Milestone 2: Quick Talk Operativo

Obiettivo: rendere Quick Talk affidabile per comandi reali.

Task:

1. Aggiungere conferme per azioni sensibili.
2. Definire intent prioritari: messaggi, reminder, ricerca, note, calendario.
3. Aggiungere fallback: "non ho capito", "posso fare X o Y?", "serve conferma".
4. Aggiungere memoria breve per multi-turno immediato.
5. Aggiungere logging strutturato per comando.
6. Creare suite test da 20 frasi realistiche.
7. Classificare esiti: `success`, `partial`, `fallback`, `fail`.
8. Raggiungere soglia >= 80%.

Done:

- almeno 16/20 frasi completano correttamente il task o arrivano a una conferma corretta;
- le azioni rischiose non partono senza conferma;
- i fallimenti sono loggati con causa leggibile.

Rischi:

- intent ambigui;
- conferme troppo lunghe;
- memoria breve che altera comandi indipendenti.

## Milestone 3: Presence Mode MVP

Obiettivo: sessione vocale persistente e controllabile.

Architettura:

```text
Presence entry point
-> PresenceSessionController
-> Audio loop + WakeWord/VAD
-> STT
-> Agent Runtime
-> TTS
-> ritorno listening/dorme
```

Task:

1. Definire comportamento sessione persistente.
2. Creare `PresenceSessionController`.
3. Creare entry point da app.
4. Creare entry point da widget/control.
5. Creare entry point da Shortcut.
6. Implementare stati: `idle`, `listening`, `thinking`, `speaking`, `muted`, `error`.
7. Implementare wake word interna "GIGI" dentro sessione.
8. Implementare VAD per capire quando l'utente parla.
9. Implementare mute/unmute.
10. Implementare timeout inattivita.
11. Implementare riattivazione dopo timeout breve.
12. Mostrare stato corrente in app.
13. Gestire barge-in: utente interrompe mentre GIGI parla.
14. Evitare loop audio tra speaker e microfono.
15. Testare sessione continua da 10 minuti.

Done:

- Presence Mode resta stabile per 10 minuti;
- wake word o VAD riattivano ascolto dentro la sessione;
- mute, unmute, stop e timeout sono affidabili;
- nessun loop audio tra TTS e STT.

Rischi:

- consumo batteria;
- audio feedback tra speaker e microfono;
- sessioni zombie;
- wake word troppo sensibile o troppo poco sensibile.

## Milestone 4: Dynamic Island

Obiettivo: rendere Presence Mode visibile e governabile dalla Dynamic Island.

Task:

1. Creare `LiveActivityController`.
2. Definire contenuti compact/minimal/expanded.
3. Disegnare stato compatto.
4. Disegnare stato espanso.
5. Collegare Live Activity alla sessione Presence.
6. Aggiornare stati listening/thinking/speaking/muted/error.
7. Aggiungere azione mute/unmute.
8. Aggiungere azione stop sessione.
9. Aggiungere feedback visivo durante thinking e speaking.
10. Gestire chiusura Live Activity a fine sessione.
11. Testare transizioni stato.

Done:

- Dynamic Island riflette sempre lo stato reale della sessione;
- mute e stop funzionano dalla UI espansa;
- nessuna Live Activity resta aperta dopo fine sessione;
- transizioni testate: start, listening, thinking, speaking, muted, error, stop.

Rischi:

- ActivityKit ha aggiornamenti limitati;
- stato UI e stato sessione possono divergere;
- azioni dalla Dynamic Island devono essere idempotenti.

## Milestone 5: Telegram Voice

Obiettivo: l'utente manda un vocale Telegram a GIGI e riceve una risposta utile.

Architettura:

```text
Telegram Bot webhook
-> voice download
-> audio normalize
-> STT
-> Agent Runtime
-> response dispatcher
-> text/voice reply
```

Task:

1. Creare adapter Telegram come modulo separato.
2. Configurare bot Telegram.
3. Configurare webhook ricezione messaggi vocali.
4. Scaricare file audio Telegram.
5. Normalizzare formato audio.
6. Eseguire STT batch.
7. Mappare Telegram user/chat id a GIGI user.
8. Inviare transcript all'Agent Runtime.
9. Rispondere con testo.
10. Rispondere con voice note.
11. Gestire conferme per azioni sensibili.
12. Gestire errori audio non valido, STT fallito, agente non disponibile.
13. Testare 15 vocali reali.

Done:

- 15 vocali Telegram ricevuti, trascritti e processati;
- almeno 12/15 ricevono risposta corretta o richiesta di chiarimento;
- risposte consegnate nello stesso thread;
- identita utente persistente;
- errori media/STT/API non rompono il webhook.

Rischi:

- payload audio variabili;
- rate limit Bot API;
- conferme asincrone;
- modulo Telegram da isolare come channel adapter.

## Milestone 6: WhatsApp Voice

Obiettivo: replicare il flusso Telegram su WhatsApp ufficiale.

Architettura:

```text
WhatsApp webhook
-> media id
-> media download
-> audio normalize
-> STT
-> Agent Runtime
-> WhatsApp dispatcher
-> text/audio reply
```

Task:

1. Configurare WhatsApp Business Cloud API.
2. Verificare webhook.
3. Parsare payload messaggi vocali.
4. Scaricare media tramite media id.
5. Normalizzare audio.
6. Eseguire STT batch.
7. Mappare numero telefono a GIGI user.
8. Inviare transcript all'Agent Runtime.
9. Rispondere con testo WhatsApp.
10. Rispondere con audio dove supportato.
11. Gestire template e session window.
12. Gestire conferme per azioni sensibili.
13. Gestire errori user-friendly.
14. Testare 15 vocali reali.

Done:

- 15 vocali WhatsApp ricevuti, trascritti e processati;
- almeno 12/15 completano o chiedono chiarimento;
- risposta consegnata via canale ufficiale;
- identita per numero stabile;
- gestione corretta della finestra conversazionale WhatsApp.

Rischi:

- vincoli WhatsApp Business su template e finestre conversazionali;
- download media con token e scadenze;
- compatibilita formato audio;
- consenso e privacy sul numero utente.

## Ordine di Implementazione

1. Fondazioni comuni.
2. Quick Talk MVP.
3. Quick Talk Operativo.
4. Presence Mode MVP.
5. Dynamic Island / Live Activity.
6. Telegram Voice.
7. WhatsApp Voice.

## Prima Release Consigliata

Prima release pubblicabile:

```text
Quick Talk Operativo
+ Presence Mode MVP base
```

Telegram e WhatsApp arrivano dopo, perche dipendono dalla qualita della pipeline vocale, dalle conferme e dalla gestione identita.

## Definition of Done Generale

Un task e completato solo se:

- ha un comportamento osservabile;
- ha un criterio di successo verificabile;
- gestisce almeno un errore prevedibile;
- e testato manualmente con casi reali;
- non lascia stati incoerenti per l'utente;
- e documentato nel changelog/prodotto con cosa e cambiato.

## Test Manuali Iniziali

Comandi Quick Talk da provare:

1. "GIGI, ricordami alle 18 di chiamare Luca."
2. "Prendi nota: domani comprare il regalo."
3. "Cerca un ristorante vicino a me."
4. "Mandami un riassunto della giornata."
5. "Sposta quel promemoria a domani."
6. "Annulla."
7. "Ripeti."
8. "Fermati."
9. "Scrivi un messaggio a Marco: arrivo tra dieci minuti."
10. "Cosa devo fare oggi?"

Test Presence:

1. Avvio sessione.
2. Stato Dynamic Island: dorme.
3. Wake word: "GIGI".
4. GIGI passa ad ascolto.
5. Utente parla.
6. GIGI pensa.
7. GIGI risponde.
8. GIGI torna a dorme.
9. Mute/unmute.
10. Stop sessione.

Test Telegram/WhatsApp:

1. Vocale breve.
2. Vocale lungo.
3. Vocale rumoroso.
4. Richiesta ambigua.
5. Richiesta con conferma.
6. Risposta testuale.
7. Risposta vocale.
8. Errore audio.
9. Errore rete/API.
10. Ripresa conversazione dopo qualche minuto.

