import Darwin
import Foundation
import UIKit
import Vision
import CoreGraphics

@MainActor
class GigiVisionAgent {
    static let shared = GigiVisionAgent()

    private init() {}

    // MARK: - Main execution
    func execute(action: VisionAction) async throws -> Bool {
        print("GIGI Vision: Starting \(action.type)")

        guard let screenshot = captureScreen() else {
            throw VisionError.screenshotFailed
        }

        let coordinates = try await findElement(
            in: screenshot,
            matching: action.targetText,
            type: action.type
        )

        guard let point = coordinates else {
            throw VisionError.elementNotFound
        }

        try await simulateTap(at: point)
        print("GIGI Vision: ✅ Tap executed at \(point)")
        return true
    }

    // MARK: - Screenshot capture (app/window only — not other apps’ UI)
    private func captureScreen() -> UIImage? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
        else { return nil }

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    // MARK: - Vision text recognition
    private func findElement(in image: UIImage, matching text: String, type: ActionType) async throws -> CGPoint? {
        guard let cgImage = image.cgImage else {
            throw VisionError.invalidImage
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGPoint?, Error>) in
            let request = VNRecognizeTextRequest { [weak self] request, error in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    Task { @MainActor in
                        let p = try? await self.findButtonHeuristic(in: image, type: type)
                        continuation.resume(returning: p)
                    }
                    return
                }

                let targetText = text.lowercased()
                let imageSize = CGSize(width: cgImage.width, height: cgImage.height)

                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let recognizedText = candidate.string.lowercased()

                    let isMatch: Bool
                    switch type {
                    case .call:
                        isMatch = recognizedText.contains("call")
                            || recognizedText.contains("dial")
                            || recognizedText.contains("chiama")
                            || candidate.string.contains("📞")
                    case .send:
                        isMatch = recognizedText.contains("send")
                            || recognizedText.contains("submit")
                            || recognizedText.contains("invia")
                            || candidate.string.contains("➤")
                            || recognizedText == ">"
                    case .tap:
                        isMatch = recognizedText.contains(targetText)
                    }

                    if isMatch {
                        let boundingBox = observation.boundingBox
                        let x = boundingBox.midX * imageSize.width
                        let y = (1 - boundingBox.midY) * imageSize.height
                        let point = CGPoint(x: x, y: y)
                        print("GIGI Vision: Found '\(candidate.string)' at \(point)")
                        continuation.resume(returning: point)
                        return
                    }
                }

                Task { @MainActor in
                    let p = try? await self.findButtonHeuristic(in: image, type: type)
                    continuation.resume(returning: p)
                }
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Button detection heuristic
    private func findButtonHeuristic(in image: UIImage, type: ActionType) async throws -> CGPoint? {
        let screenBounds = UIScreen.main.bounds
        switch type {
        case .call:
            return CGPoint(x: screenBounds.width / 2, y: screenBounds.height - 120)
        case .send:
            return CGPoint(x: screenBounds.width - 50, y: screenBounds.height - 60)
        case .tap:
            return CGPoint(x: screenBounds.width / 2, y: screenBounds.height / 2)
        }
    }

    // MARK: - Tap simulation (IOKit via dlopen — richiede privilegi / non App Store standard)
    private func simulateTap(at point: CGPoint) async throws {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            throw VisionError.iokitLoadFailed
        }
        defer { dlclose(handle) }

        typealias IOHIDEventSystemClientCreateFunc = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
        typealias IOHIDEventCreateDigitizerFingerEventFunc = @convention(c) (
            CFAllocator?, CFAbsoluteTime, UInt32, UInt32, UInt32,
            Float, Float, Float, Float, Float, Bool, Bool, UInt32
        ) -> UnsafeMutableRawPointer?
        typealias IOHIDEventSystemClientDispatchEventFunc = @convention(c) (
            UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
        ) -> Void

        guard let createClientSym = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let createEventSym = dlsym(handle, "IOHIDEventCreateDigitizerFingerEvent"),
              let dispatchSym = dlsym(handle, "IOHIDEventSystemClientDispatchEvent")
        else {
            throw VisionError.iokitSymbolsNotFound
        }

        let createClient = unsafeBitCast(createClientSym, to: IOHIDEventSystemClientCreateFunc.self)
        let createEvent = unsafeBitCast(createEventSym, to: IOHIDEventCreateDigitizerFingerEventFunc.self)
        let dispatch = unsafeBitCast(dispatchSym, to: IOHIDEventSystemClientDispatchEventFunc.self)

        guard let client = createClient(kCFAllocatorDefault) else {
            throw VisionError.hidClientCreationFailed
        }

        let screenSize = UIScreen.main.bounds.size
        let normalizedX = Float(point.x / screenSize.width)
        let normalizedY = Float(point.y / screenSize.height)
        let timestamp = CFAbsoluteTimeGetCurrent()

        if let downEvent = createEvent(
            kCFAllocatorDefault, timestamp, 3, 0, 2,
            normalizedX, normalizedY, 0, 0, 0, false, true, 0
        ) {
            dispatch(client, downEvent)
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        if let upEvent = createEvent(
            kCFAllocatorDefault, CFAbsoluteTimeGetCurrent(), 3, 0, 0,
            normalizedX, normalizedY, 0, 0, 0, false, false, 0
        ) {
            dispatch(client, upEvent)
        }
    }
}

// MARK: - Supporting types

enum ActionType {
    case call
    case send
    case tap
}

struct VisionAction {
    let type: ActionType
    let targetText: String
    let appBundleID: String?

    init(type: ActionType, targetText: String = "", appBundleID: String? = nil) {
        self.type = type
        self.targetText = targetText
        self.appBundleID = appBundleID
    }
}

enum VisionError: Error, LocalizedError {
    case screenshotFailed
    case invalidImage
    case elementNotFound
    case iokitLoadFailed
    case iokitSymbolsNotFound
    case hidClientCreationFailed

    var errorDescription: String? {
        switch self {
        case .screenshotFailed: return "Failed to capture screen"
        case .invalidImage: return "Invalid image format"
        case .elementNotFound: return "Could not find target element"
        case .iokitLoadFailed: return "Failed to load IOKit framework"
        case .iokitSymbolsNotFound: return "IOKit symbols not found"
        case .hidClientCreationFailed: return "Failed to create HID client"
        }
    }
}
