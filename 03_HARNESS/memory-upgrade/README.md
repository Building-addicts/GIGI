# Memory Upgrade — Indice

Lavoro di progettazione per il sistema di memoria Harness, organizzato per versione.

## Struttura

```
memory-upgrade/
├── research/              ← ricerca e analisi preliminari (condivise)
├── single-user/           ← piani per deployment N=1 (solo Armando)
│   ├── v1/                ← prima proposta (baseline)
│   ├── v2/                ← 17h, 7 tier, dual sleeper, LRS omeostatico
│   ├── v3/                ← hybrid Memory Tool + 3 custom layer (7.5h)
│   ├── v4/                ← SOTA: 7 layer, 19.5h + 2h spike
│   └── v4.2/              ← critica/proposta migliorativa di v4
└── multi-user-v1/         ← BRANCH: scenario 10 utenti + server fine-tuning federated
    ├── plan-multi-user-v1.md   ← architettura + decisioni pendenti
    └── gap-analysis.md         ← 31 gap consolidati + severity matrix
```

## Contenuto per cartella

### research/
- `findings.md` — analisi tecnica iniziale (stack, primitive, vincoli)
- `prior-art.md` — confronto progetti esistenti (Letta, Mem0, Zep, Hermes, OpenClaw, …)
- `dialogue.md` — discussione/Q&A che ha guidato il design

### single-user/v1/
- `plan.md` — prima proposta di architettura
- `TASK_PLAN.md` — task plan associato

### single-user/v2/
- `plan-v2.md` — architettura 7 tier + dual sleeper + LRS omeostatico (17h). Giudicata ~40% overkill per single-user.

### single-user/v3/
- `plan-v3.md` — hybrid: Memory Tool Anthropic + 3 custom layer (7.5h). Pragmatico, non SOTA.
- `TASK_PLAN_v3.md` — task plan associato

### single-user/v4/ — SOTA, base di riferimento
- `plan-v4.md` — architettura 7 layer (Filesystem, Memory Tool, Vector, Graph, Hybrid Retrieval, Sleep-Time, Skill Distillation, Proattività)
- `TASK_PLAN-v4.md` — 19.5h implementazione + 2h spike gate

### single-user/v4.2/
- `Proposta-V4.2-Critico.md` — critica e proposta migliorativa di v4 (scenario N=1)

### multi-user-v1/ — BRANCH ATTIVO
- `plan-multi-user-v1.md` — scenario 10 utenti con server centrale di fine-tuning federated (22/04/2026). Threat model L1. 10 decisioni pendenti.
- `gap-analysis.md` — 31 gap consolidati (strutturali, vs SOTA, federated, research Apr 2026) + severity matrix + piano d'azione top 10.

## Stato attuale

- **Branch attivo**: `multi-user-v1/plan-multi-user-v1.md` — scenario multi-utente con fine-tuning decentralizzato su server centrale.
- **v4.2** resta come candidato deployment N=1 single-user se il pivot multi-user non procede.
- Nessuna implementazione iniziata: gate obbligatorio = spike decisionale di Fase 0.5 prima di partire.
- Stack validato: Anthropic Memory Tool + LanceDB + BGE-M3 + SurrealDB embedded + Git versioning.
- Scartati: Kuzu (deprecato 10/2025), CozoDB (borderline morto).
