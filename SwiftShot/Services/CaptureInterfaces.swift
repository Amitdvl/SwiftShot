import AppKit

@MainActor
protocol ScreenCaptureProviding {
    func freeze(mode: CaptureMode) async throws -> [FrozenScreen]
    /// Window metadata belongs to interaction lifetime, independently of diagnostics.
    func freeze(mode: CaptureMode, selectorID: UUID) async throws -> [FrozenScreen]
    func captureWindow(id: UInt32, onDisplayID: UInt32) async throws -> FrozenWindow
    func captureWindow(id: UInt32, onDisplayID: UInt32, traceRunID: UUID?) async throws -> FrozenWindow
    func captureWindow(id: UInt32, onDisplayID: UInt32, selectorID: UUID, traceRunID: UUID?) async throws -> FrozenWindow
    func captureRegion(displayID: UInt32, rect: CGRect) async throws -> CGImage
    func invalidateDisplayCache()
    func invalidateWindowMetadata()
    func currentDisplayFrame(id: UInt32) -> CGRect?
}

extension ScreenCaptureProviding {
    func freeze(mode: CaptureMode, selectorID: UUID) async throws -> [FrozenScreen] {
        try await freeze(mode: mode)
    }
    func captureWindow(id: UInt32, onDisplayID: UInt32, selectorID: UUID, traceRunID: UUID?) async throws -> FrozenWindow {
        try await captureWindow(id: id, onDisplayID: onDisplayID, traceRunID: traceRunID)
    }
    func captureWindow(id: UInt32, onDisplayID: UInt32, traceRunID: UUID?) async throws -> FrozenWindow {
        try await captureWindow(id: id, onDisplayID: onDisplayID)
    }
    func captureWindow(id: UInt32, onDisplayID: UInt32) async throws -> FrozenWindow {
        throw CaptureError.failed("Live window capture is unavailable from this capture provider.")
    }
    func invalidateDisplayCache() {}
    func invalidateWindowMetadata() {}
    func currentDisplayFrame(id: UInt32) -> CGRect? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }?.frame
    }
    func captureRegion(displayID: UInt32, rect: CGRect) async throws -> CGImage {
        throw CaptureError.failed("Last-region capture is unavailable from this capture provider.")
    }
}

protocol CaptureRendering: Sendable {
    func render(_ request: RenderRequest) async throws -> RenderedCapture
    func renderImage(_ request: RenderRequest) async throws -> CGImage
    func clearCache() async
}

extension CaptureRendering {
    func renderImage(_ request: RenderRequest) async throws -> CGImage { try await render(request).image }
    func clearCache() async {}
}

protocol TextRecognizing: Sendable {
    func recognizeText(in image: CGImage) async throws -> String
}

enum CaptureSelectionPurpose: Sendable {
    case standard
    case scrolling
}

/// Separates interaction lifetime from asynchronous capture/export work.
@MainActor
struct CaptureActions {
    var latencyTraceRunID: UUID? = nil
    var captureWindow: (UInt32, UInt32) async throws -> FrozenWindow = { _, _ in throw CaptureError.failed("Live window capture is unavailable.") }
    var switchMode: (CaptureMode) -> Void = { _ in }
    var selectedRegion: (FrozenScreen, CGRect) -> Void = { _, _ in }
    var pin: (CaptureDocument) -> Void = { _ in }
    var copySmaller: (CaptureDocument) -> Void = { _ in }
    var saveSmaller: (CaptureDocument) -> Void = { _ in }
    var dragRenderer: (any CaptureRendering)? = nil
    var dragBegan: () -> Void = {}
    var dragEnded: () -> Void = {}
    var dragCanceled: () -> Void = {}
    var returnApplication: NSRunningApplication? = nil
    var selectorPresented: (() -> Void)? = nil
    var selectionCommitted: (() -> Void)? = nil
    var editorPresented: (() -> Void)? = nil
    var selectionPurpose: CaptureSelectionPurpose = .standard
}

@MainActor
protocol CapturePresenting: AnyObject {
    var activeDocument: CaptureDocument? { get }
    func configure(actions: CaptureActions)
    func present(screens: [FrozenScreen], mode: CaptureMode, style: CaptureStyle,
                 library: BackgroundLibrary, onDocument: @escaping (CaptureDocument) -> Void,
                 onCopy: @escaping (CaptureDocument) -> Void, onSave: @escaping (CaptureDocument) -> Void,
                 onOCR: @escaping (CaptureDocument) -> Void, onCancel: @escaping () -> Void,
                 onDiscard: @escaping (CaptureDocument) -> Void)
    func reopen(document: CaptureDocument, library: BackgroundLibrary,
                onCopy: @escaping (CaptureDocument) -> Void, onSave: @escaping (CaptureDocument) -> Void,
                onCancel: @escaping () -> Void, onDocument: @escaping (CaptureDocument) -> Void,
                onDiscard: @escaping (CaptureDocument) -> Void)
    func dismiss()
    func showStatus(_ message: String, isError: Bool)
}

extension CapturePresenting {
    func configure(actions: CaptureActions) {}
}

@MainActor
protocol FloatingCapturePresenting: AnyObject {
    func showRecent(document: CaptureDocument, backgroundURL: URL?, renderedImage: CGImage?,
                    title: String, onCopy: @escaping (CaptureDocument) -> Void, onEdit: @escaping (CaptureDocument) -> Void, onSave: @escaping (CaptureDocument) -> Void,
                    onPin: @escaping (CaptureDocument) -> Void) async throws
    func pin(document: CaptureDocument, backgroundURL: URL?,
             onCopy: @escaping (CaptureDocument) -> Void, onEdit: @escaping (CaptureDocument) -> Void, onSave: @escaping (CaptureDocument) -> Void) async throws
    func setCaptureHidden(_ hidden: Bool)
    func closeAll()
    func handleMemoryPressure()
}

extension FloatingCaptureController: FloatingCapturePresenting {}

@MainActor
protocol CaptureDirectoryPicking {
    func chooseDirectory() -> URL?
}

/// Native modal UI is isolated from navigation state and injectable in tests.
@MainActor
struct NativeCaptureDirectoryPicker: CaptureDirectoryPicking {
    func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose where SwiftShot saves screenshots"
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}
