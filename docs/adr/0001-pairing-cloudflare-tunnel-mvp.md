# ADR-0001: Cloudflare Quick Tunnel come pairing default MVP

- **Status:** Accepted
- **Date:** 2026-04-24
- **Deciders:** @armando
- **Tags:** pairing, networking, mvp

## Context

GIGI necessita di un canale iPhone↔harness PC raggiungibile da fuori la rete domestica
dell'utente (la maggior parte delle connessioni italiane è dietro CGNAT, NAT-traversal
P2P è inaffidabile). Le opzioni di mercato 2026:

- **Cloudflare Quick Tunnel** — zero account, URL pubblico ephemeral in 15 s
- **Cloudflare Named Tunnel** — URL stabile, richiede account + dominio
- **LAN mDNS** — solo stessa Wi-Fi
- **Tailscale** — mesh tailnet, full-P2P E2E quando possibile, richiede account + install
- **Iroh / iroh-ffi** — libp2p hole-punch + relay; **`iroh-ffi` ARCHIVED da Feb 2025**

Trade-off principali: facilità onboarding vs privacy (edge-TLS Cloudflare vs E2E
Tailscale/Iroh) vs stabilità URL.

Ricerca completa: `docs/research/pairing-landscape-2026.md`.

## Decision

Adottiamo **Cloudflare Quick Tunnel come default MVP** per il primo onboarding utente,
con **Tailscale documentato come "advanced path"** per chi vuole P2P/E2E.
Iroh è escluso (libreria ufficiale archiviata).

> One-click setup wins per il primo deploy. Privacy-first è una scelta esplicita
> dell'utente, non il default.

## Alternatives considered

- **Tailscale come default** — scartato perché richiede account + install lato utente, killer per onboarding < 10 min
- **LAN mDNS only** — scartato: l'utente vuole controllo da fuori casa
- **Iroh hole-punching** — scartato: `iroh-ffi` (Swift+Node bindings) archiviato Feb 2025, ultimo release Jun 2025
- **Self-hosted reverse tunnel** (frp/rathole) — scartato: ops overhead, non scala a utenti non-tecnici

## Consequences

### Positive
- Setup in 15 secondi, zero account richiesti per il primo run
- Pairing QR + secret one-time fluido (vedi `docs/runbooks/pair-iphone.md`)
- Path Tailscale resta documentato per power user

### Negative / Trade-off
- **URL ephemeral**: ogni restart `cloudflared` cambia URL → re-pair richiesto. Mitigazione: passaggio a Named Tunnel quando l'utente ha account
- **Privacy edge-TLS**: Cloudflare termina TLS al loro edge → in chiaro per loro. Accettabile per MVP, esplicitato all'utente
- **WS 100 s idle timeout** sul piano free → heartbeat richiesto lato app/harness

### Neutral / Note
- Iroh resta candidato per **v2 post-1.0** se libreria torna mantenuta o si trova alternativa libp2p mantenuta
- Codice harness è agnostico: `bind` su tutte le interfacce, l'utente sceglie il front (Cloudflare/Tailscale/LAN) nel panel admin

## References

- Ricerca: `docs/research/pairing-landscape-2026.md`
- Piano implementativo: `docs/plans/cloudflare-tunnel-pairing.md`, `docs/plans/tailscale-qr-pairing.md`
- Implementazione: commit `ca8a599` (Phase 4 — VisionKit scanner + `/api/pair` loopback-only)
- Runbook: `docs/runbooks/pair-iphone.md`
