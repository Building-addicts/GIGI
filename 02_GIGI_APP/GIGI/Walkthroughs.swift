import Foundation

// MARK: - Walkthroughs
//
// Hardcoded step-by-step guides for diagnostic checks that the harness
// can NOT auto-fix (P6.12). Mapped by checkId → Walkthrough. Steps can be:
//   .text(label, body)              — pure explanation
//   .copyable(label, body, command) — body + a copy-the-command button
//
// We deliberately keep these in Swift (not server JSON) because:
//   1. The instructions are platform-specific (Win/Mac/Linux) and the
//      iOS app can branch on UI vs the harness's cross-platform shape.
//   2. Walkthroughs evolve with iOS UX, not with backend versions.
//   3. Bundled means they show up even if the harness is unreachable
//      (which is exactly the failure mode we're walking the user
//      through).
//
// Not exhaustive: we cover the 5 user-actionable checks. Anything else
// falls back to the existing hint+action surface in DiagnosticView.

enum WalkthroughStep: Identifiable, Equatable {
    case text(label: String, body: String)
    case copyable(label: String, body: String, command: String)

    var id: String {
        switch self {
        case .text(let l, _):       return "t:\(l)"
        case .copyable(let l, _, _): return "c:\(l)"
        }
    }
}

struct Walkthrough: Equatable {
    let title: String
    let intro: String?           // optional 1-line "why" above the steps
    let steps: [WalkthroughStep]
}

enum Walkthroughs {

    /// Returns a walkthrough for the given check id, or nil if there
    /// isn't one (the hint+action fallback in DiagnosticView still works).
    static func forCheck(_ id: String) -> Walkthrough? {
        WALKTHROUGHS[id] ?? WALKTHROUGHS["_fallback_"]
    }

    private static let WALKTHROUGHS: [String: Walkthrough] = [

        "claude_cli_installed": Walkthrough(
            title: "Install Claude Code on your PC",
            intro: "GIGI delegates complex tasks to Claude running on your computer. You need Claude Code installed and an active subscription.",
            steps: [
                .text(
                    label: "Step 1 — Open Claude Code download page",
                    body: "On your PC, open https://claude.com/code in any browser."
                ),
                .text(
                    label: "Step 2 — Download and install",
                    body: "Pick your operating system (Windows / macOS / Linux), download the installer, and run it. Accept the default installation path."
                ),
                .text(
                    label: "Step 3 — Verify in a terminal",
                    body: "Open Terminal (macOS), PowerShell (Windows) or your favourite shell."
                ),
                .copyable(
                    label: "Step 4 — Confirm version",
                    body: "Paste this in the terminal. You should see a version number, not 'command not found'.",
                    command: "claude --version"
                ),
                .text(
                    label: "Step 5 — Come back here",
                    body: "GIGI auto-detects the install within 5 seconds. The check will turn green by itself."
                )
            ]
        ),

        "claude_cli_authenticated": Walkthrough(
            title: "Sign in to Claude on your PC",
            intro: "Claude Code is installed but not signed in. Use the same account where you have your Pro / Max subscription.",
            steps: [
                .text(
                    label: "Step 1 — Open a terminal on your PC",
                    body: "Windows: press Win+R, type powershell, press Enter.\nmacOS: Cmd+Space, type terminal, press Enter.\nLinux: open your usual shell."
                ),
                .copyable(
                    label: "Step 2 — Run the login command",
                    body: "Paste this and press Enter. Your browser will open the Claude sign-in page.",
                    command: "claude auth login"
                ),
                .text(
                    label: "Step 3 — Complete the sign-in",
                    body: "In the browser, sign in with the email associated with your Claude Pro or Max plan. Authorise the CLI when prompted."
                ),
                .text(
                    label: "Step 4 — Come back here",
                    body: "GIGI re-tests authentication every 5 seconds. The check turns green automatically as soon as Claude is logged in."
                )
            ]
        ),

        "outbound_https": Walkthrough(
            title: "Restore PC internet access",
            intro: "Your PC can't reach api.cloudflare.com. Without outbound HTTPS, the tunnel and Claude both fail.",
            steps: [
                .text(
                    label: "Step 1 — Check your network",
                    body: "Make sure Wi-Fi or Ethernet is connected on the PC. The taskbar / menubar icon should show 'connected'."
                ),
                .text(
                    label: "Step 2 — Test in a browser",
                    body: "On the PC, open https://api.cloudflare.com/client/v4/ — you should see a small JSON message, not a connection error."
                ),
                .text(
                    label: "Step 3 — Corporate / school networks",
                    body: "Some networks block outbound 443 to non-allowlisted hosts. Use a personal hotspot or your home network instead."
                ),
                .text(
                    label: "Step 4 — Router restart",
                    body: "If your home internet is genuinely down: unplug the router, wait 30 seconds, plug back in, wait a minute."
                ),
                .text(
                    label: "Step 5 — Recheck",
                    body: "Tap 'Recheck now' above. The check turns green as soon as Cloudflare is reachable."
                )
            ]
        ),

        "disk_space": Walkthrough(
            title: "Free up disk space on your PC",
            intro: "Less than 2 GB free. GIGI's transcripts and Claude session caches may fail to save.",
            steps: [
                .text(
                    label: "Step 1 — Find what's taking space",
                    body: "Windows: Settings → System → Storage.\nmacOS: Apple menu → About This Mac → More Info → Storage Settings.\nLinux: `df -h` in a terminal."
                ),
                .text(
                    label: "Step 2 — Common culprits",
                    body: "Old downloads, virtual machine images, Docker images, browser caches, ~/Library/Caches on macOS."
                ),
                .text(
                    label: "Step 3 — Clean up",
                    body: "Delete what you don't need. Aim for at least 5 GB free for breathing room."
                ),
                .text(
                    label: "Step 4 — Recheck",
                    body: "Tap 'Recheck now' above — the check turns green automatically once you have free space."
                )
            ]
        ),

        // Generic fallback referenced by the view when a check has hint+action
        // but no dedicated walkthrough. The view picks this up only if the
        // specific id isn't mapped above.
        "_fallback_": Walkthrough(
            title: "How to fix",
            intro: nil,
            steps: [
                .text(
                    label: "Read the hint above",
                    body: "It explains the cause."
                ),
                .text(
                    label: "Apply the suggested action",
                    body: "If a command is shown, copy it and paste it into a terminal on your PC."
                ),
                .text(
                    label: "Wait ~5 seconds",
                    body: "GIGI re-runs the diagnostic every 5 seconds. Fixed checks turn green automatically."
                )
            ]
        )
    ]
}
