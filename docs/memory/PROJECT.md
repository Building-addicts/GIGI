# Project: GIGI
**Initialized:** 2026-04-27
**Last updated:** 2026-04-27

## What it is

GIGI è un assistente vocale "True Agent" su iPhone che delega task complessi a un harness Node.js sul PC dell'utente, il quale orchestra Claude (CLI + computer-use SDK) per eseguire ricerche, automazioni browser, e azioni cross-app. Pairing iPhone↔PC via Cloudflare Tunnel + QR; secret in iOS Keychain.

Riferimento canonico: `docs/Architecture-Armando-Revision.md` (paper tecnico V3 "True Agent", aprile 2026 rev. 2).

## Tech Stack

| Layer | Technology | Version | Notes |
|-------|-----------|---------|-------|
| iOS app | Swift / SwiftUI | iOS 17+ | `02_GIGI_APP/GIGI.xcodeproj`; sideload via Sideloadly |
| iOS Siri extension | App Intents | iOS 17+ | `02_GIGI_APP/GigiIntents1/` |
| iOS NLU | CoreML | — | `GigiNLU_Transformer.mlpackage` |
| Harness backend | Node.js | v20+ | `03_HARNESS/server/`, porte 7777/7778/7779 |
| MDM server | Node.js | v20+ | `01_SERVER_MDM/` (profili MDM accessibility) |
| Claude integration | Claude Code CLI + Anthropic SDK | latest | `claude-runner.js`, computer-use loop fase 14 |
| Browser automation | Puppeteer + Playwright | — | `03_HARNESS/browser-pool/` |
| Memoria | JSON store (MVP) → LanceDB + BGE-M3 (futuro v4) | — | `03_HARNESS/memory/` |
| Push | APNS via `node-apn` | — | `03_HARNESS/apns/` |
| Tunneling | Cloudflare Quick/Named Tunnel · LAN mDNS · Tailscale | — | quick = default MVP |
| Deploy panel | Vercel (statics) | — | `vercel.json` root |

## Core Goals

1. **Jarvis, non Siri** — agente che ragiona, pianifica, chiama tool, e decide il passo successivo autonomamente (vedi `Architecture-Armando-Revision.md` §1).
2. **Privacy-first** — memoria utente sul PC dell'utente, non su cloud Anthropic; pairing E2E quando possibile (Tailscale/Iroh roadmap).
3. **Onboarding < 10 min** — setup harness + pairing QR + sideload IPA in tempo umano.
4. **Cost-aware** — routing Groq (chiacchiera istantanea) vs Claude (task complessi); Force-Claude opzionale.

## Key Constraints

- **iOS sideload only** (no App Store distribution finora) → workflow Sideloadly + IPA → ogni modifica Swift richiede rebuild + nuovo IPA (vedi `CLAUDE.md` §Pacchettizzazione IPA).
- **CGNAT / NAT traversal Italia** — Cloudflare Tunnel come default MVP; Iroh `iroh-ffi` ARCHIVED dal Feb 2025 (vedi `docs/research/pairing-landscape-2026.md`).
- **WS 100 s idle timeout** su Cloudflare free — heartbeat necessario.
- **Privacy edge-TLS** Cloudflare vs E2E Tailscale/Iroh — trade-off documentato.
- **iPhone fisico richiesto** per test (Sideloadly + Apple ID); simulatore non copre l'audio/VAD pipeline reale.

## Repo layout

```
GIGI-main/
├── 01_SERVER_MDM/  Node server profili MDM iOS
├── 02_GIGI_APP/    App iOS Swift + Siri Intents extension
├── 03_HARNESS/     Backend Node: Claude sessions, memoria, computer-use, APNS
├── docs/           TUTTI i doc project-level (architettura, piano, E2E,
│                   components, onboarding, task plan, memory/, plans/,
│                   research/, archive/)
├── bin/            tooling root
├── public/         assets condivisi web
├── start-harness.sh
└── vercel.json
```
