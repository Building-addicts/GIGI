# Setup sviluppatore — GIGI (iOS)

**Nota — SPM e prima build:** dopo il clone o l’aggiunta del pacchetto **Porcupine** (`Picovoice/porcupine`), Xcode o `xcodebuild` possono restare a lungo su *Resolve Package Graph* / *Fetching…* senza output apparente: è normale (rete e cache). In **Xcode**: **File → Packages → Resolve Package Versions**, attendi il completamento, poi **Product → Build** (⌘B). Da terminale, `xcodebuild -resolvePackageDependencies` può richiedere diversi minuti al primo giro.

## Chiave API Gemini (Vision)

La chiave non è nel repository. Per compilare ed eseguire le funzioni che usano Gemini Vision:

1. Nella cartella `02_GIGI_APP/`, copia il template:
   ```bash
   cp Config.example.xcconfig Config.xcconfig
   ```
2. Apri `Config.xcconfig` e sostituisci `YOUR_API_KEY_HERE` con la tua chiave API Google AI (Gemini), ottenibile dalla [Google AI Studio](https://aistudio.google.com/apikey).
3. In Xcode, verifica che il target **GIGI** usi `Config.xcconfig` per le configurazioni **Debug** e **Release** (Project → Info → Configurations).
4. Esegui **Clean Build Folder** (⇧⌘K) e poi **Build** (⌘B).

Se `Config.xcconfig` manca o la chiave è vuota, `GigiConfig.geminiAPIKey` sarà una stringa vuota e le chiamate Vision a Gemini non funzioneranno finché non configuri la chiave.

## Wake word (Porcupine)

1. Ottieni una **AccessKey** gratuita da [Picovoice Console](https://console.picovoice.ai/).
2. In `Config.xcconfig`, imposta `PICOVOICE_ACCESS_KEY = <la_tua_chiave>`.
3. (Opzionale) Scarica il bundle **Hey GIGI** in formato `.ppn` e aggiungi `HeyGIGI.ppn` al target GIGI (Copy Bundle Resources). Senza questo file, l’app usa la keyword integrata **«Jarvis»** come fallback.
4. In app: **Dashboard → Wake word → Always-on listening** per attivare il monitoraggio.

## File sensibili

- **Non committare** `Config.xcconfig`. È elencato in `.gitignore`.
- **Committare** `Config.example.xcconfig` come riferimento per il team.

Prima del primo commit in un nuovo clone, verifica con `git status` che `Config.xcconfig` non compaia tra i file tracciati.
