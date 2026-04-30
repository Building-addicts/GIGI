# QA Checklist — pre-release

> Checklist di test E2E **obbligatori** prima di considerare la app "demo-ready" o "release-ready".
> Originariamente in issue #17 (chiusa come deprecated). Da usare come riferimento per le PR review e per QA pre-demo.
>
> Riferimenti completi: `docs/VOICE_ASSISTANT_QA.md` · `docs/TEST_PLAN.md`

## Quando usarla

- Prima di mergiare PR demo-critical (es. wake word, Dynamic Island, native actions)
- Prima di una demo / release / build per stakeholders
- Quando si tagga `release-blocker` su issue che dipendono da QA pass

Non più una "sessione formale schedulata" ma una **checklist viva**: ogni PM/dev può rieseguirla quando serve.

---

## Voice & Wake (W2-W4)

- [ ] **W2** quiet room: 10/10 wake "hey gigi" detected in <2s
- [ ] **W3** noise: 10/10 wake con musica 60dB di sottofondo
- [ ] **W4** false positive 30 min soak: zero wake da "Luigi" / "Gigi" bare / parole simili

## Dynamic Island (D1)

- [ ] **D1** iPhone 15 Pro real device: pill scende su wake, mostra `.listening` per 3s, transition a `.speaking`, banner risposta visibile, return a `sleeping`

## Follow-up (F1-F2)

- [ ] **F1** in Presence: TTS finish → 8s mic aperto → speech captured senza wake
- [ ] **F2** in Talking Session (issue #11): mic aperto **indefinitamente** finché session attiva

## Quick Talk + Native Actions (T2.2, T4.1-T4.2)

- [ ] **T2.2** "Che ore sono?" → risposta vocale corretta
- [ ] **T4.1** "Chiama Marco" → apre dialer su contatto
- [ ] **T4.2** "Manda WhatsApp a Fede" → preview UI (issue #12) con draft enriched

## Onboarding + Pairing (T1.1, T6.1-T6.2)

- [ ] **T1.1** prima installazione: setup keys Groq/Gemini in Settings
- [ ] **T6.1** QR pairing iPhone↔harness: scan, validate, success in <2 min (vedi `docs/runbooks/pair-iphone.md`)
- [ ] **T6.2** diag convergence: tutti i check verdi

## Harness offline (H1-H3)

- [ ] **H1-H3** kill harness during session → banner offline, fallback Gemini, recovery automatico

## Scenario A1 — Active Help proactive suggestion fires

- **Trigger**: Talking Session 5-min con preferences seed (#13) + 3 task estratti (#14)
- **Atteso**: GIGI emette **almeno 1** `proactive_suggestion` autonomo (vedi #76)
- **Pass criteria**: log `proactive_suggestion` presente con `turnId`, `trigger`, `text`. Suggerimento cita 1+ preference o 1+ task
- **Owner**: Leo (esecuzione) + Armando (PM sign-off)

## Scenario P1 — Permission sheet appears for non-WhatsApp action

- **Trigger**: durante Talking Session, dire "GIGI metti in calendario riunione domani 14"
- **Atteso**: appare `PermissionConfirmationSheet` con preview `Calendar event: Riunione — domani 14:00`, pulsanti Send/Edit/Cancel uniformi al pattern WhatsApp (#12)
- **Pass criteria**: stesso layout/UX del WhatsApp draft sheet (vedi #77)
- **Owner**: Fede (esecuzione) + Armando (PM sign-off)

---

## Evidence packet richiesto

Per ogni test eseguito:

- `turnId` log
- screen recording 30s
- harness log estratto
- build SHA
- device specs

Salvataggio in: `docs/qa-evidence/<YYYY-MM-DD>/`

## Acceptance criteria globali

- [ ] Tutti i checkbox sopra ticked
- [ ] Evidence salvato
- [ ] Sign-off PM (@ArmandoBattaglino)

## Linked

- `docs/VOICE_ASSISTANT_QA.md` — full runbook
- `docs/TEST_PLAN.md` — checklist § rilascio
- `docs/MVP_SCOPE.md` — source of truth lancio
- `docs/runbooks/build-ipa.md` — come buildare IPA per test on device
- Active Help #76 · Permission sheet #77
