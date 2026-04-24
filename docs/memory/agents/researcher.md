# Researcher — Session History

## 2026-04-24 — Pairing/Transport Landscape for GIGI

**Task**: Deep research on how to connect PC harness ↔ iPhone app across NAT, without SaaS token billing, with self-host option. User had pre-evaluated 3 options (Tailscale / Iroh embedded / personal relay) and asked if there's anything better.

**Scope**: ~30 web searches + targeted WebFetches on Iroh official docs, Tailscale blog, arXiv paper, Cloudflare docs. Coverage: pair UX patterns (Plex, Signal, Syncthing, KDE Connect, Matter, Nabu Casa, Jellyfin), mesh VPNs (Tailscale, Headscale, NetBird, ZeroTier, Nebula), tunnels (ngrok, Cloudflare Tunnel, rathole, frp), embedded P2P libs (Iroh, libp2p), cross-device auth (Passkey/caBLE, WebAuthn hybrid), IPv6/CGNAT landscape Italy mobile carriers, MASQUE/QUIC-proxy IETF status.

**Key findings**:
1. **Iroh FFI repo is ARCHIVED** (Feb 2025) — Swift/Node.js bindings frozen until 1.0 (promised H2 2025, still not out Apr 2026). Last release v0.35.0 Jun 2025. This invalidates Iroh as MVP choice.
2. **libp2p NAT traversal: 70% ± 7.1% measured empirically** (arXiv:2510.27500, 4.4M attempts). Tailscale claims 95%+, Iroh ~90%. libp2p is too low for consumer product.
3. **Pair UX pattern**: Signal's provisioning-QR (temp address + Curve25519 pubkey) is the gold standard. Better than "install Tailscale app" in UX. Can be overlaid on any transport.

**Recommendation**: Cloudflare Tunnel + mDNS local discovery as MVP default. Tailscale as documented "advanced mode". Iroh as v2 upgrade path post-1.0.

**Output**: `C:\Users\arman\Desktop\GIGI\docs\research\pairing-landscape-2026.md` (~600 lines, 7 sections + bibliography).

**Gotchas flagged**:
- Cloudflare Tunnel free tier WebSocket idle timeout 100s → needs heartbeat
- Cloudflare Tunnel TOS disallows heavy streaming → verify with 1-week PoC for GIGI audio use
- Cloudflare edge-terminates TLS by default → privacy trade-off vs Tailscale/Iroh E2E
- Italian mobile CGNAT (TIM/Vodafone/Iliad) means Tailscale/Iroh often fall to relay anyway, erasing latency advantage vs Cloudflare
- iroh-ffi archived: custom uniffi-rs + napi-rs maintenance if we pick Iroh now (~2 weeks setup + ongoing sync)

**Sources authoritative**: iroh.computer/blog, tailscale.com/blog, developers.cloudflare.com, arxiv.org, signal.org/blog, docs.syncthing.net, fly.io/pricing, datatracker.ietf.org.

**Did NOT**: implement anything, run PoC code. Pure desk research as per researcher role.
