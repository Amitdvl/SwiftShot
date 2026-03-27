import Foundation

// MARK: - App Settings (Persisted)

struct AppSettings: Codable, Sendable {
    var saveDirectory: String
    /// Selected background filename (without extension), or empty string for no background.
    var backgroundName: String = "green"
    var shortcuts: [ShortcutConfig] = ShortcutConfig.defaults

    var backgroundEnabled: Bool { !backgroundName.isEmpty }

    static var `default`: AppSettings {
        AppSettings(
            saveDirectory: NSHomeDirectory() + "/Desktop"
        )
    }
}

// MARK: - Capture Mode

enum CaptureMode: String, CaseIterable, Sendable {
    case region, fullscreen, window, ocr

    var label: String {
        switch self {
        case .region: "Capture Region"
        case .fullscreen: "Capture Fullscreen"
        case .window: "Capture Window"
        case .ocr: "OCR Region"
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

    var defaultShortcut: String {
        switch self {
        case .region: "⌘⇧2"
        case .fullscreen: "⌘⇧F"
        case .window: "⌘⇧D"
        case .ocr: "⌘⇧O"
        }
    }
}

// MARK: - Shortcut Config

struct ShortcutConfig: Codable, Identifiable, Sendable {
    var id: String { mode }
    let mode: String
    var keyCode: UInt32
    var modifiers: UInt32
    var enabled: Bool
    var displayString: String

    static let defaults: [ShortcutConfig] = [
        ShortcutConfig(mode: "region", keyCode: 0x13, modifiers: 0x000900, enabled: true, displayString: "⌘⇧2"),
        ShortcutConfig(mode: "fullscreen", keyCode: 0x03, modifiers: 0x000900, enabled: false, displayString: "⌘⇧F"),
        ShortcutConfig(mode: "window", keyCode: 0x02, modifiers: 0x000900, enabled: false, displayString: "⌘⇧D"),
        ShortcutConfig(mode: "ocr", keyCode: 0x1F, modifiers: 0x000900, enabled: false, displayString: "⌘⇧O"),
    ]
}
