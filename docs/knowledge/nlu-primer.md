# Natural Language Understanding Primer — 2026-05-10

> Primer on Natural Language Understanding to re-contextualize architectural
> decisions about request routing in voice agents.
>
> **Audience**: contributors who want to understand why a hybrid pattern
> (rule-based + LLM-based) outperforms a single-approach implementation for
> agent routing.

---

## 1. NLP vs NLU vs LLM — quick definitions

| Acronym | Stands for | What it does | Example |
|---|---|---|---|
| **NLP** | Natural Language Processing | Mechanical text processing: tokenizing, POS tagging, parsing, lemmatization. Often a pre-processing step before NLU. | Splitting a sentence into tokens, identifying proper nouns |
| **NLU** | Natural Language Understanding | **Extracts meaning, intent, and context**. Produces structured output (intent + slots) from free-form input. | "send a message to Marco I'll be late" → `{intent: send_message, contact: Marco, body: "I'll be late"}` |
| **LLM** | Large Language Model | Transformer-based generative model. Can perform NLP + NLU + generation. | GPT, Claude, Llama, Apple FM, Qwen, DeepSeek |

**NLU is a subfield of NLP** focused on *understanding*, not just *processing*.

**LLMs can do NLU**, but they're not the only way. Classical NLU stacks
(Rasa, Dialogflow, IBM Watson Assistant) have been in production for over a
decade and work well within constrained scopes.

---

## 2. The two core NLU tasks

### Intent Classification

Categorizing the user utterance into a **predefined class** (the action they
want to perform).

```
"what time is it"        → ask_time
"send a message to Marco" → send_message
"5-minute timer"          → set_timer
"flashlight on"           → torch_on
"explain Bayes' theorem"  → respond (chat)
```

Output is typically `(label, confidence)`. The confidence score allows the
agent to decide between dispatching immediately or asking for clarification.

### Slot Filling

Extracting the **parameters** needed to execute the classified intent.

```
"send Marco Rossi I'll be late"
  → contact: "Marco Rossi"
  → body:    "I'll be late"
  → platform: imessage (default)

"5-minute timer for pasta"
  → label:    "pasta"
  → duration: "5 minutes"

"remind me to call the dentist tomorrow at 10"
  → action:   set_reminder
  → contact:  "dentist"
  → date:     "tomorrow"
  → time:     "10:00"
  → callback: "make_call when triggered"
```

Slot filling is where modern NLU gets hard: relative dates ("next Tuesday"),
anaphora ("call **him** back"), implicit slots ("send my usual reply"),
multi-turn slot accumulation.

---

## 3. The three implementation approaches

### 3.1 Rule-based NLU

**How it works**: regex patterns + keyword lookups + grammar rules + entity
lookup tables (e.g., contact names, app names). Each intent has 5–50 patterns
that must match.

```python
patterns = {
  "ask_time":  [r"what time", r"time is it", r"current time"],
  "set_timer": [r"timer (\d+) (min|sec|hour)", r"countdown"],
  "torch_on":  [r"flashlight on", r"turn on (the )?torch", r"light it up"],
  ...
}

for intent, regs in patterns.items():
    if any(re.match(r, text) for r in regs):
        return (intent, 0.95)
```

**Strengths**:
- Very fast (~30 ms)
- Deterministic, debuggable
- Zero training data, zero models
- Zero runtime cost
- 100% privacy (no data leaves the device)
- Easy to validate ("does this regex match X?")

**Weaknesses**:
- Brittle: only sees the patterns explicitly defined. "Drop Marco a line"
  won't match `send_message` unless you've added it
- No semantics: cannot tell "shoot Marco a text" is similar to "send Marco a
  message"
- Multilingual support requires separate regex sets per language
- Complex slot filling (relative dates, anaphora) is painful
- High maintenance: each new intent = dozens of regex additions

**When to use it**: for the **20–30% of queries that are common, predictable,
high-frequency** (timers, flashlight, "what time", standard send-message).
This is the classic **fast-path** in a hybrid system.

**Classical frameworks**: Rasa NLU (open source), Dialogflow ES, IBM Watson
Assistant, Alexa Custom Skills.

### 3.2 ML-based NLU (encoder classifiers)

**How it works**: train a supervised classifier (BERT, fastText, RoBERTa,
DistilBERT) on an annotated dataset of `(utterance, intent)` pairs. The model
learns semantic embeddings and classifies unseen sentences.

```python
model = load_finetuned_bert("intent-classifier")
embedding = model.encode(text)
intent_probs = model.classify(embedding)
return argmax(intent_probs)
```

Slot filling typically uses a separate BIO tagger (Begin-Inside-Outside
sequence labeling) on top of the same encoder.

**Strengths**:
- Robust to paraphrases and variations
- Captures semantics (similarity between sentences)
- Multilingual out-of-the-box with a multilingual encoder
- Medium latency (~100–500 ms on GPU, 1–3 s on CPU)
- Once trained, runtime is zero-cost (no API calls)

**Weaknesses**:
- Requires an annotated dataset (50–200 examples per intent minimum)
- Requires training pipeline + GPU/cloud for fine-tuning
- Heavier deployment (model file 100 MB – 1 GB)
- Recurring fine-tuning when adding new intents
- Slot filling needs a separate model
- New language = retrain or use multilingual encoder (quality trade-off)

**When to use it**: for **mid-sized scope with available dataset** (e.g.,
customer support bot with 50 intents and historical conversation logs).
Not OSS-friendly unless you ship pre-trained weights and contributors can
add intents without retraining.

### 3.3 LLM-based NLU

**How it works**: prompt the model "classify this utterance" with a
structured output schema. The LLM does intent classification + slot filling
in a single call.

```python
prompt = f"""
Classify this user request. Output JSON with fields:
- intent: one of [ask_time, send_message, set_timer, ...]
- slots: extracted parameters

User: "{text}"
"""
response = llm.generate(prompt, schema=IntentSchema)
return response.parsed
```

**Strengths**:
- Zero-shot: works without an annotated dataset (prompt engineering only)
- Handles ambiguity, context, anaphora, complex paraphrases
- Multilingual out-of-the-box
- Slot filling integrated (single call)
- Constrained-decoding frameworks (Apple Foundation Models `@Generable`,
  OpenAI `response_format`, Outlines, Instructor) guarantee valid JSON
- Easy to add a new intent: update the prompt enum, no retraining

**Weaknesses**:
- High latency (1–15 s depending on model and hardware)
- Variable runtime cost (token-based if cloud, hardware-bound if local)
- Less control: prompt changes cause subtle behavior changes
- Hallucination (mitigated but not eliminated by structured output)
- Hardware requirements (on-device LLMs require recent chips; harness LLMs
  require 5–10 GB RAM)

**When to use it**: for **new, ambiguous, complex, multilingual, or
multi-intent queries** — the remaining 70–80% that the rule-based fast-path
doesn't cover.

---

## 4. The modern pattern: Hybrid NLU

Production systems in 2026 combine **rule-based fast-path** with
**LLM-based fallback**:

```
        user utterance
              │
              ▼
    ┌─────────────────┐
    │ Rule-based NLU  │ ──── confidence ≥ 0.95 ──► fast dispatch
    │ (~30 ms, free)  │
    └────────┬────────┘
             │ confidence < 0.95
             ▼
    ┌─────────────────┐
    │ LLM-based NLU   │ ──── intent + slots ──► routed dispatch
    │ (1–15 s, smart) │
    └─────────────────┘
```

**Why hybrid wins**:
- 60–70% of queries (frequent, predictable) → fast-path → low latency, zero cost
- 30–40% of queries (novel, ambiguous) → LLM → high quality, accept latency
- Best of both worlds: quality where it matters, speed/cost where it doesn't

This is the standard architecture for production voice assistants in 2026 —
not because it's elegant, but because the alternatives have unacceptable
trade-offs (pure rule-based is too brittle; pure LLM is too slow/expensive
for the head of the distribution).

### Variations of the hybrid pattern

- **Cascade waterfall**: try rule-based, then small LLM, then large LLM.
  Each level has higher latency but higher quality.
- **Router-upfront**: rule-based fast-path, then one LLM call that decides
  routing (which downstream specialized model/path handles the query).
- **Mixture-of-experts at orchestration**: small LLM as a classifier picks
  which large model answers. Different from neural MoE (which is internal
  to a single model).

For agent runtimes, **router-upfront** is the current best practice — it
avoids paying cascaded latency on the long tail.

---

## 5. Practical guidance for an agent runtime

### What the rule-based layer should cover

Aim for the high-frequency, high-confidence intents:
- Time and date queries
- Timers, alarms, reminders with simple syntax
- Direct device controls (flashlight, brightness, volume, airplane mode)
- Standard messaging templates ("send X to Y")
- Standard calls ("call X")
- App launches ("open Spotify")
- Navigation to known places ("navigate home")

Don't try to cover ambiguous or contextual queries with rules. The maintenance
cost is too high.

### What the LLM layer should cover

- Anaphora ("call **him** back", "what about **there**")
- Implicit slots ("send my usual reply")
- Multi-step decomposition ("remind me when I leave home to grab the keys")
- Reasoning ("explain X", "summarize Y", "rephrase Z")
- Anything multilingual or culturally specific
- Disambiguation ("did you mean A or B?")

### Choosing the LLM

For the LLM layer, the architecture decision depends on your deployment:

- **On-device, iOS / iPad / Mac**: Apple Foundation Models via `LanguageModelSession`
  + `@Generable` schemas. Constrained decoding guarantees valid output.
- **On-device, Android / cross-platform**: ONNX-quantized small models
  (e.g., Phi-4 mini, Llama 3.2 3B) via local inference engine.
- **Harness / server-side, single-user**: Ollama with a 7–14B model
  (see `llm-open-source-research.md` for selection).
- **Cloud / multi-user**: provider API or self-hosted inference server
  (vLLM, SGLang) with a 14–70B model.

### Anti-patterns to avoid

- ❌ Using LLM for trivial intents (waste of latency)
- ❌ Skipping confidence threshold on rule-based layer (low-confidence rule
  matches should fall through to LLM, not dispatch directly)
- ❌ Letting the LLM hallucinate intents not in your action set (use enum
  constraint via structured output)
- ❌ Treating "respond" as a catchall (it should be a deliberate path,
  not the default when classification fails)
- ❌ Single-model serving multiple agent paths (mix routing + heavy reasoning
  in one model — quality and latency both suffer)

---

## 6. Possible future upgrades

These are not urgent for an MVP, but worth tracking:

1. **On-device embedding for fuzzy rule matching**: Apple `NLEmbedding` (iOS
   12+, free on-device) or equivalent ONNX models. Augment rule-based layer
   with semantic similarity — for each intent, compute embeddings of example
   patterns; compare against utterance embedding. Improves rule-based
   robustness without training. Adds ~5 ms latency.

2. **Small classifier neural model on-device**: Phi-4 mini or Llama 3.2 1B
   compiled to Core ML / ONNX runtime, used as a Path 1.5 between fast-path
   and the bigger LLM. Worth considering only if telemetry shows that 30%+
   of queries miss fast-path AND are too trivial to justify the bigger LLM
   round-trip.

3. **Custom adapter / LoRA on the on-device LLM**: fine-tune the on-device
   model on intent classification data. **Caveat**: adapters typically need
   re-training across OS releases when the base model updates. Recurring
   maintenance cost — skip unless there's strong evidence of need.

4. **BGE-M3 embeddings for memory retrieval**: relevant for RAG/memory
   unification, not for intent classification. Covered in a separate
   Knowledge file when that work begins.

---

## 7. Glossary

- **Intent**: the action category the user wants to perform (e.g., `send_message`)
- **Slot**: a parameter extracted from the utterance (e.g., `contact: "Marco"`)
- **Utterance**: the raw user input (text after STT)
- **Confidence**: probability (0–1) that the model is correct about the classification
- **Anaphora**: reference to a previously mentioned entity ("him", "there", "that one")
- **Slot filling**: extracting all required parameters for a given intent
- **Structured output**: model output constrained to a schema (JSON / typed object)
- **Constrained decoding**: the technique that forces output to respect a schema
- **Hybrid NLU**: combination of rule-based and ML/LLM-based approaches
- **BFCL** (Berkeley Function Calling Leaderboard): benchmark for LLM tool calling
- **IFEval**: benchmark for instruction-following precision
- **BIO tagging**: sequence labeling format for slot extraction (Begin/Inside/Outside)
- **Router-upfront**: agent pattern where a fast first call decides downstream path

---

## 8. Sources

- [What is Natural Language Understanding (NLU)? — IBM Think](https://www.ibm.com/think/topics/natural-language-understanding)
- [NLU Explained — DataCamp](https://www.datacamp.com/blog/natural-language-understanding-nlu)
- [NLP vs NLU: Differences and How They Work Together — DigitalOcean](https://www.digitalocean.com/resources/articles/nlp-vs-nlu)
- [Intent Classification: 2026 Techniques — Label Your Data](https://labelyourdata.com/articles/machine-learning/intent-classification)
- [LLM-Based vs Traditional NLU Approaches — Digital Thrive AI](https://digitalthriveai.com/en-us/resources/ai/chatbot-development/intent-classification-systems/)
- [Strengths and Weaknesses of LLM-Based and Rule-Based NLP — MDPI Electronics](https://www.mdpi.com/2079-9292/14/15/3064)
- [NLU vs NLP — Rasa Blog](https://rasa.com/blog/nlu-vs-nlp)
- [LLM vs NLU and NLG — ACM Digital Library](https://dl.acm.org/doi/fullHtml/10.1145/3635059.3635104)
- [Foundation Models Documentation — Apple Developer](https://developer.apple.com/documentation/FoundationModels)
