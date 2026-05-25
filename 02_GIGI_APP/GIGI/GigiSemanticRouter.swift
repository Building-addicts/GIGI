import Foundation
import NaturalLanguage

// MARK: - GigiSemanticRouter (GATE 15 — Smart Router fast-path)
//
// Solves the "deterministic regex intercept" problem that emerged during
// GATE 9 device testing: Apple FM constrained decoding occasionally
// mis-routes utterances to the wrong tool (e.g. "search the web for X"
// → delegate_cloud instead of web_search; "run accendi torcia" →
// homekit_on). Adding regex patterns for every variant doesn't scale.
//
// This router computes a sentence embedding for the user utterance via
// `NLEmbedding.wordEmbedding(.english)` (reused from GigiVectorStore — same
// instance, same dimension), compares it via cosine similarity to a curated
// catalog of canonical trigger phrases for each tool, and dispatches the
// best match if the top-1 score exceeds `confidenceThreshold`.
//
// Latency: 2-8ms per query on iPhone 15 Pro (pre-computed catalog embeddings,
// one dotpr per tool). Fully on-device — zero cloud, zero LLM call.
//
// Coverage strategy:
//   - 5-12 canonical triggers per tool (EN + IT). Embeddings averaged into
//     one centroid per tool, so we do N tool comparisons instead of K
//     example comparisons.
//   - Threshold tuned at 0.55 (NLEmbedding word vectors inflate similarity
//     vs sentence embeddings — same calibration as GigiVectorStore).
//   - On match, dispatch directly via GigiActionBridge; bypass Apple FM.
//   - On no match (top-1 < threshold), fall through to existing Apple FM
//     routing — no behavioral regression for queries the catalog doesn't
//     cover.
//
// Telemetry stub (GATE 15.B follow-up): every match logs the triple
// (utterance, dispatched_tool, similarity) so we can iterate the catalog
// based on real usage. For now logs only — full self-correction loop in
// GATE 15 phase 2 (not in this commit).
//
// All user-facing strings (none here — this file is internal routing logic)
// remain English per CLAUDE.md §Lingua. The trigger catalog itself contains
// both EN and IT phrases since users can speak either to Apple FM.

@MainActor
final class GigiSemanticRouter {

    static let shared = GigiSemanticRouter()

    // MARK: - Tuning

    /// Cosine similarity threshold above which we trust the semantic match.
    /// Raised to 0.80 (from 0.55) on 2026-05-15 after the semantic router
    /// kept mis-firing on bare assertions like "Marco is my brother"
    /// (→ translate_text 0.68) or recall queries lacking explicit verbs.
    /// At 0.80 only near-canonical phrasings (close to a hand-crafted
    /// trigger) bypass Apple FM. Everything else falls through to FM
    /// which has full-sentence semantics + memory context.
    private static let confidenceThreshold: Float = 0.80

    /// Gap between top-1 and top-2 required to avoid ambiguous matches.
    /// Raised to 0.10 (from 0.05) for the same reason — keep only very
    /// unambiguous matches as the semantic-tier intercepts.
    private static let topGapThreshold: Float = 0.10

    // MARK: - State

    /// Tool centroid embeddings, lazily computed on first call.
    private var toolCentroids: [String: [Float]] = [:]
    private var ready = false

    private init() {}

    // MARK: - Trigger catalog

    /// Canonical trigger phrases per tool. Apple FM is supposed to handle
    /// these via constrained decoding, but in practice it sometimes biases
    /// toward concrete tools (homekit_on, set_timer) or delegate_cloud
    /// when the description is ambiguous. We bias selection toward the
    /// right tool with explicit examples.
    ///
    /// Adding a tool: pick 5-12 phrases the user might actually say,
    /// including IT variants where common. Don't over-fit on rare phrasings.
    private static let triggerCatalog: [String: [String]] = [

        // SYSTEM — timer / alarm / reminder
        "set_timer": [
            "set a timer for 5 minutes", "start a timer", "timer 10 minutes",
            "remind me in 2 minutes", "wake me in 1 hour",
            "metti un timer", "timer di 5 minuti", "imposta timer"
        ],
        "set_alarm": [
            "set an alarm for 7am", "wake me up at 8", "alarm tomorrow morning",
            "set alarm 6:30", "sveglia alle 7", "imposta sveglia"
        ],
        // set_reminder REMOVED 2026-05-15 — multi-slot (task + date + time)
        // extraction is unreliable when the semantic router dispatches via
        // bridge directly. Routed via Apple FM Tool calling instead, which
        // uses @Generable constrained decoding to split slots correctly.

        // COMMUNICATION — call / facetime / message
        "make_call": [
            "call mom", "phone marco", "dial 555", "call my brother",
            "chiama mamma", "telefona marco", "chiamare leo corte"
        ],
        // send_message REMOVED 2026-05-15 — see note above. The semantic
        // router can't reliably extract (contact, body) from short
        // embeddings; passes the full sentence as `slot`, which becomes
        // a bad contact name. Apple FM Tool calling handles this.

        // CALENDAR — read / find slot
        "read_calendar": [
            "what's on my calendar today", "show my schedule",
            "what do i have tomorrow", "calendar this week",
            "cosa ho oggi in calendario", "agenda di oggi"
        ],
        "find_free_slot": [
            "find me a free hour tomorrow", "when am i free this afternoon",
            "free slot of 30 minutes", "quando sono libero domani"
        ],
        "read_email": [
            "read my emails", "check inbox", "any new emails",
            "leggi le email", "controlla la posta"
        ],

        // MEDIA — music
        "play_music": [
            "play music", "play the beatles", "put on my playlist",
            "play my morning playlist", "play upbeat",
            "metti la musica", "suona i beatles", "play playlist"
        ],

        // SYSTEM — apps / weather / web
        "open_app": [
            "open spotify", "launch instagram", "open the calculator",
            "apri spotify", "lancia instagram"
        ],
        "weather": [
            "what's the weather", "weather today", "will it rain tomorrow",
            "weather in tokyo", "che tempo fa", "previsioni meteo"
        ],
        // web_search — IMPORTANT: by GIGI design, generic research queries
        // ("look up X", "find X online", "google X") are handled by the
        // harness Claude subprocess with the browser MCP tool — which does
        // actual research and synthesizes an answer. The iPhone Safari path
        // (this tool) is reserved for EXPLICIT user requests to open Safari
        // on the phone (e.g. "open Safari and search X", "cerca X sul
        // telefono"). Catalog phrases below are narrowed to those explicit
        // forms; generic research falls through to Apple FM → delegate_cloud.
        // See ADR-0013.
        "web_search": [
            "open safari and search for pasta carbonara",
            "search pasta on my phone in safari",
            "open safari", "open safari with pasta carbonara",
            "search this on my phone", "open safari and look up tiramisu",
            "google this in safari", "open google in safari",
            "search in safari for ramen",
            "apri safari e cerca pasta carbonara",
            "apri safari", "cerca pasta sul telefono",
            "cerca questo sul telefono in safari",
            "apri google su safari", "cerca su safari ricetta tiramisu"
        ],

        // NAVIGATION
        "navigate": [
            "navigate home", "directions to milan", "take me to the airport",
            "navigate to via roma", "go to nearest gas station",
            "portami a casa", "indicazioni per milano"
        ],

        // SMART HOME — on / off / scene
        "homekit_on": [
            "turn on the living room lights", "lights on", "turn on the lamp",
            "accendi la luce", "luci accese", "accendi lampada"
        ],
        "homekit_off": [
            "turn off the bedroom light", "lights off", "turn off the heater",
            "spegni la luce", "luci spente", "spegni riscaldamento"
        ],
        "set_homekit_scene": [
            "activate the cinema scene", "run movie night scene",
            "trigger goodnight scene", "set good morning scene",
            "scene to relax mode", "activate sleep mode",
            "attiva scena cinema", "modalità buongiorno", "scena notte"
        ],

        // PRODUCTIVITY
        "create_note": [
            "take a note", "save a note about meeting",
            "create note grocery list", "salva una nota",
            "prendi una nota"
        ],

        // FOOD
        // PRODUCTIVITY — note append (GATE 10.A)
        //
        // NOTE: create_calendar_event INTENTIONALLY OMITTED from semantic
        // catalog. Calendar events have 3 distinct slots (title + date +
        // time) that semantic prefix-based slot extraction can't split
        // reliably. Apple FM @Generable Arguments schema does the split
        // correctly. Falling through to Apple FM gives much better parsing
        // for utterances like "Create meeting with Marco friday at 3 PM"
        // → title='meeting with Marco', date='friday', time='3 PM'.
        // Trade-off: ~150ms Apple FM latency vs ~5ms semantic — worth it.
        "add_to_note": [
            "add to my note work idea Q3 macros",
            "append to note shopping buy milk and eggs",
            "save to note ideas meeting takeaways",
            "add this to my work note",
            "aggiungi alla nota lavoro idea Q3",
            "salva nella nota idee meeting takeaways",
            "appendi alla nota spesa latte e uova"
        ],

        // KNOWLEDGE MINI — define / calculate / translate (GATE 10.C)
        "define_word": [
            "define serendipity", "what does ephemeral mean",
            "definition of altruism", "define the word resilient",
            "tell me the meaning of pristine",
            "cosa significa serendipità", "definizione di altruismo",
            "che cosa vuol dire effimero"
        ],
        "calculate_math": [
            "what's 47 times 23", "calculate 100 divided by 8",
            "how much is 15% of 200", "compute 2 to the power of 10",
            "what's the square root of 144", "47 plus 23",
            "quanto fa 47 per 23", "calcola 100 diviso 8",
            "quanto è il 15 percento di 200"
        ],
        "translate_text": [
            "translate good morning to italian",
            "how do you say hello in japanese",
            "translate 'where is the bathroom' to french",
            "come si dice good morning in italiano",
            "come si dice ciao in giapponese",
            "traduci hello in francese"
        ],

        // UTILITY — clipboard / battery / flashlight (GATE 10.B)
        "read_clipboard": [
            "what's in my clipboard", "read my clipboard", "what did i copy",
            "tell me what's copied", "what's on the clipboard",
            "cosa ho copiato", "leggi clipboard", "cosa c'è negli appunti"
        ],
        "get_device_battery": [
            "what's my battery", "battery level", "how much battery",
            "is my phone charging", "am i charging", "battery status",
            "quanta batteria", "livello batteria", "sto caricando",
            "il telefono è in carica"
        ],
        // toggle_flashlight REMOVED 2026-05-24: the semantic path dispatched
        // without a `state`, so it blind-toggled (turning the torch ON when
        // asked to turn it OFF). NLU now emits toggle_flashlight WITH state for
        // the canonical phrasings, and Apple FM's tool carries a state arg, so
        // both remaining paths preserve direction. See ROUTING_LAYERS.md.

        // META — Shortcut AUTHORING via Cherri (Phase 2)
        // Note: tier-0 regex `detectBuildShortcutPattern` is the primary path
        // for these queries. Semantic catalog is the fallback when regex
        // doesn't match (e.g. heavy paraphrase). Keep phrases diverse enough
        // to outscore run_shortcut/homekit_on bias on intent verbs.
        "build_shortcut": [
            "build me a shortcut that turns on the torch",
            "make a shortcut that plays music when I arrive home",
            "create a shortcut for goodnight routine",
            "compose a shortcut to wake me up gently",
            "design a shortcut that mutes notifications",
            "generate a shortcut that sets focus mode",
            "build a new shortcut", "make a new shortcut",
            "fammi uno shortcut che spegne tutto",
            "crea uno shortcut per buongiorno",
            "componi uno shortcut che attiva focus lavoro",
            "costruisci uno shortcut nuovo",
            "genera uno shortcut che riproduce musica"
        ],

        // META — automation
        "run_shortcut": [
            "run my morning routine", "execute work mode",
            "run accendi torcia shortcut", "launch arrive home",
            "trigger gym time", "run my shortcut",
            "esegui modo lavoro", "lancia routine mattutina",
            "esegui scorciatoia accendi torcia"
        ]
    ]

    // MARK: - Public API

    /// Returns the best-match tool name + extracted query slot if confidence
    /// exceeds threshold. Returns nil if no tool matches well enough — caller
    /// should fall through to Apple FM dispatch.
    ///
    /// - Parameter text: the user utterance (any language, any casing)
    /// - Returns: (toolName, extractedSlot) tuple or nil. extractedSlot is
    ///   a best-effort extraction of the "content" of the utterance after
    ///   stripping the trigger verb (e.g. "search the web for pasta" →
    ///   ("web_search", "pasta")). May be the full original text if no
    ///   trigger phrase identified.
    func match(_ text: String) -> SemanticMatch? {
        ensureReady()

        let queryVec = GigiVectorStore.shared.embed(text)
        guard !queryVec.isEmpty else {
            GigiDebugLogger.log("SemanticRouter: empty embedding for '\(text)' — skip")
            return nil
        }

        // Compute similarity against each tool centroid
        var scored: [(tool: String, score: Float)] = []
        for (tool, centroid) in toolCentroids where !centroid.isEmpty {
            let sim = GigiVectorStore.shared.cosineSimilarity(queryVec, centroid)
            scored.append((tool, sim))
        }
        scored.sort { $0.score > $1.score }

        guard let best = scored.first else { return nil }

        // Top-1 must clear absolute threshold
        guard best.score >= Self.confidenceThreshold else {
            GigiDebugLogger.log("SemanticRouter: top='\(best.tool)' sim=\(best.score) < \(Self.confidenceThreshold) — pass to Apple FM")
            return nil
        }

        // Top-1 must clear gap vs top-2 to avoid ambiguous routing
        if scored.count >= 2 {
            let gap = best.score - scored[1].score
            if gap < Self.topGapThreshold {
                GigiDebugLogger.log("SemanticRouter: ambiguous \(best.tool)/\(scored[1].tool) gap=\(gap) — pass to Apple FM")
                return nil
            }
        }

        let slot = extractSlot(from: text, for: best.tool)
        GigiDebugLogger.log("SemanticRouter: → \(best.tool) sim=\(best.score) slot='\(slot)'")
        return SemanticMatch(toolName: best.tool, slot: slot, confidence: best.score)
    }

    // MARK: - Lazy startup

    private func ensureReady() {
        guard !ready else { return }
        let start = Date()
        for (tool, triggers) in Self.triggerCatalog {
            let centroid = computeCentroid(from: triggers)
            if !centroid.isEmpty {
                toolCentroids[tool] = centroid
            }
        }
        ready = true
        let elapsed = Date().timeIntervalSince(start) * 1000
        GigiDebugLogger.log("SemanticRouter: ready in \(Int(elapsed))ms — \(toolCentroids.count) tool centroids")
    }

    /// Average embeddings of trigger phrases into one centroid per tool.
    private func computeCentroid(from triggers: [String]) -> [Float] {
        let store = GigiVectorStore.shared
        let vectors = triggers.compactMap { trigger -> [Float]? in
            let v = store.embed(trigger)
            return v.isEmpty ? nil : v
        }
        guard !vectors.isEmpty else { return [] }

        let dim = vectors[0].count
        var sum = [Float](repeating: 0, count: dim)
        for v in vectors where v.count == dim {
            for i in 0..<dim { sum[i] += v[i] }
        }
        let n = Float(vectors.count)
        return sum.map { $0 / n }
    }

    // MARK: - Slot extraction

    /// Best-effort extraction of the "content" portion of the utterance —
    /// the part the tool's argument needs (e.g. search query, Shortcut name).
    /// Uses simple prefix stripping based on the known trigger verb families
    /// per tool. Returns the full utterance trimmed if no prefix matches.
    private func extractSlot(from text: String, for tool: String) -> String {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        let prefixesByTool: [String: [String]] = [
            "web_search": [
                // Narrowed to "explicit Safari/phone" intents only — see
                // ADR-0013. Generic research queries fall through to
                // delegate_cloud (Claude harness with browser MCP).
                "open safari and search for ", "open safari and look up ",
                "open safari and search ", "open safari with ",
                "open safari ",
                "search in safari for ", "search in safari ",
                "google this in safari with ", "google this in safari ",
                "open google in safari for ", "open google in safari ",
                "search this on my phone for ", "search this on my phone ",
                "search on my phone for ", "search on my phone ",
                // Italian
                "apri safari e cerca per ", "apri safari e cerca ",
                "apri safari con ", "apri safari ",
                "cerca su safari per ", "cerca su safari ",
                "apri google su safari per ", "apri google su safari ",
                "cerca sul telefono per ", "cerca sul telefono ",
                "cerca questo sul telefono in safari ",
                "cerca questo sul telefono "
            ],
            "run_shortcut": [
                "run my ", "execute my ", "launch my ", "trigger my ",
                "esegui il ", "esegui la ", "esegui lo ", "esegui i ", "esegui le ",
                "lancia il ", "lancia la ", "lancia lo ", "lancia ",
                "run the ", "execute the ", "launch the ", "trigger the ",
                "run ", "execute ", "launch ", "trigger ", "esegui "
            ],
            "set_homekit_scene": [
                "activate the ", "trigger the ", "run the ", "set the ",
                "activate ", "trigger ", "run ", "set ",
                "attiva la scena ", "attiva scena ", "attiva ",
                "scena "
            ],
            "open_app": [
                "open the ", "launch the ", "start the ", "open ", "launch ",
                "apri ", "lancia "
            ],
            "play_music": [
                "play music ", "play ", "put on ", "metti ", "suona "
            ],
            "navigate": [
                "navigate to ", "directions to ", "take me to ",
                "go to ", "drive to ", "portami a ", "indicazioni per ",
                "vai a ", "navigate "
            ],
            "define_word": [
                "define the word ", "define ",
                "what does the word ", "what does ",
                "definition of the word ", "definition of ",
                "tell me the meaning of ", "meaning of ",
                "cosa significa la parola ", "cosa significa ",
                "definizione di ", "che cosa vuol dire ",
                "che vuol dire "
            ],
            "calculate_math": [
                "calculate the ", "calculate ",
                "what's ", "whats ", "what is ",
                "how much is ", "compute the ", "compute ",
                "quanto fa ", "calcola il ", "calcola ",
                "quanto è il ", "quanto è ", "quanto vale "
            ],
            "translate_text": [
                "translate ", "how do you say ", "how to say ",
                "traduci ", "come si dice "
            ],
            "build_shortcut": [
                "build me a shortcut that ", "build a shortcut that ",
                "build me a shortcut ", "build a shortcut ",
                "build shortcut that ", "build shortcut ",
                "make me a shortcut that ", "make a shortcut that ",
                "make me a shortcut ", "make a shortcut ",
                "create me a shortcut that ", "create a shortcut that ",
                "create me a shortcut ", "create a shortcut ",
                "compose a shortcut that ", "design a shortcut that ",
                "generate a shortcut that ",
                "fammi uno shortcut che ", "crea uno shortcut che ",
                "fammi uno shortcut ", "crea uno shortcut ",
                "componi uno shortcut che ", "costruisci uno shortcut che ",
                "genera uno shortcut che "
            ],
            "make_call": [
                "call ", "phone ", "dial ", "ring ", "give a call to ",
                "telephone ", "chiama ", "telefona a ", "telefona ",
                "chiamare ", "fai una chiamata a "
            ],
            "facetime": [
                "facetime audio ", "facetime with ", "facetime ",
                "video call ", "videochiama ", "videochiamata a "
            ],
            "add_to_note": [
                "add to my note ", "add to my notes ",
                "add to note ", "add to notes ",
                "append to note ", "append to my note ",
                "save to note ", "save to my note ",
                "put in note ", "put in my note ",
                "aggiungi alla nota ", "aggiungi alle note ",
                "appendi alla nota ", "salva nella nota ",
                "salva sulla nota "
            ]
            // create_calendar_event prefixes intentionally omitted — Apple
            // FM @Generable handles the 3-slot split (title + date + time)
            // far better than prefix regex. See PRODUCTIVITY catalog note.
        ]

        guard let prefixes = prefixesByTool[tool] else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for prefix in prefixes {
            if t.hasPrefix(prefix), t.count > prefix.count {
                let slot = String(t.dropFirst(prefix.count))
                return cleanSlot(slot, for: tool)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips trailing/leading filler tokens that the trigger prefix didn't
    /// catch. Per-tool to avoid over-trimming meaningful content.
    private func cleanSlot(_ raw: String, for tool: String) -> String {
        var s = raw
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "!", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trailingFiller = [
            " shortcut", " scorciatoia",
            " scene",
            " app", " application"
        ]
        for f in trailingFiller where s.hasSuffix(f) {
            s = String(s.dropLast(f.count))
        }

        // GATE 10.C bug fix — strip dictionary-query trailing filler so
        // "what does ephemeral mean" → "ephemeral" (not "ephemeral mean")
        if tool == "define_word" {
            let dictTrailing = [
                " mean", " means", " mean",
                " vuol dire", " significa", " significhi"
            ]
            for f in dictTrailing where s.lowercased().hasSuffix(f) {
                s = String(s.dropLast(f.count))
            }
        }

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - SemanticMatch

struct SemanticMatch {
    let toolName: String
    let slot: String
    let confidence: Float
}
