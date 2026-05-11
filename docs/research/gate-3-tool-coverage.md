# GATE 3 — 15 Apple FM Tool coverage test

> **Status**: template (to be filled on device with Apple Intelligence enabled)
> **Purpose**: verify each of the 15 `FM*Tool` is reachable from a natural utterance and that the bridge dispatch produces the expected user-visible result.
> **Pre-req**: GATE 0 build verified, IPA installed, Apple Intelligence enabled on iPhone 15 Pro+ / 16 / 17, Brain Path Override = `auto`, Settings → Debug → "Use Apple FM Tool calling (Path 2)" toggle ON.

## Coverage matrix

| # | Tool | Probe query | Expected visible result | Run pass | Notes |
|---|---|---|---|---|---|
| 1 | FMSetTimerTool | "Set a timer for 1 minute" | speech "Timer set for 1 minute", notifica iOS dopo 1m | ☐ |  |
| 2 | FMSetAlarmTool | "Wake me up at 7 AM tomorrow" | speech "Alarm set for 7:00 AM", Clock app entry | ☐ |  |
| 3 | FMSetReminderTool | "Remind me to call Marco tomorrow at 10am" | Reminders app entry, speech "Reminder set" | ☐ |  |
| 4 | FMSendMessageTool | "Send a message to Sara on WhatsApp saying I'll be late" | WhatsApp opens with Sara + body precompiled | ☐ |  |
| 5 | FMMakeCallTool | "Call Mum" | tel://... opens, "Tap Call to confirm" | ☐ | requires contact "Mum" |
| 6 | FMFacetimeTool | "Facetime Federico" | facetime:// opens | ☐ | requires contact "Federico" |
| 7 | FMNavigateTool | "Navigate to Bologna train station" | Maps opens in driving mode | ☐ |  |
| 8 | FMPlayMusicTool | "Play Daft Punk on Spotify" | Spotify opens with search | ☐ | Spotify installed required |
| 9 | FMOpenAppTool | "Open Notes" | Notes app launches | ☐ |  |
| 10 | FMWeatherTool | "What's the weather in Milan" | speech with weather data | ☐ | requires internet |
| 11 | FMReadCalendarTool | "What's on my calendar today" | speech with today's events | ☐ | requires Calendar access |
| 12 | FMFindFreeSlotTool | "Find a free slot Thursday afternoon" | speech with slot suggestion | ☐ | requires Calendar access |
| 13 | FMReadEmailTool | "Read my latest email" | Mail app opens | ☐ |  |
| 14 | FMHomeKitOnTool | "Turn on the living room light" | HomeKit accessory toggles ON | ☐ | requires HomeKit setup |
| 15 | FMHomeKitOffTool | "Turn off the kitchen light" | HomeKit accessory toggles OFF | ☐ | requires HomeKit setup |

## A/B comparison — Apple FM Tool round-trip vs slot bridge

Run each query in both modes (toggle "Use Apple FM Tool calling" in Settings → Debug):

| # | Tool | Mode A latency (s) | Mode B latency (s) | Mode A slot quality | Mode B slot quality | Winner |
|---|---|---|---|---|---|---|
| 1 | set_timer |  |  |  |  |  |
| 4 | send_message |  |  |  |  |  |
| 7 | navigate |  |  |  |  |  |
| 10 | weather |  |  |  |  |  |

Mode A (Apple FM Tool ON): expect 1-2s, best slot extraction.
Mode B (slot bridge OFF): expect 80-200ms, slots from router decision.

## Pass criteria

- **13/15** tools work on first probe (allows 1-2 device-specific failures: contacts missing, HomeKit accessory not named exactly as expected)
- No crashes in any tool call
- For Apple FM Tool round-trip mode (A), Console.app log shows `GIGI Router → native_tool[FM]: action=... latencyMs=...`
- For bridge mode (B), Console.app log shows `GIGI Router → native_tool[bridge]: action=... params=...`

## Decision

After running: `PASS / FAIL`:

> ___________________________________

Failures get a sub-issue with `bug` label, parent `GATE-3`, assignee `@ArmandoBattaglino`. Include: tool name, exact query, observed behavior, expected behavior, Console.app excerpt.
