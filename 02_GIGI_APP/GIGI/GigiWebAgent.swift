import Foundation
import WebKit
import UIKit

extension Notification.Name {
    /// Posted when WhatsApp Web requires a QR scan (session not linked).
    static let gigiWhatsAppNeedsQR = Notification.Name("gigiWhatsAppNeedsQR")
}

// MARK: - WebScript (T-07) — automazioni sito estendibili

enum WebScript: Sendable {
    case whatsappSend(contact: String, message: String)
    case theforkBook(restaurant: String, time: String, guests: Int)
    case googleSearch(query: String)
}

// MARK: - Errors
enum GigiWebAgentError: Error, LocalizedError {
    case navigationFailed(String)
    case elementNotFound(String)
    case timeout(String)
    case jsError(String)

    var errorDescription: String? {
        switch self {
        case .navigationFailed(let m): return "Navigation failed: \(m)"
        case .elementNotFound(let s):  return "Element not found: \(s)"
        case .timeout(let m):          return "Timeout: \(m)"
        case .jsError(let m):          return "JS error: \(m)"
        }
    }
}

enum WhatsAppResult {
    case success
    case needsQR        // user must scan QR code once in GIGI
    case failed(String)
}

// MARK: - GigiWebAgent
//
// Hidden 1×1 pt WKWebView attached to the UIWindow. Cookies and storage persist across
// launches via WKWebsiteDataStore.default(). Desktop Chrome user-agent → full WhatsApp Web.
//
// Usage:
//   let ok = await GigiWebAgent.shared.sendWhatsApp(contact: "Marco", message: "hello")
//   let detail = await GigiWebAgent.shared.sendWhatsAppResult(contact: "Marco", message: "hello")

@MainActor
final class GigiWebAgent: NSObject {
    static let shared = GigiWebAgent()

    private(set) var webView: WKWebView!
    private var navContinuation: CheckedContinuation<Void, Error>?
    private var isAttached = false

    // iPhone-sized off-screen frame — WA Web needs a real viewport to mount React UI.
    // Using 1×1pt means chat-list, compose box, and send button never render.
    static let offScreenFrame = CGRect(x: -390, y: -844, width: 390, height: 844)

    private override init() {
        super.init()
        buildWebView()
    }

    // MARK: - Setup

    private func buildWebView() {
        let config = WKWebViewConfiguration()
        // Sessioni web (inclusi cookie HTTP) persistono tra i riavvii dell’app.
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // Frame: off-screen iPhone size. WA Web (React SPA) requires a real viewport —
        // a 1×1pt frame means the chat-list and compose elements never mount.
        webView = WKWebView(frame: Self.offScreenFrame, configuration: config)
        webView.navigationDelegate = self
        webView.isHidden = false          // not hidden — just positioned off-screen
        webView.alpha = 0                 // invisible: prevents accidental display
        webView.isUserInteractionEnabled = false  // no accidental touch events
        // Desktop Chrome UA → WhatsApp Web serves full app, not m.whatsapp.com
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) " +
            "Chrome/124.0.0.0 Safari/537.36"
    }

    /// Call once from GIGIApp after the window is ready.
    func attach(to window: UIWindow) {
        guard !isAttached else { return }
        window.addSubview(webView)
        window.sendSubviewToBack(webView)   // always behind app UI
        isAttached = true
        GigiDebugLogger.log("GIGI WebAgent: attached to window ✓")
    }

    /// Make the webview visible and on-screen for user interaction (QR scanning).
    func showInWindow(_ window: UIWindow) {
        webView.frame = window.bounds
        webView.alpha = 1
        webView.isUserInteractionEnabled = true
        webView.isHidden = false
        window.bringSubviewToFront(webView)
    }

    /// Return webview to off-screen headless state after user interaction.
    func hideFromWindow() {
        webView.frame = Self.offScreenFrame
        webView.alpha = 0
        webView.isUserInteractionEnabled = false
        if let window = webView.window { window.sendSubviewToBack(webView) }
    }

    // MARK: - Core: navigate (T-05)

    /// Carica un URL in background. Timeout default 15s.
    func navigate(to url: URL, timeout: TimeInterval = 15) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                try await withCheckedThrowingContinuation { cont in
                    self.navContinuation = cont
                    self.webView.load(URLRequest(url: url))
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw GigiWebAgentError.timeout("Navigation to \(url.host ?? url.absoluteString)")
            }
            _ = try await group.next()!
            group.cancelAll()
        }
    }

    // MARK: - Core: wait for element (polls via JS)

    /// Restituisce `true` se l’elemento compare entro il timeout; altrimenti `throws`.
    @discardableResult
    func waitForElement(selector: String, timeout: Double) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await js("document.querySelector('\(esc(selector))') !== null")) as? Bool == true {
                return true
            }
            try await Task.sleep(nanoseconds: 600_000_000)
        }
        throw GigiWebAgentError.elementNotFound(selector)
    }

    // MARK: - Core: click

    func click(_ selector: String) async throws {
        let found = try await js("""
            (function(){
                const el = document.querySelector('\(esc(selector))');
                if(!el) return false;
                el.focus(); el.click(); return true;
            })()
        """) as? Bool
        if found != true { throw GigiWebAgentError.elementNotFound("click: \(selector)") }
    }

    // MARK: - Core: type text

    func type(_ text: String, into selector: String) async throws {
        let e = esc(text)
        let found = try await js("""
            (function(){
                const el = document.querySelector('\(esc(selector))');
                if(!el) return false;
                el.focus();
                if(el.tagName === 'INPUT' || el.tagName === 'TEXTAREA'){
                    const setter = Object.getOwnPropertyDescriptor(
                        window.HTMLInputElement.prototype, 'value').set;
                    setter.call(el, '\(e)');
                    el.dispatchEvent(new Event('input', {bubbles:true}));
                } else {
                    // contenteditable (WhatsApp compose box) — execCommand deprecated;
                    // React requires InputEvent with inputType='insertText' to enable Send.
                    el.focus();
                    el.innerHTML = '';
                    const dt = new DataTransfer();
                    dt.setData('text/plain', '\(e)');
                    el.dispatchEvent(new ClipboardEvent('paste', {clipboardData: dt, bubbles: true}));
                    if((el.textContent || '').trim() === '') {
                        // ClipboardEvent paste blocked — fall back to execCommand
                        document.execCommand('insertText', false, '\(e)');
                    }
                    el.dispatchEvent(new InputEvent('input', {inputType:'insertText', data:'\(e)', bubbles:true}));
                }
                return true;
            })()
        """) as? Bool
        if found != true { throw GigiWebAgentError.elementNotFound("type: \(selector)") }
    }

    // MARK: - Core: press Enter

    func pressEnter(in selector: String) async throws {
        try await js("""
            (function(){
                const el = document.querySelector('\(esc(selector))');
                if(!el) return;
                ['keydown','keypress','keyup'].forEach(t => {
                    el.dispatchEvent(new KeyboardEvent(t, {
                        key:'Enter', code:'Enter', keyCode:13, bubbles:true, cancelable:true
                    }));
                });
            })()
        """)
    }

    // MARK: - T-05 — nomi API task plan

    func clickElement(selector: String) async throws {
        try await click(selector)
    }

    func typeText(_ text: String, inSelector: String) async throws {
        try await type(text, into: inSelector)
    }

    func evaluateJS(_ script: String) async throws -> Any? {
        try await js(script)
    }

    // MARK: - Core: evaluate JS

    @discardableResult
    func js(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { cont in
            webView.evaluateJavaScript(script) { result, error in
                if let error { cont.resume(throwing: GigiWebAgentError.jsError(error.localizedDescription)) }
                else         { cont.resume(returning: result) }
            }
        }
    }

    // MARK: - Helpers

    private func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "'",  with: "\\'")
         .replacingOccurrences(of: "\n", with: "\\n")
    }

    func currentHost() -> String? { webView.url?.host }
}

// MARK: - WKNavigationDelegate

extension GigiWebAgent: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.navContinuation?.resume(); self.navContinuation = nil }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError e: Error) {
        Task { @MainActor in
            self.navContinuation?.resume(throwing: GigiWebAgentError.navigationFailed(e.localizedDescription))
            self.navContinuation = nil
        }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError e: Error) {
        Task { @MainActor in
            self.navContinuation?.resume(throwing: GigiWebAgentError.navigationFailed(e.localizedDescription))
            self.navContinuation = nil
        }
    }
}

// MARK: - WhatsApp Web automation (T-06)

extension GigiWebAgent {

    private static let waURL = URL(string: "https://web.whatsapp.com")!

    // Selectors — WhatsApp Web 2024/2025
    private enum WASel {
        static let chatList   = "[data-testid='chat-list']"
        static let qrCode     = "canvas[aria-label='Scan me!'], [data-testid='qrcode'], div[data-ref]"
        static let searchBox  = "[data-testid='search-container'] [contenteditable='true']"
        static let chatRow    = "[data-testid='cell-frame-container']"
        static let msgInput   = "[data-testid='conversation-compose-box-input']"
        static let sendBtn    = "[data-testid='send'], button[aria-label='Send'], [data-testid='compose-btn-send']"
    }

    private enum WAState { case ready, qrRequired, loading }

    private func detectWAState() async -> WAState {
        let ready = (try? await js(
            "document.querySelector('\(esc(WASel.chatList))') !== null"
        )) as? Bool == true
        if ready { return .ready }

        // Use specific QR selectors only — avoid generic 'canvas' which matches profile
        // pics, loading spinners, and other non-QR elements on the page.
        let qr = (try? await js("""
            document.querySelector('canvas[aria-label="Scan me!"]') !== null ||
            document.querySelector('[data-testid="qrcode"]') !== null ||
            document.querySelector('div[data-ref][class*="qr"]') !== null ||
            document.querySelector('[data-ref][tabindex="0"]') !== null
        """)) as? Bool == true
        return qr ? .qrRequired : .loading
    }

    /// Returns `true` only if the web send succeeded; `false` triggers the `whatsapp://` fallback in `GigiActionBridge`.
    func sendWhatsApp(contact: String, message: String, phone: String = "") async -> Bool {
        if case .success = await sendWhatsAppResult(contact: contact, message: message, phone: phone) {
            return true
        }
        return false
    }

    /// Detailed result — QR needed, error, or success — used by banner and fallback logic.
    /// Pass `phone` (international digits, no +) for a faster direct-URL path that skips name search.
    func sendWhatsAppResult(contact: String, message: String, phone: String = "") async -> WhatsAppResult {
        // 1. Ensure WhatsApp Web is loaded (check session state first)
        let alreadyOnWA = currentHost() == "web.whatsapp.com"
        if !alreadyOnWA {
            do {
                GigiDebugLogger.log("GIGI WebAgent: navigating to WhatsApp Web...")
                try await navigate(to: Self.waURL, timeout: 25)
            } catch {
                return .failed("Can't reach WhatsApp Web. Check internet.")
            }
        }

        // 2. Wait for page init (up to 8s)
        var state: WAState = .loading
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            state = await detectWAState()
            if state != .loading { break }
        }

        switch state {
        case .qrRequired:
            GigiDebugLogger.log("GIGI WebAgent: QR scan needed")
            GigiSpeechService.shared.speak(
                "Per inviare messaggi su WhatsApp Web, scansiona il QR code in Impostazioni → WhatsApp."
            )
            NotificationCenter.default.post(name: .gigiWhatsAppNeedsQR, object: nil)
            return .needsQR
        case .loading:
            return .failed("WhatsApp Web didn't load in time.")
        case .ready: break
        }

        // 3. Fast path: direct URL with phone number pre-fills message, no search needed
        if !phone.isEmpty {
            return await sendViaDirectURL(phone: phone, message: message, contact: contact)
        }

        // 4. Slow path: search contact by name in chat list
        do {
            try await waitForElement(selector: WASel.chatList, timeout: 15)
        } catch {
            return .failed("Chat list not ready.")
        }

        do {
            try await click(WASel.searchBox)
            try await Task.sleep(nanoseconds: 300_000_000)
            try await type(contact, into: WASel.searchBox)
            try await Task.sleep(nanoseconds: 1_500_000_000)

            try await waitForElement(selector: WASel.chatRow, timeout: 4)
            try await click(WASel.chatRow)
            try await Task.sleep(nanoseconds: 800_000_000)

            try await waitForElement(selector: WASel.msgInput, timeout: 5)
            try await type(message, into: WASel.msgInput)
            try await Task.sleep(nanoseconds: 500_000_000)

            let sent = try await clickSendOrEnter()
            GigiDebugLogger.log("GIGI WebAgent: WhatsApp → \(contact): '\(message.prefix(30))' \(sent ? "✓" : "⚠ Enter fallback")")
            return .success

        } catch {
            GigiDebugLogger.log("GIGI WebAgent: automation error — \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    // Direct URL: navigate to https://web.whatsapp.com/send?phone=NUMBER&text=MESSAGE
    // WhatsApp Web pre-fills the compose box and enables the send button automatically.
    private func sendViaDirectURL(phone: String, message: String, contact: String) async -> WhatsAppResult {
        var cs = CharacterSet.urlQueryAllowed
        cs.remove(charactersIn: "+&=#?")
        let encodedMsg = message.addingPercentEncoding(withAllowedCharacters: cs) ?? message
        guard let url = URL(string: "https://web.whatsapp.com/send?phone=\(phone)&text=\(encodedMsg)") else {
            return .failed("Invalid phone number format.")
        }
        do {
            try await navigate(to: url, timeout: 20)
            // Page loads chat with pre-filled text — wait for send button to appear
            try await waitForElement(selector: WASel.sendBtn, timeout: 12)
            try await Task.sleep(nanoseconds: 600_000_000)

            let sent = try await clickSendOrEnter()
            try await Task.sleep(nanoseconds: 800_000_000)

            GigiDebugLogger.log("GIGI WebAgent: WhatsApp → \(contact): '\(message.prefix(30))' ✓ (direct URL)")
            return sent ? .success : .failed("Send button not found on direct URL page.")
        } catch {
            GigiDebugLogger.log("GIGI WebAgent: direct URL send failed — \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    // Click send button; fall back to Enter key if button not found. Returns true if button was clicked.
    @discardableResult
    private func clickSendOrEnter() async throws -> Bool {
        let btnClicked = (try? await js("""
            (function(){
                const selectors = [
                    '[data-testid="send"]',
                    '[data-testid="compose-btn-send"]',
                    'button[aria-label="Send"]',
                    'span[data-icon="send"]'
                ];
                for (const sel of selectors) {
                    const btn = document.querySelector(sel);
                    if (btn) { btn.click(); return true; }
                }
                return false;
            })()
        """)) as? Bool == true

        if !btnClicked {
            try await pressEnter(in: WASel.msgInput)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        return btnClicked
    }
}

// MARK: - WebScript runner + TheFork (T-07)

extension GigiWebAgent {

    /// Dispatcher per automazioni web dichiarative.
    func run(_ script: WebScript) async -> Bool {
        switch script {
        case .whatsappSend(let contact, let message):
            return await sendWhatsApp(contact: contact, message: message)
        case .theforkBook(let restaurant, let time, let guests):
            return await bookRestaurant(name: restaurant, time: time, guests: guests)
        case .googleSearch(let query):
            var c = CharacterSet.urlQueryAllowed
            c.remove(charactersIn: "&+?=#")
            let q = query.addingPercentEncoding(withAllowedCharacters: c) ?? query
            guard let url = URL(string: "https://www.google.com/search?q=\(q)") else { return false }
            do {
                try await navigate(to: url, timeout: 20)
                return true
            } catch {
                return false
            }
        }
    }

    /// TheFork restaurant booking (best-effort: site markup may change).
    func bookRestaurant(name: String, time: String, guests: Int) async -> Bool {
        await bookRestaurantTheFork(name: name, time: time, guests: guests)
    }

    private func bookRestaurantTheFork(name: String, time: String, guests: Int) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let identity = await loadBookingProfileFromMemory()

        var c = CharacterSet.urlQueryAllowed
        c.remove(charactersIn: "&+?=#")
        let q = trimmed.addingPercentEncoding(withAllowedCharacters: c) ?? trimmed
        guard let searchURL = URL(string: "https://www.thefork.it/search?q=\(q)") else { return false }

        do {
            try await navigate(to: searchURL, timeout: 25)
            try await Task.sleep(nanoseconds: 2_000_000_000)

            // Primo risultato ristorante (selettori generici).
            let clicked = (try? await js("""
                (function(){
                  const link = document.querySelector('a[href*="/restaurant/"], a[href*="/ristorante/"], [data-testid="restaurant-card"] a');
                  if (link) { link.click(); return true; }
                  const alt = document.querySelector('article a, .restaurant-card a');
                  if (alt) { alt.click(); return true; }
                  return false;
                })()
            """)) as? Bool == true

            if !clicked {
                GigiDebugLogger.log("GIGI WebAgent: TheFork — no clickable restaurant found for '\(trimmed)'")
                return false
            }

            try await Task.sleep(nanoseconds: 2_500_000_000)

            // Slot orario / ospiti: input o pulsanti testuali (euristiche).
            let slotHint = esc(time)
            _ = try? await js("""
                (function(){
                  const t = '\(slotHint)'.toLowerCase();
                  const candidates = Array.from(document.querySelectorAll('button, a, span, div[role="button"]'));
                  const hit = candidates.find(el => (el.textContent || '').toLowerCase().includes(t));
                  if (hit) { hit.click(); return true; }
                  return false;
                })()
            """)

            try await Task.sleep(nanoseconds: 1_000_000_000)

            let guestsStr = String(guests)
            _ = try? await js("""
                (function(){
                  const g = '\(esc(guestsStr))';
                  const candidates = Array.from(document.querySelectorAll('button, a, span, option'));
                  const hit = candidates.find(el => (el.textContent || '').trim() === g || (el.textContent || '').includes(g + ' '));
                  if (hit) { hit.click(); return true; }
                  return false;
                })()
            """)

            try await Task.sleep(nanoseconds: 1_000_000_000)

            // Form contatto da memoria (se presenti).
            if !identity.email.isEmpty {
                _ = try? await type(identity.email, into: "input[type='email'], input[name*='email' i], #email")
            }
            if !identity.phone.isEmpty {
                _ = try? await type(identity.phone, into: "input[type='tel'], input[name*='phone' i], #phone")
            }
            if !identity.name.isEmpty {
                _ = try? await type(identity.name, into: "input[name*='name' i]:not([name*='last']), #firstname, input[placeholder*='nome' i]")
            }

            // Pulsante prenota / conferma
            let confirmed = (try? await js("""
                (function(){
                  const labels = ['prenota', 'book', 'conferma', 'confirm', 'reserve'];
                  const candidates = Array.from(document.querySelectorAll('button, a[type="submit"], input[type="submit"]'));
                  for (const el of candidates) {
                    const txt = (el.textContent || el.value || '').toLowerCase();
                    if (labels.some(l => txt.includes(l))) { el.click(); return true; }
                  }
                  return false;
                })()
            """)) as? Bool == true

            if confirmed {
                GigiDebugLogger.log("GIGI WebAgent: TheFork — booking submitted (best-effort) for '\(trimmed)' @\(time) (\(guests) guests)")
                return true
            }

            GigiDebugLogger.log("GIGI WebAgent: TheFork — could not auto-confirm booking.")
            return false
        } catch {
            GigiDebugLogger.log("GIGI WebAgent: TheFork error — \(error.localizedDescription)")
            return false
        }
    }

    private func loadBookingProfileFromMemory() async -> (name: String, phone: String, email: String) {
        let name: String
        if let n = await GigiMemory.shared.recall("person:prenotazione_nome") {
            name = n
        } else {
            name = await GigiMemory.shared.recall("pref:nome") ?? ""
        }
        let phone: String
        if let p = await GigiMemory.shared.recall("person:telefono") {
            phone = p
        } else {
            phone = await GigiMemory.shared.recall("pref:telefono") ?? ""
        }
        let email: String
        if let e = await GigiMemory.shared.recall("person:email") {
            email = e
        } else {
            email = await GigiMemory.shared.recall("pref:email") ?? ""
        }
        return (name, phone, email)
    }
}
