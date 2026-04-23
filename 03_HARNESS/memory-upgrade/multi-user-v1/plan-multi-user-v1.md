# Plan Multi-User V1 — Federated Memory + Centralized Fine-Tuning

**Data**: 2026-04-22
**Stato**: DRAFT — cattura la discussione in corso, decisioni aperte marcate `DECISIONE PENDENTE`
**Base**: plan-v4.md (v4.1 SOTA) + Proposta-V4.2-Critico.md + conversazione 2026-04-22
**Branch**: deviazione da v4.2 per scenario multi-utente. v4.2 resta candidato per N=1.

---

## 0 · Scopo del documento

Catturare il design della variante multi-utente di Harness dove:
1. **Il bot e l'infrastruttura li fornisce Armando** (server operator unico)
2. **Ogni utente ha la sua istanza Harness isolata** (memoria locale per utente, agente Claude proprio)
3. **Un server centrale raccoglie contributi di memoria** (opt-in, PII-scrubbed, cifrati) per fare fine-tuning
4. **Il modello fine-tuned migliora la memoria** di tutti gli utenti

NON è il piano definitivo — molte decisioni sono ancora aperte. Serve a fissare punto per punto cosa è stato discusso, cosa è deciso, cosa è pendente.

---

## 1 · Cambio di scope rispetto a v4.2

v4.2 assume N=1 single-user. Il plan multi-user V1 assume:
- 10 utenti totali, di cui ~3 heavy (tutto il giorno) e ~7 casual
- Volume stimato: ~700 turni/giorno totali (3×200 + 7×15), ~63K turni/90gg, ~315K vettori con chunking tipico
- Scope federazione = **solo sulla memoria**, non sull'agente (ogni utente ha il suo Claude)

### Conseguenze immediate

- **Dataset-ready frontmatter** killato in v4.2 §1.3 come "over-engineering per N=1" → **risorge** in forma compatta. Non più over-engineering quando il fine-tuning è il prodotto.
- **Attitude Ledger / beliefs** killato in v2 come "dead code per N=1" → **resta morto**. Ogni utente ha un suo agente, le opinioni non si propagano tra utenti per design.
- **LRS omeostatico** killato in v3 come "metrica astratta" → **resta morto per ora**, potrà tornare come fair-share metric se serve capacity planning futuro.
- **Scrubber PII + consenso granulare** → **nuovi componenti**, non erano in nessun piano precedente.

---

## 2 · Threat model — DECISO

**Livello 1** — L'operator del server (Armando) è trusted by design. Gli utenti che non si fidano semplicemente non usano il bot.

Implicazioni:
- Niente Secure Multi-Party Computation (SMPC)
- Niente Trusted Execution Environment (TEE, Intel SGX, AWS Nitro Enclaves)
- Niente Fully Homomorphic Encryption (FHE)
- Niente client-side LoRA training (che servirebbe solo a Livello 2+)

Protezione minima garantita:
- TLS in transit
- Payload cifrato con chiave server (libsodium sealed box) durante il trasporto
- At-rest encryption sul server
- PII scrubbing client-side prima dell'upload (defense in depth, non affidabilità unica)
- Consenso esplicito opt-in, default opt-out
- Right to be forgotten implementato come retraining periodico senza il pool dell'utente che revoca

---

## 3 · Architettura d'insieme

```
┌────────────────────────────────────────────────────────────┐
│  CLIENT (Harness istanza per utente)                        │
│                                                             │
│  telegram-bridge/                                           │
│    ├── bridge.js              (agent loop Claude)           │
│    ├── memory-service/        (L0-L7 come v4.2)            │
│    └── contribution-service/  (NUOVO)                       │
│        ├── export.js          (estrae shareable)            │
│        ├── pii-scrub.js       (regex + NER spaCy ita)       │
│        ├── encrypt.js         (sealed box libsodium)        │
│        ├── uploader.js        (POST al server, retry)       │
│        └── consent-store.js   (preferenze utente)           │
│                                                             │
│  memories/<userId>/                                         │
│    ├── identity.md            ← never shared                │
│    ├── entities/              ← never shared                │
│    ├── episodes/              ← never shared                │
│    ├── pinned/                ← never shared                │
│    ├── skills/                ← shareable by default        │
│    ├── lessons.md             ← shareable opt-in            │
│    ├── tacit.md               ← shareable opt-in            │
│    └── .consent.yaml          ← preferenze utente           │
│                                                             │
│  watchers.json:                                             │
│    ├── memory-reflect         (sleep-time, come v4.2)       │
│    └── memory-contribute      (NUOVO, settimanale)          │
└────────────────────────┬────────────────────────────────────┘
                         │ HTTPS + payload cifrato
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  SERVER CENTRALE (Armando)                                   │
│                                                              │
│  /api/ingest                                                 │
│    ├── decrypt (server priv key)                            │
│    ├── validate schema (Zod)                                 │
│    ├── dedupe (content hash)                                 │
│    └── store in pool                                         │
│                                                              │
│  storage/                                                    │
│    ├── pools/                                                │
│    │   ├── skills_premium/    (tier: public, verified)      │
│    │   ├── skills_standard/                                  │
│    │   ├── lessons_dpo/       (coppie errore→correzione)    │
│    │   └── retrieval_labels/  (query → relevant docs)       │
│    ├── users/                                                │
│    │   └── <user_hash>/       (anonimo, per revoca consenso)│
│    └── consent_log.jsonl      (append-only audit)           │
│                                                              │
│  /api/train                                                  │
│    ├── assemble_dataset (filter per tier/domain/consenso)   │
│    ├── lora_trainer     (QLoRA su modello open)             │
│    └── validation       (hold-out set, metriche)            │
│                                                              │
│  /api/distribute                                             │
│    └── push adapter .safetensors ai client                  │
│                                                              │
│  /api/forget                                                 │
│    └── marca user_hash come no-retrain, innesca re-train    │
└─────────────────────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  CLIENT riceve adapter                                       │
│  Lo usa per: ??? (DECISIONE PENDENTE — vedi §5)              │
└─────────────────────────────────────────────────────────────┘
```

---

## 4 · Tassonomia dati per sensibilità

Non tutta la memoria va trattata uguale. Tre tier con policy distinte.

| Tier | Contenuto | Policy upload | Motivazione |
|------|-----------|---------------|-------------|
| **Public-by-construction** | `skills/*.md` (SKILL.md format) | Opt-in per-skill, default YES, auto-upload post-validation Riflettore | SKILL.md è procedurale e astratto. Se scritto bene, raramente contiene PII. È il tier più prezioso per instruction-tuning. |
| **Sensitive opt-in** | `lessons.md`, `tacit.md` | Opt-in per blocco, default NO, richiede review utente prima dell'upload | Coppie DPO (errore→correzione) e preferenze stilistiche. Preziose ma possono contenere contesto personale. |
| **Never shared** | `episodes/`, `entities/`, `identity.md`, `pinned/` | Mai uploadato, neanche scrubbed | Conversazioni raw, nomi di persone reali, preferenze intime. Zero valore aggiunto nel condividerle. |

### Perché skills è il cuore del valore

- Già in formato instruction-tuning (When to use / Inputs / Steps / Output / Anti-examples)
- Anti-examples sono rarissimi nei dataset open → vantaggio competitivo
- Con 10 utenti che producono skill distinte → 10× competenze per il modello fine-tuned
- Anche senza ogni altra cosa, questo da solo giustifica l'infrastruttura federated

---

## 5 · Ruolo del modello fine-tuned — DECISIONE PENDENTE

Claude è cloud-only e non fine-tunabile. Il fine-tuning può avvenire solo su un modello open (Llama 4, Qwen 3, GLM 5, Mistral). Tre ruoli possibili, molto diversi:

### Opzione α — Sostituto di Claude
Il modello fine-tuned diventa l'agente principale. Azzera costi API Anthropic, privacy totale a runtime.
- **Base**: 70B+ (Llama 4 70B, Qwen 3 72B)
- **Infra**: H100 cloud (~$2-4/ora) o 2×4090 on-prem (~$4k upfront)
- **Training**: $100-200/ciclo
- **Problema**: qualità inferiore a Claude Opus 4.7, utenti lo noteranno
- **Verdetto**: troppo ambizioso per V1

### Opzione β — Sostituto di Haiku (backend specialist)
Il modello fine-tuned prende i task backend: sleep-time consolidation, pattern detection, correction classification, retrieval reranking. Claude resta main agent per i turni utente.
- **Base**: 7-14B (Llama 4 8B, Qwen 3 7B)
- **Infra**: GPU consumer (4060 Ti 16GB) o CPU con llama.cpp quantizzato
- **Training**: QLoRA 7B ≈ 2-4h 4090 ≈ $10-20/ciclo cloud o gratis on-prem
- **Verdetto**: fattibile, ROI medio (Haiku costa poco, risparmio limitato — ma privacy nei task backend è forte)

### Opzione γ — Embedding/retrieval specialist
Il modello fine-tuned è solo per embedding/retrieval. Sostituisce Voyage 3.5 o BGE-M3 con embedding model fine-tunato sui dati di retrieval reali.
- **Base**: BGE-M3 o E5-Mistral (1-7B)
- **Training**: contrastive learning, ~1-2h GPU
- **Verdetto**: fattibile, ROI focalizzato (miglioramento retrieval precision misurabile)

### Opzione β+γ combinati
Fine-tuning di entrambi: embedding + backend specialist. Doppio costo training ma ROI cumulativo.

### Pattern "global + personal LoRA" (ortogonale a α/β/γ)
- **Global LoRA**: aggregato di tutti gli utenti, rappresenta "come Harness gestisce la memoria in generale"
- **Personal LoRA** (solo heavy user dopo >500 turni): addizionato al global, rappresenta lo stile specifico dell'utente
- A runtime: `base + global_lora + personal_lora[user_id]`
- Questo è letteralmente "memoria sempre migliore su ognuno": global migliora con la crescita del pool, personal raffina per singolo utente

### Mia raccomandazione

**γ come primo step, β come secondo step quando ci sarà volume, pattern global+personal come arricchimento futuro se serve.**

Motivazioni:
1. γ ha ROI misurabile in settimane (retrieval_precision log-differenziabile prima/dopo)
2. γ gira su hardware leggero anche sul client
3. β ha ROI reale solo con volume serio (>1000 esempi di consolidation labellate)
4. α è fuori scope V1

**DECISIONE PENDENTE** — voto finale utente.

---

## 6 · Frontmatter consolidato (risurrezione da v4, con privacy federated)

Rispetto a v4 §2.2, eliminati campi ridondanti; aggiunti campi privacy. Rispetto a v4.2 §1.3, reintrodotti i campi dataset.

```yaml
---
# Provenance (c'era in v4.2, resta)
source: capture | reflection | distillation | user-pinned
created_at: <ISO>
updated_at: <ISO>
confidence: 0.0-1.0
tags: [list]
lang: it | en | mixed

# Training dataset (resurretto da v4, alleggerito)
domains: [list]              # on-demand at upload, NOT ogni 2h
quality_tier: premium | standard | draft
success_count: <int>         # solo per skills

# Privacy federated (nuovo)
shareable_for_training: true | false | pending_review
sensitivity_tier: public | sensitive | private
consent_timestamp: <ISO> | null
pii_scrubbed_at: <ISO> | null
---
```

### Differenze chiave vs v4

- `training_use` eliminato — ridondante con `shareable_for_training` + `sensitivity_tier`
- `task_type` eliminato — il server lo assegna al momento di assemblare il dataset
- `language` rinominato `lang` per coerenza con v4.2
- Auto-classification via Haiku NON è più in sleep-time ogni 2h. I campi `domains` e `quality_tier` si popolano solo al momento dell'upload settimanale (costo una-tantum per blocco).

### Differenze chiave vs v4.2

- Reintrodotti `domains`, `quality_tier`, `success_count`
- Aggiunti tutti i campi privacy

---

## 7 · Privacy pipeline client-side

Ogni upload passa attraverso questa pipeline. Zero raw data esce senza passare tutti gli step.

### 7.1 Consent gate

Il watcher `memory-contribute` (settimanale) raccoglie i file con `shareable_for_training: true`. Per il tier `sensitive`, se il `consent_timestamp` è assente o scaduto (>30gg), il file viene messo in una coda `pending_review.md` e notificato all'utente via Telegram per conferma manuale.

Default:
- `skills/` → `shareable_for_training: true` at creation
- `lessons.md`, `tacit.md` → `shareable_for_training: false` at creation
- `episodes/`, `entities/`, `identity.md`, `pinned/` → **mai** marcabili shareable (enforced by schema)

### 7.2 PII scrubber

Passaggio multi-livello:

1. **Regex layer** (veloce, noto):
   - Email: `\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b`
   - Telefono italiano: `\b(?:\+39\s?)?3\d{2}\s?\d{6,7}\b`
   - IBAN, codice fiscale, partita IVA
   - URL con path personali
   - Path filesystem `C:\Users\<name>\`

2. **NER layer** (spaCy italiano, modello `it_core_news_md`, ~50MB):
   - Nomi di persona (PER)
   - Organizzazioni (ORG) — opt-in, spesso legittime nei tech skills
   - Luoghi (LOC)

3. **Replacement strategy**:
   - Nomi → `<PERSON_N>` (stabile cross-file per preservare relazioni, ma senza identità)
   - Email → `<EMAIL>`
   - Phone → `<PHONE>`
   - Path → `<USER_PATH>`

4. **Registro scrub**: ogni sostituzione logged in `audit.jsonl` per audit/debug.

**Effort stimato**: 8-15h per versione robusta.

### 7.3 Encrypt + Upload

- Libsodium sealed box con chiave pubblica server (embedded nel client al setup)
- Payload: `{user_hash, schema_version, files: [{path, content_scrubbed, frontmatter}], timestamp}`
- Compressione zstd prima della cifratura
- Upload POST `/api/ingest`, retry con exponential backoff, conferma hash ricevuto dal server
- Log locale in `contribution-log.jsonl` con `{batch_id, file_count, bytes, server_confirmation}`

---

## 8 · Server design

### 8.1 Ingest endpoint

- Decifra payload con chiave privata server
- Valida schema (Zod)
- Dedupe per content hash (evita upload duplicati da reinstall client)
- Store in pool appropriato in base a `quality_tier` + `sensitivity_tier`
- Log in `consent_log.jsonl` (append-only)

### 8.2 Pool organization

```
pools/
├── skills_premium/         ← quality_tier=premium, verified, top data
├── skills_standard/        ← quality_tier=standard
├── skills_draft/           ← quality_tier=draft (filtered out in training)
├── lessons_dpo/            ← coppie {rejected, chosen} per DPO
├── retrieval_labels/       ← {query, selected_ids, latency_ms} per embedding fine-tune
└── tacit_patterns/         ← preferenze stilistiche aggregate
```

### 8.3 Training cycle

- **Frequenza**: iniziale mensile, poi settimanale se volume giustifica
- **Trigger**: manuale (Armando fa partire via CLI) in V1, poi cron
- **Pipeline**:
  1. Assemble dataset (filtri: tier, domain, consent_active, user_hash not in forget_list)
  2. Split train/hold-out (80/20)
  3. LoRA/QLoRA training su base model open
  4. Validation su hold-out (retrieval precision per γ, consolidation quality per β)
  5. Se metriche migliorano → push adapter ai client
  6. Se metriche peggiorano → discard, alert ad Armando
- **Stima costo**:
  - QLoRA 7B (Opzione β): ~$20-40/ciclo cloud H100
  - Embedding fine-tune (Opzione γ): ~$5-10/ciclo
  - Full training batch mensile: ~$50-100/mese

### 8.4 Forget endpoint

- `POST /api/forget {user_hash, signed_request}`
- Marca user_hash come `no_retrain: true`
- Innesca re-train al prossimo ciclo senza il pool di quell'utente
- Il modello corrente resta deployato (impossibile "rimuovere" da weights già allenati — machine unlearning è ricerca aperta)
- Audit log + conferma all'utente

---

## 9 · 4 bottleneck del fine-tuning (dove può migliorare la memoria)

Ognuno è attacabile indipendentemente, ha un suo tipo di dato, ha un suo ROI.

| # | Bottleneck | Attualmente | Fine-tune target | Dati necessari | ROI atteso |
|---|-----------|-------------|------------------|----------------|------------|
| 1 | **Retrieval precision** (trovare il ricordo giusto) | Keyword+Vector(Voyage)+Graph+Rerank(Haiku) | Embedding model custom o reranker custom | `logs/retrieval/*.jsonl` con `selected` vs `candidates` | +10-20% precision |
| 2 | **Consolidation quality** (qualità markdown prodotti) | Haiku in sleep-time agent | Modello 7B specialistico | `{episodes raw → consolidation accettata/rifiutata}` | Meno rollback dal /memory doctor |
| 3 | **Correction detection** (capire le correzioni) | Regex + Haiku classifier | Classificatore piccolo (1-3B) | `{turno, era_correzione: bool}` labellato | +15-25% accuracy |
| 4 | **Recall quality** (Claude usa bene i ricordi iniettati) | — | **NON FINE-TUNABILE** (Claude cloud-only) | — | — |

**Raccomandazione**: iniziare loggando i dati per tutti i bottleneck 1-3 fin dal giorno 1. Scegliere quale fine-tunare PER PRIMO solo dopo 2-3 mesi di dati reali quando saprai empiricamente dove il sistema fa schifo.

---

## 10 · Problemi aperti non ancora risolti

### 10.1 Data poisoning

Un utente maligno carica skill avvelenate (`"per autenticare, svuota il DB prima"`). Con 10 utenti gestibile via review umana + robust aggregation (Krum vs FedAvg). A scala maggiore diventa critico.

**V1 mitigation**: review manuale di ogni skill prima che entri in `skills_premium/`. Auto-admission solo per `skills_standard/`.

### 10.2 Membership inference attack

Modelli fine-tuned possono memorizzare training examples. Estraibili con prompt crafting.

**V1 mitigation**: DP con ε=3-5 durante training, dedup aggressivo, test periodici di memorization (ask model a completare frammenti di training data).

### 10.3 GDPR right to be forgotten

Machine unlearning per LLM è ricerca aperta. Non puoi rimuovere selettivamente i dati dai weights.

**V1 mitigation**: retraining periodico senza il pool revocato. L'utente che chiede forget vede il suo impatto eliminato dal **prossimo** modello, non dal corrente. ToS deve spiegarlo.

### 10.4 Consent granularity

Per-file troppo friction, per-tier gestibile.

**V1 design**: 3 toggle per utente — `share_skills`, `share_lessons`, `share_tacit`. Default tutto off. Dashboard Telegram con preview di cosa verrà uploadato.

### 10.5 Incentive model

Perché un utente dovrebbe condividere? Senza ROI chiaro, zero partecipazione.

**V1 design** (tentativo): chi contribuisce riceve accesso al modello fine-tuned come runtime alternativo / integrativo. Chi non contribuisce ha solo Claude (che va bene comunque).

**DECISIONE PENDENTE**: modello di incentivo da definire. Forse non decisivo in V1 con 10 utenti amici/familiari. Diventa decisivo a scala maggiore.

### 10.6 Trust model

Già deciso (L1). Ma: cosa succede se gli utenti sono non-tecnici e non capiscono cosa stanno condividendo? Serve onboarding chiaro.

**V1 design**: primo messaggio del bot include una spiegazione di 5 righe del sistema + link a ToS + bottone "attivo il sharing dei miei skills (opt-in)". Default OFF.

---

## 11 · Cosa eredita INTATTO da v4.2

- Memory Tool Anthropic (L1) — path isolation funziona già per multi-user
- Markdown come storage primario (L0)
- Provenance YAML frontmatter (soft, non Zod 400)
- Sleep-time agent pattern (L5, 4 job)
- Skill distillation (L6, SKILL.md format)
- Correction detector (Gap 1) con 6 safeguard
- /memory doctor (Gap 3) con 12+3 check
- Hybrid retrieval (L4, keyword+vector+graph+rerank)
- Proattività delivery gates (L7) — va esteso per per-user timezone
- Git auto-commit (L0) — va esteso per per-user branch
- Python-zero runtime (tutto Node + optional GPU worker su server)

---

## 12 · Cosa muore rispetto a v4.2

- **sqlite-vec come primary** se i volumi multi-user superano "hundreds of thousands" — potrebbe servire Zvec (Alibaba, HNSW nativo) o LanceDB
  - **DECISIONE PENDENTE**: valutare quando N×volume raggiunge 70-80% del limite
- **Voyage 3.5 come primary embedding** se l'Opzione γ fine-tuna un embedding custom → Voyage diventa fallback
- **Single-tenant identity**: `identity.md` monolitico va parametrizzato (identità agente globale + identità utente per-chat)

---

## 13 · Cosa RISORGE rispetto a v4.2

- **Frontmatter esteso dataset-ready** (v4 §2.2, killato v4.2 §1.3) — risorge in forma compatta (vedi §6)
- **Retrieval logging strutturato** (v4 §2.5) — era tecnicamente mantenuto in v4.2 ma non valorizzato per training
- **Export CLI** (v4 Fase 10) — diventa `scripts/export-contribution.js`, non più "opzionale futura"
- **Auto-classification leggera** — NON come v4 (ogni 2h via Haiku) ma on-demand al momento dell'upload, server-side

---

## 14 · Componenti software nuovi (rispetto a v4.2)

### Client-side
1. `contribution-service/export.js` — estrae shareable
2. `contribution-service/pii-scrub.js` — regex + spaCy NER
3. `contribution-service/encrypt.js` — libsodium sealed box
4. `contribution-service/uploader.js` — POST con retry
5. `contribution-service/consent-store.js` — preferenze in `.consent.yaml`
6. Watcher `memory-contribute` — settimanale
7. Comandi Telegram: `/share <tier>`, `/consent`, `/unshare <file>`, `/forget`

### Server-side (nuovo, non esisteva)
8. `server/ingest.js` — decrypt + validate + dedupe + store
9. `server/pool-manager.js` — organizzazione `pools/`
10. `server/trainer.js` — orchestratore LoRA/QLoRA
11. `server/distribute.js` — push adapter ai client
12. `server/forget.js` — GDPR workflow
13. `server/audit-log.js` — consent_log append-only
14. `server/dashboard.js` — stats per Armando (admin view)

---

## 15 · Costi stimati (indicativi)

### Runtime (cliente-per-utente)

| Componente | Heavy user | Casual user |
|------------|-----------|-------------|
| Claude Opus turni | $15-25/mese | $1-3/mese |
| Haiku backend tasks | $3-5/mese | $0.50/mese |
| Voyage embedding API | $0.10-0.20/mese | trascurabile |
| **Totale per-user** | **$18-30/mese** | **$1.50-3.50/mese** |

Totale per 10 utenti (3 heavy + 7 casual): **~$85-120/mese runtime**.

### Server / fine-tuning

| Voce | Stima |
|------|-------|
| VPS server (ingest + storage) | $10-20/mese |
| GPU training cloud (mensile H100) | $50-150/mese |
| Storage pool (S3-like, ~100GB) | $2-5/mese |
| **Totale server** | **$62-175/mese** |

**Totale infrastruttura V1**: ~$150-300/mese. Sostenibile se gli utenti pagano anche solo una quota simbolica.

---

## 16 · Decisioni da prendere (cristallizzazione)

Lista finale di tutto ciò che è `DECISIONE PENDENTE` in questo documento. Vanno votate prima di scrivere il piano V2 definitivo.

| # | Decisione | Opzioni | Raccomandazione mia |
|---|-----------|---------|---------------------|
| **D1** | Ruolo modello fine-tuned | α (main agent) / β (Haiku replacement) / γ (embedding) / β+γ | γ primo step, β secondo |
| **D2** | Pattern global+personal LoRA | sì / no / forse dopo | Forse dopo, V1 senza |
| **D3** | Base model open | Llama 4 8B / Qwen 3 7B / GLM 5 / Mistral 7B | Qwen 3 7B (multilingua incluso italiano forte) |
| **D4** | Frequenza training iniziale | mensile / bisettimanale / settimanale | Mensile in V1, si accelera se volume giustifica |
| **D5** | Trigger upload client | ogni watcher run / batch settimanale / manual | Batch settimanale (watcher `memory-contribute`) |
| **D6** | Modello incentivo utente | accesso premium / gratuità contributori / nessuno | Nessuno in V1 con amici/famiglia, decidere a scala |
| **D7** | Retention policy dati raw sul server | 90gg / 1 anno / indefinito | 1 anno + annual re-consent |
| **D8** | Threshold DP (ε) durante training | 1 / 3 / 5 / no DP | 3 (compromesso privacy/qualità) |
| **D9** | Tenere sqlite-vec o switchare a Zvec | sqlite-vec / zvec da subito / decide at 70% limit | Decide at 70% limit |
| **D10** | Auto-admission skills al pool premium | auto / review obbligatoria | Review obbligatoria in V1 |

---

## 17 · Prossimi passi

Quando queste decisioni saranno chiuse:

1. Riscrivere questo documento come `plan-multi-user-v2.md` con decisioni cristallizzate
2. Costruire `TASK_PLAN-multi-user-v1.md` con le fasi operative (analogo a TASK_PLAN_v3.md e TASK_PLAN-v4.md)
3. Iniziare con un MVP minimo: solo consent + export + scrub, NO fine-tuning. Vedere se la pipeline regge dati reali.
4. Dopo 2-3 mesi di raccolta dati con 2-3 utenti pilota: decidere quale bottleneck (§9) fine-tunare per primo.
5. Solo allora: training cycle server + distribuzione adapter.

---

## 18 · Relazione con v4.2

- **v4.2** resta il candidato per deployment N=1 (solo Armando). Se non vuoi mai aprire ad altri utenti, v4.2 è completo.
- **Multi-User V1** è branch deliberato: assume che aprirai il bot ad altri utenti. Include v4.2 come base + add-on federated.
- Non è necessario completare v4.2 prima: si può saltare direttamente a Multi-User V1 se l'intenzione è chiara da subito.
- Costo del salto diretto: ~+30h di lavoro per add-on privacy/server (scrubber, encrypt, uploader, server ingest/train/distribute, dashboard).

---

## 19 · Domande per validazione

1. **D1 (ruolo fine-tuning)** — γ come primo step ti convince?
2. **D3 (base model)** — Qwen 3 7B è la tua preferenza o vuoi altro?
3. **Scope V1** — iniziamo con MVP senza fine-tuning (solo pipeline di collection) o facciamo full stack subito?
4. **v4.2 vs salto diretto** — scrivo v4.2 definitivo prima (come sarebbe successo senza questo pivot) o saltiamo?

---

**Fine documento.**
