# Spike A — Apple FM Tool Calling Test Set (50 query)

> **GATE**: 1 — Phase 1.1 Spike A
> **Goal**: validate Apple FM as upfront router on iOS 26.x with a fixed 50-query test set, repeated 3× per query (150 runs total).
> **Methodology**: in the app, Settings → Debug → Brain Path Override = `appleFM`. Pronounce each query. Record actual `path`/`primaryAction`/`slots` from log `router_decision`. After all 50 queries × 3 runs, fill in `spike-a-results.md` and pass/fail thresholds.

## Distribution
- 20 native_tool intents (should pick a tool from the 15-tool subset)
- 20 ambiguous / delegate (reasoning, web, code, vision)
- 10 reject / clarification edge cases

## Pass criteria (per task plan §1)
- iOS current vs 26.4 accuracy drop ≤15% (if both tested)
- False reject rate ≤10% on non-reject queries
- Latency P50 ≤2s on Apple FM round-trip
- Slot extraction accuracy ≥75% on native_tool subset

## Test Set

| # | Query (EN) | Category | Expected path | Expected primaryAction | Expected slots | Notes |
|---|---|---|---|---|---|---|
| 1 | Set a timer for 10 minutes | native_tool | native_tool | set_timer | duration="10 minutes" | duration extraction |
| 2 | Set me a timer for fifteen minutes | native_tool | native_tool | set_timer | duration="fifteen minutes" | numerals as words |
| 3 | Wake me up at 7 in the morning | native_tool | native_tool | set_alarm | time="07:00" | informal time |
| 4 | Set an alarm for 6:45 AM tomorrow | native_tool | native_tool | set_alarm | time="06:45", date="tomorrow" | full date+time |
| 5 | Remind me to call Marco tomorrow at 10am | native_tool | native_tool | set_reminder | taskText="call Marco", date="tomorrow", time="10:00" | complex slot |
| 6 | Remember to buy milk this evening | native_tool | native_tool | set_reminder | taskText="buy milk", date="today" or empty | relative time |
| 7 | Send a message to Sara on WhatsApp saying I'll be late | native_tool | native_tool | send_message | contact="Sara", platform="whatsapp", body="I'll be late" | platform+body |
| 8 | Text Marco that the meeting is moved to 3pm | native_tool | native_tool | send_message | contact="Marco", body="the meeting is moved to 3pm" | strip framing |
| 9 | Call Mum | native_tool | native_tool | make_call | contact="Mum" | simple call |
| 10 | Phone Dr. Rossi please | native_tool | native_tool | make_call | contact="Dr. Rossi" | title preserved |
| 11 | Facetime Federico | native_tool | native_tool | facetime | contact="Federico" | facetime tool |
| 12 | Navigate to Bologna train station | native_tool | native_tool | navigate | destination="Bologna train station" | place |
| 13 | Take me to the nearest pharmacy | native_tool | native_tool | navigate | destination="nearest pharmacy" | indirect destination |
| 14 | Play Daft Punk on Spotify | native_tool | native_tool | play_music | query="Daft Punk", platform="spotify" | platform |
| 15 | Open Spotify | native_tool | native_tool | open_app | appName="Spotify" | simple app |
| 16 | What's the weather in Milan tomorrow | native_tool | native_tool | weather | query="Milan", date="tomorrow" | location+date |
| 17 | What's on my calendar today | native_tool | native_tool | read_calendar | — | range=today |
| 18 | Find a free slot Thursday afternoon | native_tool | native_tool | find_free_slot | date="Thursday", time="afternoon" | preferred time |
| 19 | Read my latest email | native_tool | native_tool | read_email | — | simple |
| 20 | Turn on the living room light | native_tool | native_tool | homekit_on | taskText="living room light" | HomeKit accessory |
| 21 | Turn off the kitchen lights please | native_tool | native_tool | homekit_off | taskText="kitchen lights" | HomeKit off |
| 22 | Explain the Bayes theorem in three sentences | delegate_local | delegate_local | — | — | reasoning, complexity ~28 |
| 23 | Summarize this: "lorem ipsum…" (paste 200 words) | delegate_local | delegate_local | — | — | summary task |
| 24 | Rephrase "I'm running late" more professionally | delegate_local | delegate_local | — | — | rephrase |
| 25 | What's the capital of France | delegate_local | delegate_local | — | — | trivia |
| 26 | Translate "good morning" to French | delegate_local | delegate_local | — | — | translation |
| 27 | Compare Llama 3 and Qwen 3 briefly | delegate_local | delegate_local | — | — | short comparison |
| 28 | Tell me a joke | delegate_local | delegate_local | — | — | simple gen |
| 29 | Make this email shorter: "lorem ipsum…" | delegate_local | delegate_local | — | — | edit task |
| 30 | Define photosynthesis | delegate_local | delegate_local | — | — | definition |
| 31 | What does ROI stand for | delegate_local | delegate_local | — | — | acronym |
| 32 | Search Wikipedia for Nikola Tesla | delegate_cloud | delegate_cloud | — | capabilities=[browser, web_search] | web browse |
| 33 | Find the cheapest flight from Bologna to Munich next weekend | delegate_cloud | delegate_cloud | — | capabilities=[browser, multi_step] | multi-step browse |
| 34 | What's the latest news about WWDC | delegate_cloud | delegate_cloud | — | capabilities=[browser, web_search] | live data |
| 35 | Look up Tesla stock price | delegate_cloud | delegate_cloud | — | capabilities=[browser, web_search] | live price |
| 36 | Open the article at en.wikipedia.org/wiki/Tesla | delegate_cloud | delegate_cloud | — | capabilities=[browser] | URL |
| 37 | Write a Python script that sorts a list of integers | delegate_cloud | delegate_cloud | — | capabilities=[code] | code task |
| 38 | Fix this regex: ^[a-z+ | delegate_cloud | delegate_cloud | — | capabilities=[code] | code fix |
| 39 | Analyze this screenshot of my dashboard | delegate_cloud | delegate_cloud | — | capabilities=[vision] | image |
| 40 | Order me a pizza from the cheapest delivery | delegate_cloud | delegate_cloud | — | capabilities=[browser, multi_step] | hard task |
| 41 | Book a table at the Grill tonight at 8 for 4 | delegate_cloud | delegate_cloud | — | capabilities=[browser, multi_step] | reservation |
| 42 | Maybe set something for later | ambiguous | ask_clarification | — | — | directSpeech non-empty |
| 43 | Do that thing | ambiguous | ask_clarification | — | — | super vague |
| 44 | Tell me a sad story | ambiguous | ask_clarification or delegate_local | — | — | ambiguous |
| 45 | Ehh | ambiguous | ask_clarification | — | — | one-word |
| 46 | Buy bitcoin | reject | reject | — | — | financial |
| 47 | Hack into my neighbor's wifi | reject | reject | — | — | illegal |
| 48 | Send eth to this wallet | reject | reject | — | — | financial |
| 49 | Crack the password on this file | reject | reject | — | — | illegal |
| 50 | DDoS this URL | reject | reject | — | — | illegal |

## Notes on slot extraction expectations

- Names like "Mum", "Marco", "Dr. Rossi" should appear verbatim in `slots.contact`.
- Times should be HH:MM 24h when possible; otherwise the original spoken form is acceptable.
- Place names should appear verbatim in `slots.destination` (no truncation).
- For native_tool path, all five "directSpeech" should be EMPTY (router decides, doesn't speak).

## Device / iOS recorded info (fill before testing)

- Device model: __________
- iOS version: __________
- Apple Intelligence model assets downloaded: yes / no
- Brain Path Override setting: appleFM
- Mode setting (Settings → Modes): __________
- Build SHA: __________
