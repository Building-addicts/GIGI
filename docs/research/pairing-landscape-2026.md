# Pairing & Secure Transport Landscape for GIGI — 2026

> Research report per decidere come connettere l'app iOS GIGI al harness Node.js sul PC dell'utente, quando entrambi sono dietro NAT, senza SaaS centrale a pagamento token, con opzione self-host del relay.
>
> Researcher: Claude (Opus 4.7, 1M). Data: 24 aprile 2026. Fonti: ~30 documenti tecnici, blog tecnici, issue GitHub, paper accademico recente, documentazione ufficiale. Scope: production-ready OGGI.

---

## SEZIONE 1 — Verdetto in una riga

**NO**, non esiste una quarta opzione nettamente superiore a Tailscale / Iroh / Relay-personale per il modello GIGI.
Però **la classifica pratica cambia rispetto alla tua valutazione**: Iroh oggi è molto meno maturo di quanto sembri (il repo `iroh-ffi` per Swift/Node.js è **ARCHIVIATO** da febbraio 2025 e non più aggiornato), quindi per un MVP serio nel 2026 il ranking realistico è **1) Tailscale + pair-code UX, 2) Cloudflare Tunnel o relay self-host, 3) Iroh (solo per iterazione futura quando 1.0 esce)**.

---

## SEZIONE 2 — Top 3 scoperte

### 2.1 — Iroh FFI (Swift + Node.js) è archiviato. Ripeto: **archiviato.**

Il repository ufficiale `n0-computer/iroh-ffi` — che è l'unico path per usare Iroh da Swift o da Node.js — è marchiato "archived and provided as a reference example only" e l'ultimo release è v0.35.0 del **23 giugno 2025**. La ragione è dichiarata nel [post ufficiale del 12 febbraio 2025](https://www.iroh.computer/blog/ffi-updates): il team ha congelato Kotlin/Python/Swift/JavaScript perché "l'esperienza FFI non è buona abbastanza" e hanno posticipato una soluzione alla 1.0. La 1.0 era prevista per "la seconda metà del 2025" ma ad aprile 2026 non è ancora uscita (versioni correnti tipo 0.93/0.94/0.95 ancora sulla linea pre-1.0).

**Implicazione per GIGI**: se scegliamo Iroh nel 2026 dobbiamo scrivere/mantenere noi stessi i binding Swift (uniffi-rs) e i binding Node.js (napi-rs). Non è impossibile ma è un investimento ingegneristico significativo, e non era nella tua valutazione iniziale. Il core Rust di Iroh è buono e in produzione (NAT traversal al 90%+ con fallback relay, analoga a Tailscale), ma la superficie linguistica che serve a GIGI oggi non c'è.

### 2.2 — Il "success rate" P2P di Tailscale è realisticamente > 95%; quello di libp2p è 70% misurato empiricamente

Uno studio di ottobre 2025 ([arXiv:2510.27500](https://arxiv.org/abs/2510.27500), "Challenging Tribal Knowledge") ha misurato **4.4 milioni** di tentativi di hole-punching sulla rete IPFS in produzione attraverso 85'000+ network e 167 paesi: il tasso di successo DCUtR (libp2p) è **70% ± 7.1%**. Tailscale invece riporta > 95% grazie alla combo STUN + hairpin + DERP + peer-relay (loro blog post [nat-traversal-improvements-pt-1](https://tailscale.com/blog/nat-traversal-improvements-pt-1)). Iroh rivendica ~90% di "direct connection" (simile a Tailscale) ma ciò è credibile perché eredita i trick DERP-style di Tailscale: la loro pagina di confronto lo dichiara esplicitamente ([iroh vs libp2p](https://www.iroh.computer/blog/comparing-iroh-and-libp2p)).

**Implicazione per GIGI**: il 30% di connessioni che fallirebbero con libp2p "puro" rende quella opzione non considerabile. Tailscale e Iroh sono allo stesso livello di affidabilità P2P — la scelta non è su NAT traversal ma su UX e maturità dei binding.

### 2.3 — Il pattern "Plex claim code" e "Signal provisioning QR" sono migliori della "VPN install" dal punto di vista UX, ma richiedono un endpoint di discovery

Il flusso Plex (claim code 4 cifre, [docs Plex Support](https://support.plex.tv/articles/requirements-for-remote-playback-of-personal-media/)) e soprattutto il flusso Signal linked-device (QR che contiene temp provisioning address + Curve25519 public key, [Signal blog](https://signal.org/blog/a-synchronized-start-for-linked-devices/)) sono UX molto più "app Store-ready" di "installa Tailscale, fai login, aggiungi il device, apri l'app, inserisci IP 100.x.y.z". Entrambi però richiedono **un endpoint raggiungibile** dove l'app iOS può depositare la sua chiave pubblica e dove l'harness può fetcharla (o viceversa).

**Implicazione per GIGI**: se vogliamo l'UX Plex-style, ci serve **un mini servizio di rendezvous**. Può essere (a) un micro-endpoint hostato da noi (single VM free-tier o Cloudflare Worker), (b) piggy-back su un relay esistente (Tailscale, Iroh, Syncthing), oppure (c) puro BLE/mDNS per pairing locale + opzionale relay dopo. Questa intuizione **rimescola l'architettura**: il pairing iniziale e il trasporto runtime possono (e forse dovrebbero) essere due layer separati.

---

## SEZIONE 3 — Matrice di confronto esteso

Legenda UX: ottimo / buono / medio / scarso. Maturità: 1-5. Latenza: ms aggiuntivi rispetto a un round-trip diretto.

| # | Opzione | UX finale | Maturità | Self-host | Costo/mese utente | Latenza extra | Deps terze | Adatto a GIGI |
|---|---------|-----------|----------|-----------|-------------------|---------------|-----------|---------------|
| 1 | **Tailscale** (app separata) | medio | 5/5 | parziale (Headscale) | €0 personale (3 user/100 dev) | ~5-10ms P2P / ~30-80ms DERP | Tailscale Inc. | **SI** (baseline realistico) |
| 2 | **Iroh embedded** | ottimo (se funziona) | 3/5 (core) · 2/5 (FFI) | si (relay custom) | €0 | ~5-10ms P2P / ~30-80ms relay | n0 Labs (relay pubblici) | **MAYBE** (v2, post 1.0) |
| 3 | **Relay personale** (Fly/VPS) | ottimo | 5/5 (HTTP/WSS noto) | si (100%) | €0-5 (free tier Fly) | +30-100ms fisso | Fly.io/Hetzner/ecc. | **SI** (fallback solido) |
| 4 | **Cloudflare Tunnel** + Access JWT | ottimo | 5/5 | no (dip. Cloudflare) | €0 free tier | +20-60ms fisso | Cloudflare | **SI** (migliore UX zero-setup) |
| 5 | **Headscale** (self-hosted Tailscale) | medio-scarso | 4/5 | si (100%) | €3-5 VPS | ~5-10ms P2P | nessuna dopo setup | **MAYBE** (utenti tech) |
| 6 | **ngrok / Pinggy / zrok** | buono | 5/5 | no (parziale zrok) | €0 free, €8+/mese prod | +30-80ms | ngrok | **NO** (free tier troppo limitato, TOS instabile) |
| 7 | **WireGuard "nudo"** embedded | scarso | 5/5 | si | €0 | ~5-10ms se P2P, altrimenti N/A | nessuna | **NO** (scambio chiavi manuale, niente NAT traversal) |
| 8 | **NetBird** self-hosted | medio | 4/5 | si | €0-5 VPS | ~5-10ms | NetBird server | **MAYBE** (Tailscale alternative) |
| 9 | **libp2p** (js-libp2p + swift-libp2p) | scarso (pair via PeerID) | 3/5 | si | €0 | variabile, 70% P2P | libp2p network | **NO** (70% success, Swift immaturo) |
| 10 | **ZeroTier** | scarso (config manuale) | 4/5 | parziale | €0 free fino 25 nodi | ~5-15ms | ZeroTier controller | **NO** (UX clunky) |
| 11 | **Apple Multipeer Connectivity** | ottimo | 5/5 Apple-only | N/A | €0 | <5ms locale | N/A | **NO** (solo Apple-to-Apple → PC fuori) |
| 12 | **BLE + Wi-Fi credentials bootstrap** (pairing locale) | ottimo | 5/5 | si | €0 | N/A | nessuna | **COMPLEMENTO** (solo bootstrap) |
| 13 | **Passkey / caBLE** cross-device | sperimentale | 2/5 consumer API | no | €0 | N/A | WebAuthn infra | **NO** (API non pubblica per use case) |
| 14 | **Nabu Casa-style relay proprio** (servizio hostato tu) | ottimo | 5/5 | no (tu paghi) | €0 utente / tu paghi €50-200/mese | +30-100ms | la tua VM | **NO** per modello GIGI (tu diventi SaaS) |

---

## SEZIONE 4 — Per-opzione deep dive

### 1. Tailscale (app separata)
Come funziona: client Tailscale su PC e iPhone si registrano a un coordination server (tailscale.com), ottengono keys WireGuard e indirizzi `100.x.y.z`, stabiliscono tunnel P2P diretti; fallback DERP (relays di Tailscale) quando la P2P non va. MagicDNS dà hostname friendly. L'harness bindsa su `100.x.y.z:7779` e l'app iOS si connette a quello IP. Freetier: 3 user + 100 device illimitato, "free forever" (loro parole, [pricing FAQ](https://tailscale.com/docs/reference/faq/pricing)). Effort integrazione: **zero in codice**. Tutto il lavoro è UX: bisogna spiegare all'utente "installa 2 app in più e fai login". Pairing UX è il punto debole — fattibile con un QR che l'harness genera contenente il suo tailnet-IP. Rischio: dipendenza da Tailscale Inc. per coord server (mitigabile con Headscale in futuro).

### 2. Iroh embedded
Come funziona: libreria Rust che implementa QUIC sopra chiavi Ed25519 (NodeID come chiave pubblica). Discovery via relay pubblici `relay.iroh.network` (DERP-simile), NAT traversal sempre tentato, fallback relay se serve. Pairing: scambio di NodeID (stringa base32). Il core Rust è solido e in produzione su "centinaia di migliaia di device" ([roadmap 1.0](https://www.iroh.computer/blog/road-to-1-0)). **MA**: i binding Node.js (`@number0/iroh`) e Swift (`IrohLib` via `iroh-ffi`) sono su repository archiviato, l'ultimo release è di giugno 2025, e il team dichiara che non li aggiornano fino alla 1.0 (che doveva uscire H2 2025 ma non è ancora uscita ad aprile 2026). Effort integrazione per GIGI: **alto** — dovremmo forkare/riabilitare iroh-ffi, tenerlo sincronizzato con le release core Rust, produrre xcframework iOS e package Node.js custom. Stima: 2-4 settimane iniziali + manutenzione continua. Da considerare solo se il team decide di fare dell'ownership P2P un differenziatore tecnico.

### 3. Relay personale (Fly.io / VPS / Docker)
Come funziona: un micro-servizio Node.js (o Go/Rust) hostato da qualche parte con IP pubblico, che mantiene una WebSocket con l'harness dell'utente (outbound) e accetta WebSocket dall'app iOS (inbound), fa routing 1-a-1. Bearer token come credential condivisa. Costi Fly.io realistici per single-user: **~€0-2/mese** con compute shared, partendo da $1.94/month ([Fly pricing](https://fly.io/pricing/)). Effort integrazione: **medio**. Richiediamo all'utente di runnare un Docker su un suo VPS / di cliccare un "Deploy to Fly" button / di usare un nostro relay condiviso con auth Bearer. Latenza: +30-100ms per messaggio, accettabile per conversazione AI ma non per real-time audio. Pro: HTTP/WSS standard, debug banale, TLS con Let's Encrypt ovunque.

### 4. Cloudflare Tunnel + Access JWT
Come funziona: l'harness installa `cloudflared` e lo logga al Cloudflare account dell'utente; Cloudflare assegna un hostname tipo `gigi-abc123.cfargotunnel.com`; l'app iOS si connette a quell'hostname via HTTPS/WSS con un JWT Service Token. WebSockets supportati nativamente sul free tier con **idle timeout 100s** ([Cloudflare docs](https://developers.cloudflare.com/network/websockets/)) — serve heartbeat client ogni 60s. Connessioni "long-lived" SSH-style fino 8h su Cloudflare One. Free tier: **100% gratis, unlimited tunnels, unmetered bandwidth** ([docs Tunnel](https://developers.cloudflare.com/tunnel/)). Effort: **basso**. Lo user fa un signup Cloudflare (free) + runs cloudflared sul suo PC; l'app iOS ha il suo hostname nel QR. Unico trade-off: dipendenza piattaforma Cloudflare (che però è tra le più longeve del mercato, non è Ngrok).

### 5. Headscale
Come funziona: re-implementazione open-source del control server di Tailscale. Lo user lo deploya su un suo VPS. Le app Tailscale client ufficiali si configurano per puntare al suo Headscale invece che a Tailscale Inc. Ottiene piena sovranità, nessun dato verso Tailscale Inc. Ma l'utente deve gestire un VPS, un DNS, cert Let's Encrypt, auth. Per GIGI è il "modo avanzato" — utile come alternativa pubblicata nella doc ("se preferisci zero lock-in, usa Headscale") ma **non default**.

### 6. ngrok / Pinggy / zrok
Come funziona: agent sul PC dell'utente apre tunnel verso infrastruttura del vendor, che gli dà un hostname pubblico. Free tier ngrok: 1 GB/mese, 1 endpoint, random domain con interstitial warning ([comparison 2025-26](https://instatunnel.my/blog/comparing-the-big-three-a-comprehensive-analysis-of-ngrok-cloudflare-tunnel-and-tailscale-for-modern-development-teams)). **Non adatto a GIGI**: il limite di banda e l'interstitial warning lo escludono dall'uso quotidiano. zrok (self-hostable fork di ngrok) è più interessante ma meno maturo.

### 7. WireGuard embedded nudo
Come funziona: scambio manuale di chiavi pubbliche PC ↔ iPhone, nessun control plane, nessun NAT traversal (solo endpoint statico). Per GIGI è **inutilizzabile** perché l'utente dovrebbe gestire endpoint/port forwarding. Serve comunque un coordinatore — e se c'è un coordinatore siamo essenzialmente su Tailscale o Headscale.

### 8. NetBird self-hosted
Alternativa open-source a Tailscale, WireGuard-based con control plane proprio deployabile ovunque. Team-oriented, ha management dashboard web. Stesso profilo di Headscale ma feature-set maggiore. Eventuale alternativa se l'utente non vuole toccare ecosystem Tailscale.

### 9. libp2p
70% hole-punch success rate misurato empiricamente ([arXiv:2510.27500](https://arxiv.org/abs/2510.27500)) — troppo basso per un consumer product. Binding Swift (`swift-libp2p`) low-maintenance, binding JS (`js-libp2p`) più maturo ma pesante. Modello "DHT + transport" è overkill per GIGI (ci servono 2 peer che si trovano, non una rete).

### 10. ZeroTier
Networking layer-2 globale. Control plane principale proprietario, self-host possibile ma lesss common. UX ammin dashboard clunky rispetto a Tailscale. Prestazioni single-threaded, capped dai benchmark Netbird/Defined. **Sconsigliato per GIGI** (la community consumer è migrata su Tailscale).

### 11. Apple Multipeer Connectivity
API Apple ottima per pairing **Apple-to-Apple** (iPhone-iPhone, iPhone-Mac) via Wi-Fi Direct / Bluetooth. Non fa Internet, non attraversa NAT, non parla con un Windows PC. Utile **solo per use case tipo "iPhone si trova accanto a Mac"**. Per GIGI (PC anche Windows e Linux) **irrilevante** — salvo pattern complementare per setup iniziale se l'harness gira su Mac.

### 12. BLE + Wi-Fi credentials bootstrap
Pattern Matter/HomeKit: pairing iniziale via Bluetooth LE in stanza, scambio di credenziali (qui sarebbe token + endpoint), poi il device si autentica via Internet con quei credential. **Pattern forte come bootstrap**, ma non risolve il trasporto runtime — va composto con una delle opzioni 1-4.

### 13. Passkey / caBLE
WebAuthn hybrid transport (caBLE/hybrid) fa pairing device-to-device via QR+BLE per autenticare un login. Bellissimo in teoria ma le API consumer sono per browser/OS, non esposte come "dammi una chiave di sessione tra due dei miei device qualsiasi". **Non c'è una via pubblica per farlo oggi** per una app custom. Da tenere d'occhio negli anni futuri.

### 14. "Gigi Cloud" (fare il Nabu Casa di noi stessi)
Se tu offrissi un relay hostato da te, ti addosseresti costi sempre crescenti (Nabu Casa costa $6.50/mese perché loro ci girano infrastruttura). **Esplicitamente contro il modello GIGI** che hai descritto.

---

## SEZIONE 5 — Novel / unconventional ideas

### 5.1 — Pattern ibrido "Signal-provisioning" sopra Tailscale
Combinare Tailscale come trasporto con un **pairing UX Signal-style**: l'app iOS genera una chiave effimera, la incolla in un QR che include (a) Tailscale-IP dell'harness, (b) chiave pubblica effimera iOS. L'utente scansiona il QR dal PC, l'harness lo decodifica, risponde con provisioning (endpoint Tailscale + Bearer auth). L'utente non vede mai un "IP Tailscale" a schermo: solo un QR. Questo **compensa il punto debole UX di Tailscale** senza abbandonarlo.

### 5.2 — Multi-tier fallback: LAN → Tailscale → Relay
L'app iOS prova nell'ordine: (a) mDNS/Bonjour sulla LAN per vedere se l'harness è nella stessa Wi-Fi (ping `_gigi._tcp.local`), (b) Tailscale IP se entrambi sono su tailnet, (c) Cloudflare Tunnel hostname come ultima risorsa. L'utente non sceglie — l'app prova e usa la prima che risponde. Richiede che l'harness registri tutti e 3 gli endpoint durante il setup. Pattern ispirato a Syncthing (local discovery + global discovery + relay).

### 5.3 — QUIC-Aware Proxying (MASQUE) come relay future-proof
IETF MASQUE QUIC proxy è Experimental-status ma attivo (draft pubblicato novembre 2025, [datatracker](https://datatracker.ietf.org/doc/draft-ietf-masque-quic-proxy/)). Idealmente un self-host relay MASQUE saprebbe forwardare QUIC con transform-ID senza reincapsulazione — latency minima, E2E crittografia preservata. **Non production-ready nel 2026** ma da watchare: Cloudflare lo sta adoptando. Possibile upgrade path per v2 del relay GIGI nel 2027-2028.

### 5.4 — Passkey come "account linking" credential
Anche se caBLE non è esposto come API pubblica, si potrebbe usare un passkey condiviso (iCloud Keychain se entrambi i device sono dell'utente su Apple) come fondamento crypto per fare tutto il resto — la WebAuthn challenge diventa il "claim code" iniziale. Richiede che harness sia su Mac (per iCloud Keychain). Limitazione severa ma **UX magica** quando funziona.

### 5.5 — Syncthing relay protocol come dipendenza
Syncthing ha una rete pubblica di global discovery + relay **free forever**, e il protocollo è semplice (device-ID Curve25519 + BEP). In teoria GIGI potrebbe usare quei relay come trasporto (WebSocket sopra relay Syncthing), evitando di mantenere infrastruttura. **Sconsigliato**: uso non-intended, violerebbe lo spirito dei relay operator volontari, e dipenderemmo da una community altrui. Menzionato per completezza.

---

## SEZIONE 6 — Raccomandazione finale

Data la maturità effettiva del 2026 e il modello single-user-per-instance di GIGI:

### Priorità 1 — MVP (prossime 4-8 settimane)
**Cloudflare Tunnel** come default + **mDNS/Bonjour** per auto-discovery in LAN.

Perché:
- Zero setup utente (signup Cloudflare è 2 click e free forever, cloudflared è single binary)
- WSS over HTTPS già supportato nativamente, bearer auth via header HTTP
- L'app iOS vede un hostname tipo `gigi-<random>.cfargotunnel.com`, ci parla come qualsiasi server HTTP
- Il tuo codice server attuale (Node + WS su porta 7779) **non cambia**: cloudflared proxya
- Pairing UX: harness genera QR con `{hostname, bearerToken}` → app scansiona → done
- Dipendenza terza è Cloudflare (tra le più stabili del settore, 15+ anni), non un piccolo vendor

Costo utente: €0. Il dolore è Cloudflare account setup (~2 minuti).

### Priorità 2 — Fallback/Alternative documentata
**Tailscale** come "modalità avanzata" per utenti che vogliono full-P2P / massima privacy / latenza minima.

Documentare in `00_DOCS/`: "Se non vuoi dipendere da Cloudflare, installa Tailscale su entrambi i device e configura GIGI con modalità tailnet". È 10 righe di doc — il codice harness non cambia (bind su tutte le interfacce, l'utente mette l'IP Tailscale nel QR).

### Priorità 3 — Futuro / Upgrade path (post-1.0 ship, fase v2)
**Iroh embedded** quando 1.0 esce con FFI ufficiale supportato.

Realistically post Q4 2026 / 2027. Fino ad allora monitor `iroh-computer` releases. Quando annunceranno "Swift + Node.js officially supported post-1.0", fare PoC di 2 settimane e se ok migrare. Il wire protocol diventa QUIC over Ed25519, pairing è NodeID (stringa). Rimuove sia Cloudflare che Tailscale dalla dependency list.

### Da NON fare ora
- libp2p (troppo immaturo per mobile, 70% P2P)
- ZeroTier (UX e performance inferiori)
- ngrok free tier (banda insufficiente e warning interstitial)
- hostare un relay condiviso fatto da te (diventi un SaaS con bills)

---

## SEZIONE 7 — Gotchas e Open Questions

### 7.1 — Cloudflare Tunnel free tier: copre davvero TUTTO?
Il claim di "unmetered bandwidth" e "unlimited tunnels" su [Cloudflare One](https://developers.cloudflare.com/cloudflare-one/) è documentato, MA il Terms of Service vieta streaming video/file di grandi dimensioni ([§2.8](https://www.cloudflare.com/service-specific-terms-application-services/)). Per GIGI (messaggi testuali, JSON events, audio opzionale) siamo dentro il perimetro lecito. **Verificare**: se l'app GIGI inviasse audio continuo (voice input streaming) per molte ore/giorno, Cloudflare potrebbe contattare l'utente. Fare PoC con 1 settimana di uso realistico prima di committare l'architettura.

### 7.2 — WebSocket idle timeout 100s su Cloudflare Free
Richiede heartbeat ogni 60-80s dal client o dal server. Non è hard, ma il harness deve implementarlo. Il tuo codice attuale WS su 7779 potrebbe già averlo — da verificare.

### 7.3 — Tailscale usage policy ACL su free tier
Free tier Tailscale è "3 utenti / unlimited device" (pre-aggiornamento era 100 device). Se l'utente avesse 5 iPhone e 3 PC, tutto sotto lo stesso account Tailscale, è OK. Se vuole condividere accesso con un amico/famiglia il free tier permette fino 3 utenti. **Non blocca GIGI**.

### 7.4 — iroh binding Swift / Node.js — community mantain?
Il repo è archived ma esiste una community? Verificare fork attivi su GitHub. Al momento sembra che n0 Labs stesso consigli "scrivi il tuo wrapper via uniffi-rs / napi-rs". Effort stimato: 2 settimane iniziali, poi sync manuale a ogni release Iroh. **Non fattibile da 1 developer solo** se in parallelo ci sono tante altre feature GIGI da portare avanti.

### 7.5 — NAT CGNAT su operatori mobili italiani
TIM, Vodafone, WindTre, Iliad: la maggior parte usa CGNAT IPv4 senza IPv6 pubblico exposed all'utente. Iliad ha annunciato investimenti SRv6/IPv6 ma timeline incerta. Questo significa che (a) l'app iOS su 4G è dietro CGNAT → P2P hole-punching più difficile → Iroh/Tailscale useranno il relay (latenza +30-80ms), (b) se l'harness è su connessione FTTH italiana magari ha IPv6 nativo (TIM/Fastweb offrono) — ma è il lato iPhone il problema. **Questo NON esclude Iroh/Tailscale** ma implica che il relay sarà usato spesso nei mobile use case, pareggiando di fatto la latenza con Cloudflare Tunnel. Rivaluta il premium di Tailscale vs Cloudflare quando il primo finisce su DERP.

### 7.6 — Authentication e revocation
Qualsiasi opzione scelta: serve un meccanismo per revocare un pairing (es: iPhone perso). Pattern: token JWT con device-id binding + lista revoca server-side. Già implementato parzialmente nel tuo harness (Bearer auth). Estendere con "lista device paired" visibile all'utente.

### 7.7 — Installazione harness su Windows vs Mac vs Linux
Cloudflared ha installer ufficiale per tutti e 3. Tailscale idem. Iroh sarebbe un binario unico (bene). **Opzione 3 (relay personale)** è l'unica dove lo user deve setupare anche VPS → richiede un livello tecnico più alto. Ogni opzione va testata sui 3 OS per verifica.

### 7.8 — Privacy: il relay vede i metadati?
- Tailscale DERP: vede timing + IP coppie, NON vede traffico (E2E WireGuard).
- Iroh relay: vede NodeID + timing, NON vede traffico (E2E QUIC).
- Cloudflare Tunnel: vede traffico TLS-terminato EDGE-side (MITM by design). **Importante**: se l'harness termina TLS da solo e Cloudflare è puro passthrough (tunnel mode), Cloudflare non legge. Se invece usa Cloudflare Access JWT, Cloudflare legge header + può ispezionare payload. **Trade-off sostanziale**: Cloudflare Tunnel è più comodo, ma meno privato di Tailscale/Iroh per-default. Da documentare onestamente.

### 7.9 — Cosa fare se l'utente è paranoid?
Documentare un terzo path: self-host Headscale + Tailscale client. Zero dipendenze da terzi. Target audience: 2-5% dei nostri utenti ma molto vocal su Reddit/HN.

---

## Appendice A — Links e citazioni

### Iroh
- [Update On FFI Bindings](https://www.iroh.computer/blog/ffi-updates) — Feb 2025: iroh-ffi Kotlin/Python/Swift/JS non aggiornati fino 1.0. Fonte primaria per il verdetto "FFI archived".
- [iroh 1.0 Roadmap](https://www.iroh.computer/blog/road-to-1-0) — 1.0 slated H2 2025 (non ancora uscito apr 2026).
- [n0-computer/iroh-ffi GitHub](https://github.com/n0-computer/iroh-ffi) — Repo archived, ultimo release v0.35.0 giugno 2025.
- [@number0/iroh npm](https://www.npmjs.com/package/@number0/iroh) — pacchetto Node.js, v0.35.0, last publish 9 mesi fa (giugno 2025).
- [Comparing iroh & libp2p](https://www.iroh.computer/blog/comparing-iroh-and-libp2p) — conferma Iroh usa DERP-style approach.
- [Iroh FAQ](https://www.iroh.computer/docs/faq) — dettagli relay model 9/10 diretto, 1/10 relay.

### Tailscale
- [Pricing FAQ](https://tailscale.com/docs/reference/faq/pricing) — free plan 3 user, device unlimited.
- [How NAT traversal works](https://tailscale.com/blog/how-nat-traversal-works) — Tailscale spiega 90%+ con tech base, 95%+ con full stack.
- [NAT traversal improvements pt. 1](https://tailscale.com/blog/nat-traversal-improvements-pt-1) — breakdown dei trick (STUN, hairpin, PMP).
- [MagicDNS docs](https://tailscale.com/docs/features/magicdns) — UX improvement sopra IP 100.x.y.z.
- [Peer relays](https://www.sitepoint.com/tailscale-peer-relays-nat-traversal-derp/) — 2025 feature per reliability.

### Cloudflare Tunnel
- [Cloudflare Tunnel docs](https://developers.cloudflare.com/tunnel/) — free forever, unmetered bandwidth, unlimited tunnels.
- [WebSockets docs](https://developers.cloudflare.com/network/websockets/) — 100s idle timeout free/pro, 8h max on Cloudflare One.
- [Publish self-hosted app](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/) — JWT Service Token pattern.

### NAT & P2P research
- [arXiv:2510.27500 — Large Scale NAT Traversal Measurement](https://arxiv.org/abs/2510.27500) — Oct 2025, 4.4M attempts libp2p DCUtR, **70% ± 7.1%** success rate. Fonte accademica primaria.
- [libp2p circuit relay docs](https://docs.libp2p.io/concepts/nat/circuit-relay/) — architettura relay.

### Pair UX patterns
- [Signal provisioning blog](https://signal.org/blog/a-synchronized-start-for-linked-devices/) — QR contiene provisioning address + Curve25519 pub key.
- [Plex remote access guide](https://support.plex.tv/articles/requirements-for-remote-playback-of-personal-media/) — claim code pattern.
- [Plex Remote Watch changes Nov 2025](https://www.privacyguides.org/news/2025/11/26/plex-begins-enforcing-new-restrictions-on-remote-streaming-this-week/) — cautionary tale: Plex ora richiede Pass/Remote Watch.
- [Syncthing device IDs docs](https://docs.syncthing.net/dev/device-ids.html) — ed25519 device ID base32.
- [Syncthing relaying docs](https://docs.syncthing.net/users/relaying.html) — community-hosted free relay model.
- [KDE Connect protocol](https://userbase.kde.org/KDEConnect) — LAN UDP broadcast pairing.
- [Matter QR code explainer](https://www.matteralpha.com/explainer/how-does-matter-qr-code-work) — commissioning standard.

### Tunnel / relay services
- [ngrok vs Cloudflare Tunnel vs Tailscale comparison 2025-26](https://instatunnel.my/blog/comparing-the-big-three-a-comprehensive-analysis-of-ngrok-cloudflare-tunnel-and-tailscale-for-modern-development-teams)
- [Awesome Tunneling list](https://github.com/anderspitman/awesome-tunneling) — curated list of 40+ alternatives.
- [Fly.io pricing](https://fly.io/pricing/) — compute from $1.94/month.
- [Nabu Casa docs](https://www.nabucasa.com/) — $6.50/month, comparison point.

### Self-hosted mesh VPN
- [Headscale GitHub](https://github.com/juanfont/headscale) — self-host Tailscale control server.
- [NetBird knowledge hub](https://netbird.io/knowledge-hub/top-5-opensource-alternatives-to-tailscale2) — alternative breakdown.

### WireGuard iOS
- [WireGuard embedding guide](https://www.wireguard.com/embedding/) — ufficiale, patterns per custom apps.
- [WireGuard/wireguard-apple](https://github.com/WireGuard/wireguard-apple) — NetworkExtension integration.

### Passkey / WebAuthn cross-device
- [Corbado CDA guide](https://www.corbado.com/blog/webauthn-cross-device-authentication-passkeys-mobile-first) — hybrid transport / caBLE dettagli.
- [FIDO Passkeys](https://fidoalliance.org/passkeys/) — standard reference.

### IPv6 Italia / carrier
- [Wikipedia IPv6 deployment](https://en.wikipedia.org/wiki/IPv6_deployment) — status by country.
- [Iliad SRv6 announcement](https://www.iliad.it/) — investimento IPv6 ma timeline aperta.

### MASQUE / QUIC
- [IETF MASQUE WG](https://datatracker.ietf.org/wg/masque/about/) — working group page.
- [draft-ietf-masque-quic-proxy-08](https://datatracker.ietf.org/doc/draft-ietf-masque-quic-proxy/) — Nov 2025 Experimental.
- [Cloudflare MASQUE blog](https://blog.cloudflare.com/unlocking-quic-proxying-potential/) — production intent.

---

*Fine report. Caveat: stima basata su documentazione pubblica al 24 aprile 2026. Prima di committare l'architettura, eseguire PoC di 1 settimana con Cloudflare Tunnel su un harness vero e un iPhone vero su 4G italiano per verificare latenza media, occorrenze di reconnect e uso banda.*
