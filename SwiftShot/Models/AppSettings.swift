import Foundation

struct AppSettings: Codable, Sendable {
    var saveDirectory: String
    var style = CaptureStyle()
    var immediateCopy = false
    var shortcuts: [ShortcutConfig] = ShortcutConfig.defaults

    var backgroundName: String { style.backgroundID.replacingOccurrences(of: "bundled:", with: "") }
    var backgroundEnabled: Bool { !style.backgroundID.isEmpty }
    static var `default`: AppSettings { AppSettings(saveDirectory: NSHomeDirectory() + "/Desktop") }
    init(saveDirectory: String) { self.saveDirectory = saveDirectory }
    private enum CodingKeys: String, CodingKey { case saveDirectory, style, immediateCopy, shortcuts, backgroundName, version }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        saveDirectory = try container.decodeIfPresent(String.self, forKey: .saveDirectory) ?? Self.default.saveDirectory
        immediateCopy = try container.decodeIfPresent(Bool.self, forKey: .immediateCopy) ?? false
        style = try container.decodeIfPresent(CaptureStyle.self, forKey: .style) ?? CaptureStyle()
        if !container.contains(.style), let legacy = try container.decodeIfPresent(String.self, forKey: .backgroundName), !legacy.isEmpty {
            style.backgroundID = "bundled:" + legacy
        }
        shortcuts = try container.decodeIfPresent([ShortcutConfig].self, forKey: .shortcuts) ?? ShortcutConfig.defaults
        // Migrate only the exact mislabeled old default modifier pair.
        if (try container.decodeIfPresent(Int.self, forKey: .version) ?? 1) < 2 {
            for index in shortcuts.indices where shortcuts[index].modifiers == 0x900 && shortcuts[index].displayString.hasPrefix("⌘⇧") {
                shortcuts[index].modifiers = 0x300
            }
        }
        for index in shortcuts.indices { shortcuts[index].refreshLabel() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(2, forKey: .version)
        try container.encode(saveDirectory, forKey: .saveDirectory)
        try container.encode(style, forKey: .style)
        try container.encode(immediateCopy, forKey: .immediateCopy)
        try container.encode(shortcuts, forKey: .shortcuts)
    }
}

enum CaptureMode: String, CaseIterable, Sendable {
    case region, fullscreen, window, ocr
    var label: String {
        switch self {
        case .region: "Capture Region"
        case .fullscreen: "Capture Fullscreen"
        case .window: "Capture Window"
        case .ocr: "Copy Text from Screen"
        }
    }
    var icon: String {
        switch self {
        case .region: "crop"
        case .fullscreen: "desktopcomputer"
        case .window: "macwindow"
        case .ocr: "text.viewfinder"
        }
    }
    var defaultShortcut: String { ShortcutConfig.defaults.first(where: { $0.mode == rawValue })?.displayString ?? "" }
}

struct ShortcutConfig: Codable, Identifiable, Sendable {
    var id: String { mode }
    let mode: String
    var keyCode: UInt32
    var modifiers: UInt32
    var enabled: Bool
    var displayString: String

    mutating func refreshLabel() {
        let names: [UInt32: String] = [0x13: "2", 0x03: "F", 0x02: "D", 0x1F: "O"]
        displayString = (modifiers & 0x1000 != 0 ? "⌃" : "") + (modifiers & 0x800 != 0 ? "⌥" : "")
            + (modifiers & 0x100 != 0 ? "⌘" : "") + (modifiers & 0x200 != 0 ? "⇧" : "") + (names[keyCode] ?? "Key \(keyCode)")
    }

    static let defaults: [ShortcutConfig] = [
        ShortcutConfig(mode: "region", keyCode: 0x13, modifiers: 0x300, enabled: true, displayString: "⌘⇧2"),
        ShortcutConfig(mode: "fullscreen", keyCode: 0x03, modifiers: 0x300, enabled: false, displayString: "⌘⇧F"),
        ShortcutConfig(mode: "window", keyCode: 0x02, modifiers: 0x300, enabled: false, displayString: "⌘⇧D"),
        ShortcutConfig(mode: "ocr", keyCode: 0x1F, modifiers: 0x300, enabled: false, displayString: "⌘⇧O")
    ]
}
