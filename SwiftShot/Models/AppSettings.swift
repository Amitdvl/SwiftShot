import Foundation

struct AppSettings: Codable, Sendable {
    var saveDirectory: String
    var style = CaptureStyle()
    var quickCopyStyle = CaptureStyle()
    var workflowStyles: [String: CaptureStyle] = [:]
    var presets: [CaptureStylePreset] = []
    var retentionSavedCount: Int?
    var lastRegion: CaptureRegionReference?
    func style(for workflow: CaptureWorkflow) -> CaptureStyle {
        if let explicit = workflowStyles[workflow.rawValue] { return explicit }
        if workflow == .quickCopy { return quickCopyStyle }
        if workflow == .region { return style } // Preserve the legacy Region preset.
        return CaptureStyle()
    }
    mutating func setStyle(_ style: CaptureStyle, for workflow: CaptureWorkflow) {
        workflowStyles[workflow.rawValue] = style
        if workflow == .region { self.style = style }
        if workflow == .quickCopy { quickCopyStyle = style }
    }
    var immediateCopy = false
    var privateCapture = false
    /// Recent captures stay out of the way until the user explicitly asks for
    /// a floating result (or pins one from the capture toolbar).
    var showRecentThumbnail = false
    var historyIndexingEnabled = true
    /// Zero keeps saved captures until explicit deletion. Unsaved/pinned captures are never age-pruned.
    var retentionDays = 0
    var shareMaxDimension = 2048
    var shortcuts: [ShortcutConfig] = ShortcutConfig.defaults

    var backgroundName: String { style.backgroundID.replacingOccurrences(of: "bundled:", with: "") }
    var backgroundEnabled: Bool { !style.backgroundID.isEmpty }
    static var `default`: AppSettings { AppSettings(saveDirectory: NSHomeDirectory() + "/Desktop") }
    init(saveDirectory: String) { self.saveDirectory = saveDirectory }
    private enum CodingKeys: String, CodingKey {
        case saveDirectory, style, quickCopyStyle, immediateCopy, privateCapture, showRecentThumbnail
        case historyIndexingEnabled, retentionDays, shareMaxDimension, shortcuts, backgroundName, version
        case workflowStyles, presets, retentionSavedCount, lastRegion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        saveDirectory = try container.decodeIfPresent(String.self, forKey: .saveDirectory) ?? Self.default.saveDirectory
        immediateCopy = try container.decodeIfPresent(Bool.self, forKey: .immediateCopy) ?? false
        privateCapture = try container.decodeIfPresent(Bool.self, forKey: .privateCapture) ?? false
        showRecentThumbnail = try container.decodeIfPresent(Bool.self, forKey: .showRecentThumbnail) ?? false
        historyIndexingEnabled = try container.decodeIfPresent(Bool.self, forKey: .historyIndexingEnabled) ?? true
        retentionDays = min(3650, max(0, try container.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 0))
        shareMaxDimension = min(8192, max(320, try container.decodeIfPresent(Int.self, forKey: .shareMaxDimension) ?? 2048))
        quickCopyStyle = try container.decodeIfPresent(CaptureStyle.self, forKey: .quickCopyStyle) ?? CaptureStyle()
        workflowStyles = try container.decodeIfPresent([String: CaptureStyle].self, forKey: .workflowStyles) ?? [:]
        workflowStyles = workflowStyles.filter { CaptureWorkflow(rawValue: $0.key) != nil }
        presets = Array((try container.decodeIfPresent([CaptureStylePreset].self, forKey: .presets) ?? []).prefix(32))
        retentionSavedCount = try container.decodeIfPresent(Int.self, forKey: .retentionSavedCount).map { min(10_000, max(1, $0)) }
        if let region = try container.decodeIfPresent(CaptureRegionReference.self, forKey: .lastRegion), region.isValid, !region.isPrivate {
            lastRegion = region
        }
        style = try container.decodeIfPresent(CaptureStyle.self, forKey: .style) ?? CaptureStyle()
        if !container.contains(.style), let legacy = try container.decodeIfPresent(String.self, forKey: .backgroundName), !legacy.isEmpty {
            style.backgroundID = "bundled:" + legacy
        }
        shortcuts = try container.decodeIfPresent([ShortcutConfig].self, forKey: .shortcuts) ?? ShortcutConfig.defaults
        if !shortcuts.contains(where: { $0.mode == "quickCopy" }),
           let quickCopy = ShortcutConfig.defaults.first(where: { $0.mode == "quickCopy" }) {
            shortcuts.append(quickCopy)
        }
        // Migrate only the exact mislabeled old default modifier pair.
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        if version < 2 {
            for index in shortcuts.indices where shortcuts[index].modifiers == 0x900 && shortcuts[index].displayString.hasPrefix("⌘⇧") {
                shortcuts[index].modifiers = 0x300
            }
        }
        // Version 2 encoded the old automatic floating thumbnail default. The
        // new behavior is opt-in, so migrate that legacy value off once while
        // preserving an explicit choice in current settings.
        if version < 3 { showRecentThumbnail = false }
        for index in shortcuts.indices { shortcuts[index].refreshLabel() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(3, forKey: .version)
        try container.encode(saveDirectory, forKey: .saveDirectory)
        try container.encode(style, forKey: .style)
        try container.encode(quickCopyStyle, forKey: .quickCopyStyle)
        try container.encode(workflowStyles, forKey: .workflowStyles)
        try container.encode(presets, forKey: .presets)
        try container.encodeIfPresent(retentionSavedCount, forKey: .retentionSavedCount)
        if let lastRegion, lastRegion.isValid, !lastRegion.isPrivate { try container.encode(lastRegion, forKey: .lastRegion) }
        try container.encode(immediateCopy, forKey: .immediateCopy)
        try container.encode(privateCapture, forKey: .privateCapture)
        try container.encode(showRecentThumbnail, forKey: .showRecentThumbnail)
        try container.encode(historyIndexingEnabled, forKey: .historyIndexingEnabled)
        try container.encode(retentionDays, forKey: .retentionDays)
        try container.encode(shareMaxDimension, forKey: .shareMaxDimension)
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
        ShortcutConfig(mode: "quickCopy", keyCode: 0x13, modifiers: 0xB00, enabled: true, displayString: "⌥⌘⇧2"),
        ShortcutConfig(mode: "fullscreen", keyCode: 0x03, modifiers: 0x300, enabled: false, displayString: "⌘⇧F"),
        ShortcutConfig(mode: "window", keyCode: 0x02, modifiers: 0x300, enabled: false, displayString: "⌘⇧D"),
        ShortcutConfig(mode: "ocr", keyCode: 0x1F, modifiers: 0x300, enabled: false, displayString: "⌘⇧O")
    ]
}
