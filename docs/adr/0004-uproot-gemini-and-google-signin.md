# ADR-0004: Sradicare completamente Gemini (Live + REST) e Google Sign-In

- **Status:** Accepted
- **Date:** 2026-05-07
- **Deciders:** @ArmandoBattaglino
- **Tags:** ios, llm, gemini, google-signin, cascade, dependency-pruning

## Context

Il design originale di GIGI v3 (`docs/Architecture-Armando-Revision.md`) prevedeva una cascade a 4 livelli per il reasoning lato app:

- **L0** — Gemini Live WebSocket (`BidiGenerateContent`, streaming ~200ms con barge-in)
- **L1** — Apple Foundation Models (on-device, iOS 18.1+ con Apple Intelligence)
- **L2** — Gemini REST API (online, fallback per device senza Apple Intelligence)
- **L3** — Local rule-based NLU (offline, sempre disponibile)

Implementazione reale presente nel codice all'inizio del rework:

- `GigiRealtimeEngine.swift` (1062 righe) — pipeline Gemini Live full-duplex con WebSocket, jitter buffer, barge-in detection
- `GigiCloudService.processWithGemini` — alias che internamente puntava già a `processWithGroq` (Groq aveva soppiantato Gemini REST, ma il nome era rimasto)
- `GigiAuthManager.swift` (134 righe) + dipendenza `GoogleSignIn` SDK — usata SOLO per OAuth scope `generative-language.retriever` (autenticazione Gemini Live)
- Onboarding aveva uno step "Gemini key (optional)" + Settings esponeva un campo gestione chiave Gemini
- `GigiKeychain.Key.geminiAPIKey` + `GigiConfig.geminiAPIKey` per persistere la chiave

Audit di rework ha rilevato:

1. La cascade V3 era nominalmente 4-livelli ma `processWithGemini` era già un alias morto verso Groq → di fatto solo L0 (Live) era realmente Gemini.
2. Gemini Live è classificato out-of-scope MVP nel `MVP_SCOPE.md` e nella `CAPABILITIES_crosscut.md` analysis.
3. `GoogleSignIn` SDK è una dipendenza non banale (build size, Privacy Manifest, URL scheme custom in `Info.plist`) usata da una sola feature (Gemini Live) post-MVP.
4. Cloud reasoning per il path agente vive nel harness Node (Groq via `claude-runner`/CLI subprocess + Claude via SDK per computer-use, vedi ADR-0002), non in app — quindi non c'è dipendenza tecnica dal path Gemini in app.

Il PM (@ArmandoBattaglino, ora unico dev) ha richiesto sradicamento totale (vs. soft-kill come per il wake word, ADR-0003) per tagliare definitivamente la dipendenza Google e ridurre la superficie da manutenere.

## Decision

Sradichiamo completamente entrambi i path Gemini (Live L0 + REST L2 alias) e tutta la dipendenza Google Sign-In. La cascade in `GigiBrainPipeline` si riduce a:

> **L1 Apple Foundation Models** (on-device, primary brain quando Apple Intelligence è disponibile) **→ L2 local rule-based NLU** (fallback offline).
>
> Cloud reasoning per agent loop e action execution vive nel harness (Groq/Claude) accessibile via `GigiHarnessClient` — path completamente separato e non parte di questa cascade.

In v1.1 o successivamente, se vorremo riattivare ambient mode (full-duplex voice streaming), valuteremo OpenAI Realtime API o Apple's own real-time framework anziché tornare a Gemini Live — la decisione sarà oggetto di nuovo ADR.

## Alternatives considered

- **A — Soft-kill come wake word (ADR-0003)**: scartato perché la dipendenza `GoogleSignIn` SDK pesa nel binary anche se il codice è gated, e la sua Privacy Manifest aggiungeva entry da dichiarare nello Privacy Manifest aggregato dell'app. Risparmio reale solo con kill totale.
- **B — Mantenere Gemini REST come fallback per device senza Apple Intelligence**: scartato perché il fallback REST era già un alias verso Groq, quindi non c'era valore aggiunto di "Gemini come backend". Groq è il nostro cloud LLM unico in app, semplificare il naming + cancellare l'alias riduce confusione.
- **C — Migrare Gemini Live a OpenAI Realtime API ora**: scartato come scope creep. La feature ambient è post-MVP. Valuteremo l'alternativa quando avremo il segnale di prodotto che giustifica reintrodurla.

## Consequences

### Positive
- **~1200 righe rimosse** (`GigiRealtimeEngine.swift` 1062 + `GigiAuthManager.swift` 134 + edits sparsi).
- **Dipendenza `GoogleSignIn` SDK eliminata** — meno build time, binary più snello, niente Privacy Manifest entry da gestire per Google, niente URL scheme custom in `Info.plist`.
- **Cascade più semplice** in `GigiBrainPipeline.resolve` — 2 livelli invece di 4. Logica più facile da seguire e debuggare.
- **Onboarding più corto** — uno step in meno (no Gemini key field).
- **Settings più puliti** — niente sezione gestione chiave Gemini.
- **Naming coerente** — `GigiCloudService` ora si presenta esplicitamente come "Groq backend", non più con metodi mascherati `processWithGemini`.

### Negative / Trade-off
- **Niente full-duplex / barge-in audio in app** finché non torniamo con un altro provider. Per MVP non è uno svantaggio — Talking Session è tap-to-talk turnaround, non ambient.
- **Riattivare ambient mode in v1.1 richiede nuova implementazione** (provider diverso o re-import via git history). La storia git conserva il know-how della pipeline Gemini Live (jitter buffer, barge-in detection, schema BidiGenerateContent) per chi volesse studiarla.
- **Utenti che avevano configurato Gemini key**: la chiave persiste nel Keychain finché l'utente non disinstalla l'app, ma è ignorata dal codice. Nessun impatto pratico perché il setter è stato rimosso (la chiave non si può più aggiornare dall'UI) — è semplicemente leftover che il prossimo "Reset all data" o reinstall pulirà.

### Neutral / Note
- L'SDK `GoogleSignIn` rimosso da `Package.resolved` non basta — va rimosso anche dal target Xcode tramite **Project → Package Dependencies → GoogleSignIn → Remove**. Senza questo step, il linker tenterà di cercarlo. Vedi commit message per istruzioni.
- `Info.plist` ha entry `CFBundleURLTypes` con uno scheme `com.googleusercontent.apps.<client_id>` per il callback OAuth Google. Va rimosso a mano (l'edit di `Info.plist` plain XML è banale).
- Se mai dovessimo reintegrare un real-time voice provider, varrà la pena fare un nuovo ADR che valuti opzioni e blindi la scelta — questo ADR chiude esplicitamente Gemini, non apre la porta a "qualunque sostituto".

## References

- ADR-0002 — doppio path Claude (CLI subprocess + SDK cloud) — stabilisce dove vive il cloud reasoning post-Gemini
- ADR-0003 — wake word soft-kill MVP
- `docs/rework/CAPABILITY_MAP.md` § "Chirurgia da fare — Google Sign-In dependency"
- `docs/rework/CAPABILITIES_iOS.md` — entry Gemini Live + GoogleSignIn classificate come "experimental / removable"
- `docs/rework/CAPABILITIES_crosscut.md` — Gemini Live in lista "out-of-scope MVP"
- `02_GIGI_APP/GIGI/GigiBrainPipeline.swift` — cascade simplificata (post-edit)
- `docs/Architecture-Armando-Revision.md` §13 — sezione Gemini Live storica marcata RIMOSSO

---

> Una volta `Accepted`, **non si edita più questo file**. Se la decisione cambia,
> si crea un nuovo ADR che la _supersedes_ e si aggiorna lo Status di questo a
> `Superseded by ADR-XXXX`.
