import AppKit

@MainActor
protocol ScreenCaptureProviding {
    func freeze(mode: CaptureMode) async throws -> [FrozenScreen]
}

protocol CaptureRendering: Sendable {
    func render(_ request: RenderRequest) async throws -> RenderedCapture
}

protocol TextRecognizing: Sendable {
    func recognizeText(in image: CGImage) async throws -> String
}

/// Separates interaction lifetime from asynchronous capture/export work.
@MainActor
protocol CapturePresenting: AnyObject {
    var activeDocument: CaptureDocument? { get }
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
