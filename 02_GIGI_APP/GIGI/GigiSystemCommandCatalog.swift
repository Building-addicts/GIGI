import Foundation

// MARK: - GigiSystemCommandCatalog
//
// Canonical app-side registry for every command family the GIGI orchestrator is
// allowed to emit into the generated Talk to GIGI Shortcut. The generator must
// consume this same list conceptually: adding a command here means the Shortcut
// needs an execution branch before the feature is considered complete.

enum GigiSystemCommandID: String, CaseIterable, Equatable {
    case torch
    case volume
    case brightness
    case wifi
    case bluetooth
    case airplane
    case dnd
    case silent
    case lpm
    case screenshot
    case alarm
    case timer
    case reminder
    case music
    case weather
    case battery
    case location
    case event
    case spotify
    case youtube
    case amazon
    case maps
    case instagram
}

struct GigiSystemCommandDefinition: Equatable {
    let id: GigiSystemCommandID
    let parameterDescription: String
    let exampleMarker: String
    let shortcutAction: String
}

enum GigiSystemCommandCatalog {
    static let markerPrefix = "SYS"

    static let definitions: [GigiSystemCommandDefinition] = [
        .init(id: .torch,      parameterDescription: "on|off",        exampleMarker: "SYS:torch:on",          shortcutAction: "Set Flashlight"),
        .init(id: .volume,     parameterDescription: "0...100",       exampleMarker: "SYS:volume:30",         shortcutAction: "Set Volume"),
        .init(id: .brightness, parameterDescription: "0...100",       exampleMarker: "SYS:brightness:80",     shortcutAction: "Set Brightness"),
        .init(id: .wifi,       parameterDescription: "on|off",        exampleMarker: "SYS:wifi:off",          shortcutAction: "Set Wi-Fi"),
        .init(id: .bluetooth,  parameterDescription: "on|off",        exampleMarker: "SYS:bluetooth:on",      shortcutAction: "Set Bluetooth"),
        .init(id: .airplane,   parameterDescription: "on|off",        exampleMarker: "SYS:airplane:on",       shortcutAction: "Set Airplane Mode"),
        .init(id: .dnd,        parameterDescription: "on|off",        exampleMarker: "SYS:dnd:on",            shortcutAction: "Set Focus / Do Not Disturb"),
        .init(id: .silent,     parameterDescription: "on|off",        exampleMarker: "SYS:silent:on",         shortcutAction: "Set Silent Mode"),
        .init(id: .lpm,        parameterDescription: "on|off",        exampleMarker: "SYS:lpm:on",            shortcutAction: "Set Low Power Mode"),
        .init(id: .screenshot, parameterDescription: "empty",         exampleMarker: "SYS:screenshot:",       shortcutAction: "Take Screenshot + Save"),
        .init(id: .alarm,      parameterDescription: "HH-MM|Hpm",     exampleMarker: "SYS:alarm:07-30",       shortcutAction: "Create Alarm"),
        .init(id: .timer,      parameterDescription: "minutes",       exampleMarker: "SYS:timer:10",          shortcutAction: "Start Timer"),
        .init(id: .reminder,   parameterDescription: "raw text",      exampleMarker: "SYS:reminder:call Mom", shortcutAction: "Add Reminder"),
        .init(id: .music,      parameterDescription: "play|pause|next|prev", exampleMarker: "SYS:music:next", shortcutAction: "Music controls"),
        .init(id: .weather,    parameterDescription: "empty",         exampleMarker: "SYS:weather:",         shortcutAction: "Get Current Weather"),
        .init(id: .battery,    parameterDescription: "empty",         exampleMarker: "SYS:battery:",         shortcutAction: "Get Battery Level"),
        .init(id: .location,   parameterDescription: "empty",         exampleMarker: "SYS:location:",        shortcutAction: "Get Current Location"),
        .init(id: .event,      parameterDescription: "raw text",      exampleMarker: "SYS:event:Doctor 5pm", shortcutAction: "Add Calendar Event"),
        .init(id: .spotify,    parameterDescription: "raw query",     exampleMarker: "SYS:spotify:queen",     shortcutAction: "Open Spotify search"),
        .init(id: .youtube,    parameterDescription: "raw query",     exampleMarker: "SYS:youtube:lofi",      shortcutAction: "Open YouTube search"),
        .init(id: .amazon,     parameterDescription: "raw query",     exampleMarker: "SYS:amazon:shoes",      shortcutAction: "Open Amazon search"),
        .init(id: .maps,       parameterDescription: "raw query",     exampleMarker: "SYS:maps:Times Square", shortcutAction: "Open Maps route/search"),
        .init(id: .instagram,  parameterDescription: "raw query",     exampleMarker: "SYS:instagram:marco",   shortcutAction: "Open Instagram profile/search")
    ]

    static func marker(_ id: GigiSystemCommandID, _ parameter: String = "") -> String {
        "\(markerPrefix):\(id.rawValue):\(parameter)"
    }
}
