import Foundation

enum WalkthroughStep: Identifiable, Equatable {
    case text(label: String, body: String)
    case copyable(label: String, body: String, command: String)

    var id: String {
        switch self {
        case .text(let label, let body):
            return "text:\(label):\(body)"
        case .copyable(let label, let body, let command):
            return "copyable:\(label):\(body):\(command)"
        }
    }
}

struct Walkthrough: Equatable {
    let intro: String?
    let steps: [WalkthroughStep]
}

enum Walkthroughs {
    static func forCheck(_ id: String) -> Walkthrough? {
        switch id {
        case "claude_cli_installed":
            return Walkthrough(
                intro: "GIGI needs Claude Code installed on the Mac/PC that runs the harness.",
                steps: [
                    .text(
                        label: "Install Claude Code",
                        body: "Install Claude Code from claude.com/code, then reopen the terminal you use for the harness."
                    ),
                    .copyable(
                        label: "Verify the binary",
                        body: "Run this on the harness machine. If it fails, update config.json with the real full path.",
                        command: "claude --version"
                    )
                ]
            )

        case "claude_cli_authenticated":
            return Walkthrough(
                intro: "The harness can see Claude Code, but Claude is not authenticated yet.",
                steps: [
                    .copyable(
                        label: "Login again",
                        body: "Run this in the same user account that starts the harness.",
                        command: "claude auth login"
                    ),
                    .copyable(
                        label: "Test one request",
                        body: "This confirms the CLI can answer without opening an interactive flow.",
                        command: "claude --print --model claude-haiku-4-5 ok"
                    )
                ]
            )

        case "config_secret_strength":
            return Walkthrough(
                intro: "The iOS bearer secret is empty, too short, or still a placeholder.",
                steps: [
                    .copyable(
                        label: "Generate a strong secret",
                        body: "Put the output in 03_HARNESS/server/config.json under ios.shared_secret.",
                        command: "openssl rand -hex 16"
                    ),
                    .text(
                        label: "Re-pair the phone",
                        body: "After changing the secret, open the pairing panel again and scan the new QR code from GIGI."
                    )
                ]
            )

        case "tunnel_mode_active":
            return Walkthrough(
                intro: "The harness is not exposing a reachable URL for iPhone traffic.",
                steps: [
                    .text(
                        label: "Enable tunnel mode",
                        body: "Open the harness panel and enable cloudflared/tunnel mode, then wait for a public HTTPS URL."
                    ),
                    .text(
                        label: "Pair with the tunnel URL",
                        body: "Once the tunnel is active, re-pair GIGI so the app stores the new gateway URL."
                    )
                ]
            )

        case "tunnel_running":
            return Walkthrough(
                intro: "Tunnel mode is configured, but the tunnel process is not currently running.",
                steps: [
                    .copyable(
                        label: "Restart the harness",
                        body: "Run this from the GIGI-harness folder on the machine hosting GIGI.",
                        command: "./start-harness.sh"
                    ),
                    .text(
                        label: "Check the panel",
                        body: "Wait until the panel shows the tunnel URL, then run diagnostics again."
                    )
                ]
            )

        case "cloudflared_binary":
            return Walkthrough(
                intro: "Tunnel mode needs the cloudflared command available on the harness machine.",
                steps: [
                    .copyable(
                        label: "Install with Homebrew",
                        body: "Use this on macOS if cloudflared is missing.",
                        command: "brew install cloudflared"
                    ),
                    .copyable(
                        label: "Verify install",
                        body: "The diagnostics should pass after this command prints a version.",
                        command: "cloudflared --version"
                    )
                ]
            )

        case "outbound_https":
            return Walkthrough(
                intro: "The harness cannot reach the public internet over HTTPS.",
                steps: [
                    .text(
                        label: "Check network blocks",
                        body: "Disable VPN/firewall rules that block outbound HTTPS, then confirm the machine can open https://cloudflare.com."
                    ),
                    .text(
                        label: "Retry diagnostics",
                        body: "Once HTTPS works from the harness machine, rerun the setup diagnostics."
                    )
                ]
            )

        case "port_7779_bound":
            return Walkthrough(
                intro: "The local harness API is not listening on port 7779.",
                steps: [
                    .copyable(
                        label: "Start the harness",
                        body: "Run this from the GIGI-harness folder.",
                        command: "./start-harness.sh"
                    ),
                    .text(
                        label: "Avoid duplicate servers",
                        body: "If another process already owns port 7779, stop it or change the harness port consistently in the app and server config."
                    )
                ]
            )

        case "disk_space":
            return Walkthrough(
                intro: "The harness machine is low on free disk space.",
                steps: [
                    .text(
                        label: "Free space",
                        body: "Delete old build products, logs, downloads, or unused simulator data, then run diagnostics again."
                    )
                ]
            )

        case "last_request_ago":
            return Walkthrough(
                intro: "The harness has not seen a recent request from the phone.",
                steps: [
                    .text(
                        label: "Wake the app",
                        body: "Open GIGI on the phone, keep it on the same network or tunnel pairing, then refresh diagnostics."
                    ),
                    .text(
                        label: "Re-pair if needed",
                        body: "If the phone was paired before a secret or URL change, scan the pairing QR again."
                    )
                ]
            )

        default:
            return nil
        }
    }
}
