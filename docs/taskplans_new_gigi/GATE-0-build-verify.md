# GATE 0 — Build verify post-cleanup armando-rework

> **Status**: Ready to start
> **Effort stimato**: ~45 min (di cui ~30 di build SSH MacInCloud)
> **Bloccanti pre-gate**: nessuno (è il primo GATE in assoluto)
> **Sblocca**: GATE 1, GATE 2, GATE 3, GATE 4, GATE 5, GATE 6, GATE 7, GATE 8 (è il prerequisito di tutti)
> **Funzione consegnata (1 frase)**: confermare che la codebase post-cleanup (commits `2f504a9` + `bdc393a` + `<groq-removal-SHA>`, ~46 file modificati, ~1500 righe `_legacy` disconnesse + agentLoop Groq rimosso) compila ed esegue sul device fisico senza regressioni rispetto al nuovo flow corrente (2-Gate flat: NLU fast-path → harness Claude bridge).

---

## 1. Obiettivo

Dopo i 3 commit di cleanup pre-Phase 2 (zombie kill + UI trim + stub creation + **Groq removal**) la build SSH MacInCloud non è ancora stata verificata. Questo GATE è il **checkpoint di partenza**: vogliamo essere sicuri che (a) il target Xcode compili senza errori, (b) l'IPA si installi sul telefono di Armando, (c) le 3 tab principali siano visibili, (d) le funzionalità non toccate dal cleanup (NLU fast-path "set timer", harness Claude per query non-NLU, Settings → Debug picker) continuino a funzionare, (e) il Brain Path Override picker introdotto da `bdc393a` sia visibile in Settings → Debug, (f) Groq non sia più chiamato da nessun path runtime.

Se il GATE chiude verde, possiamo iniziare GATE 1 (Spike A) con confidence che la baseline è solida.

Se chiude rosso (build failed o regressioni runtime), va aperta una sub-issue P0 e il piano si ferma finché la baseline non è ricostruita.

---

## 2. Pre-condizioni

- [ ] Branch `armando-rework` checkout-ato in `C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/`
- [ ] Working tree pulito (`git status` clean) o solo questo task plan come modifica non staged
- [ ] SSH key ed25519 autorizzata su `user297422@FF125.macincloud.com` (verificare con `ssh -o BatchMode=yes user297422@FF125.macincloud.com 'echo OK'` → deve tornare `OK` senza prompt)
- [ ] Xcode 26.3 (Build 17C529) presente sul Mac remoto
- [ ] iPhone fisico Apple Intelligence-capable (iPhone 15 Pro / 16 Pro / 17 Pro) collegato al PC Windows con Sideloadly aperto
- [ ] Drop folder `C:/Users/arman/Desktop/GIGI/bug/` esiste
- [ ] **Step manuale Xcode pendente**: `02_GIGI_APP/GIGI/_legacy/` aggiunta come folder reference (cartella **blu**, NON gialla group). Se non fatto, Xcode ri-compila i file zombie in `_legacy/` e la build esplode con simboli duplicati / dipendenze rimosse. Vedi commit `bdc393a` body.
- [ ] **Step manuale Xcode pendente**: `GoogleSignIn` rimossa da Project → Package Dependencies (deve già essere così dopo `2f504a9` ma confermare visivamente)

---

## 3. Task implementativi

- **Task 0.1 — Sync worktree Windows → Mac via rsync** (5 min)
  - Da PowerShell o WSL bash, dentro `C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/`:
    ```bash
    rsync -az --delete \
      --exclude '.git' --exclude '*.xcuserdata' --exclude 'DerivedData' \
      --exclude 'node_modules' --exclude '.DS_Store' \
      ./ user297422@FF125.macincloud.com:~/GIGI-armando-rework/
    ```
  - Trasferimento ~50MB Swift + risorse, può durare 2-5 min su prima esecuzione (cache calda dopo)
  - Riferimento: `CLAUDE.local.md` §"Sync worktree Windows → Mac (via rsync)"
  - Note di rischio: se la rsync fallisce con "Permission denied", verificare la chiave SSH ed25519 con `ssh -v user297422@FF125.macincloud.com`

- **Task 0.2 — xcodebuild filtrato errori** (10-20 min)
  - SSH dal PC Windows:
    ```bash
    ssh user297422@FF125.macincloud.com "cd ~/GIGI-armando-rework/02_GIGI_APP && /usr/bin/xcodebuild \
      -project GIGI.xcodeproj -scheme GIGI -configuration Debug \
      -destination 'generic/platform=iOS' \
      CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
      build 2>&1 | grep -E 'error:|BUILD SUCCEEDED|BUILD FAILED' | head -40"
    ```
  - Output atteso: `BUILD SUCCEEDED`
  - Output incompatibile: qualunque linea che inizia con `error:` o `BUILD FAILED`
  - Se BUILD FAILED, NON proseguire — diagnosticare prima
  - Riferimento: `CLAUDE.local.md` §"Comando build verify"

- **Task 0.3 — Packaging IPA + scp al drop folder Windows** (3-5 min)
  - SSH dal PC Windows:
    ```bash
    ssh user297422@FF125.macincloud.com '
      APP=$(find ~/Library/Developer/Xcode/DerivedData -name "GIGI.app" -type d | head -1)
      rm -rf /tmp/Payload && mkdir /tmp/Payload && cp -R "$APP" /tmp/Payload/
      cd /tmp && zip -qr /tmp/GIGI.ipa Payload
    '
    mkdir -p "/c/Users/arman/Desktop/GIGI/bug"
    scp user297422@FF125.macincloud.com:/tmp/GIGI.ipa \
      "/c/Users/arman/Desktop/GIGI/bug/GIGI.ipa"
    ```
  - File atteso: `C:/Users/arman/Desktop/GIGI/bug/GIGI.ipa` (~20-40MB)
  - Riferimento: `CLAUDE.local.md` §"Comando packaging IPA + scp"

- **Task 0.4 — Sideload + first launch verifica visuale** (15 min)
  - Drag-and-drop `GIGI.ipa` su Sideloadly → install su iPhone fisico
  - Aprire l'app
  - Visuale check:
    1. App lancia senza crash (no splash screen freeze)
    2. **3 tab visibili** (Chat / Dashboard / Settings) — NON 4
    3. Dashboard mostra 1 dot di stato (NON 3 pill sovrapposte)
    4. Onboarding (se primo launch) ha **5 step**, NON 7 (welcome → permissions → harness pair → hardware trigger → done — apiKeyStep e profileStep rimossi)
    5. Settings → cercare sezione "Debug" → deve contenere **Brain Path Override picker** con 4 opzioni: `auto` / `appleFM` / `ollama` / `claude`

- **Task 0.5 — Sanity runtime test (3 query)** (10 min)
  - Lasciare `Brain Path Override` su `auto`
  - Test 1: pronunciare "What time is it" → deve rispondere ora corrente in <500ms (NLU fast-path hit, `GigiNLUEngine`)
  - Test 2: pronunciare "Set a timer for 5 minutes" → deve schedulare notifica iOS, rispondere "Timer set" / equivalente, in <500ms (NLU fast-path hit)
  - Test 3: pronunciare "Tell me a joke" → deve cadere sul harness Claude bridge (NLU fast-path miss → `GigiClaudeBridge.shared.run()`), latency 5-20s, response testuale
    - **Pre-condizione**: harness paired (Settings → Harness section deve mostrare "Configured/OK"). Senza pairing, la query ritornerà l'errore "Pair the harness from Settings to enable the AI brain."
  - Riferimento: `GigiAgentEngine.process(text:)` flow §"2-Gate post-Groq removal"

- **Task 0.6 — Cleanup folder Xcode warnings (opzionale)** (5 min)
  - Se la build mostra warning `@Published` unused properties in `GigiAudioManager` (dormant wake state) — documentati ma non bloccanti, vedi piano §3.12 "Probabili candidati di errore minore"
  - NO fix automatico in questo GATE — solo registrare nei note per GATE 8

---

## 4. Acceptance Criteria (AC)

- **AC1** — `xcodebuild ... build` ritorna esattamente `BUILD SUCCEEDED` su iOS 26.3 SDK
- **AC2** — IPA generato in `/tmp/GIGI.ipa` sul Mac remoto, dimensione 15-50MB (sanity check)
- **AC3** — IPA copiato in `C:/Users/arman/Desktop/GIGI/bug/GIGI.ipa` su Windows (filesize > 10MB)
- **AC4** — Sideloadly conferma install OK su iPhone fisico
- **AC5** — App lancia senza crash al primo tap; splash screen disappare; tab bar è visibile
- **AC6** — Tab bar mostra esattamente 3 tab (Chat, Dashboard, Settings) — NO Presence tab
- **AC7** — Dashboard header mostra 1 dot di stato (NO 3 pill brain/harness/local-ai)
- **AC8** — In Settings → Debug section c'è il picker "Brain Path Override" con 4 valori selezionabili: `auto`, `appleFM`, `ollama`, `claude`
- **AC9** — Query "what time is it" classificata da `GigiNLUEngine` come fast-path (verifica in console Xcode: log `nlu_fast_path` o `intent=ask_time`)
- **AC10** — Query "set timer 5 minutes" schedula effettivamente una notifica iOS (verifica nel Lock Screen che la notifica timer appaia dopo 5 min, o controlla Notifications Pending in iOS Settings)
- **AC11** — Query generica non NLU ("tell me a joke") raggiunge il harness Claude bridge (`GigiClaudeBridge.shared.run`) e risponde con testo (latency 5-20s, NO immediate fast-path, NO chiamata Groq — Groq è stato rimosso pre-GATE 0). Se harness NON paired: risposta "Pair the harness from Settings to enable the AI brain."
- **AC12** — Cartella `_legacy/` esiste in `02_GIGI_APP/GIGI/_legacy/` e contiene 4 file `.swift` + README (WakeWordEngine, DayPlanReasoner, BrainPipeline, PlannerEngine), ma **NON è compilata** nel target (verifica: nessun simbolo legacy linkato nel binario)
- **AC13** — `GigiCloudService.swift` è ridotto a thin shell (~185 righe vs ~496 pre-cleanup) e contiene solo stub `noop` (extractTasksRaw → "[]", askRaw → throws featureUnavailable, summarizeNews → prefix passthrough, testKey → fixed string). NESSUN HTTP call a `api.groq.com`.

---

## 5. Test E2E sul telefono (verificabili dall'utente)

- **E2E-1** — Pronunciare "What time is it"
  - Atteso: speech response con ora corrente (es. "It's 10:42 PM"), latency <500ms percepita
  - Verifica path: in console Xcode appare log relativo a NLU fast-path / `intent=ask_time`

- **E2E-2** — Pronunciare "Set a timer for 1 minute"
  - Atteso: speech response "Timer set" o equivalente, notifica iOS visibile in Lock Screen dopo 1 minuto
  - Verifica path: NLU fast-path, NO chiamata a Groq

- **E2E-3** — Toccare la tab Settings → scorrere fino a sezione Debug
  - Atteso: il picker "Brain Path Override" è visibile con label "Force Path (Debug)" e 4 segmenti (Auto / AppleFM / Ollama / Claude)
  - Verifica: tap su "Ollama" → l'app NON crasha (ricorda che oggi Ollama path ritorna `"Path 3 Ollama is not configured yet"`)

- **E2E-4** — In Brain Path Override scegliere `appleFM` + pronunciare "Tell me a joke"
  - Atteso: response da Apple FM (`GigiFoundationAgent.shared.process()`), testo coerente con una battuta, latency 1-3s
  - Verifica path: console mostra log `brain_path=appleFM` o equivalente

- **E2E-5** — In Brain Path Override scegliere `ollama` + pronunciare qualunque cosa
  - Atteso: response `"Path 3 Ollama is not configured yet"` (stub corrente, sarà sostituito in GATE 4)
  - Verifica: nessun crash, fallback graceful

- **E2E-6** — In Brain Path Override scegliere `claude` + pronunciare "Search the web for Tesla"
  - Atteso: l'app spawn-a Claude Code subprocess (richiede harness in esecuzione), response 10-30s
  - Verifica path: console mostra log Claude Code subprocess
  - Note: se harness non è running, atteso fallback graceful con messaggio chiaro

- **E2E-7** — Reset Brain Path Override a `auto` + close/reopen app
  - Atteso: l'app riparte senza problemi, override torna su `auto`, comportamento default (3-Gate flat) ripristinato

---

## 6. Test post-creazione (verifica autonoma — ripetibile mesi dopo)

Anche fra 3 mesi, Armando può aprire questo GATE e verificare che è davvero chiuso eseguendo:

### 6.1 Verifica via filesystem / grep

```bash
# 1. Verifica esistenza cartella _legacy e contenuto atteso
ls "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/02_GIGI_APP/GIGI/_legacy/"
# Output atteso: GigiBrainPipeline.swift, GigiDayPlanReasoner.swift, GigiWakeWordEngine.swift, README.md

# 2. Verifica che i 4 stub Phase 2 esistano
ls "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/02_GIGI_APP/GIGI/" | grep -E "GigiRequestRouter|GigiFoundationToolRegistry|GigiFallbackRouter|GigiFoundationContracts"
# Output atteso: tutti e 4 i file

# 3. Verifica che GoogleSignIn sia sparita dal project file
grep -c "GoogleSignIn" "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/02_GIGI_APP/GIGI.xcodeproj/project.pbxproj"
# Output atteso: 0

# 4. Verifica che selectRelevant() sia DEPRECATED
grep "selectRelevant_DEPRECATED" "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/02_GIGI_APP/GIGI/GigiToolRegistry.swift"
# Output atteso: almeno 1 match con annotation @available(*, deprecated)

# 5. Verifica BrainPathOverride enum in SettingsView
grep -c "BrainPathOverride" "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/02_GIGI_APP/GIGI/SettingsView.swift"
# Output atteso: >= 2 (definizione + uso)
```

### 6.2 Verifica via xcodebuild (re-run baseline)

```bash
ssh user297422@FF125.macincloud.com "cd ~/GIGI-armando-rework/02_GIGI_APP && /usr/bin/xcodebuild \
  -project GIGI.xcodeproj -scheme GIGI -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tail -5"
# Output atteso: linea con BUILD SUCCEEDED
```

### 6.3 Verifica via git log

```bash
cd "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework"
git log --oneline | head -10
# Output atteso: commits 2f504a9 e bdc393a presenti nella history del branch armando-rework
git log -1 --stat bdc393a
# Output atteso: 25 file changed, ~885 insertions, ~235 deletions
```

### 6.4 Verifica runtime (re-install IPA)

Se il GATE è "chiuso correttamente" 3 mesi fa, rebuilding ora dovrebbe produrre lo stesso comportamento:
- 3 tab visibili, 6 step onboarding, Brain Path Override picker visibile
- Fast-path `set_timer` ancora funzionante

---

## 7. Rollback plan

Questo GATE non aggiunge codice, è solo verifica. Quindi rollback "puro" non si applica.

Se la build fallisce e bisogna tornare a uno stato precedente noto-funzionante:

```bash
cd "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework"
git log --oneline -- 02_GIGI_APP/  # trova SHA pre-cleanup
git checkout <SHA-pre-cleanup> -- 02_GIGI_APP/  # rollback solo iOS
# rebuild + sideload come Task 0.1-0.4
```

Side effects da pulire: nessuno (build verify è puro check, no state mutation in app/UserDefaults).

---

## 8. Files modificati / creati

| Path | Operazione | Righe stimate |
|---|---|---|
| nessuno | nessuna | 0 |

Questo GATE NON modifica codice. Tutto il lavoro è in CLI + verifica visuale.

L'unico file che POTREBBE essere creato in questo GATE è un report di build verify che Armando può salvare in `docs/research/` per archiviazione, ma è opzionale e non in scope.

---

## 9. ADR collegati

- ADR-0001 (Pairing Cloudflare Tunnel) — non modificato, solo verificato che il pairing funziona post-cleanup
- ADR-0003 (Wake word soft-kill) — verificato runtime che NO wake word listener gira più
- ADR-0004 (Uproot Gemini + Google Sign-In) — verificato grep `GoogleSignIn` = 0
- ADR-0005 (Day Plan Reasoner soft-kill) — verificato runtime che NO day plan UI compare
- ADR-0006 (UI cleanup MVP trim) — verificato visualmente che le 8 decisioni D1-D8 sono applicate (3 tab, 6 onboarding, etc)

---

## 10. Note operative

- **Build verify command**: vedi `CLAUDE.local.md` § "Comando build verify"
- **SSH MacInCloud**: `user297422@FF125.macincloud.com` — auth via ed25519 key
- **Cosa committare**: NULLA in questo GATE. Eventuale build report manuale va in `docs/research/build-verify-gate-0-YYYY-MM-DD.md` come opt-in
- **Conventional Commits suggerito**: nessun commit di codice. Se serve registrare il PASS:
  ```
  docs(taskplans): mark GATE 0 build verify as PASSED on YYYY-MM-DD
  ```

### Cosa fare se BUILD FAILED

1. Aprire una sub-issue `[BUG] GATE 0 — BUILD FAILED post-cleanup` su GitHub con label `release-blocker`
2. Includere nell'issue:
   - L'output completo del comando `xcodebuild` (almeno le linee `error:`)
   - SHA dei 2 commit di cleanup (`2f504a9`, `bdc393a`)
   - File ipotizzati coinvolti (probabilmente: stub iOS in `bdc393a` con import / type non risolti)
3. **NON proseguire a GATE 1**: la baseline deve essere verde prima di partire con Spike A

### Cosa fare se runtime ha regressioni ma build passa

Esempi possibili:
- App crash al launch (NULL deref in `GigiCloudService` dopo zombie kill?)
- Settings → Debug picker invisibile
- Tab Presence ancora visibile

Tutti questi sono bug P0 che bloccano GATE 1. Aprire sub-issue dedicata + non procedere.

### Step manuali Xcode (impossibili da CLI)

- Aprire `GIGI.xcodeproj` su Xcode (sul Mac)
- Tasto destro su `02_GIGI_APP/GIGI/` → "Add Files to GIGI" → selezionare `_legacy/` → checkbox **"Create folder references"** (cartella **blu**), NON "Create groups"
- Verificare in Project → Package Dependencies che `GoogleSignIn` non sia più listato (deve già essere così, ma confermare)

Questi 2 step sono documentati nel commit body di `bdc393a` ma vanno fatti UNA volta sul Mac, non si possono automatizzare.
