import AppKit
import SwiftUI
import Observation

/// AppKit owns the panels; the session owns exactly one editable capture.
@MainActor
final class CaptureOverlayController: CapturePresenting {
    private var panels: [CaptureOverlayPanel] = []
    private var session: OverlaySession?
    private var keyMonitor: Any?
    private var displayObserver: NSObjectProtocol?
    private var previousApplication: NSRunningApplication?
    var activeDocument: CaptureDocument? { session?.document }

    func present(screens: [FrozenScreen], mode: CaptureMode, style: CaptureStyle,
                 library: BackgroundLibrary, onDocument: @escaping (CaptureDocument) -> Void,
                 onCopy: @escaping (CaptureDocument) -> Void, onSave: @escaping (CaptureDocument) -> Void,
                 onOCR: @escaping (CaptureDocument) -> Void, onCancel: @escaping () -> Void,
                 onDiscard: @escaping (CaptureDocument) -> Void = { _ in }) {
        dismiss()
        let session = OverlaySession(mode: mode, style: style, library: library,
                                     onDocument: onDocument, onCopy: onCopy, onSave: onSave,
                                     onOCR: onOCR, onCancel: onCancel, onDiscard: onDiscard)
        self.session = session
        show(screens: screens, session: session)
        if mode == .fullscreen, let screen = screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? screens.first {
            session.select(screen: screen, crop: CGRect(x: 0, y: 0, width: screen.image.width, height: screen.image.height))
        }
    }

    func reopen(document: CaptureDocument, library: BackgroundLibrary,
                onCopy: @escaping (CaptureDocument) -> Void, onSave: @escaping (CaptureDocument) -> Void,
                onCancel: @escaping () -> Void, onDocument: @escaping (CaptureDocument) -> Void = { _ in },
                onDiscard: @escaping (CaptureDocument) -> Void = { _ in }) {
        dismiss()
        guard let display = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let screen = FrozenScreen(id: 0, frame: display.frame, image: document.image, windows: [])
        let session = OverlaySession(mode: .region, style: document.edits.style, library: library,
                                     onDocument: onDocument, onCopy: onCopy, onSave: onSave,
                                     onOCR: { _ in }, onCancel: onCancel, onDiscard: onDiscard)
        session.document = document
        session.activeScreenID = screen.id
        self.session = session
        show(screens: [screen], session: session)
    }

    private func show(screens: [FrozenScreen], session: OverlaySession) {
        if let application = NSWorkspace.shared.frontmostApplication, application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = application
        }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self, weak session] _ in
            Task { @MainActor in
                guard let session, self?.session === session else { return }
                session.commitStyle()
                session.onCancel()
                NotificationService.showToast(title: "Display layout changed", subtitle: "Capture again on the current display. Your selected capture is available in Reopen Last Capture.")
            }
        }
        for screen in screens {
            let panel = CaptureOverlayPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isOpaque = true
            panel.backgroundColor = .black
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.acceptsMouseMovedEvents = true
            panel.contentView = NSHostingView(rootView: CaptureOverlayView(screen: screen, session: session))
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        NSApp.activate(ignoringOtherApps: true)
        (panels.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? panels.first)?.makeKey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let session = self.session, let keyWindow = NSApp.keyWindow,
                  self.panels.contains(where: { $0 === keyWindow }), keyWindow.attachedSheet == nil else { return event }
            // Text editing retains ordinary typing and native text undo/copy.
            let isTextEditing = keyWindow.firstResponder is NSTextView
            if isTextEditing { return event }
            if event.keyCode == 53 {
                session.commitStyle()
                if session.activePopover != nil { session.activePopover = nil }
                else if session.annotationTool != nil { session.annotationTool = nil }
                else { session.onCancel() }
                return nil
            }
            guard !isTextEditing, event.modifierFlags.contains(.command), let document = session.document else { return event }
            session.commitStyle()
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": session.onCopy(document)
            case "s": session.onSave(document)
            case "z":
                if event.modifierFlags.contains(.shift) { document.redo() } else { document.undo() }
                session.changed()
            default: return event
            }
            return nil
        }
    }

    func showStatus(_ message: String, isError: Bool = false) {
        session?.status = message
        session?.statusIsError = isError
    }

    func dismiss() {
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        displayObserver = nil
        let shouldRestoreFocus = NSApp.isActive && !panels.isEmpty
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels.removeAll()
        session = nil
        if shouldRestoreFocus { previousApplication?.activate(options: []) }
        previousApplication = nil
    }
}

private final class CaptureOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor @Observable
final class OverlaySession {
    enum Popover { case backgrounds, annotations, more }
    let mode: CaptureMode
    let initialStyle: CaptureStyle
    let library: BackgroundLibrary
    var activeScreenID: UInt32?
    /// Placement of a preacquired window image in the frozen display’s local points.
    var imagePlacement: CGRect?
    var document: CaptureDocument?
    var cropMode = false
    var previewStyle: CaptureStyle?
    var effectiveStyle: CaptureStyle { previewStyle ?? document?.edits.style ?? initialStyle }
    var annotationTool: CaptureAnnotation.Kind?
    var activePopover: Popover?
    var status = ""
    var statusIsError = false
    let onDocument: (CaptureDocument) -> Void
    let onCopy: (CaptureDocument) -> Void
    let onSave: (CaptureDocument) -> Void
    let onOCR: (CaptureDocument) -> Void
    let onCancel: () -> Void
    let onDiscard: (CaptureDocument) -> Void

    init(mode: CaptureMode, style: CaptureStyle, library: BackgroundLibrary,
         onDocument: @escaping (CaptureDocument) -> Void, onCopy: @escaping (CaptureDocument) -> Void,
         onSave: @escaping (CaptureDocument) -> Void, onOCR: @escaping (CaptureDocument) -> Void,
         onCancel: @escaping () -> Void, onDiscard: @escaping (CaptureDocument) -> Void = { _ in }) {
        self.mode = mode; initialStyle = style; self.library = library
        self.onDocument = onDocument; self.onCopy = onCopy; self.onSave = onSave
        self.onOCR = onOCR; self.onCancel = onCancel; self.onDiscard = onDiscard
    }

    func select(screen: FrozenScreen, crop: CGRect) {
        let document = CaptureDocument(image: screen.image, edits: CaptureEdits(crop: crop, style: initialStyle))
        imagePlacement = nil
        activeScreenID = screen.id
        self.document = document
        cropMode = false
        status = ""
        onDocument(document)
        if mode == .ocr { onOCR(document) }
    }

    func select(window: FrozenWindow, on screen: FrozenScreen) {
        guard let snapshot = window.snapshot else {
            status = "This window could not be frozen. Cancel and try again."
            statusIsError = true
            return
        }
        let document = CaptureDocument(image: snapshot, style: initialStyle)
        imagePlacement = window.frame
        activeScreenID = screen.id
        self.document = document
        cropMode = false
        status = ""
        statusIsError = false
        onDocument(document)
    }

    func commitStyle() {
        guard let style = previewStyle, let document else { return }
        document.change { $0.style = style }
        previewStyle = nil
        changed()
    }

    func changed() {
        status = ""
        statusIsError = false
        if let document {
            do { try library.restoreForEdit(id: document.edits.style.backgroundID) }
            catch {
                status = "This background is unavailable. Choose another background or None."
                statusIsError = true
            }
            onDocument(document)
        }
    }
}

/// Pure point/pixel transforms. Cross-display selections are always clipped to their starting display.
enum OverlayGeometry {
    static func imageFrame(imageSize: CGSize, screenSize: CGSize) -> CGRect {
        let scale = min(screenSize.width / imageSize.width, screenSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (screenSize.width - size.width) / 2, y: (screenSize.height - size.height) / 2, width: size.width, height: size.height)
    }

    static func clamped(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    static func rectangle(from start: CGPoint, to end: CGPoint, bounds: CGRect) -> CGRect {
        let a = clamped(start, to: bounds), b = clamped(end, to: bounds)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func pixels(from rect: CGRect, imageFrame: CGRect, pixelSize: CGSize) -> CGRect {
        let sx = pixelSize.width / imageFrame.width, sy = pixelSize.height / imageFrame.height
        let value = CGRect(x: (rect.minX - imageFrame.minX) * sx, y: (rect.minY - imageFrame.minY) * sy,
                           width: rect.width * sx, height: rect.height * sy)
        return value.integral.intersection(CGRect(origin: .zero, size: pixelSize))
    }

    static func points(from rect: CGRect, imageFrame: CGRect, pixelSize: CGSize) -> CGRect {
        let sx = imageFrame.width / pixelSize.width, sy = imageFrame.height / pixelSize.height
        return CGRect(x: imageFrame.minX + rect.minX * sx, y: imageFrame.minY + rect.minY * sy,
                      width: rect.width * sx, height: rect.height * sy)
    }

    static func toolbarFrame(selection: CGRect, size: CGSize, screen: CGSize) -> CGRect {
        let margin: CGFloat = 14
        let width = min(size.width, max(1, screen.width - margin * 2))
        let height = min(size.height, max(1, screen.height - margin * 2))
        let x = min(max(margin, selection.midX - width / 2), screen.width - width - margin)
        var y = selection.maxY + 14
        if y + height > screen.height - margin { y = selection.minY - height - 14 }
        y = min(max(margin, y), screen.height - height - margin)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func moved(_ rect: CGRect, by delta: CGSize, in bounds: CGRect) -> CGRect {
        CGRect(x: min(max(bounds.minX, rect.minX + delta.width), bounds.maxX - rect.width),
               y: min(max(bounds.minY, rect.minY + delta.height), bounds.maxY - rect.height),
               width: rect.width, height: rect.height)
    }

    static func resized(_ rect: CGRect, handle: Int, to point: CGPoint, in bounds: CGRect) -> CGRect {
        let p = clamped(point, to: bounds)
        var left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
        if [0, 6, 7].contains(handle) { left = min(p.x, right - 2) }
        if [2, 3, 4].contains(handle) { right = max(p.x, left + 2) }
        if [0, 1, 2].contains(handle) { top = min(p.y, bottom - 2) }
        if [4, 5, 6].contains(handle) { bottom = max(p.y, top + 2) }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top).intersection(bounds)
    }

    static func handles(for rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)]
    }
}
