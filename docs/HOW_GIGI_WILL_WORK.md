# Come funzionerà GIGI — spiegazione discorsiva

> Documento di accompagnamento al piano tecnico (`docs/plans/frolicking-stargazing-pancake.md`).
> Scritto per dare al PM e a chiunque legga il repo una visione **leggibile, non tecnica**
> di cosa stiamo costruendo e perché. Per il dettaglio implementativo: vedi piano + ADR.
>
> Aggiornato 2026-05-11 — dopo cleanup pre-Phase 2 (commit `bdc393a`).

---

## 1. Cos'è GIGI in una frase

GIGI è un assistente vocale per iPhone che si comporta come un Siri più intelligente: gli parli in inglese, lui capisce cosa vuoi e o lo fa direttamente (chiamare, mandare un messaggio, navigare, accendere le luci) oppure delega a un cervello più potente quando il task è complesso (cercare sul web, scrivere un'email, ragionare). Il tutto **senza pagare API ogni volta che lo usi** — gira on-device per il routing, sul tuo PC di casa per il reasoning offline, e sulla subscription Claude Code che hai già per i task pesanti.

---

## 2. Perché abbiamo deciso di ricostruirlo

GIGI esiste già e funziona. Ma negli ultimi sei mesi è cresciuto in modo disordinato: ogni feature è stata appiccicata sopra la precedente senza un piano architetturale, e oggi il cervello principale è **Groq cloud** che fa la maggior parte del lavoro. Significa due cose:

- **Dipendi da una API a pagamento ogni volta che apri l'app**. Per un'app che vuoi rilasciare open-source al mondo, questa è una barriera enorme: nessuno cloderà GIGI se prima deve creare un account Groq, ricaricare crediti e configurare una chiave.
- **Apple Foundation Models, il modello AI on-device gratuito che Apple mette dentro iPhone 15 Pro+ e successivi, oggi è praticamente inutilizzato**. Esiste il codice che lo collega, ma il flow principale non lo chiama mai. Tipico drift architetturale: feature aggiunte una sopra l'altra, e nessuno è mai tornato a riequilibrare le cose.

Il piano è un **riequilibrio strategico**: rimettiamo Apple Foundation Models al centro, eliminiamo Groq, e usiamo Claude Code (la CLI che usa la tua subscription Pro/Max) solo per i task davvero complessi. Il risultato è un'app open-source dove **chiunque cloni il repo riesce a far girare la demo in meno di mezz'ora, senza ricaricare una sola API**.

---

## 3. Come funzionerà — la visione

Immagina di premere il bottone del microfono di GIGI sul tuo iPhone e dire una di queste 4 frasi:

1. *"Set a timer for ten minutes"*
2. *"Send a message to Marco saying I'll be 15 minutes late"*
3. *"Explain the Bayes theorem in three sentences"*
4. *"Search Wikipedia for Nikola Tesla and create an iPhone Note about his most important invention"*

Sono richieste con complessità crescente, e GIGI userà 4 motori diversi in base a quello che chiedi, in modo invisibile per te. Ti spiego cosa succede dietro le quinte per ognuna.

### Caso 1 — "Set a timer for 10 minutes"

Questa è la richiesta più semplice. GIGI ha **regole scritte a mano** (regex) per riconoscere immediatamente intent del tipo "timer", "torch on", "what time is it" senza nemmeno chiamare un LLM. È il **Path 1** del piano, che chiamiamo "Native fast". Quando l'intent è chiaro e ha confidence altissima (≥95%), GIGI esegue subito l'azione iOS nativa (in questo caso schedula una notifica iOS per 10 minuti) e ti conferma con un breve "Timer set" detto a voce.

**Tempo totale**: 80-200 millisecondi. Costa zero, gira al 100% on-device.

### Caso 2 — "Send a message to Marco saying I'll be 15 minutes late"

Più complesso: c'è una persona da identificare (Marco), un canale da scegliere (WhatsApp? iMessage?), e un testo da costruire. Le regole della Path 1 non ce la fanno a estrarre tutti i pezzi con sicurezza.

Qui interviene **Apple Foundation Models**. È un modello AI da 3 miliardi di parametri che gira on-device sul Neural Engine dell'iPhone 15 Pro+ (e successivi). Apple gli ha dato un super-potere: quando gli dici "rispondi seguendo questo schema preciso" (con la nostra notazione `@Generable`), il modello è **forzato matematicamente** a rispettarlo. Non può sgarrare i nomi dei campi, non può inventare valori sbagliati. Si chiama "constrained decoding" — pensalo come un binario invisibile su cui il modello DEVE viaggiare.

Apple FM legge la tua frase, capisce che vuoi `send_message`, estrae `contact: "Marco"`, `platform: "whatsapp"`, `body: "I'll be 15 minutes late"`, e chiama uno dei nostri 15 tool nativi iOS preregistrati. È il **Path 2** del piano.

**Tempo totale**: 1-3 secondi. Costa zero, gira al 100% on-device.

### Caso 3 — "Explain the Bayes theorem in three sentences"

Qui non c'è nessuna azione iOS da eseguire. Serve **ragionamento testuale**. Apple FM 3B non è abbastanza potente per spiegazioni dense (è bravo a fare routing, debole a ragionare). E noi non vogliamo bruciare la tua subscription Claude Code per ogni Q&A.

Apple FM, agendo come **router**, riconosce che è una richiesta di reasoning semplice e la deleg al nostro **Path 3 — Ollama harness**. Ollama è un piccolo server che gira sul tuo PC di casa (Mac o Windows). Ha scaricato un modello open-source di Alibaba chiamato Qwen 3 (14 miliardi di parametri, Apache 2.0, gratuito per sempre) che è bravo a ragionare offline.

Apple FM passa la query a Qwen via HTTP, Qwen risponde in 5-15 secondi, la risposta torna all'iPhone via WebSocket, e GIGI te la legge a voce.

**Tempo totale**: 7-17 secondi. Costa zero (gira sul tuo hardware). Privacy massima: niente esce dal tuo PC.

### Caso 4 — "Search Wikipedia for Tesla and create a Note"

Questo è il caso "killer demo". È un task multi-step che richiede:
1. Aprire un browser
2. Navigare Wikipedia
3. Leggere l'articolo
4. Estrarre l'invenzione più importante (alternating current induction motor)
5. Sintetizzare in 2-3 frasi
6. Creare una nota iOS con il riassunto

Qui Apple FM 3B non basta — serve un modello più grande che capisca multi-step + sappia usare un browser. Apple FM, sempre come router, riconosce la complessità e deleg al **Path 4 — Claude Code subprocess**.

Claude Code è la CLI ufficiale di Anthropic, quella che usano i developer per programmare con Claude. Tu hai già una subscription (Pro $20/mese, o Max $100-200/mese). Il nostro harness, invece di chiamare le API a pagamento di Anthropic, **spawn-a un subprocess `claude` esattamente come faresti tu da terminale**, e Claude usa il tuo abbonamento.

Claude legge i tool che gli abbiamo dato (un MCP server custom che pilota Chrome via Playwright), pianifica: "navigo Wikipedia, leggo l'articolo, estraggo l'invention, ritorno il summary". Ogni passo è streamato all'iPhone in tempo reale come "thought bubbles" che vedi nell'UI ("Searching Wikipedia...", "Reading article...", "Extracting main invention"). Quando ha il summary, lo passa di nuovo ad Apple FM che chiama il tool `create_note` iOS-side per creare la nota.

**Tempo totale**: 30-90 secondi. Costa zero come API marginale (la tua subscription copre tutto). Limite: la subscription ha un cap settimanale, quindi se usi GIGI 200 volte al giorno con task complessi, potresti esaurire il Pro plan.

### Il quinto path — Reject graceful

Se Apple FM riceve una query che non capisce o che non può servire (es. "buy bitcoin" → no), risponde cortesemente "I can't help with that, sorry". Niente errori cripticitri, niente crash. È il **Path 5**.

---

## 4. Il cervello centrale — chi decide tra i 5 path?

Apple Foundation Models. È letteralmente il "centralinista" che riceve ogni query e decide dove mandarla.

Tecnicamente: c'è un piccolo schema strutturato (`FoundationRouterDecision`) con questi campi:

- `path` → quale dei 5 path attivare
- `primaryAction` → se è azione iOS, quale tool chiamare
- `complexityEstimate` → un numero da 0 a 100 che misura quanto è difficile il task
- `requiredCapabilities` → cosa serve (browser? codice? vision?)
- `slots` → dati pre-estratti (contact, body, destination, time, etc.)
- `directSpeech` → se è chiarificazione/reject, cosa dire

Apple FM produce questo schema in modo garantito (constrained decoding), e il router del nostro codice (`GigiRequestRouter`) lo legge e dispatcha.

**Regola di cost-aware routing**: se `complexityEstimate ≤ 40` e non serve un browser, mandiamo a Ollama (Path 3). Se è più complesso o serve un browser, mandiamo a Claude Code (Path 4). Così non bruciamo la subscription per task che Ollama può fare benissimo.

---

## 5. I 4 modes operativi — l'utente sceglie la filosofia

Non tutti hanno lo stesso hardware o vogliono la stessa cosa. Per questo GIGI offre **4 modes** selezionabili da Settings:

### Minimal — "voglio provare velocemente"
Solo Path 1 (regole on-device) + Path 4 (Claude Code per tutto il resto). Setup richiesto: solo la subscription Claude Code. Niente PC con Ollama. Path 2/3 disabilitati. Per chi vuole vedere come funziona senza configurare l'harness Ollama.

### Privacy Max — "niente esce dal mio ecosistema"
Path 1 + Path 2 (Apple FM iOS) + Path 3 (Ollama PC). Path 4 disabilitato (no cloud). Per chi vuole zero dati che lasciano il proprio hardware. Limitazione: niente browser automation, niente reasoning complesso. Lo rinomineremo "Local-First Mode" perché Apple Private Cloud Compute è opaco e "Privacy Max" è imprecisa.

### Apple Optimized — "ho un iPhone top ma non voglio installare Ollama"
Path 1 + Path 2 + Path 4. Niente Ollama. Per chi ha iPhone 15 Pro+ e subscription Claude Code, ma non vuole il setup harness.

### Full Power — "voglio tutto, decide GIGI da solo"
Tutti i 5 path attivi. Setup richiesto: iPhone Apple Intelligence-capable + harness Ollama installato + subscription Claude Code. Cost-aware routing automatico decide.

L'app rileva al boot quale infrastruttura è disponibile e propone il mode adatto, ma l'utente può cambiarlo da Settings.

---

## 6. Cosa abbiamo già fatto (commit 2026-05-11)

A oggi il branch `armando-rework` è in stato "ready per Phase 1 design doc". Sintesi delle ultime 3 sessioni di lavoro:

**Pulizia drastica della codebase**:
- ~1262 righe di engine "soft-killed" rimosse fisicamente dal target Xcode (wake word, day plan reasoner, brain pipeline morta), spostate in una cartella `_legacy/` per preservare la storia.
- Rimossa la dipendenza Google Sign-In e tutto il suo plist OAuth (residuo Gemini-era).
- ~110 righe di zombie in `GigiCloudService.swift` rimosse (5 funzioni morte tipo `processWithGroq`, `classifyIntent`).
- ~600 righe di UI morta rimosse (debug FAB consolidati, sezioni Settings dupli, tab Presence duplicate, Voice Setup wizard duplicato di Profile editor).

**Risultato visivo nell'app**:
- 4 tab → 3 tab (Chat / Dashboard / Settings)
- 7 step onboarding → 6 (profilo si compila opt-in dal Dashboard)
- Dashboard: 3 pill di stato sovrapposte → 1 dot pulito
- Settings: rimosse 5 sezioni debug per test consolidati
- Zero stringhe italiane user-facing rimaste (regola CLAUDE.md rispettata)

**Preparazione per Phase 2**:
- Aggiunto un **Brain Path Override picker** nascosto in Settings → Debug. Permette di forzare manualmente quale path usare (Auto / Apple FM / Ollama stub / Claude) anche prima che il router 5-path sia implementato. Serve a testare incrementalmente.
- Estratto lo schema `FoundationAgentOutput` in un nuovo file `GigiFoundationContracts.swift` per fare spazio al futuro `FoundationRouterDecision`.
- Rinominato `selectRelevant()` (il vecchio scoring brittle dei 47 tool) in `selectRelevant_DEPRECATED()` con annotation `@available(*, deprecated)` per renderlo grep-able.
- Aggiunto stub vuoti per i 4 file iOS Phase 2 (`GigiRequestRouter`, `GigiFoundationToolRegistry`, `GigiFallbackRouter`, `GigiFoundationContracts`) e i 3 harness (`ollama-client.js`, `ios-local-llm.js`, `local-llm/config.example.json`).
- Creati 6 ADR placeholder (0007-0012) e un research doc (`docs/research/phase-1-1-empirical-validation.md`) con il piano dei 4 Spike empirici.

**Cosa serve all'utente di mettere a mano in Xcode** (impossibile da CLI):
1. Aggiungere `_legacy/` come folder reference (cartella blu, non gruppo giallo). Altrimenti Xcode ri-compila i file morti.
2. Verificare che GoogleSignIn sia sparita dalle Package Dependencies (dovrebbe già esserlo).

**Build verify SSH MacInCloud**: ancora da fare. Il branch ha 46 file modificati, non possiamo essere sicuri al 100% che compili senza eseguire `xcodebuild` sul Mac reale.

---

## 7. Cosa resta da decidere (decisioni di prodotto bloccanti)

Due decisioni rimangono aperte prima di poter scrivere il design doc Phase 1:

### Q2 — Lista finale dei 15 tool Apple FM
Oggi GIGI ha 47 tool registrati. Apple FM ha un context window di 4096 token che si satura velocemente: ogni tool description pesa ~80-120 token, quindi al massimo 15-20 tool stanno comodi. Dobbiamo scegliere quali esporre direttamente ad Apple FM (path veloce iOS-side) e quali invece raggiungere indirettamente via delegate al Path 3/4.

**Proposta**: `set_timer, set_alarm, set_reminder, send_message, make_call, facetime, navigate, play_music, open_app, weather, read_calendar, find_free_slot, read_email, homekit_on, homekit_off, delegate_to_claude`.

Tu (PM) devi confermare o rivedere questa lista. È la decisione che sblocca l'ADR-0008 e l'implementazione del Phase 2.

### Q11 — Pin iOS 26.3 o accettare 26.4 con feature flag?
iOS 26.4 ha una regressione del tool calling di Apple FM documentata sui Apple Developer Forums (maggio 2026). Se pinniamo a 26.3 escludiamo gli utenti che hanno già aggiornato a 26.4. Se accettiamo 26.4 con feature flag che disabilita Path 2 quando rileva regressione, includiamo tutti ma c'è rischio degradazione esperienza.

La decisione dipende dai risultati dello Spike A che dobbiamo eseguire (test su iPhone fisico, 50 query, misura accuratezza tool calling).

---

## 8. Cosa serve fare prima di partire con l'implementazione (Phase 1.1 Spike)

Quattro Spike empirici da fare in parallelo, 5-7 giorni totali. Sono **gate critici**: se uno fallisce, il piano va rivisto, non si procede a Phase 2 assumendo che vada bene.

**Spike A — Apple FM iOS 26.4 regression test**: 50 query su iPhone fisico, misurare se la regressione segnalata è reale e quanto è grave. Gate: drop accuracy ≤15% → procediamo, altrimenti pin 26.3.

**Spike B — Qwen tier-based Ollama validation**: pull dei 4 modelli (qwen3:4b/8b/14b/3.6:27b) sul Mac M4 Pro, 40 query test set + 200 multi-turn tool call per detettare loop infinite (problema noto su modelli Qwen MoE). Gate: tier default (qwen3:14b) accuracy ≥75%, loop rate <5%.

**Spike C — Claude Code subscription burn rate**: 100 query reali, misurare quanti messaggi della cap settimanale consumiamo. Gate: documentare Max 5x come minimo nel README se Pro plan brucia in <2h.

**Spike D (opzionale) — SwiftMCP feasibility**: fork del repo SwiftMCP (300 righe glue code), implementare 1 tool MCP, misurare latency. Gate: se è ≥50% più veloce di Path 4 → schedule Path 2-fast per Phase 5.

---

## 9. I 3 rischi alti che dobbiamo tenere d'occhio

L'analisi di validation deep ha trovato 3 rischi noti che possono compromettere il piano:

1. **Apple FM iOS 26.4 regression PRODUZIONE ATTIVA**: testimonianze sui Dev Forums dicono "model non usabile" su 26.4. Se Spike A conferma, dobbiamo pinare 26.3 e perdere utenti già aggiornati. ADR-0011 mitigation pronto.

2. **Qwen MoE infinite loop su tool calling**: anche Qwen 3.6-27B (il nostro tier "Pro Quality") ha loop documentati. Spike B valida empiricamente. Mitigazione: fallback su Qwen 3 14B dense come default 32GB+, MoE solo opt-in power user.

3. **Claude Code subscription weekly cap**: Pro plan 45 messaggi ogni 5h. Per uso "always-on agent" può esaurire in 2h. Mitigazione: cost-aware routing che manda quanto possibile a Ollama, documentare Max 5x come minimo nel README setup.

C'è anche un quarto rischio sottile: il `ANTHROPIC_API_KEY` env var può causare silent API billing anche con subscription attiva (Issue claude-code#45572). Il setup wizard deve fare `unset` esplicito. È documentato.

---

## 10. Cosa NON faremo (deferred esplicitamente)

Per essere chiari su scope MVP:

- **Ambient mode / wake word** ("Hey GIGI" sempre in ascolto): impossibile su iOS senza essere VoIP app. Deferred a v1.1, valuteremo OpenAI Realtime API o frameworks custom Apple.
- **Day Plan Reasoner** (riassunto della giornata): soft-killed in ADR-0005, riattivabile post-MVP.
- **TD-002 memoria unificata** (oggi 3 layer scollegati): deferred, useremo CloudKit bypass attuale per MVP.
- **SwiftMCP Path 2-fast** (Apple FM chiama MCP diretto): Phase 5 opt-in. Pure ottimizzazione di latency, non collassa Path 4.
- **Vision iOS-side** (analisi immagini on-device): Apple FM è text-only. Vision passa per Path 4 Claude Code MCP browser screenshot.
- **Voice quality upgrade** (TTS espressive tipo F5-TTS): Phase 5, AVSpeechSynthesizer basta per MVP.
- **Watchers proattivi** (morning briefing, meeting prep automatici): Phase 5.

---

## 11. La promessa del demo "killer"

Quando tutto questo è in piedi, il pubblico vedrà un video di 3 minuti circa così:

> *L'utente apre GIGI sul suo iPhone, tap sul microfono, dice: "Search Wikipedia for Nikola Tesla and create an iPhone note about his most important invention".*
>
> *Sull'iPhone appare il Dynamic Island animato: "Searching Wikipedia..." → screenshot live del browser headless che naviga → "Reading article..." → "Found: alternating current induction motor" → "Creating note...".*
>
> *In ~60 secondi la app Note iOS si apre con dentro: "**Nikola Tesla - Most Important Invention**\n\nThe alternating current (AC) induction motor, patented in 1888, revolutionized..." [3-4 frasi di summary].*
>
> *L'utente non ha fatto niente. Non ha aperto Wikipedia, non ha copiato testo, non ha cliccato sull'app Note. Ha solo parlato.*
>
> *Sotto, in piccolo: "Powered by Apple Foundation Models on-device + Claude Code on your Mac. Zero API costs."*

Questa è la promessa del piano. Per arrivarci servono 5-6 settimane di implementazione dopo che i Spike Phase 1.1 ci avranno detto che le assunzioni reggono.

---

## 12. Glossario veloce

- **Apple Foundation Models (Apple FM)**: il modello AI 3B parametri che Apple include negli iPhone 15 Pro+ / 16 Pro / 17 Pro. On-device, gratuito, ma piccolo.
- **`@Generable` / `Tool` protocol**: le API Swift di Apple per fare structured output garantito + tool calling iOS-side.
- **Ollama**: server locale open-source che fa girare LLM sul tuo PC (Mac / Windows / Linux).
- **Qwen 3 / 3.6**: famiglia di modelli open-source di Alibaba (Apache 2.0). Il "nostro" preferito per Path 3.
- **Claude Code CLI**: la CLI ufficiale di Anthropic per usare Claude. Si lancia con `claude` dal terminale. Usa la tua subscription.
- **MCP (Model Context Protocol)**: standard aperto per dare tool ai modelli AI. Il nostro `harness-browser` è un MCP server custom che pilota Chrome via Playwright.
- **Cloudflare Tunnel**: il modo come l'app iPhone si connette al tuo harness Node.js senza dover configurare port forwarding sul router di casa.
- **Constrained decoding**: il super-potere di Apple FM — forza matematicamente l'output a rispettare uno schema. No hallucination dei field name.
- **BFCL (Berkeley Function Calling Leaderboard)**: benchmark standard per misurare la reliability del tool calling nei modelli. Lo usiamo nei Spike.

---

## 13. Riferimenti

- **Piano tecnico completo**: `docs/plans/frolicking-stargazing-pancake.md` (1000+ righe, ogni dettaglio implementativo)
- **Stato architettura**: `docs/rework/Architecture-Armando-Revision.md`
- **Ricerca LLM open-source**: `docs/knowledge/llm-open-source-research.md` (motivazione scelta Qwen)
- **NLU primer**: `docs/knowledge/nlu-primer.md`
- **ADR già approvate**: 0001-0006 in `docs/adr/`
- **ADR placeholder Phase 2**: 0007-0012 in `docs/adr/`
- **Research validation**: `docs/research/phase-1-1-empirical-validation.md`
- **Codice legacy disconnesso**: `02_GIGI_APP/GIGI/_legacy/`

---

## 14. La domanda da farti adesso

Letto questo documento, ti senti pronto a dire "sì, partiamo con Phase 1.1 Spike"? Oppure ci sono pezzi del piano che vuoi rivedere prima?

Le 2 decisioni bloccanti che richiedono il tuo input esplicito sono:
- **Q2** lista 15 tool Apple FM (proposta sopra al §7)
- **Q11** pin iOS 26.3 vs 26.4 (decidiamo dopo Spike A)

Se ti senti pronto, il prossimo step è il build verify SSH MacInCloud (~30 min tuo lavoro) + iniziare Phase 1.1 Spike A (test Apple FM 26.4 regression sul tuo iPhone fisico).

Se invece ci sono dubbi su qualche parte, dimmi quale e approfondiamo.
