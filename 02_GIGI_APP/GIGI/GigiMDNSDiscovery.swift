import Foundation
import Network

// MARK: - GigiMDNSDiscovery
//
// Browses the local Wi-Fi for `_gigi._tcp.local` services advertised by the
// harness when the user chose LAN-only mode. Returns a list of discovered
// peers (hostname + port + TXT record metadata). The pairing sheet uses the
// first discovered peer, or times out after ~10 seconds with a clear error.
//
// This file uses `Network.framework` (`NWBrowser`) — iOS 14+. The Info.plist
// must list `_gigi._tcp` under `NSBonjourServices`, otherwise the OS blocks
// the browse silently.

@MainActor
final class GigiMDNSDiscovery {

    struct DiscoveredPeer {
        let serviceName: String          // e.g. "armando-pc"
        let hostname: String             // e.g. "Armando-Pc.local"
        let port: UInt16                 // usually 7779
        let txt: [String: String]        // device, version, ...
    }

    private var browser: NWBrowser?
    private var onUpdate: (([DiscoveredPeer]) -> Void)?
    private(set) var peers: [DiscoveredPeer] = []

    /// Starts browsing. Calls `onUpdate` every time the peer list changes.
    /// The handler runs on the main actor so the caller can bind it to SwiftUI
    /// state directly.
    func start(onUpdate: @escaping ([DiscoveredPeer]) -> Void) {
        self.onUpdate = onUpdate
        peers.removeAll()

        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_gigi._tcp", domain: "local."),
            using: parameters
        )
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.peers = results.compactMap { Self.toPeer($0) }
                self.onUpdate?(self.peers)
            }
        }

        browser.stateUpdateHandler = { state in
            if case .failed(let err) = state {
                Task { @MainActor in
                    GigiDebugLogger.log("mDNS browse failed: \(err.localizedDescription)")
                }
            }
        }

        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        onUpdate = nil
    }

    /// Convenience: waits up to `timeout` seconds for at least one peer to
    /// appear, returning the first one found. Stops the browse on return.
    func waitForFirstPeer(timeout: TimeInterval = 10) async -> DiscoveredPeer? {
        if let first = peers.first { stop(); return first }
        return await withCheckedContinuation { (cont: CheckedContinuation<DiscoveredPeer?, Never>) in
            var resumed = false
            let resumeOnce: (DiscoveredPeer?) -> Void = { [weak self] peer in
                guard !resumed else { return }
                resumed = true
                self?.stop()
                cont.resume(returning: peer)
            }
            start { peers in
                if let first = peers.first { resumeOnce(first) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                resumeOnce(nil)
            }
        }
    }

    // MARK: - Parsing

    private static func toPeer(_ result: NWBrowser.Result) -> DiscoveredPeer? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        let txt: [String: String]
        switch result.metadata {
        case .bonjour(let record):
            txt = record.dictionary
        default:
            txt = [:]
        }
        // NWBrowser doesn't give us the IP/port at browse time — resolving
        // happens later when we attach an NWConnection. The pair sheet uses
        // the hostname directly so we synthesize `<name>.local`.
        return DiscoveredPeer(
            serviceName: name,
            hostname:    "\(name).local",
            port:        UInt16(txt["port"].flatMap(UInt16.init) ?? 7779),
            txt:         txt
        )
    }
}
