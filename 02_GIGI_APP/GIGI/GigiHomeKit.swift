import Foundation
import HomeKit

// MARK: - GigiAccessory

struct GigiAccessory {
    let name: String
    let normalizedName: String
    let hmAccessory: HMAccessory
    let service: HMService

    var isPowerControllable: Bool {
        service.characteristics.contains { $0.characteristicType == HMCharacteristicTypePowerState }
    }
    var isBrightnessControllable: Bool {
        service.characteristics.contains { $0.characteristicType == HMCharacteristicTypeBrightness }
    }
    var isThermostat: Bool {
        service.serviceType == HMServiceTypeThermostat
    }
    var isLock: Bool {
        service.serviceType == HMServiceTypeLockMechanism
    }
}

// MARK: - GigiHomeKit (T-13 + T-14)
//
// HomeKit integration. Zero-tap light / thermostat / lock control via voice.
// Requires HomeKit capability in Xcode + NSHomeKitUsageDescription in Info.plist.

@MainActor
final class GigiHomeKit: NSObject {
    static let shared = GigiHomeKit()

    private let manager = HMHomeManager()
    private var delegate: HomeKitDelegate?
    private var cachedAccessories: [GigiAccessory] = []
    private var isLoaded = false

    private override init() {
        super.init()
        let d = HomeKitDelegate()
        d.engine = self
        manager.delegate = d
        delegate = d
    }

    // MARK: - Discovery

    func loadAccessories() async {
        guard !isLoaded else { return }
        // If homes already loaded (e.g. re-entry), just rebuild cache
        if !manager.homes.isEmpty {
            rebuildCache()
            isLoaded = true
            return
        }
        // Wait for delegate (with 3s timeout for auth/network)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var resumed = false
            delegate?.onHomeManagerReady = {
                guard !resumed else { return }
                resumed = true
                cont.resume()
            }
            // Timeout fallback
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard !resumed else { return }
                resumed = true
                cont.resume()
            }
        }
        rebuildCache()
        isLoaded = true
    }

    fileprivate func rebuildCache() {
        var result: [GigiAccessory] = []
        for home in manager.homes {
            for accessory in home.accessories {
                for service in accessory.services {
                    guard !service.characteristics.isEmpty else { continue }
                    let relevant = [
                        HMServiceTypeLightbulb,
                        HMServiceTypeOutlet,
                        HMServiceTypeSwitch,
                        HMServiceTypeThermostat,
                        HMServiceTypeLockMechanism,
                        HMServiceTypeFan,
                        HMServiceTypeAirPurifier,
                        HMServiceTypeHeaterCooler,
                    ]
                    guard relevant.contains(service.serviceType) else { continue }
                    result.append(GigiAccessory(
                        name: accessory.name,
                        normalizedName: normalize(accessory.name),
                        hmAccessory: accessory,
                        service: service
                    ))
                }
            }
        }
        cachedAccessories = result
    }

    // MARK: - Accessory control

    /// Power on/off — "accendi la luce del salotto" / "spegni la lampada"
    func setAccessoryPower(_ name: String, on: Bool) async -> String {
        await ensureLoaded()
        guard let acc = find(name) else { return notFoundMessage(name) }
        guard acc.isPowerControllable,
              let ch = acc.service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypePowerState })
        else { return "I can't control the power for \(acc.name)." }

        return await writeCharacteristic(ch, value: on as NSNumber, successMessage: "\(acc.name) is now \(on ? "on" : "off").")
    }

    /// Brightness 0–100 — "metti la luce al 40%"
    func setAccessoryBrightness(_ name: String, percent: Int) async -> String {
        await ensureLoaded()
        guard let acc = find(name) else { return notFoundMessage(name) }
        guard acc.isBrightnessControllable,
              let ch = acc.service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeBrightness })
        else { return "I can't adjust brightness for \(acc.name)." }

        let clamped = max(0, min(100, percent))
        return await writeCharacteristic(ch, value: clamped as NSNumber, successMessage: "\(acc.name) set to \(clamped)%.")
    }

    /// Thermostat target temperature (Celsius) — "metti il termostato a 21 gradi"
    func setThermostat(temperature: Double) async -> String {
        await ensureLoaded()
        guard let acc = cachedAccessories.first(where: { $0.isThermostat }),
              let ch = acc.service.characteristics.first(where: {
                  $0.characteristicType == HMCharacteristicTypeTargetTemperature
              })
        else { return "I couldn't find a thermostat." }

        return await writeCharacteristic(ch, value: temperature as NSNumber,
                                         successMessage: "Thermostat set to \(Int(temperature))°C.")
    }

    /// Lock / unlock door — "chiudi la porta" / "apri la porta"
    func setLock(_ name: String, locked: Bool) async -> String {
        await ensureLoaded()
        let query = name.isEmpty ? "door" : name
        let acc: GigiAccessory? = name.isEmpty
            ? cachedAccessories.first(where: { $0.isLock })
            : find(query)
        guard let acc, acc.isLock,
              let ch = acc.service.characteristics.first(where: {
                  $0.characteristicType == HMCharacteristicTypeTargetLockMechanismState
              })
        else { return "I couldn't find a lock." }

        let value: Int = locked ? 1 : 0
        return await writeCharacteristic(ch, value: value as NSNumber,
                                         successMessage: "\(acc.name) is now \(locked ? "locked" : "unlocked").")
    }

    // MARK: - T-14 Scenes

    /// Activates a HomeKit scene by name — "buonanotte", "film", "relax"
    func activateScene(_ name: String) async -> String {
        await ensureLoaded()
        let normalized = normalize(name)

        for home in manager.homes {
            if let scene = home.actionSets.first(where: {
                normalize($0.name).contains(normalized) || normalized.contains(normalize($0.name))
            }) {
                return await withCheckedContinuation { cont in
                    home.executeActionSet(scene) { err in
                        if let err {
                            cont.resume(returning: "Scene failed: \(err.localizedDescription)")
                        } else {
                            cont.resume(returning: "Scene '\(scene.name)' activated.")
                        }
                    }
                }
            }
        }

        // Built-in GIGI scenes
        switch normalized {
        case _ where normalized.contains("notte") || normalized.contains("night") || normalized.contains("sleep"):
            return await gigiSceneGoodnight()
        case _ where normalized.contains("cinema") || normalized.contains("film") || normalized.contains("movie"):
            return await gigiSceneCinema()
        case _ where normalized.contains("lavoro") || normalized.contains("work") || normalized.contains("office"):
            return await gigiSceneWork()
        default:
            return "I don't know a scene called '\(name)'."
        }
    }

    // MARK: - Built-in GIGI scenes

    private func gigiSceneGoodnight() async -> String {
        var results: [String] = []
        for acc in cachedAccessories {
            if acc.isPowerControllable {
                _ = await setAccessoryPower(acc.name, on: false)
                results.append(acc.name)
            }
        }
        _ = await setThermostat(temperature: 19)
        _ = await setLock("", locked: true)
        return results.isEmpty ? "Goodnight!" : "Lights off, thermostat at 19°, door locked. Goodnight!"
    }

    private func gigiSceneCinema() async -> String {
        var dimmed = 0
        for acc in cachedAccessories where acc.isBrightnessControllable {
            _ = await setAccessoryBrightness(acc.name, percent: 20)
            dimmed += 1
        }
        return dimmed > 0 ? "Cinema mode — lights dimmed to 20%. Enjoy!" : "Cinema mode set."
    }

    private func gigiSceneWork() async -> String {
        var lit = 0
        for acc in cachedAccessories where acc.isBrightnessControllable {
            _ = await setAccessoryBrightness(acc.name, percent: 100)
            lit += 1
        }
        _ = await setThermostat(temperature: 21)
        return "Work mode — lights at 100%, thermostat at 21°."
    }

    // MARK: - Helpers

    private func ensureLoaded() async {
        if !isLoaded { await loadAccessories() }
    }

    private func find(_ name: String) -> GigiAccessory? {
        let q = normalize(name)
        return cachedAccessories.first { acc in
            acc.normalizedName.contains(q) || q.contains(acc.normalizedName)
        }
    }

    private func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "luce", with: "light")
            .replacingOccurrences(of: "lampada", with: "light")
            .replacingOccurrences(of: "salotto", with: "living")
            .replacingOccurrences(of: "cucina", with: "kitchen")
            .replacingOccurrences(of: "camera", with: "bedroom")
            .replacingOccurrences(of: "bagno", with: "bathroom")
            .replacingOccurrences(of: "porta", with: "door")
            .replacingOccurrences(of: "serratura", with: "lock")
            .replacingOccurrences(of: "termostato", with: "thermostat")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func notFoundMessage(_ name: String) -> String {
        let names = cachedAccessories.map { $0.name }.prefix(4).joined(separator: ", ")
        return names.isEmpty
            ? "No HomeKit accessories found. Make sure they're added in the Home app."
            : "I couldn't find '\(name)'. Available: \(names)."
    }

    private func writeCharacteristic(_ ch: HMCharacteristic, value: NSNumber, successMessage: String) async -> String {
        await withCheckedContinuation { cont in
            ch.writeValue(value) { err in
                if let err {
                    cont.resume(returning: "Failed: \(err.localizedDescription)")
                } else {
                    cont.resume(returning: successMessage)
                }
            }
        }
    }

    // MARK: - Accessory list (for settings UI)

    func accessoryNames() async -> [String] {
        await ensureLoaded()
        return cachedAccessories.map { $0.name }
    }

    func invalidateCache() {
        isLoaded = false
        cachedAccessories = []
    }
}

// MARK: - HMHomeManager delegate

private final class HomeKitDelegate: NSObject, HMHomeManagerDelegate {
    weak var engine: GigiHomeKit?
    var onHomeManagerReady: (() -> Void)?

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in
            engine?.rebuildCache()
            onHomeManagerReady?()
            onHomeManagerReady = nil
        }
    }

    func homeManager(_ manager: HMHomeManager, didAdd home: HMHome) {
        Task { @MainActor in engine?.rebuildCache() }
    }

    func homeManager(_ manager: HMHomeManager, didRemove home: HMHome) {
        Task { @MainActor in engine?.rebuildCache() }
    }
}
