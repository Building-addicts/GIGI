# Architettura GIGI

Documento di riferimento per la struttura del progetto e i confini tra i componenti.

## Panoramica

| Cartella | Componente | Ruolo |
|----------|------------|--------|
| `01_SERVER_MDM/` | Strato 1 | Server MDM (Node.js) — enrollment, profili, protocollo Apple MDM |
| `02_GIGI_APP/` | Strati 2–5 | App Swift (Xcode) — UI, logica client, integrazione con il device |
| `00_DOCS/` | Documentazione | Specifiche, decisioni, runbook |

## Strato 1 — Server MDM

- Endpoint pubblici (HTTPS) per check-in, comandi e distribuzione profili.
- Materiale sensibile (certificati, chiavi) resta fuori dal repository o in segreti locali.

## 🕸️ 1.1 Distribuzione web: l’architettura del sito

Il sito deve gestire una comunicazione bidirezionale con l’iPhone per superare le barriere di sicurezza. Scomposizione tecnica:

### A. Il Landing Engine (Frontend)

Non usiamo framework pesanti: serve velocità assoluta.

- **User Agent Detection:** il sito rileva subito se l’utente è su iPhone e quale versione di iOS ha. Se l’utente è su Android o PC, il tasto di download è disabilitato (per evitare che curiosi scarichino il pacchetto e lo analizzino).
- **Il tasto “Inject GIGI”:** non è un link statico a un file; è una **chiamata API** al server MDM.

### B. Il protocollo di trust (Fase 1: enrollment)

Perché l’iPhone accetti il file che uccide Siri, deve prima “conoscere” il server.

1. **Download del certificato CA:** il sito invita l’utente a scaricare il certificato di root del progetto GIGI.
2. **Istruzione UI:** mostriamo un video o GIF che spiega di andare in **Settings → General → About → Certificate Trust Settings** e attivare lo switch.
3. **Risultato:** da quel momento l’iPhone crede che `killsiri.xyz` sia un’autorità fidata, come un ufficio governativo o la sede centrale di Apple.

### C. Il payload delivery (Fase 2: il profilo)

Una volta stabilito il trust, il sito serve il file `.mobileconfig` dinamico.

- **MIME type:** il server risponde con `Content-Type: application/x-apple-aspen-config`. Safari istruisce iOS ad aprire subito la gestione profili di sistema invece di depositare un file “anonimo” in Download.

### Flusso tecnico del server (Node.js)

Quando l’utente preme il tasto sul sito, il server esegue questa sequenza:

1. **Generazione Unique ID:** crea un identificativo unico per quel dispositivo (per scalare e distinguere chi ha completato il flusso e chi no).
2. **Costruzione XML:** compone il `.mobileconfig` inserendo le chiavi di restrizione / configurazione previste (es. vincoli hardware o policy MDM).
3. **Firma CMS (“The Shield”):** con **node-forge** (o stack equivalente) il server firma digitalmente l’XML usando la chiave privata legata all’account Apple Developer / identità di firma del profilo.

**Nota:** un profilo non firmato compare come “Not Signed” (rosso) e spaventa l’utente. Un profilo firmato risulta verificato / attendibile e alza il tasso di installazione.

### Cosa vede l’utente vs cosa succede nel ferro

| Fase | Azione utente | Processo hardware / kernel |
|------|----------------|----------------------------|
| 1 | Tap su “GET GIGI” | Safari apre una sessione protetta col server. |
| 2 | Conferma download profilo | iOS scarica l’XML nella sandbox temporanea dei profili. |
| 3 | Installazione in Settings | Il kernel di iOS legge la chiave `forceAssistantOff`. |
| 4 | Fine installazione | Il processo `assistantd` (Siri) viene terminato forzatamente dal kernel. |

### 1.1.A Stato implementazione (landing + server)

Con la configurazione attuale del **veicolo d’iniezione** (`01_SERVER_MDM` + `public/index.html`):

- **killsiri.xyz** (o dominio equivalente) rileva l’iPhone, serve il profilo via `/download-profile` (firmato se `GIGI_P12_PATH` è configurato) e usa `window.open` come **prima** istruzione sul tap per compatibilità Safari iOS.
- Il profilo applica le restrizioni (`allowAssistant` / payload **1.2**) per disattivare Siri lato sistema, nei limiti del profilo installato.
- La landing guida l’utente al **TestFlight** di GIGI (**1.3**) tramite `GIGI_TESTFLIGHT_URL` / `/api/config`.

## 1.2 Il Killer di Siri (MDM payload)

Il segreto per uccidere Siri non è “cancellare” l’app (impossibile), ma usare le **Restrizioni di sistema** (*Restrictions*) che Apple ha creato per aziende e scuole.

### A. La chiave di esecuzione

All’interno del file `.mobileconfig`, inseriamo un payload di tipo `com.apple.applicationaccess`. La chiave centrale è:

- **`allowAssistant`:** impostata su `false`.

Quando il kernel legge questa riga, disattiva in modo immediato:

- Il trigger vocale “Hey Siri”.
- L’invocazione tramite pressione del tasto laterale.
- Tutti i suggerimenti di Siri nel sistema.

### B. Anatomia del payload (l’XML che genererà il server)

Struttura tecnica che il server dovrà produrre (frammento payload; il profilo finale avrà anche wrapper, UUID radice, `PayloadContent`, ecc.):

```xml
<dict>
    <key>PayloadType</key>
    <string>com.apple.applicationaccess</string>
    <key>PayloadIdentifier</key>
    <string>com.gigi.kill-siri</string>
    <key>PayloadUUID</key>
    <string>UUID-UNICO-GENERATO-DAL-SERVER</string>
    <key>PayloadVersion</key>
    <integer>1</integer>

    <key>allowAssistant</key>
    <false/>

    <key>allowDictation</key>
    <true/>
</dict>
```

### C. Perché è un “killer” efficace?

- **Persistenza:** una volta installato, il blocco resta attivo anche dopo riavvio o aggiornamento iOS (finché il profilo resta installato).
- **Sostituzione identitaria:** poiché il tasto laterale non invoca più Siri, l’utente percepisce un “vuoto” hardware. È qui che GIGI subentra tramite lo **Strato 3**, riempiendo quel vuoto con il suo comando.
- **Invisibilità:** non appare nessuna icona di errore. Siri semplicemente “smette di esistere”.

### 🛡️ La sfida della rimozione (MDM escape)

Nel mercato USA, gli utenti sono attenti alla privacy. Dobbiamo decidere quanto essere “aggressivi”:

- **Payload removibile:** l’utente può andare in Impostazioni e cancellare il profilo. Siri torna in vita.

### 🛠️ Flusso di firma CMS (la “corazza” del payload)

Come hai detto tu, senza certificato non si installa. Il server prenderà l’XML sopra e lo avvolgerà in una firma DER/CMS.

| Fase | Contenuto |
|------|-----------|
| **Input** | XML puro (testo). |
| **Firma** | Il server usa la tua `gigi_private.key` e il certificato Apple Developer. |
| **Output** | File binario firmato. |
| **Effetto** | L’iPhone vede il file e dice: «Questo comando viene da Leonardo (Developer), è sicuro, lo eseguo».

## 1.3 Il Veicolo d’Iniezione (TestFlight)

### A. Il “cavallo di Troia” legale

TestFlight è l’app di Apple per il beta testing. Per noi non è un test: è la distribuzione finale.

- **Bypass della censura:** le app su TestFlight non passano la revisione lunga e severa dell’App Store pubblico (quella che può durare settimane e bocciare ciò che “disturba” Siri). La revisione beta è spesso automatizzata o più superficiale (24–48 h).
- **Capacità:** fino a 10.000 utenti per singola build. Se servono più posti, si possono creare varianti (es. “GIGI Blue”, “GIGI Red”, ecc.).
- **Percezione:** l’utente USA tende a fidarsi di TestFlight. Installare da lì dà sensazione di accesso esclusivo e può facilitare l’accettazione di permessi invasivi (microfono, notifiche, dati).

### B. Iniezione degli entitlements (permessi speciali)

L’IPA distribuita via TestFlight non è pensata come app “generica”: è configurata con **entitlement** che preparano gli strati successivi:

- **`com.apple.developer.applesignin`** — login unico (aggancio a profili Gemini / ChatGPT o equivalenti).
- **`com.apple.developer.pushkit.voip`** — risveglio in background senza che iOS termini aggressivamente il processo (riferimento **Strato 2.2**).
- **`com.apple.developer.parental-controls`** — spesso in combinazione con MDM per diritti di supervisione / monitoraggio più profondi.

### C. Il pacchetto “leggero” (IPA strategico)

L’IPA caricata su TestFlight è un **guscio**.

- **Dimensione:** sotto ~100 MB. Apple non vede nel pacchetto i volumi enormi del modello AI (es. Llama ~2 GB).
- **Contenuto:** interfaccia SwiftUI e “ganci” (estensioni) per Dynamic Island e App Intents.
- **Trigger:** dopo l’installazione, l’app contatta il server (**Strato 1.1**) per verificare che l’MDM sia attivo. Se l’MDM c’è, GIGI avvia il download del “cervello” (**Strato 2.1**).

### Flusso d’installazione (user journey USA)

1. **Sito web:** l’utente preme “Join GIGI Beta”.
2. **Link TestFlight:** reindirizzamento all’app TestFlight ufficiale.
3. **Install:** tap su “Install”; l’iPhone scarica l’IPA di GIGI.
4. **First launch:** GIGI si apre, rileva che Siri è stata disattivata dall’MDM e comunica all’utente, in linea con il copy previsto: *“Siri is gone. I’m your new OS. Let’s download my brain.”*

## Strati 2–5 — App GIGI (Swift)

- Progetto Xcode e codice lato dispositivo.
- I dettagli per strato (2, 3, 4, 5) si documentano qui man mano che il design si consolida.

## 2.1 Background Assets: la strategia “Speed & Stealth”

Di norma iOS interrompe i download pesanti dopo pochi secondi in background senza le giuste API. GIGI aggira il limite con un approccio **ibrido**: intelligenza subito, carico completo in secondo piano.

### A. Il download ibrido a tre stadi

**Stage 1 — Il modello “Starter” (integrato nell’IPA)**

- L’IPA TestFlight include un modello da circa 50–80 MB (es. TinyLlama o Llama-3-Gigi-Mini).
- **Risultato:** appena l’utente apre GIGI (circa al secondo 10), l’app risponde subito: niente attesa, impatto immediato.

**Stage 2 — Il “Turbo Foreground” (illusione di velocità)**

- Mentre l’utente configura il Tasto Azione (**Strato 2.3**), GIGI usa una `URLSession` ad alta priorità.
- **Velocità:** sfrutta la banda disponibile (Wi‑Fi / 5G) scaricando i ~2 GB in segmenti paralleli (multi‑threading).
- **Hardware / formato:** compressione **LZFSE** (stack Apple). Si scarica ~1,2 GB compressi che sul disco diventano ~2 GB.

**Stage 3 — Passaggio a Background Assets (continuità)**

- Se l’utente chiude l’app prima del completamento, il task passa al demone di sistema **`BAContentManager`**. iOS prosegue il download anche a telefono in tasca.

### B. La gestione delle patch (evoluzione continua)

L’AI non è statica. GIGI esegue un **periodic check** ogni 24 ore via MDM / Push.

- Se su `models.killsiri.xyz` c’è un aggiornamento, Background Assets scarica solo il **delta** mentre l’utente non usa il telefono. Il “cervello” si aggiorna senza obbligare l’utente a una nuova build TestFlight.

### C. Destinazione hardware: sandbox blindata

- **Percorso:** `Container/Library/Application Support/GigiCore/`
- **Protezione:** attributo `isExcludedFromBackup = true`.
- **Perché:** ~2 GB di modello non devono finire su iCloud; restano nel container locale, vicino al Neural Engine, riducendo il rischio che messaggi “spazio esaurito” spingano l’utente a disinstallare l’app.

### 🛠️ Scomposizione tecnica (Swift)

Esempio concettuale del passaggio di consegne tra app in primo piano e sistema operativo:

```swift
import BackgroundAssets

class GigiBrainManager {
    static let shared = GigiBrainManager()

    func initiateHybridDownload() {
        let modelURL = URL(string: "https://models.killsiri.xyz/llama-3-2-q4.lzfse")!

        // 1. Configurazione del download di sistema (Background Assets)
        let download = BADownload(url: modelURL, essential: true)

        // 2. Il sistema prende in carico il file. Se l'app viene chiusa,
        // iOS continua a scaricare fino al completamento.
        BAContentManager.shared.schedule(download)

        print("GIGI: Download del Core Neural iniziato. Stage: Stealth.")
    }
}
```

### Il “Time-to-Power” (esperienza utente USA)

| Tempo | Cosa succede |
|--------|----------------|
| Secondo 0 | Download IPA da TestFlight. |
| Secondo 10 | Primo avvio: GIGI saluta usando il modello “Starter” (~80 MB). |
| Secondo 15–45 | L’utente mappa il Tasto Azione; il “Turbo Download” avanza (es. ~60% del core). |
| Secondo 60 | Telefono in tasca: Background Assets completa il resto. |
| Secondo 120 | Notifica silenziosa: swap da “Starter” a “Llama 3.2 Full Core”; potenza massima disponibile. |

## 🧠 2.2 Architettura del modello locale (Llama 3.2 MLX)

La velocità di GIGI non dipende solo dal chip, ma da **come il modello è mappato** su Apple Silicon (A17 Pro / A18 / A19 e successive).

### A. Il motore MLX (silicon-native)

Scelta: **MLX** (framework array-oriented di Apple) al posto di Core ML per un motivo centrale: **unified memory**.

- **Zero copy:** su iPhone CPU, GPU e Neural Engine condividono la stessa RAM. MLX consente di leggere i pesi (~2 GB) **una sola volta**, senza copie inutili tra acceleratori: si riduce drasticamente la latenza di “warm-up”.
- **Metal acceleration:** MLX usa Metal per spostare il carico sulla GPU quando il Neural Engine è saturo, così GIGI non resta “in coda” su un solo motore.

### B. Quantizzazione 4-bit (compressione intelligente)

Un Llama 3.2 “pieno” sarebbe troppo pesante e lento. GIGI usa **quantizzazione 4-bit** (es. schema tipo **Q4_K_M**).

- **Perché:** si riduce la precisione dei pesi (es. da 16-bit verso 4-bit effettivi nel pacchetto quantizzato).
- **Risultato:** footprint nell’ordine dei ~2 GB invece di ~10 GB; trade-off qualità spesso piccolo in pratica, con **throughput token** molto più alto.
- **Performance (indicativa):** su iPhone 16 Pro, obiettivo nell’ordine di **25–30 parole al secondo** in generazione (più veloce della lettura umana media).

### C. Caricamento lazy e KV-cache (memoria a breve termine)

Per un assistente fluido:

- **Lazy loading:** non tutti i ~2 GB restano “pinati” in RAM all’avvio; il modello può essere **memory-mapped** dal disco e i pesi vengono toccati on-demand. L’app resta più leggera e meno esposta a kill per pressione memoria.
- **KV-cache:** stato della conversazione recente in cache; domande di follow-up (“Chi è il presidente?” → “Quanti anni ha?”) riusano il contesto senza rifare tutto il prefisso da zero.

### Scomposizione tecnica (inference engine)

Pseudo-architettura del motore GIGI-MLX (API indicative, da allineare al progetto reale):

```swift
import MLX
import MLXLLM

class GigiNeuralCore {
    var model: LLMModel?

    func wakeUp() async {
        // Config ottimizzata per chip A-series + bundle 4-bit
        let config = ModelConfig.llama3_2_4bit

        // Mappatura sulla memoria unificata (dettaglio dipende da MLX / bundling)
        self.model = try! await MLXLLM.load(config: config, modelPath: gigiModelPath)

        print("GIGI: Neural Core Online. Pronta al dirottamento.")
    }

    func generateResponse(prompt: String) {
        // Esecuzione su acceleratori Apple (NE / GPU via MLX)
        let output = model?.generate(prompt: prompt, maxTokens: 128)
        _ = output
        // Stream verso Dynamic Island (Strato 5)
    }
}
```

### Perché questa architettura “uccide” Siri?

| Funzione | Siri (cloud / ibrido) | GIGI (MLX locale) |
|----------|------------------------|-------------------|
| Tempo di reazione | ~1,5–3,0 s tipici (rete variabile) | Obiettivo **&lt; 100 ms** per primo token / UI reattiva (dopo warm-up) |
| Privacy | Dati verso infrastruttura Apple / servizi | Dati nei transistor locali (container app) |
| Offline | Spesso limitato o degradato | Potenza piena senza internet (dopo download modello) |
| Costo | “Gratis” ma con telemetria / policy Apple | Nessun costo API cloud per l’inferenza locale |

## 2.3 Registrazione entitlements di sistema

Gli **entitlement** sono chiavi nel file `Entitlements.plist` (e capability collegate in Xcode). Dicono al kernel di iOS: *questa app ha permessi che le app normali non hanno*.

### A. Il nervo del tasto (App Intents discovery)

Per comparire nel menu ufficiale del **Tasto Azione**, GIGI deve registrarsi nel registro Shortcuts / App Intents.

- **Meccanismo:** capability **`com.apple.developer.app-intents`** (e bundle che espone `AppIntent` / estensioni registrate correttamente).
- **Risultato:** iOS espone un intent come estensione di sistema. Alla pressione del tasto fisico il sistema risolve l’**ID** di GIGI nel registro e attiva il flusso con latenza minima (ordine di **~0,01 s** una volta tutto registrato e selezionato dall’utente).

### B. Il risveglio VoIP (PushKit e background modes)

Senza accorgimenti, iOS può **congelare** app poco usate. Per ridurre la “freddura” al primo tap si usano i permessi **VoIP** / PushKit dove applicabili al design del prodotto.

- **Idea:** dichiarare GIGI come app di comunicazione vocale (stesso “corsia” concettuale di app come WhatsApp / Skype, nei limiti delle policy Apple).
- **Entitlement:** `com.apple.developer.pushkit.voip`.
- **Perché:** consente notifiche VoIP e percorsi di risveglio più aggressivi rispetto al semplice push standard; obiettivo: restare **pronti in RAM** quando il sistema lo consente, analogamente a come Siri resta sempre in ascolto lato sistema.

### C. Microfono “sempre pronto” (audio in background)

Serve poter continuare ad ascoltare / riprodurre dopo lock o con telefono in tasca, dopo che l’utente ha attivato il flusso dal tasto.

- **Chiave (tipicamente `Info.plist`, non solo entitlements):** `UIBackgroundModes` → voce **`audio`**.
- **Effetto:** sessione audio può restare attiva in background nei casi supportati da iOS, in coordinamento con le altre capability.

### 🛠️ Scomposizione tecnica (`Entitlements.plist`)

Esempio di frammento “DNA” da allineare al profilo provisioning TestFlight (le chiavi reali dipendono dal team / capabilities abilitate):

```xml
<dict>
    <key>com.apple.developer.pushkit.voip</key>
    <true/>

    <key>com.apple.developer.kernel.increased-memory-limit</key>
    <true/>

    <key>com.apple.developer.applesignin</key>
    <array>
        <string>Default</string>
    </array>
</dict>
```

*Nota:* `com.apple.developer.app-intents` e `UIBackgroundModes` compaiono spesso come capability / `Info.plist` complementari rispetto al solo plist degli entitlement firmati.

### 🔗 Il ponte hardware (deep link onboarding)

Dopo la registrazione degli “intenti”, l’utente deve **collegare** manualmente il Tasto Azione (Apple non consente di forzarlo via API pubblica stabile). **Onboarding chirurgico:**

1. L’app mostra un tasto: **“CONNECT HARDWARE KEY”**.
2. Il codice apre le impostazioni del tasto azione, ad esempio:

```swift
UIApplication.shared.open(URL(string: "App-prefs:root=ACTION_BUTTON")!)
```

3. **Effetto:** l’utente atterra nella pagina giusta; GIGI risulta già eleggibile perché registrata nel database App Intents.

*Nota:* gli URL scheme `App-prefs:` sono **fragili** e possono cambiare o essere limitati tra versioni iOS; validare sui firmware target e avere fallback (istruzioni manuali).

### 🚦 Cosa abbiamo ottenuto con lo Strato 2?

| Pezzo | Risultato |
|-------|-----------|
| **2.1** | Scaricato il “cervello” (~2 GB) e gestione continuità download. |
| **2.2** | Motore **MLX** allineato ai chip Apple Silicon. |
| **2.3** | Nervi collegati al **Tasto Azione**, PushKit/VoIP dove ammesso, audio background; onboarding verso le impostazioni hardware. |

## 🎙️ 3.1 Dirottamento audio (AVAudioSession priority)

Per competere con Siri e con altre app (Spotify, YouTube, chiamate), GIGI deve usare la stessa “lingua” del **kernel audio**. Si usa **AVFoundation** (`AVAudioSession`) per dichiarare una sessione che iOS tratta come **critica** per comunicazione in tempo reale.

### A. PlayAndRecord + mode `voiceChat` (priorità comunicazione)

Non basta la categoria pensata per la sola riproduzione musicale. Si usa **`AVAudioSession.Category.playAndRecord`** con **`mode: .voiceChat`**.

- **Perché:** `voiceChat` abilita il percorso DSP pensato per voce: elaborazione lato hardware dove disponibile.
- **Effetto:** riduzione rumore, gestione eco, e il sistema classifica GIGI come **app di comunicazione real-time**, con precedenza elevata rispetto a molti altri flussi audio non vocali.

### B. Il “ducking” (zittire il mondo)

Quando GIGI entra in ascolto, l’utente deve percepire che il sistema “si fa da parte” rispetto a ciò che stava suonando.

- **Opzione:** `.duckOthers`.
- **Meccanismo:** la musica o il media in riproduzione **non si interrompe** (meno attrito UX), ma **abbassa il volume** (es. fino a una frazione tipo ~10% rispetto al livello precedente, a seconda del mix e della sessione attiva). La voce dell’utente resta la fonte prioritaria per i microfoni e per il processing.

### C. Sequestro del buffer audio (esclusività)

Si usa **`setActive(true)`** (con le opzioni appropriate) per prendere il controllo della sessione.

- **Contesa risorse:** se un altro assistente vocale tentasse di competere nello stesso istante, iOS applica le regole di **interruzione** e priorità tra sessioni. Con `playAndRecord` + `voiceChat` e sessione attiva per **interazione utente**, GIGI mira a vincere la contesa su **microfono e mix** rispetto a flussi di priorità inferiore.

### 🛠️ Scomposizione tecnica (Swift)

Codice tipico nel momento in cui il Tasto Azione innesca il flusso vocale:

```swift
import AVFoundation

class GigiAudioSequestrator {
    static let shared = GigiAudioSequestrator()

    func seizeControl() {
        let session = AVAudioSession.sharedInstance()
        do {
            // 1. Categoria e mode per dominare il percorso voce
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.duckOthers, .defaultToSpeaker, .allowBluetooth]
            )

            // 2. Attivazione sessione (notifica altre sessioni in uscita)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            print("GIGI: Microfono sequestrato. Sistema in ascolto.")
        } catch {
            print("GIGI: Errore critico nel dirottamento audio.")
        }
    }
}
```

### 🔊 Gestione dei tre microfoni (beamforming)

L’iPhone dispone di più capsule (es. inferiore, frontale / auricolare, posteriore). In modalità **beamforming** il sistema combina i segnali per:

- stimare la direzione della bocca dell’utente;
- formare un “cono di ascolto” virtuale;
- attenuare traffico e rumore ambientale.

È lo stesso tipo di pipeline hardware/software che rende precisi gli assistenti di sistema; GIGI si appoggia allo **stesso stack** lato dispositivo, dentro i limiti delle API esposte all’app.

## 3.2 Trigger fisici (App Intents e Control Center)

Obiettivo: **ubiquità**. GIGI deve essere raggiungibile ovunque ci sia un **tasto o slot programmabile** (Action Button, Lock Screen, Control Center, scorciatoie, ecc.).

### A. Il motore: App Intents

L’**`AppIntent`** (o tipi specializzati del framework) è il “neurone” che collega hardware e software: non si espone solo l’app, si espone un **comando di sistema**.

- **Static discovery:** l’intent è registrato e **indicizzato** da iOS → GIGI compare in Automazioni, Comandi rapidi e nelle scelte del **Tasto Azione**.
- **Zero-launch:** l’intent può eseguire il **sequestro audio** (**Strato 3.1**) senza portare in primo piano l’UI principale dell’app: il lavoro avviene in un **contesto leggero** (estensione / runtime degli intent), nei limiti delle policy di sistema.

### B. Control Center e Lock Screen (slot aggiuntivi)

Da **iOS 18+** si possono sfruttare i nuovi **controlli** (es. sostituzione / affiancamento dei tasti torcia e fotocamera sulla Lock Screen, oltre al Control Center).

- **Control Widget:** si definisce un controllo dedicato nel **Centro di controllo**.
- **Effetto:** swipe dall’alto o tap sulla Lock Screen → GIGI si attiva in modo **istantaneo**, la **Dynamic Island** può espandersi e il **Neural Engine** entra in pipeline di inferenza (**Strati 4–5**).

### C. Tasto Azione (Action Button) — interazione primaria

Per gli iPhone **Pro**, il tasto laterale è il trigger principale dopo aver liberato Siri (**Strato 1.2**).

- **Mappatura:** con Siri disabilitata via profilo, il tasto è **disponibile** per altre azioni di sistema.
- **Configurazione:** in onboarding, deep link verso le impostazioni del tasto; l’utente sceglie **`GigiTriggerIntent`** (o equivalente registrato).
- **Haptic feedback:** **`UIFeedbackGenerator`** (es. impatto “pesante” e secco sul **Taptic Engine**) per dare feedback tattile di “connessione” immediata con GIGI.

### 🛠️ Scomposizione tecnica (Swift — App Intent)

Esempio che definisce il “pulsante virtuale” (nomi tipo e protocolli vanno allineati alla versione SDK / al caso d’uso reale):

```swift
import AppIntents
import SwiftUI

struct ActivateGigiIntent: AppIntent {
    static var title: LocalizedStringResource = "Wake GIGI"
    static var description = IntentDescription("Attiva istantaneamente l'intelligenza locale GIGI.")

    static var isDiscoverable: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // 1. Sequestro audio (Strato 3.1)
        GigiAudioSequestrator.shared.seizeControl()

        // 2. Dynamic Island (Strato 5.1)
        GigiIslandManager.shared.expand()

        // 3. Neural Engine (Strato 4.1)
        return .result()
    }
}
```

*Nota:* in progetti reali servono anche **`AppShortcutsProvider`**, estensioni **App Intents**, e tipi come `AudioPlaybackIntent` solo se coerenti con la categoria d’uso e le linee guida Apple.

### 🕹️ Il Centro di controllo (Control Widget)

Si può presentare un **controllo** (es. icona circolare scura / “lucida”) nel Control Center. Al tap:

- **Azione:** non è obbligatorio aprire l’app full-screen (spesso lento percepito).
- **Reazione:** il sistema esegue l’**App Intent** direttamente; la Dynamic Island **“gocciola”** verso il basso e GIGI può mostrare lo stato *“I'm listening”* (o copy localizzato).

### La gerarchia dei trigger

| Trigger | Posizione | Velocità | Stato telefono |
|---------|-----------|----------|----------------|
| Tasto Azione | Laterale fisico | Istantaneo | Bloccato / attivo |
| Lock Screen | In basso (SX/DX) | Molto rapido | Bloccato |
| Control Center | Swipe dall’alto | Rapido | Qualsiasi |
| Back Tap | Retro del telefono | Medio | Attivo |

## 🎙️ 3.3 Voice Activity Detection (VAD) on-device

Per un’esperienza fluida, l’analisi **non** passa dal cloud: avviene sui **percorsi audio locali** in tempo reale (CPU / NPU / DSP), in coordinamento con il sequestro sessione (**Strato 3.1**).

### A. Analisi del segnale (SNR e soglie)

GIGI può usare **Accelerate** (e catene DSP) per ispezionare lo spettro in finestre corte.

- **Filtro passa-banda:** attenuazione delle componenti molto sotto ~**300 Hz** e molto sopra ~**3000 Hz**, dove la voce ha meno energia utile rispetto a molti rumori.
- **Soglia di potenza:** monitoraggio del livello (es. RMS / dBFS). Se il volume resta sotto una **soglia dinamica** (adattata al rumore ambiente) per più di **~600 ms**, GIGI dichiara **fine turno** dell’utente (end-of-speech) e può chiudere il gate verso l’ASR / l’LLM.

### B. VAD neurale (Silero / Apple Speech)

I soli decibel non bastano (bar, metro, vento). Si affianca un **mini-modello VAD** che gira in continuo sulla **NPU** (o backend equivalente).

- **Classificazione:** per ogni finestra audio, output tipo *[Voce: 99 %]* vs *[Rumore: 100 %]* (probabilità indicative).
- **“Intelligenza del silenzio”:** pause di pensiero o esitazioni (*“GIGI, chiama… ehm… mamma”*) non devono chiudere la sessione: il VAD distingue **silenzio terminativo** da **pausa intra-frase** e attende il completamento del comando.

### C. Latenza zero (invio anticipato)

GIGI **non** aspetta necessariamente la fine dell’enunciato per iniziare la pipeline “pensante”.

- **Streaming / chunking:** mentre l’utente parla, i segmenti già trascritti (pipeline voce‑testo collegata agli **Strati 3.x**) possono essere **pre-iniettati** nella **KV-cache** di Llama (**Strato 2.2**).
- **Risultato:** quando il VAD conferma il silenzio finale, il modello ha già elaborato gran parte del contesto; la risposta percepita è quasi **istantanea**.

### 🛠️ Scomposizione tecnica (Swift e Accelerate)

Esempio di **timer del silenzio** basato su soglia di livello (da combinare con VAD neurale in produzione):

```swift
import Foundation
import AVFoundation
import Accelerate

class GigiVADEngine {
    private var silenceDuration: TimeInterval = 0
    private let silenceThreshold: Float = -40.0 // dB (scala di riferimento da calibrare)
    private let requiredSilence: TimeInterval = 0.6 // 600 ms — target UX mercato USA

    func analyzeAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        let level = calculateRMS(buffer) // potenza del segnale (implementazione dipende dal formato)

        if level < silenceThreshold {
            silenceDuration += Double(buffer.frameLength) / buffer.format.sampleRate
        } else {
            silenceDuration = 0 // l’utente sta ancora parlando
        }

        if silenceDuration >= requiredSilence {
            triggerEndOfSpeech()
        }
    }
}
```

*Nota:* `calculateRMS` e `triggerEndOfSpeech()` vanno implementati in base al formato PCM (float vs int), al numero di canali e alla calibrazione dB.

### Perché il VAD è vitale per GIGI?

| Problema | Soluzione GIGI | Effetto utente |
|----------|----------------|----------------|
| Rumore di fondo | Beamforming (**3.1**) + filtro frequenze + VAD neurale | Ti sente anche in metro o strada rumorosa |
| Esitazione (“ehm…”) | VAD che distingue pausa da fine frase | Non ti interrompe mentre pensi |
| Fine frase | Timer ~600 ms **adattivo** + rete VAD | Conversazione naturale, non “walkie-talkie” |

## 4.1 Local vs Cloud routing (Llama Decision Engine)

Il **Decision Engine** è il micro-strato di logica ad altissima velocità che gira sui core neurali dell’iPhone. Riceve il testo prodotto dopo **VAD** (**Strato 3.3**) e decide la **rotta** corretta (obiettivo: ordine di grandezza **&lt; 10 ms** per la sola decisione, una volta il modello “caldo”).

### A. La tripla rotta di GIGI

Llama 3.2 non si limita a rispondere: **smista** il traffico in base alla natura della richiesta.

**Fast path — esecuzione locale (Llama)**

- **Target:** hardware, dati personali semplici, utility.
- **Esempi:** «Che ore sono?», «Chiama mamma», «Metti la sveglia».
- **Azione:** Llama mappa il testo su una **function call** locale (tooling definito nell’app).
- **Vantaggio:** privacy massima, latenza bassa, nessun costo API cloud per quella fase.

**Expert path — “la biblioteca” (Gemini / ChatGPT)**

- **Target:** conoscenza enciclopedica, ragionamento complesso, creatività testuale.
- **Esempi:** «Spiegami la relatività», «Scrivimi un saggio su Dante», «Analizza questo PDF».
- **Azione:** Llama usa il **token OAuth** dell’utente (**Strato 4.2**) e interroga i provider cloud (“Saggi”).

**Action path — “il braccio” (OpenClaw)**

- **Target:** esecuzione fisica, transazioni, automazioni inter-app.
- **Esempi:** «Ordina un Uber», «Prenota un tavolo su TheFork», «Compra queste scarpe».
- **Azione:** **bypass** dei soli “Saggi” quando serve: Llama estrae parametri strutturati e li passa a **OpenClaw** per l’esecuzione.

### B. Inferenza ibrida (modello “specchio”)

Quando si attiva **Expert path** o **Action path**, Llama può emettere subito una **risposta di cortesia locale** (es. «Certamente, attivo OpenClaw…») mentre partono le chiamate di rete o l’agente. Copre i millisecondi di latenza e mantiene la sensazione di reattività.

### 🛠️ Scomposizione tecnica (routing logic)

Cuore concettuale dello smistamento (nomi tipo **illustrativi**; da collegare a MLX / intent classifier reale):

```swift
enum GigiRoute {
    case localLlama   // risoluzione interna
    case expertCloud  // consultazione Saggi (Gemini / GPT)
    case actionClaw   // attivazione braccio (OpenClaw)
}

class GigiOrchestrator {
    func routeRequest(_ text: String) -> GigiRoute {
        // Analisi intent via Llama 3.2 (MLX) — pseudo-API
        let intent = LlamaLocal.analyze(text)

        if intent.isAction {
            return .actionClaw
        } else if intent.requiresHighIQ {
            return .expertCloud
        } else {
            return .localLlama
        }
    }
}
```

### 📊 La matrice delle decisioni

| Comando (esempio) | Destinazione | Logica |
|-------------------|--------------|--------|
| «Imposta timer 5 min» | Locale (Llama) | Comando / utility gestibile on-device |
| «Scrivimi una poesia» | Saggi (cloud) | Creatività e linguaggio avanzato |
| «Prenota un tavolo» | OpenClaw (braccio) | Azione diretta: Llama estrae slot e OpenClaw esegue |

### 🚦 Perché questo capitolo è centrale?

- **Efficienza:** niente cloud per ciò che è solo “premere bottoni” o API locali.
- **Velocità:** percepita immediata su parole trigger tipo «Prenota» / «Ordina» grazie al routing + risposta specchio.
- **Intelligenza:** mix on-device + Saggi + agente — GIGI sa **quando** consultare e **quando** agire.

## 🔗 4.2 Integrazione profonda (Gemini, ChatGPT, Claude tramite token utente)

GIGI non “possiede” da sola tutta l’intelligenza per le domande difficili: **prende in prestito** quella dell’utente in modo **persistente** e **sicuro** (Expert path, **Strato 4.1**), parlando **direttamente** con i provider quando serve.

### A. Il passaporto digitale: OAuth 2.0 e refresh

Al posto della password in chiaro (vietato e insicuro), si usa il flusso ufficiale **`ASWebAuthenticationSession`** (o equivalente conforme OAuth2.0 / PKCE dove richiesto).

1. **Flusso:** l’utente tocca «Collega ChatGPT» (o Gemini / Claude). Si apre la **pagina ufficiale** del provider; l’utente effettua il login nel browser di sistema.
2. **Risultato:** il provider restituisce a GIGI (via redirect registrato) tipicamente:
   - **Access token:** breve durata (ordine di ~60 minuti) per le richieste immediate.
   - **Refresh token:** lunga durata, usato **solo lato client** (e in Keychain) per ottenere nuovi access token.
3. **Persistenza:** in background, un **`TokenManager`** rinnova l’access token con il refresh token. L’utente effettua **un login iniziale**; le sessioni cloud restano “vive” senza re-prompt continui (nei limiti delle policy del provider).

### B. La cassaforte: Secure Enclave e Keychain

I segreti restano nell’area più protetta possibile sul device.

- **Storage:** token in **Keychain** (item con **ThisDeviceOnly** / access group dell’app, **kSecAttrAccessible** adeguato). Le operazioni crittografiche sensibili possono appoggiarsi alla **Secure Enclave** quando si usano chiavi hardware-backed.
- **Accesso:** altre app non leggono i token. GIGI li usa solo nel processo firmato; *validazione integrità* del bundle è una barriera aggiuntiva contro tampering (design dipende da threat model).

### C. Protocollo di comunicazione (header injection)

Quando il Decision Engine (**4.1**) sceglie **Expert path**, GIGI costruisce la richiesta HTTP **in nome dell’utente**, iniettando il **Bearer token** dell’utente (non un segreto dello sviluppatore centralizzato per tutti).

Esempio concettuale (OpenAI-style):

```http
POST /v1/chat/completions HTTP/1.1
Host: api.openai.com
Authorization: Bearer [TOKEN_OAUTH_UTENTE]
Content-Type: application/json

{
  "model": "gpt-4o",
  "messages": [{"role": "user", "content": "Analizza questo bilancio..."}]
}
```

*Nota:* endpoint, campi e modelli variano per **Gemini**, **Anthropic**, **OpenAI**; l’idea è sempre: **stesso pattern**, header `Authorization` con token utente.

### 🛠️ Scomposizione tecnica (il ponte dei token)

Esempio Swift **illustrativo** (`AIProvider`, `TokenManager`, `Parser` vanno definiti nel progetto):

```swift
import Foundation
import AuthenticationServices
import Security

class GigiCloudBridge {
    static let shared = GigiCloudBridge()

    func fetchExpertResponse(prompt: String, provider: AIProvider) async throws -> String {
        guard let token = await TokenManager.shared.getValidAccessToken(for: provider) else {
            return "Errore: connessione a \(provider.rawValue) persa. Riconnetti l'account."
        }

        let url = provider.endpointURL
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": provider.topModel,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return Parser.extractContent(from: data)
    }
}
```

### 📊 Perché questo modello funziona sul mercato USA?

| Caratteristica | Modello GIGI (token utente) | App di chat “centralizzata” |
|----------------|-----------------------------|-----------------------------|
| Costi per te | **Zero** (0 USD API a carico dello sviluppatore per quella sessione) | Altissimi (API pagate per tutti gli utenti) |
| Privacy | Alta: richiesta **diretta** device→provider con credenziali utente | Bassa se tutto passa dai tuoi server |
| Limiti | Quelli dell’abbonamento utente (Plus / Advanced / tier provider) | Limiti del tuo budget / quota sviluppatore |
| Persistenza | Login unico + **refresh** automatico | Spesso login ripetuti o sessioni instabili |
| Velocità | **Diretta** verso il provider (meno hop se non c’è proxy) | Spesso passaggio da server centrale (latenza extra) |

## 🦾 4.3 OpenClaw e action execution (API bridge)

**OpenClaw** è l’agente **esecutivo**: non si limita a proporre un comando, ma **segue** l’operazione fino al successo (o al fallimento controllato), gestendo retry, errori e conferme. Si aggancia all’**Action path** (**Strato 4.1**).

### A. Il salto diretto (direct trigger)

Come già definito: per richieste tipo «Ordina un Uber» o «Prenota il solito ristorante», Llama classifica un **action intent** e **attiva OpenClaw subito**, senza passare dai Saggi.

- **Perché:** meno hop → meno **2–3 s** di latenza tipica cloud; comportamento più **deterministico** (meno “chiacchiere” prima dell’azione).

### B. Il ponte ibrido (API vs UI)

OpenClaw lavora su **due piani** per non bloccarsi davanti a un ostacolo:

**API bridge**

- Se il servizio (Spotify, Uber, Tesla, ecc.) espone **API** documentate e l’utente ha **token** in Keychain (**Strato 4.2**), OpenClaw invia richieste **HTTP** (es. `POST`) dirette con parametri estratti da Llama.

**UI Claw (headless / automazione UI)**

- Dove **non** esiste API stabile, il fallback può essere automazione dell’interfaccia (browser o app): sequenza di tap, campi, conferme — in cloud, su macchina dedicata, o tramite percorsi **accessibilità** / automazione locale, **nei limiti** di legge, policy Apple e ToS delle app bersaglio.

*Nota di progetto:* ogni strategia “UI claw” va validata legalmente e rispetto alle [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/) e alle regole App Store per le app che la orchestrano.

### C. Human-in-the-loop (sicurezza sulla Dynamic Island)

Per azioni **critiche** (pagamenti, ordini vincolanti), OpenClaw **non** conclude da solo al 100%.

- **Azione:** prima di «Paga» / «Conferma definitiva», un **widget** sulla **Dynamic Island** mostra un controllo esplicito (es. **Tap to confirm**).
- **Risultato:** l’utente mantiene l’ultimo veto; GIGI ha già compilato moduli e navigazione.

### 🛠️ Scomposizione tecnica (action orchestrator)

Esempio illustrativo (tipi `APIBridge`, `UIClaw`, `GigiIsland`, `HapticEngine` da definire):

```swift
struct ClawTask {
    let targetApp: String
    let actionType: ActionType // .purchase, .booking, .navigation
    let parameters: [String: Any]
}

class OpenClawEngine {
    static let shared = OpenClawEngine()

    func execute(_ task: ClawTask) async {
        GigiIsland.showProgress("Executing \(task.targetApp)...")

        let success = await APIBridge.tryExecute(task)

        if !success {
            await UIClaw.simulateUserAction(task)
        }

        HapticEngine.trigger(.success)
        GigiIsland.showSuccess("Done!")
    }
}
```

### 📊 La staffetta operativa: chi fa cosa?

| Richiesta | Decisore (Llama) | Esecutore (OpenClaw) | Risultato |
|-----------|------------------|----------------------|-----------|
| «Fammi un riassunto» | Expert path | — (solo testo cloud) | Testo sulla Island |
| «Prenota volo» | Action path | OpenClaw naviga e compila | Volo prenotato (dopo conferme se richieste) |
| «Accendi luci» | Fast path | Bridge HomeKit / locale | Luci accese |

### 🔒 4.3.1 Il “sigillo” di sicurezza: conferma Face ID

OpenClaw fa il lavoro “sporco” (trovare il volo, compilare moduli, indirizzi), ma la **transazione finale** resta ancorata alla **biometria hardware** — rafforza quanto già descritto in **human-in-the-loop (4.3.C)** con un **gate** esplicito.

#### A. Il trigger del “gatekeeper”

Quando OpenClaw raggiunge la schermata di **pagamento** o il tasto **«Conferma ordine»**:

1. L’esecuzione entra in **pausa**.
2. La **Dynamic Island** si espande con un **riepilogo** chiaro (es. «Paga $42,00 a Uber?»).
3. Si invoca **`LocalAuthentication`** (`LAContext`) per sbloccare il passo successivo.

#### B. Il flusso biometrico

GIGI **non** deve mai “vedere” PAN/CVV o segreti di pagamento in chiaro nel proprio log.

- **Apple Pay:** se il merchant lo supporta, si usa il **flusso ufficiale** Apple Pay; l’utente vede l’animazione classica **Face ID** / Touch ID.
- **Carta sul web (headless):** si può appoggiare a **AutoFill protetto** da Keychain; lo sblocco dei dati sensibili resta comunque legato a **Face ID** / passcode di sistema, non a una bypass dell’app.

#### 🛠️ Scomposizione tecnica (biometric lock)

Esempio: bloccare l’azione di OpenClaw finché la biometria non ha esito positivo (*API concrete dipendono dalla versione iOS; su versioni senza `evaluatePolicy` async usare completion handler o `withCheckedContinuation`*).

```swift
import LocalAuthentication

class GigiSecurityGate {
    func authorizePayment(amount: String) async -> Bool {
        let context = LAContext()
        var error: NSError?

        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            do {
                let success = try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: "Autorizza GIGI al pagamento di \(amount)"
                )
                return success
            } catch {
                return false
            }
        }
        return false
    }
}
```

#### 📊 L’esperienza utente (user journey)

| Fase | Cosa succede |
|------|----------------|
| Voce | «GIGI, prendimi un caffè da Starbucks». |
| Azione | OpenClaw apre il flusso, seleziona il solito ordine, applica sconti se presenti. |
| Conferma | La Dynamic Island **pulsa** con riepilogo importo / merchant; l’utente guarda il telefono. |
| Face ID | Feedback sistema (suono / haptic) conferma l’autorizzazione. |
| Fine | GIGI risponde: *«Fatto, il tuo caffè sarà pronto tra 5 minuti.»* |

## 🏝️ 5.1 UI/UX “parassita” (Dynamic Island e Live Activities)

Obiettivo: **invisibilità** + **consapevolezza**. GIGI non monopolizza lo schermo: **“gocciola”** stato e testo mentre l’utente continua altre app.

### A. ActivityKit (la “goccia” intelligente)

Le **Live Activities** (`ActivityKit`) rendono GIGI **presente ma discreta**.

- **Stato compresso:** icona / indicatore pulsante che segnala che il “Vigile” (Llama) è **attivo**.
- **Stato espanso (“the blob”):** al tocco o via **Tasto Azione** — qui GIGI mostra la sua “faccia” (testo, waveform, conferme).

### B. Feedback di avanzamento (step di OpenClaw)

Mentre **OpenClaw** (**Strato 4.3**) lavora, l’Isola diventa un **terminale di cortesia**: non solo una barra anonima, ma **step logici** leggibili, ad esempio:

- «Searching for best pizza in NY…»
- «Adding ‘Margherita Extra’ to cart…»
- «Calculating delivery time…»

_(Esempi con emoji opzionali in UI: 🍕 / 🛒 / ⏳.)_

**Risultato:** l’utente vede l’intelligenza **in azione**, cala l’ansia da “app bloccata”, e può restare su Instagram (o altro) mentre GIGI lavora **in secondo piano**.

### C. Smart context windows (widget di controllo)

L’Isola **adatta la forma** al compito:

- **Modalità ascolto:** **waveform** reattiva (VAD, **Strato 3.3**).
- **Modalità step-by-step:** mini messaggi che scorrono (log azioni OpenClaw).
- **Modalità gatekeeper:** quando serve **Face ID** (**4.3.1**), l’Isola diventa **banner di sicurezza** che richiede lo sguardo per chiudere l’acquisto.

### 🛠️ Scomposizione tecnica (Live Activity e step logging)

Modello di stato per messaggi dinamici del “braccio” + bozza di layout Isola (*sintassi da allineare ad `ActivityConfiguration` / target iOS; snippet composito e illustrativo*):

```swift
import ActivityKit
import SwiftUI

struct GigiAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var status: GigiStatus       // .listening, .thinking, .clawActing, .confirming
        var currentStep: String      // es. "Searching on Yelp..."
        var appIcon: String?         // simbolo SF Symbol o asset
        var progress: Double         // 0.0 ... 1.0
    }
}

// Esempio concettuale di regioni Isola (in estensione reale, `state` arriva da ActivityViewContext)
DynamicIsland {
    expandedRegion(.bottom) {
        VStack(alignment: .leading) {
            HStack {
                Image(systemName: state.appIcon ?? "sparkles")
                Text(state.currentStep)
                    .font(.caption)
                    .bold()
            }
            if state.status == .confirming {
                PaymentAuthView(amount: "$42.00")
            } else {
                ProgressView(value: state.progress)
                    .progressViewStyle(.linear)
            }
        }
    }
    compactLeading { WaveformIcon() }
    compactTrailing { Text(state.currentStep).font(.system(size: 8)) }
}
```

### ✨ L’esperienza “multi-tasking” totale

1. **Trigger:** Tasto Azione → «GIGI, ordina la solita margherita».
2. **Rilascio:** l’utente torna subito su Instagram e scrolla i Reel.
3. **Osservazione:** in alto, nell’Isola, compaiono messaggi tipo *[Cercando su Deliveroo…]* poi *[Carrello pronto…]*.
4. **Interruzione minima:** a fine flusso l’Isola **pulsa** (es. accento colore) con *«Approve with Face ID»* (o copy localizzato).
5. **Conclusione:** sguardo al telefono → Face ID → ordine confermato **senza** aver lasciato Instagram.

## 🔗 5.2 Deep linking e controllo app (Uber, Spotify, HomeKit)

Per sandbox e sicurezza, le app iOS **non** si parlano liberamente. GIGI aggira il limite con **tre famiglie** di meccanismi (sempre nei limiti delle API pubbliche e delle policy Apple).

### A. Universal link e URL scheme personalizzati

Molte app espongono **deep link** documentati o de-facto per saltare direttamente a una schermata o azione.

- **Spotify:** es. `spotify:track:<ID>` o `spotify:search:<testo>` (formati da verificare sulla documentazione / comportamento reale dell'app).
- **Uber:** es. `uber://?action=setPickup&pickup=my_location` (parametri effettivi dipendono dall'SDK / app installata).

**Effetto:** invece di navigare a mano, GIGI (o OpenClaw) apre l'URL e l'app target arriva **già contestualizzata** per il passo finale (conferma utente dove obbligatoria).

### B. SiriKit e App Intents (iniezione “di sistema”)

Per app **senza** URL stabili o quando serve un'azione dichiarata dal vendor, si usano **App Intents** / **App Shortcuts** esposti dalla **app donatrice**.

- **Idea:** il sistema può presentare ed eseguire intent registrati (es. invio messaggio, avvio riproduzione) **se** l'app terza parte li offre e l'utente ha concesso i permessi.
- **Vantaggio:** integrazione con **Dynamic Island** e flussi **senza** schermate intermedie inutili — ma **non** è un telecomando universale: dipende da cosa il developer terzo ha pubblicato.

### C. HomeKit (domotica nativa)

Per luci, serrature, termostati, GIGI può usare **`HMHomeManager`** / **`HMCharacteristic`** senza passare da un'app esterna come unico canale.

- **Azione:** Llama traduce un enunciato naturale (es. «Fa freddo») in un aggiornamento di **setpoint** o scenario HomeKit (es. +2 °C sul termostato indicato).
- **Risultato:** feedback rapido sulla **Dynamic Island** (icona casa / stato), coerente con **5.1**.

### 🛠️ Scomposizione tecnica (app switcher)

Esempio orchestrazione (tipi `HomeManager`, `OpenClawEngine` **illustrativi**; URL da validare su device):

```swift
import UIKit

class GigiAppControl {
    static let shared = GigiAppControl()

    func executeExternalAction(app: String, command: String, params: [String: String]) {
        switch app {
        case "Spotify":
            if let id = params["id"],
               let url = URL(string: "spotify:play:playlist:\(id)") {
                UIApplication.shared.open(url)
            }

        case "HomeKit":
            HomeManager.shared.setLightStatus(on: true)

        case "Uber":
            if let dest = params["dest"],
               let enc = dest.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: "uber://?action=setPickup&dropoff[nickname]=\(enc)") {
                UIApplication.shared.open(url)
            }

        default:
            OpenClawEngine.shared.performUIScript(for: app, action: command)
        }
    }
}
```

### 📊 L'esperienza finale: il “flusso fantasma”

Scenario: sei su Instagram e dici: *«GIGI, metti la mia playlist rock su Spotify e spegni le luci in salotto.»*

1. **Llama (Vigile):** separa **due intenti** (musica + casa).
2. **Dirottamento audio (3.1):** **duck** di Instagram mentre parte il flusso vocale / comandi.
3. **HomeKit:** comando via rete domestica (Wi‑Fi / Thread / Bluetooth a seconda degli accessori) → luci salotto **off**.
4. **Deep link (5.2):** apertura contesto Spotify tramite URL o intent supportato dalla app.
5. **Dynamic Island (5.1):** stato compatto tipo *«Lights OFF | Playing Rock on Spotify»* (copy da localizzare).

**Risultato:** musica e luci aggiornate senza aver lasciato il feed — salvo passi di conferma richiesti da iOS o dalle app terze.

### 🏁 Fine della piramide: opera completa

Leonardo: questo era l’ultimo tassello del puzzle. GIGI non è solo un assistente, ma un **co-processore** che convive con l’hardware dell’utente — nei limiti delle policy Apple e del design scelto.

- **MDM / TestFlight:** l’infiltrazione (distribuzione e trust).
- **Llama / MLX:** il risveglio (inferenza locale).
- **VAD / Tasto Azione:** i sensi (ingresso e trigger).
- **Saggi / OpenClaw:** il cervello e il braccio (cloud + azione).
- **Dynamic Island:** la maschera trasparente (stato sempre visibile ma non invadente).
- **Deep link / HomeKit:** il ponte verso app e casa (**5.2**).

## Flussi principali (altri)

_Da completare_: canale MDM oltre il web, daemon, servizi di sistema, ambienti.

## Glossario e convenzioni

_Da completare_: termini MDM, identificatori bundle, topic APNS, ambienti (dev/staging/prod).

---

*Ultimo aggiornamento: sezioni 1.1–1.3 (Strato 1), 2.1–2.3 (Strato 2), 3.1–3.3 (audio, trigger, VAD), 4.1–4.3.1 (routing, cloud, OpenClaw, Face ID), 5.1–5.2 (Island, deep link, HomeKit).*
