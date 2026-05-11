# 🧪 Test verification — 2026-05-13 morning

> Self-contained test protocol per Armando. Verifica i 11 fix landati ieri.
> Tempo totale: ~20 minuti. Niente assistente, basta seguire i pass.

---

## 🎯 IPA da installare

**File**: `C:\Users\arman\Desktop\GIGI\bug\GIGI-c8b1d1a.ipa`
**Commit**: `c8b1d1a` (branch `armando-rework`)
**Size**: 4.0 MB
**Build**: 2026-05-12 ~01:04 (cumulativo con tutti i fix bug 001-016)

---

## ⚙️ Setup (3 min)

### 1. Restart harness (CRITICO per bug 015/016)

I fix 015 e 016 sono **prompt engineering** nel file `.claude-sandbox/CLAUDE.md`. Claude Code legge questo file all'avvio sessione, NON dinamicamente. Senza restart, le sessioni in-flight usano la versione vecchia.

```bash
cd "C:\Users\arman\Desktop\PROGETTI VIBE CODING\GIGI FOLDER\GIGI-work\Armando-Rework"
./start-harness.sh
```

Lo script è idempotente: kill stale, restart pulito, nuovo tunnel URL.

### 2. Re-pair iPhone

Quick tunnels Cloudflare hanno URL ephemeral. Restart = nuovo URL = re-pair.

- Sul PC: `http://localhost:7777/pair`
- iPhone Settings → Harness → tap "Re-pair" → scansiona QR

### 3. Install IPA

- Kill GIGI dall'app switcher
- Sideloadly → trascina `GIGI-c8b1d1a.ipa` → install
- Apri GIGI → conferma che Settings → Harness mostra il nuovo tunnel URL

### 4. Apri Live Monitor

- Browser PC: **http://localhost:7777/live.html**
- Ctrl+F5 per cache pulita
- Verifica le 4 cards in cima tutte verdi (Tunnel reachable, Ollama ready, Claude wired, iOS bridge ready)
- Tieni aperto durante i test

---

## 📋 Test suite (12 test, in ordine)

> Per ogni test: pronuncia / digita il prompt indicato. **Reset chat (icona ↻) tra ogni test** per evitare history pollution.

### TEST 1 — Bug #001 Dashboard banner softer

**Cosa fare**:
- Vai tab **Dashboard**
- Guarda i banner in cima

**PASS se**:
- ✅ Vedi al massimo il banner **purple "Connect GIGI to your PC"** (solo se non sei paired)
- ✅ Banner blu "Optional: cloud AI brain" (se non hai Groq key) — con bottone **x** dismissibile
- ✅ NESSUN banner orange "Groq key required"

**FAIL se**: vedi ancora orange con "required"

---

### TEST 2 — Bug #004 + #005 Timer "two minutes" (spelled-out)

**Prompt**: *"Set a timer for two minutes"*

**PASS se**:
- ✅ Bubble: "Timer set for 2 minutes."
- ✅ Banner pill in chat: "Starting timer"
- ✅ Notifica iOS arriva ~2 minuti dopo

**FAIL se**: "How long should the timer run?"

---

### TEST 3 — Bug #006 + #010 Call con WhatsApp bypass

**Prompt**: *"Call Leo Corte"* (assumendo Leo abbia WhatsApp + numero internazionale)

**PASS se WhatsApp installato (path principale)**:
- ✅ Bubble: "Opening WhatsApp call with leo corte. Tap the call icon at the top of the chat."
- ✅ WhatsApp si apre **direttamente** nella chat di Leo
- ✅ **NESSUN popup iOS** "Chiama X / Annulla"

**PASS se contatto senza WhatsApp (fallback)**:
- ✅ Bubble: "Calling leo corte."
- ✅ iOS popup standard appare (è OK, fallback corretto)

**FAIL se**: "Tap Call to confirm — iOS requires your approval..." (= IPA vecchia)

---

### TEST 4 — Bug #002 create_note pulito

**Prompt**: *"Create a note titled test with body hello world"*

**PASS se**:
- ✅ Bubble dice SOLO: "The note titled 'test' with the body 'hello world' has been created and copied to the clipboard. You can paste it into the Notes app..."
- ✅ NESSUN "/login" all'inizio
- ✅ Apple Notes si apre

**FAIL se**: vedi "Not logged in · Please run /login" da qualche parte

---

### TEST 5 — Bug #003 Knowledge Q&A → Ollama EN

**Prompt**: *"Explain Bayes theorem"*

**PASS se**:
- ✅ Risposta in **INGLESE**, 2-3 frasi su Bayes theorem
- ✅ Live monitor mostra `[ios-request] POST /api/ios/local-llm/generate` + `[local-llm] generate START`
- ✅ NESSUN "/login" error

**FAIL se**: vedi "/login" o risposta in italiano

---

### TEST 6 — Bug #009 NLU "and say hi" contact extraction

**Prompt**: *"Send a message and say hi to Leo Corte"*

**PASS se**:
- ✅ WhatsApp/iMessage apre con chat di Leo Corte
- ✅ Body pre-compilato: "hi"

**FAIL se**: "Couldn't find and say hi" (= contact extraction broken)

---

### TEST 7 — Bug #012 Telemetry visibile in Live Monitor

**Prompt qualsiasi** (es. *"What time is it"*)

**PASS se** nel Live Monitor compare entro 1 secondo:
```
[ios-telemetry] router_decision · path=native_tool · action=ask_time · text="what time is it"
```

**FAIL se** Live Monitor resta vuoto durante azioni on-device

---

### TEST 8 — Bug #013 History pollution limiter

**Sequenza** (in questo ordine, NO reset tra le 4):
1. *"Send a message to Leo Corte"*
2. *"Send a message to Leo Corte"*
3. *"Send a message to Leo Corte"*
4. *"Order a Kebab"*

**PASS se** test 4:
- ✅ GIGI risponde **sul tema Kebab** (es. apre JustEat, o ask_clarification su cibo)

**FAIL se**: GIGI dice "Send a message to Leo Corte." come echo dalla history

---

### TEST 9 — Bug #011 JustEat native dispatch

**Reset chat** (importante per evitare history bias)

**Prompt**: *"Order something on JustEat"*

**PASS se**:
- ✅ JustEat app si apre (se installata), oppure justeat.it in Safari
- ✅ Bubble: "Opening Just Eat." (o "Opening Just Eat in your browser.")
- ✅ NESSUN "I can't place orders for you..." dismissive

**FAIL se**: vedi il vecchio reject "I can't place orders for you, but you can visit..."

---

### TEST 10 — Bug #014 Geographic context (no più Londra)

**Reset chat**

**Prompt**: *"Find a kebab restaurant using browser"*

**PASS se** (vivendo in Italia):
- ✅ Risposta menziona **Italia / città italiana** (Milano, Roma, etc.)
- ✅ Live monitor mostra Claude navigare su **justeat.it**, NON just-eat.co.uk
- ✅ Risposta breve (max 2 frasi, vedi #015)

**FAIL se**:
- ❌ Risposta menziona "London" / "UK"
- ❌ Live monitor mostra `browser_navigate · url:"https://www.just-eat.co.uk/..."`

---

### TEST 11 — Bug #015 Verbose response

Stesso prompt del #10. Conta le frasi nella risposta GIGI.

**PASS se**:
- ✅ **Max 2 frasi**
- ✅ UN solo ristorante consigliato (non multi-option "X, alternatively Y, finally Z")
- ✅ Niente narrazione step ("I'll search...", "Falling back...")

**FAIL se**: 3+ frasi, lista di ristoranti, narrazione step

---

### TEST 12 — Bug #016 Silent browser fallback

Stesso prompt del #10. Cerca nel TTS / bubble.

**PASS se**:
- ✅ La risposta **NON contiene** "Browser pool is down"
- ✅ NON contiene "Falling back to WebFetch"
- ✅ Risposta diretta sul kebab

**FAIL se**: risposta inizia con o contiene "Browser pool is down. Falling back..."

---

## 📊 Reportazione risultati

Dopo i test, una riga per ognuno:

```
Test 01: PASS / FAIL
Test 02: PASS / FAIL
Test 03: PASS / FAIL — WhatsApp / tel:// (specifica path preso)
Test 04: PASS / FAIL
Test 05: PASS / FAIL
Test 06: PASS / FAIL
Test 07: PASS / FAIL
Test 08: PASS / FAIL
Test 09: PASS / FAIL — app / safari (specifica)
Test 10: PASS / FAIL — IT / UK (specifica)
Test 11: PASS / FAIL — count frasi: N
Test 12: PASS / FAIL
```

Per ogni FAIL: screenshot + paragrafo descrittivo.

---

## 🚨 Cose che NON sono bug

Queste comportamenti sono **intenzionali**, non riportarli come bug:

- **iOS popup "Chiama X / Annulla"** per contatti senza WhatsApp → mandatory iOS per `tel://` (vedi bug #006 doc)
- **TTS in italiano per query Ollama** → solo se mandi prompt italiano. Per EN garantito, prompta in EN.
- **Live monitor vuoto per native_tool** quando telemetry non spara (es. NLU fast-path) → architettura
- **Apple Notes apre su nota esistente** invece di nuova → iOS sandbox non permette create-note diretto (vedi bug #002 spiegazione)
- **WhatsApp/Messages aperto con body pre-compilato ma NON inviato** → iOS richiede tap manuale Send (privacy)

---

## 🐛 Bug ancora aperto

**#008** — "Hellllo" (typo greeting) classified as send_message. P2 cosmetico, fix pronto da deployare quando vuoi.

---

## 🧠 Risorse

- **Ledger DEBUG**: [docs/DEBUG/README.md](README.md)
- **Live Monitor**: http://localhost:7777/live.html
- **iPhone captured logs**: Settings → 🔧 Debug → 📋 Captured GIGI logs
- **Last router decision JSON**: Settings → 🔧 Debug → Last router decision

## 🆘 Se qualcosa va male

1. Verifica IPA installata: Settings → about → build "c8b1d1a" (o data 2026-05-12 ~01:04)
2. Verifica harness running: `curl http://localhost:7777/api/panel/stack-status` → tutto verde
3. Verifica tunnel reachable: stessa URL → `tunnel.reachable: True`
4. Re-pair se Settings → Harness URL non matcha il tunnel attuale

Buon test mattutino. ☕
