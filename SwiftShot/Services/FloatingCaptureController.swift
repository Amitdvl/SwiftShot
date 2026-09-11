import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum FloatingCaptureError: LocalizedError {
    case pinLimit, pixelLimit, memoryLimit, invalidReservation, invalidGeometry, noDisplay, payloadTooLarge
    var errorDescription: String? {
        switch self {
        case .pinLimit: "Close a floating pin before adding another."
        case .pixelLimit: "These captures exceed the floating-image pixel limit. Close a pin and try again."
        case .memoryLimit: "There is not enough room in the floating-image memory budget. Close a pin and try again."
        case .invalidReservation: "This floating capture is already being prepared."
        case .invalidGeometry: "This capture cannot be displayed safely."
        case .noDisplay: "No display is available for the floating capture."
        case .payloadTooLarge: "This image is too large to drag safely. Save a smaller export instead."
        }
    }
}

/// Reservations include pending renders, displayed pins and the optional recent
/// thumbnail. This primitive is independently testable without creating windows.
struct FloatingCaptureBudget {
    enum Kind { case pin, recent }
    private struct Reservation { var kind: Kind; var pixels: Int; var bytes: Int }
    private let maxPins: Int
    private let maxPixels: Int
    private let maxBytes: Int
    private var reservations: [UUID: Reservation] = [:]
    var pinCount: Int { reservations.values.filter { $0.kind == .pin }.count }
    var retainedPixels: Int { reservations.values.reduce(0) { $0 + $1.pixels } }
    var retainedBytes: Int { reservations.values.reduce(0) { $0 + $1.bytes } }

    init(maxPins: Int = 8, maxPixels: Int = 64_000_000, maxBytes: Int = 320 * 1024 * 1024) {
        self.maxPins = max(0, min(16, maxPins))
        self.maxPixels = max(0, maxPixels)
        self.maxBytes = max(0, maxBytes)
    }

    mutating func reserve(id: UUID, kind: Kind, pixels: Int, bytes: Int) throws {
        guard pixels > 0, bytes > 0, reservations[id] == nil else { throw FloatingCaptureError.invalidReservation }
        if kind == .recent && reservations.values.contains(where: { $0.kind == .recent }) {
            throw FloatingCaptureError.invalidReservation
        }
        guard kind != .pin || pinCount < maxPins else { throw FloatingCaptureError.pinLimit }
        guard pixels <= maxPixels - retainedPixels else { throw FloatingCaptureError.pixelLimit }
        guard bytes <= maxBytes - retainedBytes else { throw FloatingCaptureError.memoryLimit }
        reservations[id] = Reservation(kind: kind, pixels: pixels, bytes: bytes)
    }
    mutating func release(id: UUID) { reservations.removeValue(forKey: id) }
}

@MainActor
struct FloatingCaptureSnapshot {
    let request: RenderRequest
    let isPrivate: Bool
    let isQuickCopy: Bool
    let workflow: CaptureWorkflow
    init(document: CaptureDocument, backgroundURL: URL?) {
        request = document.request(backgroundURL: backgroundURL)
        isPrivate = document.isPrivate
        isQuickCopy = document.isQuickCopy
        workflow = document.workflow
    }
    func editableDocument() -> CaptureDocument {
        let document = CaptureDocument(image: request.image, edits: request.edits, revision: request.revision)
        document.isPrivate = isPrivate
        document.isQuickCopy = isQuickCopy
        document.workflow = workflow
        return document
    }
    func flattenedDocument(image: CGImage) -> CaptureDocument {
        let document = CaptureDocument(image: image)
        document.isPrivate = isPrivate
        document.isQuickCopy = isQuickCopy
        document.workflow = workflow
        return document
    }

    /// Charge the original needed by Edit, the flattened displayed image, and
    /// its potential lazy PNG. Conservative row alignment avoids undercounting.
    func retentionCost(renderedImage: CGImage? = nil) throws -> (pixels: Int, bytes: Int, pngLimit: Int) {
        let crop = request.edits.crop
        let style = request.edits.style
        guard [crop.minX, crop.minY, crop.width, crop.height, style.padding].allSatisfy(\.isFinite),
              crop.width > 0, crop.height > 0, crop == crop.integral,
              CGRect(x: 0, y: 0, width: request.image.width, height: request.image.height).contains(crop),
              (0...16_384).contains(style.padding), request.edits.annotations.count <= 10_000 else {
            throw FloatingCaptureError.invalidGeometry
        }
        let padding = style.backgroundID.isEmpty ? 0 : Int(style.padding.rounded())
        let width = renderedImage?.width ?? (Int(crop.width) + padding * 2)
        let height = renderedImage?.height ?? (Int(crop.height) + padding * 2)
        guard width > 0, height > 0, width <= 32_768, height <= 32_768 else { throw FloatingCaptureError.invalidGeometry }
        let originalPixels = request.image.width.multipliedReportingOverflow(by: request.image.height)
        let originalBytes = request.image.bytesPerRow.multipliedReportingOverflow(by: request.image.height)
        let outputPixels = width * height
        guard !originalPixels.overflow, !originalBytes.overflow, originalPixels.partialValue <= 128_000_000,
              originalBytes.partialValue <= 1024 * 1024 * 1024, outputPixels <= 64_000_000 else {
            throw FloatingCaptureError.pixelLimit
        }
        let componentBytes = (renderedImage?.bitsPerComponent ?? request.image.bitsPerComponent) > 8 ? 8 : 4
        let outputBytes = max(((width * componentBytes + 63) / 64) * 64 * height,
                              (renderedImage?.bytesPerRow ?? 0) * height)
        let textBytes = request.edits.annotations.reduce(0) { $0 + $1.text.utf8.count * 2 }
        guard textBytes <= 2_097_152 else { throw FloatingCaptureError.memoryLimit }
        let metadata = textBytes + request.edits.annotations.count * MemoryLayout<CaptureAnnotation>.stride * 2 + 4096
        // PNG has small container/filter overhead beyond incompressible pixels.
        let pngLimit = outputBytes + outputBytes / 20 + 65_536
        return (originalPixels.partialValue + outputPixels, originalBytes.partialValue + outputBytes + pngLimit + metadata, pngLimit)
    }
}

/// All bitmap and PNG work for this controller is serialized. Cancellation is
/// propagated to queued tasks; a canceled predecessor is still awaited so an
/// uninterruptible ImageIO operation cannot overlap the next allocation.
actor FloatingRenderQueue {
    private let renderer: any CaptureRendering
    private var tail: Task<Void, Never>?
    private var pendingImages: [UUID: Task<CGImage, Error>] = [:]
    private var pendingPNG: [UUID: Task<Data, Error>] = [:]
    private var tailID: UUID?
    var pendingOperationCount: Int { pendingImages.count + pendingPNG.count }

    init(renderer: any CaptureRendering) { self.renderer = renderer }

    func image(_ request: RenderRequest) async throws -> CGImage {
        let predecessor = tail, renderer = renderer, id = UUID()
        let work = Task {
            if let predecessor { await predecessor.value }
            try Task.checkCancellation()
            return try await renderer.renderImage(request)
        }
        pendingImages[id] = work
        tailID = id
        tail = Task { _ = try? await work.value }
        defer {
            pendingImages.removeValue(forKey: id)
            if tailID == id { tail = nil; tailID = nil }
        }
        return try await withTaskCancellationHandler {
            let result = try await work.value
            try Task.checkCancellation()
            return result
        } onCancel: { work.cancel() }
    }

    func png(_ request: RenderRequest) async throws -> Data {
        let predecessor = tail, renderer = renderer, id = UUID()
        let work = Task {
            if let predecessor { await predecessor.value }
            try Task.checkCancellation()
            return try await renderer.render(request).png
        }
        pendingPNG[id] = work
        tailID = id
        tail = Task { _ = try? await work.value }
        defer {
            pendingPNG.removeValue(forKey: id)
            if tailID == id { tail = nil; tailID = nil }
        }
        return try await withTaskCancellationHandler {
            let result = try await work.value
            try Task.checkCancellation()
            return result
        } onCancel: { work.cancel() }
    }

    func cancelAll() {
        for task in pendingImages.values { task.cancel() }
        for task in pendingPNG.values { task.cancel() }
    }
}

actor FloatingCapturePayload {
    private var request: RenderRequest?
    private let queue: FloatingRenderQueue
    private let maximumPNGBytes: Int
    private var closed = false
    private var cachedPNG: Data?
    private var encoding: Task<Data, Error>?
    private var encodingID: UUID?

    init(image: CGImage, renderer: any CaptureRendering) {
        request = RenderRequest(image: image, edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: image.width, height: image.height)), backgroundURL: nil)
        queue = FloatingRenderQueue(renderer: renderer)
        maximumPNGBytes = 320 * 1024 * 1024
    }
    init(image: CGImage, queue: FloatingRenderQueue, maximumPNGBytes: Int) {
        request = RenderRequest(image: image, edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: image.width, height: image.height)), backgroundURL: nil)
        self.queue = queue
        self.maximumPNGBytes = maximumPNGBytes
    }

    func pngData() async throws -> Data {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        if let cachedPNG { return cachedPNG }
        let work: Task<Data, Error>
        let id: UUID
        if let existing = encoding, let existingID = encodingID { work = existing; id = existingID }
        else {
            guard let request else { throw CancellationError() }
            let queue = queue
            work = Task { try await queue.png(request) }
            id = UUID()
            encoding = work
            encodingID = id
        }
        do {
            let data = try await work.value
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            guard data.count <= maximumPNGBytes else { throw FloatingCaptureError.payloadTooLarge }
            cachedPNG = data
            if encodingID == id { encoding = nil; encodingID = nil }
            return data
        } catch {
            if encodingID == id { encoding = nil; encodingID = nil }
            throw error
        }
    }

    nonisolated func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = "SwiftShot.png"
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            let work = Task {
                do {
                    let data = try await self.pngData()
                    try Task.checkCancellation()
                    completion(data, nil)
                    progress.completedUnitCount = 1
                } catch { completion(nil, error) }
            }
            progress.cancellationHandler = { work.cancel() }
            return progress
        }
        return provider
    }

    func purgePNG() async {
        let task = encoding, id = encodingID
        task?.cancel()
        _ = try? await task?.value
        if encodingID == id { encoding = nil; encodingID = nil }
        cachedPNG = nil
    }

    func close() async {
        closed = true
        await purgePNG()
        // Destinations can retain NSItemProvider long after its panel closes.
        // Drain work before releasing the bitmap, then retain only the closed
        // provider shell so controller accounting reflects the released image.
        request = nil
    }
}

/// The sole owner of lazily-created transient panels. AppState supplies actions;
/// the controller never persists screenshots and never creates drag temp files.
@MainActor
final class FloatingCaptureController {
    private struct Entry {
        let kind: FloatingCaptureBudget.Kind
        let panel: FloatingCapturePanel
        let payload: FloatingCapturePayload
        let snapshot: FloatingCaptureSnapshot
        let image: CGImage
    }
    private let queue: FloatingRenderQueue
    private var budget: FloatingCaptureBudget
    private var entries: [UUID: Entry] = [:]
    private var pending: [UUID: Task<CGImage, Error>] = [:]
    private var pendingKinds: [UUID: FloatingCaptureBudget.Kind] = [:]
    private var recentID: UUID?
    private var recentGeneration = UUID()
    private var captureHidden = false
    private var retiring: [UUID: Task<Void, Never>] = [:]
    private var releaseWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    var pinCount: Int { entries.values.filter { $0.kind == .pin }.count }
    var retainedPixels: Int { budget.retainedPixels }
    var retainedBytes: Int { budget.retainedBytes }

    init(renderer: any CaptureRendering, budget: FloatingCaptureBudget = FloatingCaptureBudget()) {
        queue = FloatingRenderQueue(renderer: renderer)
        self.budget = budget
    }

    func showRecent(document: CaptureDocument, backgroundURL: URL?, renderedImage: CGImage? = nil,
                    title: String = "Recent Capture", onCopy: @escaping (CaptureDocument) -> Void,
                    onEdit: @escaping (CaptureDocument) -> Void,
                    onSave: @escaping (CaptureDocument) -> Void,
                    onPin: @escaping (CaptureDocument) -> Void) async throws {
        dismissRecent()
        let generation = UUID()
        recentGeneration = generation
        // A replaced thumbnail's reservation is retained until its pending
        // render/PNG tasks drain. Await that boundary before reserving the next.
        let canceledRecent = pending.keys.filter { pendingKinds[$0] == .recent }
        let retirements = Array(retiring.keys)
        for id in canceledRecent + retirements { await waitForRelease(id) }
        try Task.checkCancellation()
        guard recentGeneration == generation else { throw CancellationError() }
        try await present(kind: .recent, document: document, backgroundURL: backgroundURL, renderedImage: renderedImage,
                          recentGeneration: generation, recentTitle: title, onCopy: onCopy, onEdit: onEdit, onSave: onSave, onPin: onPin)
    }

    func pin(document: CaptureDocument, backgroundURL: URL?,
             onCopy: @escaping (CaptureDocument) -> Void, onEdit: @escaping (CaptureDocument) -> Void,
             onSave: @escaping (CaptureDocument) -> Void) async throws {
        try await present(kind: .pin, document: document, backgroundURL: backgroundURL, renderedImage: nil,
                          recentGeneration: nil, recentTitle: nil, onCopy: onCopy, onEdit: onEdit, onSave: onSave, onPin: nil)
    }

    private func present(kind: FloatingCaptureBudget.Kind, document: CaptureDocument, backgroundURL: URL?, renderedImage: CGImage?,
                         recentGeneration: UUID?, recentTitle: String?, onCopy: @escaping (CaptureDocument) -> Void,
                         onEdit: @escaping (CaptureDocument) -> Void,
                         onSave: @escaping (CaptureDocument) -> Void,
                         onPin: ((CaptureDocument) -> Void)?) async throws {
        try Task.checkCancellation()
        guard !document.isDiscarded else { throw CancellationError() }
        let snapshot = FloatingCaptureSnapshot(document: document, backgroundURL: backgroundURL)
        let cost = try snapshot.retentionCost(renderedImage: renderedImage)
        let id = UUID()
        try budget.reserve(id: id, kind: kind, pixels: cost.pixels, bytes: cost.bytes)
        let queue = queue, request = snapshot.request
        let work = Task { if let renderedImage { return renderedImage }; return try await queue.image(request) }
        pending[id] = work
        pendingKinds[id] = kind
        do {
            let image = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            try Task.checkCancellation()
            guard !document.isDiscarded, !work.isCancelled else { throw CancellationError() }
            if let recentGeneration, recentGeneration != self.recentGeneration { throw CancellationError() }
            guard let display = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else {
                throw FloatingCaptureError.noDisplay
            }
            let payload = FloatingCapturePayload(image: image, queue: queue, maximumPNGBytes: cost.pngLimit)
            let panel = Self.makePanel(kind: kind, image: image, visible: display.visibleFrame, cascadeIndex: entries.count)
            if let recentTitle { panel.title = recentTitle }
            let content = FloatingCaptureContent(image: image, payload: payload, isRecent: kind == .recent,
                onCopy: { onCopy(snapshot.flattenedDocument(image: image)) }, onEdit: { [weak self] in
                    let editable = snapshot.editableDocument()
                    if kind == .recent { self?.closeEntry(id) }
                    onEdit(editable)
                }, onSave: { onSave(snapshot.flattenedDocument(image: image)) },
                onPin: { [weak self] in
                    let flattened = snapshot.flattenedDocument(image: image)
                    self?.closeEntry(id)
                    Task { @MainActor [weak self] in
                        await self?.waitForRelease(id)
                        onPin?(flattened)
                    }
                }, onClose: { [weak self] in self?.closeEntry(id) })
            Self.installContent(content, in: panel)
            panel.onClose = { [weak self] in self?.closeEntry(id, closeWindow: false) }
            entries[id] = Entry(kind: kind, panel: panel, payload: payload, snapshot: snapshot, image: image)
            pending.removeValue(forKey: id)
            pendingKinds.removeValue(forKey: id)
            if kind == .recent { recentID = id }
            if !captureHidden { panel.orderFrontRegardless() } // Do not steal focus from the paste destination.
        } catch {
            pending.removeValue(forKey: id)
            pendingKinds.removeValue(forKey: id)
            releaseReservation(id)
            throw error
        }
    }

    func dismissRecent() {
        recentGeneration = UUID()
        for (id, task) in pending where pendingKinds[id] == .recent { task.cancel() }
        if let recentID { closeEntry(recentID) }
        recentID = nil
    }

    /// Hide only panels owned here while the next screenshot is frozen. Their
    /// payloads and user-created pins remain intact, without window enumeration.
    /// A user-created pin is source content and must stay visible so Window and
    /// Region capture can capture it. Only the optional recent thumbnail is
    /// transient capture chrome.
    func setCaptureHidden(_ hidden: Bool) {
        captureHidden = hidden
        for entry in entries.values where entry.kind == .recent {
            if hidden { entry.panel.orderOut(nil) }
            else { entry.panel.orderFrontRegardless() }
        }
    }

    func closeAll() {
        dismissRecent()
        for task in pending.values { task.cancel() }
        for id in Array(entries.keys) { closeEntry(id) }
    }

    func handleMemoryPressure() {
        dismissRecent()
        for task in pending.values { task.cancel() }
        // User pins remain visible. Only their regenerable PNG caches are purged.
        for entry in entries.values { Task { await entry.payload.purgePNG() } }
    }

    private func closeEntry(_ id: UUID, closeWindow: Bool = true) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        if recentID == id { recentID = nil }
        entry.panel.onClose = nil
        if closeWindow { entry.panel.orderOut(nil); entry.panel.close() }
        // Keep the reservation (and original/image owner) until cancellation has
        // drained. A newly-requested pin cannot reuse bytes still being encoded.
        let task = Task { [weak self, entry] in
            await entry.payload.close()
            self?.retiring.removeValue(forKey: id)
            self?.releaseReservation(id)
        }
        retiring[id] = task
    }

    private func waitForRelease(_ id: UUID) async {
        guard pending[id] != nil || retiring[id] != nil else { return }
        await withCheckedContinuation { releaseWaiters[id, default: []].append($0) }
    }

    private func releaseReservation(_ id: UUID) {
        budget.release(id: id)
        for waiter in releaseWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
    }

    static func installContent(_ content: FloatingCaptureContent, in panel: FloatingCapturePanel) {
        let initialFrame = panel.frame
        let hosting = NSHostingView(rootView: content)
        // The controller owns the window bounds and control-row minimum. A
        // screenshot's native-pixel ideal size must not resize the NSPanel.
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: panel.contentLayoutRect.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setFrame(initialFrame, display: false)
    }

    static func makePanel(kind: FloatingCaptureBudget.Kind, image: CGImage, visible: CGRect, cascadeIndex: Int = 0) -> FloatingCapturePanel {
        let controls: CGFloat = 44
        // Pins are intentionally compact; the image remains the focus and can
        // still be resized when a larger working surface is useful.
        let maximum = kind == .recent ? CGSize(width: 280, height: 200) : CGSize(width: 560, height: 420)
        let scale = min(maximum.width / CGFloat(image.width), maximum.height / CGFloat(image.height),
                        (visible.width - 40) / CGFloat(image.width), (visible.height - controls - 60) / CGFloat(image.height))
        let size = CGSize(width: max(220, CGFloat(image.width) * scale), height: max(100, CGFloat(image.height) * scale) + controls)
        let cascade = CGFloat(cascadeIndex % 6) * 26
        let origin = CGPoint(x: max(visible.minX + 12, visible.maxX - size.width - 24 - cascade),
                             y: max(visible.minY + 12, visible.minY + 24 + cascade))
        var style: NSWindow.StyleMask = [.titled, .closable, .nonactivatingPanel, .utilityWindow]
        if kind == .pin { style.insert(.resizable) }
        let panel = FloatingCapturePanel(contentRect: CGRect(origin: origin, size: size), styleMask: style, backing: .buffered, defer: false)
        panel.title = kind == .recent ? "Recent Capture" : "SwiftShot Pin"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentMinSize = NSSize(width: 220, height: 144)
        return panel
    }
}

final class FloatingCapturePanel: NSPanel {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func close() {
        let callback = onClose
        onClose = nil
        super.close()
        callback?()
    }
}

struct FloatingCaptureContent: View {
    let image: CGImage
    let payload: FloatingCapturePayload
    let isRecent: Bool
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onSave: () -> Void
    let onPin: () -> Void
    let onClose: () -> Void
    var body: some View {
        ZStack(alignment: .bottom) {
            FloatingEditedImageView(image: image)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
                // Reserve the compact control strip while keeping it visually
                // over the image, so pins do not grow a second toolbar row.
                .padding(.bottom, 44)
                .onDrag { payload.itemProvider() }
                .help("Drag this edited image into an app. Move the pin by its title bar.")
                .accessibilityLabel("Edited screenshot. Drag to share image.")
                .contextMenu {
                    Button("Copy", systemImage: "document.on.document", action: onCopy)
                    Button("Save", systemImage: "square.and.arrow.down", action: onSave)
                    Button("Edit", systemImage: "pencil.tip", action: onEdit)
                    if isRecent { Button("Pin to Screen", systemImage: "pin", action: onPin) }
                }
            HStack(spacing: 5) {
                Button("Copy", action: onCopy)
                    .buttonStyle(CaptureButtonStyle(prominent: true, compact: true))
                    .keyboardShortcut("c", modifiers: .command)
                    .help("Copy (⌘C)")
                Button(action: onSave) { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(CaptureButtonStyle(compact: true))
                    .accessibilityLabel("Save")
                    .help("Save (⌘S)")
                    .keyboardShortcut("s", modifiers: .command)
                Button(action: onEdit) { Image(systemName: "pencil.tip") }
                    .buttonStyle(CaptureButtonStyle(compact: true))
                    .accessibilityLabel("Edit capture").help("Edit (⌘E)")
                    .keyboardShortcut("e", modifiers: .command)
                Spacer(minLength: 0)
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(CaptureButtonStyle(compact: true))
                    .accessibilityLabel(isRecent ? "Dismiss recent capture" : "Close pin")
                    .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(CaptureButtonStyle())
            .padding(.horizontal, 5).padding(.vertical, 5)
            .captureChrome(capsule: true)
            .padding(.horizontal, 5)
            .frame(height: 44)
        }
    }
}

/// Only the image-view boundary is AppKit. SwiftUI owns controls and the native
/// NSItemProvider drag; image fitting never reads the original hidden pixels.
private struct FloatingEditedImageView: NSViewRepresentable {
    let image: CGImage
    final class Coordinator { var image: CGImage? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSImageView {
        let view = FloatingViewportImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.isEditable = false
        view.allowsCutCopyPaste = false
        view.animates = false
        return view
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        // Use the SwiftUI viewport, not NSImage.size (which deliberately remains
        // native pixels for the immutable image/drag contract). Zero is the
        // flexible minimum during unspecified or unbounded measurement passes.
        CGSize(width: proposal.width.map { $0.isFinite ? max(0, $0) : 0 } ?? 0,
               height: proposal.height.map { $0.isFinite ? max(0, $0) : 0 } ?? 0)
    }
    func updateNSView(_ view: NSImageView, context: Context) {
        if context.coordinator.image !== image {
            view.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            context.coordinator.image = image
        }
    }
}

private final class FloatingViewportImageView: NSImageView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}
