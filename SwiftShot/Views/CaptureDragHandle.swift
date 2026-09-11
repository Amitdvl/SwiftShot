import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum CaptureDragCompletion {
    static func dispatch(operation: NSDragOperation, onCopied: () -> Void, onCanceled: () -> Void) {
        if operation.contains(.copy) { onCopied() }
        else { onCanceled() }
    }
}

/// A narrowly scoped AppKit drag source: SwiftUI supplies one immutable action
/// request, and receives lifecycle callbacks without owning native sessions.
struct CaptureDragHandle: NSViewRepresentable {
    let request: RenderRequest
    let renderer: any CaptureRendering
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void
    var onDragCanceled: () -> Void = {}
    var onError: (Error) -> Void = { _ in NSSound.beep() }

    func makeNSView(context: Context) -> CaptureDragSourceView {
        let view = CaptureDragSourceView()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: CaptureDragSourceView, context: Context) {
        view.request = request
        view.renderer = renderer
        view.onDragBegan = onDragBegan
        view.onDragEnded = onDragEnded
        view.onDragCanceled = onDragCanceled
        view.onError = onError
    }
    static func dismantleNSView(_ view: CaptureDragSourceView, coordinator: ()) {
        view.cancelPreparation()
    }
}

struct PreparedCaptureDrag: @unchecked Sendable {
    let image: CGImage
    let png: Data

    /// Work begins on the drag gesture, never while the inspector is mounted.
    /// PNG preparation is asynchronous because native PNG pasteboard callbacks
    /// are synchronous. No renderer work or semaphore waits run in those callbacks.
    @MainActor static func prepare(request: RenderRequest, renderer: any CaptureRendering) async throws -> Self {
        let document = CaptureDocument(image: request.image, edits: request.edits, revision: request.revision)
        let snapshot = FloatingCaptureSnapshot(document: document, backgroundURL: request.backgroundURL)
        let cost = try snapshot.retentionCost()
        var budget = FloatingCaptureBudget(maxPins: 1)
        try budget.reserve(id: UUID(), kind: .pin, pixels: cost.pixels, bytes: cost.bytes)
        try Task.checkCancellation()
        let image = try await renderer.renderImage(request)
        try Task.checkCancellation()
        // The PNG producer sees only already-flattened pixels. It cannot export
        // the editable original or re-read a mutable background asset.
        let queue = FloatingRenderQueue(renderer: renderer)
        let payload = FloatingCapturePayload(image: image, queue: queue, maximumPNGBytes: cost.pngLimit)
        do {
            let png = try await payload.pngData()
            try Task.checkCancellation()
            await payload.close()
            return Self(image: image, png: png)
        } catch {
            await payload.close()
            throw error
        }
    }
}

enum CaptureDragFileWriter {
    /// The only filesystem write in this feature. AppKit supplies the exact
    /// user-selected drop URL; no staging directory, bookmark or temp file exists.
    static func write(png: Data, to destination: URL) throws {
        guard destination.isFileURL, destination.pathExtension.lowercased() == "png",
              png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try png.write(to: destination, options: .withoutOverwriting)
    }
}

private final class CaptureDragPromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let png: Data
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "SwiftShot.UserDropDestination"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    init(png: Data) { self.png = png }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        "SwiftShot.png"
    }
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }
    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                        completionHandler: @escaping (Error?) -> Void) {
        do { try CaptureDragFileWriter.write(png: png, to: url); completionHandler(nil) }
        catch { completionHandler(error) }
    }
}

/// One drag item supports image consumers and Finder file promises. The delegate
/// is strongly retained here because NSFilePromiseProvider.delegate is weak.
final class CaptureDragPasteboardWriter: NSFilePromiseProvider {
    private let png: Data
    private let retainedDelegate: CaptureDragPromiseDelegate
    init(png: Data) {
        self.png = png
        retainedDelegate = CaptureDragPromiseDelegate(png: png)
        super.init()
        fileType = UTType.png.identifier
        delegate = retainedDelegate
    }
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.png] + super.writableTypes(for: pasteboard).filter { $0 != .png }
    }
    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == .png ? .promised : super.writingOptions(forType: type, pasteboard: pasteboard)
    }
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .png ? png : super.pasteboardPropertyList(forType: type)
    }
}

@MainActor
final class CaptureDragSourceView: NSView, NSDraggingSource {
    var request: RenderRequest?
    var renderer: (any CaptureRendering)?
    var onDragBegan: () -> Void = {}
    var onDragEnded: () -> Void = {}
    var onDragCanceled: () -> Void = {}
    var onError: (Error) -> Void = { _ in NSSound.beep() }
    private var preparation: Task<Void, Never>?
    private var preparationID: UUID?
    private var activeWriter: CaptureDragPasteboardWriter?
    private var endAction: (() -> Void)?
    private var cancelAction: (() -> Void)?
    private var pressed = false
    private var failed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Drag edited image")
        toolTip = "Drag the edited PNG into an app or Finder."
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 170, height: 30) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2).stroke()
        let label = failed ? "Drag unavailable — retry" : (preparation == nil ? "Drag Edited Image" : "Preparing image…")
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12),
                                                        .foregroundColor: NSColor.labelColor]
        let size = (label as NSString).size(withAttributes: attributes)
        (label as NSString).draw(at: NSPoint(x: max(6, (bounds.width - size.width) / 2),
                                           y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
    override func mouseDown(with event: NSEvent) { pressed = true; failed = false; needsDisplay = true }
    override func mouseUp(with event: NSEvent) { pressed = false; cancelPreparation() }
    override func mouseDragged(with event: NSEvent) {
        guard pressed, preparation == nil, activeWriter == nil, let request, let renderer else { return }
        let id = UUID()
        preparationID = id
        let begin = onDragBegan, end = onDragEnded, cancel = onDragCanceled, errorHandler = onError
        preparation = Task { [weak self] in
            defer {
                if let self, self.preparationID == id {
                    self.preparation = nil; self.preparationID = nil; self.needsDisplay = true
                }
            }
            do {
                let prepared = try await PreparedCaptureDrag.prepare(request: request, renderer: renderer)
                try Task.checkCancellation()
                guard let self, self.preparationID == id, self.pressed,
                      NSEvent.pressedMouseButtons & 1 != 0, self.window != nil else { return }
                self.preparation = nil; self.preparationID = nil; self.needsDisplay = true
                let writer = CaptureDragPasteboardWriter(png: prepared.png)
                let item = NSDraggingItem(pasteboardWriter: writer)
                let scale = min(180 / CGFloat(prepared.image.width), 120 / CGFloat(prepared.image.height), 1)
                let size = NSSize(width: CGFloat(prepared.image.width) * scale, height: CGFloat(prepared.image.height) * scale)
                let point = self.convert(event.locationInWindow, from: nil)
                item.setDraggingFrame(NSRect(origin: NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), size: size),
                                      contents: NSImage(cgImage: prepared.image, size: size))
                self.activeWriter = writer
                self.endAction = end
                self.cancelAction = cancel
                let session = self.beginDraggingSession(with: [item], event: event, source: self)
                session.animatesToStartingPositionsOnCancelOrFail = false
                begin()
            } catch {
                guard let self, self.preparationID == id else { return }
                self.preparation = nil; self.preparationID = nil; self.needsDisplay = true
                if !(error is CancellationError) {
                    self.pressed = false
                    self.failed = true; self.toolTip = error.localizedDescription
                    errorHandler(error)
                }
            }
        }
        needsDisplay = true
    }
    func cancelPreparation() {
        preparation?.cancel()
        // Keep the in-flight owner until it drains; rapid canceled drags must
        // not overlap another bitmap/PNG preparation and bypass the byte cap.
        needsDisplay = true
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        pressed = false
        activeWriter = nil
        let end = endAction; endAction = nil
        let cancel = cancelAction; cancelAction = nil
        CaptureDragCompletion.dispatch(operation: operation, onCopied: { end?() }, onCanceled: { cancel?() })
    }
}
