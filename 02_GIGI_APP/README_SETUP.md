# Setup sviluppatore — GIGI iOS

**Nota SPM e prima build:** dopo il clone, Xcode o `xcodebuild` possono restare a lungo su *Resolve Package Graph* / *Fetching…*. È normale. In Xcode usa **File → Packages → Resolve Package Versions**, poi **Product → Build**.

## Config locale

Le chiavi non devono stare nel repository.

1. Nella cartella `02_GIGI_APP/`, copia il template:
   ```bash
   cp Config.example.xcconfig Config.xcconfig
   ```
2. Compila solo le chiavi che ti servono:
   ```xcconfig
   GROQ_API_KEY = gsk_...
   GEMINI_API_KEY = AIza...
   PICOVOICE_ACCESS_KEY = ...
   GIGI_GATEWAY_ICLOUD_URL = https://www.icloud.com/shortcuts/...
   ```
3. `GIGIApp.xcconfig` include automaticamente `Config.xcconfig` se esiste.
4. Esegui **Clean Build Folder** e poi **Build**.

## Groq — obbligatoria per il cervello

`GROQ_API_KEY` alimenta:

- agent brain;
- tool calling;
- intent reasoning;
- web vision;
- diagnosi brain;
- fallback cloud principale.

Puoi inserirla anche in app da **Settings → AI Brain (Groq)**. In quel caso viene salvata in Keychain e prevale su `Info.plist`.

## Gemini — opzionale per realtime voice

`GEMINI_API_KEY` è separata da Groq e viene usata solo dai percorsi realtime/native audio che parlano con Gemini.

Non viene più usata come fallback Groq. Se manca, il cervello Groq continua a funzionare; semplicemente le funzioni realtime Gemini non si connettono.

Puoi inserirla anche in app da **Settings → Realtime Voice (Gemini)**.

## Picovoice — opzionale per custom wake word

1. Ottieni una AccessKey da [Picovoice Console](https://console.picovoice.ai/).
2. Imposta:
   ```xcconfig
   PICOVOICE_ACCESS_KEY = ...
   ```
3. Per una keyword custom, aggiungi `HeyGIGI.ppn` al target GIGI.

Senza Picovoice/custom model, l’app usa il fallback wake word disponibile nel progetto.

## File sensibili

- Non committare `Config.xcconfig`. È in `.gitignore`.
- `Config.example.xcconfig` deve contenere solo placeholder vuoti.
- Se una chiave reale finisce in `Config.example.xcconfig`, ruotala subito dal provider.
