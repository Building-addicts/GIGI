# Setup sviluppatore — GIGI (iOS)

> Aggiornato dopo il rework `armando-rework` (2026-05-07): Gemini sradicato (ADR-0004), wake word soft-killed per MVP (ADR-0003).

## API key richiesta — Groq

GIGI usa Groq come backend cloud per reasoning, NLU e Vision. Serve una chiave API:

1. Registrati gratuitamente su [console.groq.com](https://console.groq.com/) → API Keys.
2. La chiave si inserisce nell'app durante onboarding (step "API key") oppure in **Settings → API key**.

Se manca, GIGI gira in modalità "Limited" (solo Apple Foundation Models on-device + NLU rule-based locale).

## Niente più Gemini API key

Storicamente l'app usava Gemini Live (WebSocket) e Gemini REST. Entrambi rimossi nel rework — non serve più alcuna chiave Google AI Studio. Vision è gestita da Groq.

## Niente più Porcupine

Il wake word "Hey GIGI" via Porcupine è stato sostituito da `SFSpeechRecognizer` on-device, ed è ora soft-killed per MVP (issue #102). Riferimenti residui in `Info.plist` e `Config.example.xcconfig` (`PICOVOICE_ACCESS_KEY`) sono dormienti — possono essere rimossi in una fase futura del rework.

I trigger MVP sono:
- **Action Button** (iPhone 15 Pro+) → Shortcut "Talk to GIGI"
- **Back Tap** (iPhone 14 e precedenti) → stesso Shortcut
- **Siri AppIntent** → "Hey Siri, talk to GIGI"

## File sensibili

`Config.xcconfig` (gitignored) è ancora supportato per chi vuole iniettare `GROQ_API_KEY` build-time invece che dall'UI. `Config.example.xcconfig` è committato come template.

Prima del primo commit in un nuovo clone, verifica con `git status` che `Config.xcconfig` non compaia tra i file tracciati.
