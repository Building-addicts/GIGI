import Foundation
import AVFoundation
import UIKit

// MARK: - GigiAudioSequestrator
// Manages AVAudioSession lifecycle and coordinates mic/speaker sharing
// between VAD capture, Realtime streaming, and TTS playback.
//
// Bluetooth strategy:
//   playAndRecord  -> .allowBluetoothHFP (mic + HFP playback, used for all states)
//   TTS playback stays in playAndRecord — switching to .playback causes OSStatus -50 on device.
//   prewarmBluetooth() is called at wake-word detection to start the 300-500ms HFP negotiation
//   before the earcon fires, so the first blip is never cut off.

final class GigiAudioSequestrator: NSObject {
    static let shared = GigiAudioSequestrator()

    private let session = AVAudioSession.sharedInstance()
    private var captureRefCount = 0   // mic users (VAD + Realtime)
    private var isSpeaking = false
    // Tracks app background state without hitting UIApplication on non-main threads.
    // Prevents deactivating the audio session in background — iOS starts a 30s kill timer
    // the moment the session goes inactive while the app is backgrounded.
    private var appIsBackground = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func handleDidEnterBackground() { appIsBackground = true }
    @objc private func handleDidBecomeActive()    { appIsBackground = false }

    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            print("GIGI Audio: Interruption began")
            // Pause VAD or Realtime if needed
            Task { @MainActor in
                GigiSmartOrchestrator.shared.stopListening()
            }
        case .ended:
            print("GIGI Audio: Interruption ended")
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                Task { @MainActor in
                    // Wait 1.5s for hardware to fully settle (e.g. after phone call ends).
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    // Wake word is now only valid inside Presence Mode.
                    if GigiAudioManager.shared.presenceMode {
                        GigiAudioManager.shared.startWakeWordListening()
                    }
                }
            }
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        switch reason {
        case .oldDeviceUnavailable:
            // BT device disconnected mid-conversation — reactivate so .defaultToSpeaker kicks in
            print("GIGI Audio: BT disconnected — falling back to speaker")
            if captureRefCount > 0 || isSpeaking { activatePlayAndRecord() }
        case .newDeviceAvailable:
            // BT device connected — re-apply category so it is picked up
            print("GIGI Audio: new audio route available")
            if captureRefCount > 0 { activatePlayAndRecord() }
        default:
            break
        }
    }

    // MARK: - Session state query (used by SoundEngine to skip redundant deactivation)

    var isSessionActive: Bool { captureRefCount > 0 || isSpeaking }

    // MARK: - Bluetooth pre-warm
    //
    // HFP profile negotiation takes 300-500ms. Call this at wake-word detection so the BT
    // stack is ready before the earcon fires and before VAD seizes the session.

    func prewarmBluetooth() {
        guard captureRefCount == 0, !isSpeaking else { return }
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            GigiDebugLogger.log("prewarmBluetooth: session active")
        } catch {
            print("GIGI Audio: prewarm — \(error.localizedDescription)")
        }
    }

    // MARK: - Microphone control

    func seizeControl() {
        GigiDebugLogger.log("seizeControl called (current refCount=\(captureRefCount))")
        captureRefCount += 1
        guard captureRefCount == 1 else { return }
        activatePlayAndRecord()
    }

    func releaseControl() {
        GigiDebugLogger.log("releaseControl called (current refCount=\(captureRefCount))")
        guard captureRefCount > 0 else {
            GigiDebugLogger.log("releaseControl IGNORED — refCount already 0")
            return
        }
        captureRefCount -= 1
        guard captureRefCount == 0, !isSpeaking else { return }
        deactivate()
    }

    // MARK: - TTS coordination (called by GigiSpeechService delegate)

    func notifySpeechStarted() {
        isSpeaking = true
        // Keep playAndRecord active for TTS — switching to .playback causes OSStatus -50.
        // .allowBluetoothHFP already routes audio to AirPods/BT for output; no category change needed.
        if captureRefCount == 0 {
            do {
                try session.setCategory(
                    .playAndRecord,
                    mode: .voiceChat,
                    options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP]
                )
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                print("GIGI Audio: TTS session — \(error.localizedDescription)")
            }
        }
    }

    func notifySpeechFinished() {
        isSpeaking = false
        if captureRefCount == 0 {
            deactivate()
        } else {
            // Mic still in use — restore playAndRecord
            activatePlayAndRecord()
        }
    }

    // MARK: - Private

    private func activatePlayAndRecord() {
        GigiDebugLogger.log("activatePlayAndRecord")
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                // .allowBluetoothHFP — AirPods/BT mic + compressed playback (HFP, required for recording)
                // .duckOthers        — lower Spotify/YouTube volume during interaction
                // .defaultToSpeaker  — fallback if BT device disconnects mid-turn
                options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            GigiDebugLogger.log("activatePlayAndRecord SUCCESS")
        } catch {
            print("GIGI Audio: seize — \(error.localizedDescription)")
            GigiDebugLogger.log("activatePlayAndRecord ERROR: \(error.localizedDescription)")
        }
    }

    private func deactivate() {
        guard !appIsBackground else {
            GigiDebugLogger.log("deactivate SKIPPED — app in background (keep session alive)")
            return
        }
        GigiDebugLogger.log("deactivate")
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            GigiDebugLogger.log("deactivate SUCCESS")
        } catch {
            print("GIGI Audio: release — \(error.localizedDescription)")
            GigiDebugLogger.log("deactivate ERROR: \(error.localizedDescription)")
        }
    }
}
