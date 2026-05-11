# Bug 011 — `Order something on JustEat` returns dismissive reject instead of opening the app

- **Status**: open
- **Severity**: P2 (missed opportunity to be useful; surfaces architecture gap)
- **Discovered**: 2026-05-12 — Armando re-test
- **Area**: iOS · Apple FM router / GigiActionBridge · missing `web_order_food` native handler

## Symptom

User: **"Order something on JustEat"**

GIGI response:
> I can't place orders for you, but you can visit JustEat's website or app to browse and order food from local restaurants.

Apple FM router classified as `path=reject` with this dismissive `directSpeech`. The user gets nothing useful — no app opened, no web link offered programmatically.

## Why this is wrong

GIGI doesn't need to *actually place* the order — just open JustEat for the user to continue. This is a common pattern:
- "Order food on JustEat" → open JustEat app
- "Book a restaurant on TheFork" → open TheFork
- "Order on Deliveroo" → open Deliveroo

The current toolCaption registry already references `web_order_food` ("Opening food delivery") but there is NO matching bridge handler, so the router can't pick it as a `native_tool` action — falls through to reject.

## Repro

1. Reset chat
2. Pronounce or type "Order something on JustEat" (or any food delivery service)
3. GIGI says it can't place orders

## Root cause

`GigiActionBridge.swift` is missing a `case "web_order_food":` handler. `GigiFoundationToolRegistry.swift` is missing the corresponding `Tool` struct. So even though the router knows the action exists by caption, there's no way to dispatch it.

## Proposed fix

### Layer A — add `FMWebOrderFoodTool` to the tool registry

```swift
@available(iOS 26.0, *)
struct FMWebOrderFoodTool: Tool {
    let name = "web_order_food"
    let description = "Open a food delivery app or website. Use when the user wants to order food, takeout, or delivery."

    @Generable
    struct Arguments {
        @Guide(description: "Service name: justeat, deliveroo, ubereats, glovo, doordash, talabat. Empty if unspecified — opens a generic search.")
        var service: String

        @Guide(description: "Optional restaurant/cuisine query (e.g. 'tariq kebab', 'sushi near me'). Empty if not specified.")
        var query: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "web_order_food", params: [
            "service": arguments.service.lowercased(),
            "query": arguments.query
        ])
    }
}
```

Register it in `Self.tools` list.

### Layer B — add bridge handler

```swift
case "web_order_food":
    let service = intent.params["service"] ?? ""
    let query = intent.params["query"] ?? ""
    return await openFoodDeliveryApp(service: service, query: query)
```

```swift
private func openFoodDeliveryApp(service: String, query: String) async -> String {
    // Try native app first, then web fallback
    let appScheme: [String: String] = [
        "justeat":   "justeat://",
        "deliveroo": "deliveroo://",
        "ubereats":  "ubereats://",
        "glovo":     "glovo://",
        "doordash":  "doordash://",
    ]
    let webURL: [String: String] = [
        "justeat":   "https://www.justeat.it",
        "deliveroo": "https://deliveroo.com",
        "ubereats":  "https://www.ubereats.com",
        "glovo":     "https://glovoapp.com",
        "doordash":  "https://www.doordash.com",
    ]
    let svc = service.lowercased()
    let displayName = svc.isEmpty ? "food delivery" : service.capitalized

    if let scheme = appScheme[svc], let url = URL(string: scheme),
       await MainActor.run(resultType: Bool.self, body: { UIApplication.shared.canOpenURL(url) }) {
        await MainActor.run { UIApplication.shared.open(url) }
        return "Opening \(displayName)."
    }
    if let urlStr = webURL[svc], let url = URL(string: urlStr) {
        await MainActor.run { UIApplication.shared.open(url) }
        return "Opening \(displayName) in your browser."
    }
    // Generic fallback: web search
    let q = query.isEmpty ? "food delivery near me" : query
    let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
    if let url = URL(string: "https://www.google.com/search?q=\(encoded)") {
        await MainActor.run { UIApplication.shared.open(url) }
        return "Opening search for \(q)."
    }
    return "I couldn't open a food delivery app."
}
```

### Info.plist `LSApplicationQueriesSchemes`

Add: `justeat`, `deliveroo`, `ubereats`, `glovo`, `doordash` (whichever you target).

## Test plan after fix

| Input | Expected |
|---|---|
| "Order on JustEat" | JustEat app opens (if installed), else justeat.it in Safari |
| "Order from Deliveroo near me" | Deliveroo app opens with `query="near me"` |
| "Order food" (no service) | Web search "food delivery near me" |
| "Order a Kebab from Tariq" (no service) | Web search "kebab from tariq" |

## Files involved

| File | What |
|---|---|
| `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` | Add `FMWebOrderFoodTool` |
| `02_GIGI_APP/GIGI/GigiActionBridge.swift` | Add `case "web_order_food":` + `openFoodDeliveryApp()` |
| `02_GIGI_APP/GIGI/Info.plist` | Add app schemes to `LSApplicationQueriesSchemes` |
| `02_GIGI_APP/GIGI/GigiFoundationAgent.swift` | Add `web_order_food` to allowed primaryAction list in router prompt |

## Resolution

_(empty)_
