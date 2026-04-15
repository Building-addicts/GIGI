import AVFoundation
import CallKit
import Foundation
import UIKit

/// Integrazione CallKit (outgoing). Il sistema gestisce ancora la UI nativa delle chiamate in molti casi.
final class GigiCallKitManager: NSObject {
    static let shared = GigiCallKitManager()

    private let callController = CXCallController()
    private var provider: CXProvider!

    private override init() {
        super.init()
        setupProvider()
    }

    private func setupProvider() {
        let configuration = CXProviderConfiguration(localizedName: "GIGI")
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.phoneNumber]
        if let icon = UIImage(named: "AppIcon") {
            configuration.iconTemplateImageData = icon.pngData()
        }

        provider = CXProvider(configuration: configuration)
        provider.setDelegate(self, queue: nil)
    }

    func makeCall(to number: String, contactName: String? = nil) async throws {
        _ = contactName
        print("GIGI CallKit: Requesting call to \(number)")

        let handle = CXHandle(type: .phoneNumber, value: number)
        let callUUID = UUID()
        let startCallAction = CXStartCallAction(call: callUUID, handle: handle)
        let transaction = CXTransaction(action: startCallAction)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            callController.request(transaction) { error in
                if let error {
                    print("GIGI CallKit: ❌ request failed — \(error)")
                    continuation.resume(throwing: error)
                } else {
                    print("GIGI CallKit: ✅ transaction accepted")
                    continuation.resume()
                }
            }
        }
    }

    func endCall(callUUID: UUID) async throws {
        let endCallAction = CXEndCallAction(call: callUUID)
        let transaction = CXTransaction(action: endCallAction)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            callController.request(transaction) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

// MARK: - CXProviderDelegate

extension GigiCallKitManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        print("GIGI CallKit: Provider reset")
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        print("GIGI CallKit: perform CXStartCallAction")
        configureAudioSession()
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        action.fulfill()

        let uuid = action.callUUID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            provider.reportOutgoingCall(with: uuid, connectedAt: Date())
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        configureAudioSession()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        print("GIGI CallKit: Audio session activated")
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        print("GIGI CallKit: Audio session deactivated")
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
            try session.setActive(true)
        } catch {
            print("GIGI CallKit: Audio session error — \(error)")
        }
    }
}
