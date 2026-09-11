import AppIntents

enum CaptureIntentMode: String, AppEnum {
    case region, window, fullscreen, ocr
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Capture Mode"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .region: "Region", .window: "Window", .fullscreen: "Fullscreen", .ocr: "Text Recognition"
    ]
    var captureMode: CaptureMode { CaptureMode(rawValue: rawValue) ?? .region }
}

enum CaptureIntentAction: Equatable, Sendable {
    case start(mode: CaptureMode, quickCopy: Bool, privateCapture: Bool)
    case lastRegion(quickCopy: Bool)
    case history
}

/// One injectable handoff for system entry points. No history text or image
/// content is donated to system search, Siri, or cloud services.
@MainActor
struct CaptureIntentRouter {
    static let shared = CaptureIntentRouter { action in try await AppState.shared.performIntent(action) }
    let handler: @MainActor (CaptureIntentAction) async throws -> Void
    func route(_ action: CaptureIntentAction) async throws { try await handler(action) }
}

struct StartSwiftShotCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Capture"
    static let description = IntentDescription("Open SwiftShot's selector, then choose a region or window. Text mode copies recognized text. Only Fullscreen captures immediately.")
    // Compatibility API: supportedModes cannot be required on macOS 14.
    static let openAppWhenRun = true
    @Parameter(title: "Mode", default: .region) var mode: CaptureIntentMode
    @Parameter(title: "Quick Copy", default: false) var quickCopy: Bool
    @Parameter(title: "Private Capture", default: false) var privateCapture: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Start \(\.$mode) capture") { \.$quickCopy; \.$privateCapture }
    }

    func perform() async throws -> some IntentResult {
        try await CaptureIntentRouter.shared.route(.start(mode: mode.captureMode, quickCopy: quickCopy, privateCapture: privateCapture))
        return .result()
    }
}

struct RecaptureLastRegionIntent: AppIntent {
    static let title: LocalizedStringResource = "Recapture Last Region"
    static let description = IntentDescription("Capture the previous region on the same display and resolution. Quick Copy copies to the clipboard and stays in memory until you save it.")
    static let openAppWhenRun = true
    @Parameter(title: "Quick Copy", default: true) var quickCopy: Bool

    func perform() async throws -> some IntentResult {
        try await CaptureIntentRouter.shared.route(.lastRegion(quickCopy: quickCopy))
        return .result()
    }
}

struct OpenSwiftShotHistoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Capture History"
    static let description = IntentDescription("Open local capture history to search, edit, pin, or combine screenshots.")
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult {
        try await CaptureIntentRouter.shared.route(.history)
        return .result()
    }
}

struct SwiftShotAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartSwiftShotCaptureIntent(), phrases: ["Start a capture with \(.applicationName)"],
            shortTitle: "Start Capture", systemImageName: "viewfinder")
        AppShortcut(intent: RecaptureLastRegionIntent(), phrases: ["Recapture the last region with \(.applicationName)"],
            shortTitle: "Recapture Region", systemImageName: "arrow.clockwise")
        AppShortcut(intent: OpenSwiftShotHistoryIntent(), phrases: ["Open capture history in \(.applicationName)"],
            shortTitle: "Capture History", systemImageName: "clock.arrow.circlepath")
    }
}
