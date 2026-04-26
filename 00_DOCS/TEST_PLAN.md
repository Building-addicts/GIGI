# GIGI — Test Plan Completo (2026-04-26)

> **Scope**: tutto ciò che è stato costruito in questo workspace.
> **Come usare**: esegui ogni scenario nell'ordine elencato. Ogni scenario ha:
> - **Setup**: prerequisiti prima di iniziare
> - **Passi**: cosa fare esattamente

> **Output atteso**: cosa DEVE succedere
> - **Output KO**: cosa indica un bug
>
> **Legenda stato**: ⬜ Da fare · ✅ Passato · ❌ Fallito · ⏭️ Saltato (dipendenza non soddisfatta)

---

## AREA 1 — ONBOARDING & CONFIGURAZIONE

### T1.1 — Primo avvio (nessun dato salvato)
**Setup**: cancella app da iPhone → reinstalla `.ipa` fresca (nessun dato Keychain).

**Passi**:
1. Apri app
2. Osserva se compare schermata onboarding

**Output atteso**:
- Schermata onboarding appare automaticamente
- Step 1: benvenuto
- Step 2: campi "Groq API key" e "Gemini API key" visibili
- Step 3: profilo (nome, email, telefono, indirizzo, città, CAP)
- Step 4: riepilogo

**Output KO**: app va direttamente a tab principale senza onboarding → `UserDefaults gigi.onboarding.complete` non viene resettato correttamente.

---

### T1.2 — Salvataggio Groq API key via Onboarding
**Setup**: T1.1 completato, sei allo Step 2.

**Passi**:
1. Inserisci chiave Groq valida (inizia con `gsk_`)
2. Premi Continua
3. Completa onboarding fino alla fine
4. Vai in Settings → sezione Brain
5. Osserva campo chiave

**Output atteso**:
- Campo mostra `gsk_••••••` (mascherato)
- Tasto "Test Connection" → risponde "✓ Connected (llama-3.3-70b)"

**Output KO**: campo vuoto → `GigiConfig.setGroqAPIKey` non salva in Keychain.

---

### T1.3 — Salvataggio Gemini API key via Onboarding
**Setup**: T1.1 completato.

**Passi**:
1. Step 2 onboarding: inserisci chiave Gemini valida (`AIzaSy...`)
2. Completa onboarding
3. Vai Settings → cerca sezione Gemini
4. Poi parla: "ciao" (conversazionale)

**Output atteso**:
- Chiave salvata in Keychain slot `gemini_api_key`
- `GigiRealtimeEngine` tenta connessione WebSocket a Gemini Live
- Log console: `GIGI Realtime: ✓ connesso` (o simile, NO "skip connect — Gemini key mancante in Keychain")

**Output KO**: log mostra "skip connect — Gemini key mancante in Keychain" → regressione fix sicurezza di oggi.

---

### T1.4 — Profilo utente salvato su iCloud
**Setup**: iCloud attivo sull'iPhone, onboarding completato con nome/email/telefono.

**Passi**:
1. Completa Step 3 onboarding con dati reali
2. Apri app su secondo device con stesso Apple ID (se disponibile)
3. Oppure: forza chiusura app + riapertura

**Output atteso**:
- Dopo riapertura, Settings mostra profilo con i dati inseriti
- Dashboard → card "Your Profile" mostra score > 0

**Output KO**: dati scomparsi → persistenza CloudKit non funziona.

---

## AREA 2 — VOICE & AUDIO

### T2.1 — Wake Word "GIGI"
**Setup**: Picovoice key configurata in Settings. App in background, schermo spento.

**Passi**:
1. Aspetta 5 secondi (app stabile)
2. Di' chiaramente: **"GIGI"**
3. Osserva feedback visivo e audio

**Output atteso**:
- App si attiva (non necessariamente foreground)
- Suono earcon di attivazione
- Stato passa a "Listening..."
- Microfono attivo (indicatore iOS in alto)

**Output KO**: nessuna reazione → wake word engine non funzionale (issue aperto noto — documenta se passa o fallisce).

---

### T2.2 — Registrazione e STT base
**Setup**: app in foreground, nessun audio in play.

**Passi**:
1. Premi pulsante Quick Talk (FAB in basso a destra in ChatView)
2. Di': **"che ore sono"**
3. Aspetta risposta

**Output atteso**:
- Stato: "Listening..." → "Thinking..." → risposta
- GIGI risponde con ora attuale (es: "Sono le 15:42")
- Risposta TTS vocale udibile
- Bolla chat "GIGI" appare in ChatView

**Output KO**:
- Stato resta "Listening..." forever → VAD non rileva silenzio
- Risposta vuota → STT non funziona
- No TTS → GigiSpeechService non parte

---

### T2.3 — Duck audio durante TTS
**Setup**: Spotify o Apple Music in play.

**Passi**:
1. Avvia musica su Spotify
2. Attiva Quick Talk → di' "che ore sono"
3. Osserva volume Spotify durante risposta GIGI

**Output atteso**:
- Spotify si abbassa durante TTS GIGI
- Spotify torna al volume normale dopo che GIGI finisce di parlare

**Output KO**: musica non si abbassa → `GigiAudioSequestrator.notifySpeechStarted()` non triggerata.

---

### T2.4 — Barge-in (interrompi GIGI mentre parla)
**Setup**: GIGI sta dando una risposta lunga.

**Passi**:
1. Di' qualcosa che genera risposta lunga (es. "raccontami una storia")
2. Mentre GIGI parla, inizia a parlare tu

**Output atteso**:
- GIGI smette di parlare entro ~1s
- App torna in stato "Listening..."
- La tua nuova frase viene processata

**Output KO**: GIGI continua a parlare ignorandoti → `GigiRealtimeEngine.onBargein` non triggerato (solo se Gemini Live attivo).

---

## AREA 3 — BRAIN PIPELINE

### T3.1 — Level 3 Fallback (NLU locale, offline)
**Setup**: disabilita WiFi e dati cellulare sull'iPhone.

**Passi**:
1. Quick Talk → "chiama mamma"

**Output atteso**:
- GIGI risponde "Calling mamma." o "Chi vuoi chiamare?" (se contatto non risolto)
- Azione di chiamata avviata
- Banner "⚠️ Offline — limited responses" NON appare (azione nativa — non serve cloud)

**Output KO**: nessuna risposta, spinner infinito → NLU locale non funziona offline.

---

### T3.2 — Level 2 Groq REST
**Setup**: WiFi attivo, Groq key valida, Gemini key NON configurata (o Gemini Live disconnesso), Foundation Models non supportato (iPhone non 15 Pro).

**Passi**:
1. Quick Talk → "che tempo fa domani a Milano"

**Output atteso**:
- Log: `GIGI brain: Gemini ✓` oppure `GIGI brain: Foundation Models ✓` — MA se non disponibili → `GIGI brain: Groq ✓` (o simile)
- Risposta meteo via `GigiAgentEngine` + tool `WeatherTool`
- Risposta TTS con previsioni

**Output KO**: spinner infinito o "I ran into trouble" → Groq API key non valida o timeout.

---

### T3.3 — Agent Loop con tool calling
**Setup**: Groq key valida.

**Passi**:
1. Quick Talk → **"aggiungi una riunione col dottor Rossi giovedì alle 15"**
2. Osserva ChatView

**Output atteso**:
- Stato: "Thinking..." con eventuali tool event bubble (gear icon in chat)
- `CreateEventTool` chiamato con: titolo="Riunione dottor Rossi", data=giovedì, ora=15:00
- iOS Calendar sheet appare (o evento creato direttamente se permesso già dato)
- GIGI: "Aggiunto al calendario per giovedì alle 15."

**Output KO**:
- Nessun Calendar sheet → `GigiActionDispatcher.handleCalendar()` non raggiunto
- Tool event bubble non appare → `GigiConversationMemory.addToolEvent()` non chiamato

---

### T3.4 — Conferma richiesta (payment action)
**Setup**: harness configurato (URL + secret in Keychain) oppure simula con tool `web_book_restaurant`.

**Passi**:
1. Quick Talk → **"prenota un tavolo da Nobu per due persone stasera alle 20"**
2. GIGI chiede conferma
3. Rispondi **"sì"**

**Output atteso**:
- GIGI: "Vuoi che prenoti da Nobu per 2 persone stasera alle 20?" (o simile)
- Dopo "sì": avvia web booking (o harness se configurato)
- Stato: "Booking..."

**Output KO**:
- GIGI esegue subito senza chiedere → confirmation gate non attivo
- Dopo "sì" niente succede → `confirmAndContinue()` non richiama il tool pending

---

### T3.5 — Force Claude Mode
**Setup**: harness attivo e raggiungibile. Settings → Brain Mode → "Force Claude" ON.

**Passi**:
1. Quick Talk → **"analizza il mio calendario questa settimana e dimmi se sono sovraccarico"**
2. Osserva ChatView durante elaborazione

**Output atteso**:
- Chat mostra bubble grigie italic con 💭 (pensieri Claude in streaming)
- Bubble gear icon per tool events
- Risposta finale appare dopo 5-15s
- Risposta è di qualità Claude (non Groq)

**Output KO**:
- Nessuna bubble 💭 → streaming WebSocket non funziona
- Risposta immediata senza pensieri → Force Claude bypass non attivo
- "Harness non raggiungibile" → controlla URL in Keychain

---

### T3.6 — Auto Fallback (Force Claude + harness down)
**Setup**: Force Claude ON, Auto Fallback ON. Spegni il server harness.

**Passi**:
1. Quick Talk → "che ore sono"

**Output atteso**:
- GIGI risponde normalmente via Groq (silently fell back)
- Nessun messaggio di errore harness all'utente
- Log: "harness unreachable, falling back to Groq"

**Output KO**:
- "Harness non disponibile" mostrato all'utente → auto-fallback non attivo
- Spinner infinito → timeout non gestito

---

## AREA 4 — AZIONI NATIVE

### T4.1 — Chiamata telefonica
**Setup**: contatto "Mamma" o "Marco" in rubrica iPhone.

**Passi**:
1. Quick Talk → **"chiama Marco"**

**Output atteso**:
- iOS mostra schermata chiamata in uscita verso Marco
- GIGI: "Sto chiamando Marco."

**Output KO**: "Chi vuoi chiamare?" (disambiguazione) → contatto non trovato in rubrica. Controlla permesso Contatti.

---

### T4.2 — Messaggio WhatsApp
**Setup**: WhatsApp installato, contatto in rubrica.

**Passi**:
1. Quick Talk → **"manda un messaggio WhatsApp a Marco: ci vediamo alle 8"**

**Output atteso**:
- WhatsApp apre con messaggio pre-compilato a Marco
- GIGI: "Messaggiando Marco su WhatsApp."

**Output KO**: apre iMessage invece → platform detection errata in `GigiActionDispatcher`.

---

### T4.3 — Evento calendario
**Setup**: permesso Calendario concesso.

**Passi**:
1. Quick Talk → **"crea evento 'Dentista' domani alle 10"**

**Output atteso**:
- Calendar sheet pre-compilato: titolo=Dentista, data=domani, ora=10:00
- Dopo conferma: GIGI "Aggiunto al calendario."

**Output KO**: sheet vuoto o con campi sbagliati → slot filling `CreateEventTool` non funziona.

---

### T4.4 — Sveglia
**Setup**: nessuno.

**Passi**:
1. Quick Talk → **"mettimi la sveglia alle 7 e mezza"**

**Output atteso**:
- Clock app apre con sveglia pre-impostata 7:30
- GIGI: "Setting your alarm."

---

### T4.5 — HomeKit
**Setup**: almeno un accessorio HomeKit configurato (luce, presa, termostato).

**Passi**:
1. Quick Talk → **"accendi la luce del salotto"**

**Output atteso**:
- Luce si accende
- GIGI: "Turning it on."

**Output KO**: "HomeKit non disponibile" → permesso HomeKit mancante o accessorio non trovato.

---

### T4.6 — Memoria (remember / recall)
**Setup**: nessuno.

**Passi**:
1. Quick Talk → **"ricorda che il mio ristorante preferito è Nobu"**
2. Aspetta 2s
3. Quick Talk → **"qual è il mio ristorante preferito?"**

**Output atteso**:
- Step 1: GIGI "Got it — I'll remember that." + salva `pref:ristorante = Nobu` in CloudKit
- Step 3: GIGI risponde "Il tuo ristorante preferito è Nobu."

**Output KO**: step 3 GIGI non sa → `GigiMemory.recallResolving()` non trova entry o CloudKit non ha sincronizzato.

---

### T4.7 — Navigazione
**Setup**: Maps o Google Maps installato.

**Passi**:
1. Quick Talk → **"portami a casa"**
2. (Deve aver configurato "place:casa" in memoria o essere in rubrica come indirizzo)

**Output atteso**:
- Maps apre con navigazione verso indirizzo casa
- GIGI: "Opening Maps to casa."

---

## AREA 5 — CHAT VIEW & UI

### T5.1 — Bubble thinking e tool event
**Setup**: Force Claude attivo O usa `ask_claude` tool manualmente.

**Passi**:
1. Invia richiesta che usa `ask_claude` (es. "analizza questi dati...")
2. Osserva ChatView durante elaborazione

**Output atteso**:
- Bolla grigia italic con 💭 prefix → ruolo `.thinking`
- Bolla con icona gear → ruolo `.toolEvent`
- Auto-scroll segue le nuove bubble
- Dopo risposta finale, bubble thinking rimangono visibili (non spariscono)

---

### T5.2 — Persistenza chat tra riavvii
**Setup**: fai 3-4 scambi vocali.

**Passi**:
1. Forza chiusura app
2. Riapri entro 1 ora

**Output atteso**:
- ChatView mostra la storia precedente (UserDefaults session, TTL 1h)
- I messaggi vecchi sono visibili

**Output KO**: chat vuota → `GigiConversationMemory.saveSession()` non chiamato o TTL scaduto.

---

### T5.3 — Banner status
**Setup**: nessuno.

**Passi**:
1. Disabilita internet
2. Quick Talk → "ciao"
3. Osserva banner

**Output atteso**:
- Banner giallo/arancio in alto: "⚠️ Offline — limited responses" (appare e sparisce dopo 3s)

---

### T5.4 — Input testuale
**Setup**: nessuno.

**Passi**:
1. ChatView → campo testo in basso
2. Scrivi "che ore sono" + invio

**Output atteso**:
- Risposta identica al flusso vocale
- Bolla "tu" + bolla "GIGI" appaiono

---

## AREA 6 — HARNESS PAIRING

### T6.1 — QR Pairing da zero
**Setup**: server harness avviato su Mac (`./start-harness.sh`), cloudflared tunnel attivo, iPhone NON ancora paired.

**Passi**:
1. Mac: apri browser `http://localhost:7777/pair`
2. iPhone: Settings → "Pair con Harness" → pulsante principale
3. Scansiona QR
4. Aspetta 4 stadi: scanning → validating → diagnostic → success

**Output atteso**:
- Stage 1 (scanning): viewfinder attivo, QR riconosciuto automaticamente
- Stage 2 (validating): spinner "Validating..." poi ✓
- Stage 3 (diagnostic): lista check 10 item, ✓ verdi per tutti i critical
- Stage 4 (success): "Paired!" + HarnessStatusCard appare in Settings

**Output KO**:
- Stage 2 fail: URL non raggiungibile → Cloudflare tunnel non attivo
- Stage 3 check rossi: mostra esattamente quale check fallisce (es. "claude CLI not authenticated")
- Stage 4 non arriva: "Finalize" button disabilitato → almeno 1 critical check ❌

---

### T6.2 — Diagnostics live convergence (scenario B obbligatorio)
**Setup**: harness paired, ma Claude CLI NON autenticato (`claude auth logout`).

**Passi**:
1. iPhone: Settings → "Diagnostica harness"
2. Osserva check "claude CLI authenticated" → ❌
3. Mac terminal: `claude auth login` → completa login
4. **Aspetta senza fare nulla su iPhone**

**Output atteso**:
- Entro 5 secondi il check "claude CLI authenticated" diventa ✓ su iPhone
- Nessun tap richiesto (polling automatico ogni 5s)

**Output KO**: check resta ❌ anche dopo login → endpoint `/api/setup/diagnostics` non si aggiorna o polling iOS si è fermato.

---

### T6.3 — Rimozione pairing
**Setup**: iPhone paired.

**Passi**:
1. Settings → "Rimuovi pairing"
2. Conferma
3. Osserva Settings

**Output atteso**:
- HarnessStatusCard scompare
- Pulsante "Pair con Harness" torna disponibile
- Keychain: `harness_base_url` e `harness_shared_secret` cancellati

---

### T6.4 — Connection Loss durante sessione
**Setup**: iPhone paired, Force Claude ON.

**Passi**:
1. Quick Talk → richiesta a Claude (es. "spiegami la relatività")
2. MENTRE elabora: spegni WiFi Mac (o spegni server)

**Output atteso**:
- Entro timeout: messaggio errore user-friendly in chat (NO crash)
- Es: "Can't reach the harness right now. Try again in a moment."
- Se Auto Fallback ON: risposta via Groq silenziosamente

---

## AREA 7 — HARNESS PANEL (browser Mac)

### T7.1 — Panel connections card
**Setup**: server avviato, iPhone connesso.

**Passi**:
1. `http://localhost:7777` → tab "Connections"
2. Fai una richiesta vocale dall'iPhone

**Output atteso**:
- Card "Tunnel": stato cloudflared (running/stopped)
- Card "WebSocket": device iPhone elencato con IP + tempo connessione
- Card "Requests": ultima richiesta appare nella tabella entro 3s (polling 3s)
- Card "Devices": device ID iPhone elencato

---

### T7.2 — Setup diagnostics dal panel
**Setup**: server avviato.

**Passi**:
1. `http://localhost:7777/setup`
2. Osserva sezione diagnostics

**Output atteso**:
- 10 check visualizzati con ✓/⚠/❌
- "Recheck" button → aggiorna entro 5s
- Auto-expand sui check falliti con hint copyable

---

### T7.3 — Auto-fix
**Setup**: almeno 1 check autoFixable è ❌ (es. secret troppo corto).

**Passi**:
1. `/setup` → identifica check con banner giallo "Auto-fix available"
2. Clicca "Fix"

**Output atteso**:
- Fix applicato (es. secret rinforzato)
- Check diventa ✓ entro 10s

---

## AREA 8 — MEMORIA & PROFILO

### T8.1 — Dashboard card memoria
**Setup**: almeno 5 memorie salvate via "ricorda che...".

**Passi**:
1. Apri tab Dashboard

**Output atteso**:
- Card "Memory" mostra N records
- Tasto "View All" (se implementato) mostra lista

---

### T8.2 — Dashboard card profilo
**Setup**: profilo compilato in onboarding.

**Passi**:
1. Apri tab Dashboard

**Output atteso**:
- Card "Your Profile" mostra score 3/4 o 4/4 (a seconda di quanti campi compilati)
- Nome utente visibile nella card

---

### T8.3 — Context snapshot in Claude Bridge
**Setup**: Force Claude ON, profilo compilato, almeno 3 memorie salvate.

**Passi**:
1. Quick Talk → "cosa sai di me?"

**Output atteso**:
- Claude risponde citando info dal profilo (nome, preferenze) e dalle memorie
- Risposta dimostra che `buildContextSnapshot()` ha funzionato

**Output KO**: Claude risponde "Non ho informazioni su di te" → snapshot non incluso nel payload.

---

## AREA 9 — SETTINGS

### T9.1 — Toggle Brain Mode persistente
**Setup**: nessuno.

**Passi**:
1. Settings → Brain Mode → attiva "Force Claude"
2. Forza chiusura app
3. Riapri app → Settings

**Output atteso**:
- Toggle "Force Claude" ancora attivo dopo riavvio
- Keychain `brain_force_claude = "1"` persistito

---

### T9.2 — Test connection Groq
**Setup**: Groq key valida.

**Passi**:
1. Settings → sezione Brain → "Test Connection"

**Output atteso**:
- Spinner → "✓ Connected (llama-3.3-70b)" entro 5s

**Output KO**: "✗ No API key" → key non letta da Keychain. "✗ Timeout" → Groq non raggiungibile.

---

### T9.3 — Cambio chiave API in Settings
**Setup**: nessuno.

**Passi**:
1. Settings → inserisci nuova chiave Groq (sovrascrive vecchia)
2. Salva
3. Test Connection

**Output atteso**:
- Nuova chiave attiva, test passes

---

## AREA 10 — EDGE CASES & REGRESSIONI

### T10.1 — Utterance ambigua (disambiguazione contatti)
**Setup**: in rubrica hai "Marco Rossi" e "Marco Bianchi".

**Passi**:
1. Quick Talk → "chiama Marco"

**Output atteso**:
- GIGI chiede: "Quale Marco? Rossi o Bianchi?"
- Rispondi "Rossi"
- Chiamata verso Marco Rossi

---

### T10.2 — Richiesta offline complessa
**Setup**: WiFi e dati OFF.

**Passi**:
1. Quick Talk → "spiegami la teoria della relatività"

**Output atteso**:
- Banner "⚠️ Offline — limited responses"
- GIGI: "I need internet to answer that." (o simile)
- NO crash, NO spinner infinito

---

### T10.3 — Input vuoto
**Setup**: nessuno.

**Passi**:
1. Premi Quick Talk
2. Non dire nulla per 5 secondi

**Output atteso**:
- VAD rileva silenzio → torna a stato idle
- NO richiesta inviata a Groq con testo vuoto

---

### T10.4 — Richiesta molto lunga (stress test)
**Setup**: harness attivo.

**Passi**:
1. Quick Talk → di' una frase di 60+ parole (racconta evento complesso)

**Output atteso**:
- STT trascrive correttamente tutta la frase
- Agent engine processa senza timeout prematuro
- Risposta sensata

---

### T10.5 — Ripetute richieste rapide
**Setup**: nessuno.

**Passi**:
1. Quick Talk → "che ore sono"
2. Immediatamente dopo TTS inizia: Quick Talk → "che giorno è"
3. Subito: Quick Talk → "che tempo fa"

**Output atteso**:
- Ogni richiesta processata in ordine
- No crash, no stato bloccato
- Queue gestisce la serializzazione

---

### T10.6 — Cold start (app appena installata senza iCloud)
**Setup**: iCloud OFF sull'iPhone.

**Passi**:
1. Installa app senza iCloud
2. Completa onboarding
3. Fai "ricorda che mi piace il sushi"

**Output atteso**:
- App funziona in modalità locale
- Memoria salvata localmente (non su CloudKit)
- NO crash, NO alert iCloud obbligatorio

---

## CHECKLIST FINALE PRIMA DI OGNI RELEASE

```
[ ] T1.1 Onboarding primo avvio
[ ] T1.2 Groq key salva + test
[ ] T2.2 Quick Talk base (che ore sono)
[ ] T3.3 Agent loop con tool calling (evento calendario)
[ ] T4.1 Chiamata telefonica
[ ] T5.4 Input testuale funziona
[ ] T6.1 QR Pairing da zero
[ ] T6.2 Diagnostics convergence (scenario B — OBBLIGATORIO)
[ ] T9.1 Settings persistono dopo riavvio
[ ] T10.2 Offline non crasha
[ ] T10.3 Input vuoto gestito
```

---

## COME RIPORTARE UN BUG

Per ogni test fallito, annota:

```
Test ID: T3.3
Device: iPhone 14 Pro, iOS 18.2
Build: commit b66b244
Passi eseguiti: [elenco esatto]
Output atteso: [dal piano]
Output ottenuto: [cosa è successo]
Log Xcode (se disponibile): [copia errori]
Screenshot/video: [allega]
```

---

*Generato da analisi diretta del codebase — 2026-04-26*
