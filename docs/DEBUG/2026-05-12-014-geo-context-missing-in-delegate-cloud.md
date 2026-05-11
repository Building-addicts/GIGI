# Bug 014 — Geographic context missing in `delegate_cloud` → Claude defaults to London/UK

- **Status**: ✅ fixed
- **Severity**: **P1** (visible failure on first-impression queries — food, weather, news, navigation)
- **Discovered**: 2026-05-12 — Armando re-test
- **Area**: iOS · GigiRequestRouter.dispatchDelegateCloud · prompt construction

## Symptom

User (in Italy): **"Order a Kebab using browser"**

Live monitor logs show Claude navigating to:
```
mcp__harness-browser__browser_navigate · {"url":"https://www.just-eat.co.uk/area/ec1a-london/kebab"}
```

And the spoken response: *"…The Best Kebab in Finsbury, central London…"*

Claude defaulted to **just-eat.co.uk** (UK domain) and **London postcode `ec1a-london`** for a user clearly in Italy.

User reaction: *"è andato a cercare a Londra senza chiedermi prima dove io fossi"* — searched in London without asking my location first.

## Root cause

`dispatchDelegateCloud` was passing only the rephrased prompt to Claude:
```swift
let prompt = decision.delegatePrompt.isEmpty ? originalText : decision.delegatePrompt
// passed to runClaudeCode(prompt: prompt, ...)
```

No location, no country, no locale. Claude with web tools defaults to the most prominent English-language result for "JustEat" → UK domain + London postcode.

This wasn't visible until bug-016 (browser pool down) made the URL appear in logs. Before that, Claude would have made the same UK-default choice via in-app web search invisibly.

## Fix

New static helper `GigiRequestRouter.prependUserContext(to:)` prepends a parseable header to every delegate_cloud prompt:

```swift
private static func prependUserContext(to prompt: String) -> String {
    let locale = Locale.current
    let country = locale.region?.identifier ?? "unknown"
    let language = locale.language.languageCode?.identifier ?? "en"
    let timezone = TimeZone.current.identifier
    let header = "[User context: country=\(country), locale=\(language)_\(country), timezone=\(timezone)]\n"
    return header + prompt
}
```

Sample output sent to Claude:
```
[User context: country=IT, locale=it_IT, timezone=Europe/Rome]
find a kebab restaurant on justeat
```

The `.claude-sandbox/CLAUDE.md` operator manual was updated with parsing rules:
```
The first line of every user request will include a `[User context: …]`
header with their country / locale / timezone. Use it to:
- Choose the right regional service (justeat.it, not just-eat.co.uk;
  amazon.com for US, not amazon.de)
- Localize date / time / currency mentions
- Default to closest cities in that country
NEVER default to London / UK / US arbitrarily when the user is silent on
location.
```

## Privacy / permissions

- Uses **only `Locale.current`** — set by iOS based on the user's region (Settings → General → Language & Region). No GPS, no location permission.
- For city-level GPS context (future v1.1), would need `CLLocationManager` + permission prompt. Deferred.

## Resolution

- **Commit**: `c8b1d1a` (2026-05-12)
- **IPA**: `GIGI-c8b1d1a.ipa`
- **Files**:
  - `02_GIGI_APP/GIGI/GigiRequestRouter.swift` (+prependUserContext, applied in dispatchDelegateCloud)
  - `03_HARNESS/server/.claude-sandbox/CLAUDE.md` (+Geographic context parsing rules)

### Test plan

| Input (user in IT) | Expected Claude behavior |
|---|---|
| "Find a kebab on JustEat using browser" | navigates justeat.it, returns Italian restaurants |
| "What's the weather here" | Italian city default (Milan/Rome depending on prior context) |
| "Amazon prime delivery" | amazon.it, not amazon.com |
| "Latest news" | Italian-language sources prioritized |
