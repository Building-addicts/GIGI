import SwiftUI
import UIKit

// MARK: - HarnessStatusCard (Phase 6C)
//
// Rich runtime snapshot rendered inside Settings → Harness when paired.
// Shows: tunnel mode, redacted URL (with "Copy full URL"), last request
// time, request count in the last hour, and a "Test latency" button
// that fires `/api/ios/health` and prints the round-trip in ms.
//
// Polls `/api/ios/status` every 15s while the view is visible.

struct HarnessStatusCard: View {
    @State private var snapshot: GigiHarnessClient.StatusSnapshot?
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var isMeasuringLatency = false
    @State private var latencyMs: Int?
    @State private var copiedToast: String?
    @State private var pollTask: Task<Void, Never>?

    let deviceName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            urlRow
            metricsRow
            latencyRow
        }
        .padding(.vertical, 4)
        .overlay(alignment: .top) {
            if let toast = copiedToast {
                Text(toast)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.85)))
                    .offset(y: -6)
                    .transition(.opacity)
            }
        }
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
    }

    // MARK: - Sub-rows

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: tunnelIcon)
                .foregroundColor(snapshot != nil ? .green : .secondary)
            Text(tunnelLabel)
                .font(.subheadline.weight(.semibold))
            if isLoading && snapshot == nil {
                ProgressView().scaleEffect(0.7)
            }
            Spacer()
        }
    }

    private var urlRow: some View {
        HStack {
            Text(snapshot?.publicUrlRedacted ?? "—")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                copyFullURL()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundColor(.purple)
            }
            .disabled(GigiHarnessClient.shared.pairedBaseURL == nil)
            .buttonStyle(.borderless)
        }
    }

    private var metricsRow: some View {
        HStack(spacing: 14) {
            metric(label: "Last", value: snapshot.flatMap(Self.relativeTime) ?? "—")
            metric(label: "Last hour", value: snapshot.map { "\($0.requestsLastHour) req" } ?? "—")
            Spacer()
        }
    }

    private var latencyRow: some View {
        HStack {
            Button {
                Task { await measureLatency() }
            } label: {
                HStack(spacing: 6) {
                    if isMeasuringLatency {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: "speedometer")
                    }
                    Text("Test latency")
                }
                .font(.caption.weight(.medium))
                .foregroundColor(.purple)
            }
            .disabled(isMeasuringLatency)
            .buttonStyle(.borderless)

            if let ms = latencyMs {
                Text("\(ms) ms")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(latencyColor(ms))
                    .padding(.leading, 4)
            }
            if let err = errorText, snapshot == nil {
                Spacer()
                Text(err)
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .lineLimit(1)
            }
        }
    }

    private func metric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundColor(.secondary)
            Text(value).font(.caption.weight(.medium))
        }
    }

    // MARK: - Derived display

    private var tunnelLabel: String {
        guard let mode = snapshot?.tunnelMode else { return deviceName ?? "Harness" }
        switch mode {
        case "quick":  return "Cloudflare Quick Tunnel"
        case "named":  return "Cloudflare Named Tunnel"
        case "lan":    return "LAN (mDNS)"
        case "manual": return "Manual / Tailscale"
        default:       return mode.capitalized
        }
    }

    private var tunnelIcon: String {
        switch snapshot?.tunnelMode {
        case "quick", "named": return "cloud.fill"
        case "lan":            return "wifi"
        case "manual":         return "network"
        default:               return "questionmark.circle"
        }
    }

    private static func relativeTime(_ snap: GigiHarnessClient.StatusSnapshot) -> String? {
        guard let iso = snap.lastRequestAt,
              let date = ISO8601DateFormatter().date(from: iso) else { return nil }
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "\(secs)s ago" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        return "\(secs / 3600)h ago"
    }

    private func latencyColor(_ ms: Int) -> Color {
        if ms < 300 { return .green }
        if ms < 1000 { return .yellow }
        return .orange
    }

    // MARK: - Actions

    private func copyFullURL() {
        guard let url = GigiHarnessClient.shared.pairedBaseURL else { return }
        UIPasteboard.general.string = url.absoluteString
        showToast("Copied")
    }

    private func showToast(_ text: String) {
        withAnimation(.easeIn(duration: 0.15)) { copiedToast = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) { copiedToast = nil }
            }
        }
    }

    private func measureLatency() async {
        isMeasuringLatency = true
        latencyMs = nil
        let start = Date()
        let result = await GigiHarnessClient.shared.health()
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        await MainActor.run {
            isMeasuringLatency = false
            switch result {
            case .success: latencyMs = elapsed
            case .failure: errorText = "Latency probe failed"
            }
        }
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        pollTask = Task {
            await fetchOnce()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { break }
                await fetchOnce()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func fetchOnce() async {
        let result = await GigiHarnessClient.shared.statusSnapshot()
        await MainActor.run {
            isLoading = false
            switch result {
            case .success(let snap):
                snapshot = snap
                errorText = nil
            case .failure:
                errorText = "Can't load status"
            }
        }
    }
}
