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
    private var actions = CaptureActions()
    var activeDocument: CaptureDocument? { session?.document }
    func configure(actions: CaptureActions) { self.actions = actions }

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
        configureSessionActions(session)
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
        configureSessionActions(session)
        show(screens: [screen], session: session)
    }

    private func show(screens: [FrozenScreen], session: OverlaySession) {
        session.pendingSelectorScreens = Set(screens.map(\.id))
        if let application = actions.returnApplication ?? NSWorkspace.shared.frontmostApplication,
           application.processIdentifier != ProcessInfo.processInfo.processIdentifier, !application.isTerminated {
            previousApplication = application
        }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self, weak session] _ in
            Task { @MainActor in
                guard let session, self?.session === session else { return }
                session.commitStyle()
                session.onCancel()
            NotificationService.showToast(title: "Display layout changed", subtitle: "Capture again on the current display.")
            }
        }
        for (surface, screen) in screens.enumerated() {
            if session.latencyTraceRunID != nil { session.latencyTraceSurfaces[screen.id] = surface }
            CaptureLatencyTrace.shared.mark(.panelCreationStarted, for: session.latencyTraceRunID, surface: surface)
            let panel = CaptureOverlayPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            CaptureLatencyTrace.shared.mark(.panelCreationFinished, for: session.latencyTraceRunID, surface: surface)
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isOpaque = !screen.isLive
            panel.backgroundColor = screen.isLive ? .clear : .black
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.acceptsMouseMovedEvents = true
            CaptureLatencyTrace.shared.mark(.hostingAttachmentStarted, for: session.latencyTraceRunID, surface: surface)
            let hosting = NSHostingView(rootView: CaptureOverlayView(screen: screen, session: session))
            // The controller owns this display-sized surface. Content-derived
            // min/ideal/max sizing otherwise remeasures selector and editor roots.
            hosting.sizingOptions = []
            hosting.frame = CGRect(origin: .zero, size: screen.frame.size)
            hosting.autoresizingMask = [.width, .height]
            panel.contentView = hosting
            CaptureLatencyTrace.shared.mark(.hostingAttachmentFinished, for: session.latencyTraceRunID, surface: surface)
            CaptureLatencyTrace.shared.mark(.panelOrderStarted, for: session.latencyTraceRunID, surface: surface)
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            CaptureLatencyTrace.shared.mark(.panelOrderFinished, for: session.latencyTraceRunID, surface: surface)
            panels.append(panel)
        }
        CaptureLatencyTrace.shared.mark(.activationStarted, for: session.latencyTraceRunID)
        NSApp.activate(ignoringOtherApps: true)
        (panels.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? panels.first)?.makeKey()
        CaptureLatencyTrace.shared.mark(.activationFinished, for: session.latencyTraceRunID)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, let session = self.session, let keyWindow = NSApp.keyWindow,
                  self.panels.contains(where: { $0 === keyWindow }), keyWindow.attachedSheet == nil else { return event }
            session.shiftHeld = event.modifierFlags.contains(.shift)
            if event.type == .flagsChanged { return event }
            return session.handleKey(code: event.keyCode, characters: event.charactersIgnoringModifiers,
                modifiers: event.modifierFlags, isTextEditing: keyWindow.firstResponder is NSTextView,
                isKeyUp: event.type == .keyUp) ? nil : event
        }
    }

    private func configureSessionActions(_ session: OverlaySession) {
        session.actions = actions
        session.latencyTraceRunID = actions.latencyTraceRunID
        let onBegan = actions.dragBegan
        session.actions.dragBegan = { [weak self, weak session] in
            guard let self, let session, self.session === session else { return }
            // Keep the native drag source alive until AppKit ends its session.
            for panel in self.panels { panel.orderOut(nil) }
            onBegan()
        }
        let onCanceled = actions.dragCanceled
        session.actions.dragCanceled = { [weak self, weak session] in
            guard let self, let session, self.session === session else { return }
            // A rejected destination or Escape does not deliver a PNG. Restore
            // the same edit session; stale drag callbacks cannot revive old UI.
            for panel in self.panels { panel.orderFrontRegardless() }
            NSApp.activate(ignoringOtherApps: true)
            (self.panels.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? self.panels.first)?.makeKey()
            onCanceled()
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
        session?.windowTask?.cancel()
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
    let presentationID = UUID()
    @ObservationIgnored var latencyTraceRunID: UUID?
    @ObservationIgnored var latencyTraceSurfaces: [UInt32: Int] = [:]
    var pendingSelectorScreens: Set<UInt32> = []
    func selectorPresented(on screen: UInt32) {
        guard pendingSelectorScreens.remove(screen) != nil else { return }
        if pendingSelectorScreens.isEmpty { actions.selectorPresented?() }
    }
    var actions = CaptureActions()
    var selectedAnnotationID: UUID?
    var spaceHeld = false
    var shiftHeld = false
    var isDragging = false
    var windowTask: Task<Void, Never>?
    var selectedAnnotation: CaptureAnnotation? { document?.edits.annotations.first { $0.id == selectedAnnotationID } }

    @discardableResult
    func handleKey(code: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags, isTextEditing: Bool, isKeyUp: Bool) -> Bool {
        guard !isTextEditing else { return false }
        if code == 49 {
            spaceHeld = !isKeyUp
            if !isKeyUp && !isDragging && document == nil { actions.switchMode(mode == .window ? .region : .window) }
            return true
        }
        guard !isKeyUp else { return false }
        if code == 53 {
            commitStyle()
            if activePopover != nil { activePopover = nil }
            else if annotationTool != nil { annotationTool = nil }
            else if selectedAnnotationID != nil { selectedAnnotationID = nil }
            else { windowTask?.cancel(); onCancel() }
            return true
        }
        if modifiers.contains(.command), let document {
            let key = characters?.lowercased()
            if isDragging && (key == "c" || key == "s") {
                // The canvas owns an uncommitted draft during a gesture. A
                // visible redaction must not authorize exporting the old edits.
                status = "Finish the current drawing or crop gesture before copying or saving."
                statusIsError = true
                return true
            }
            commitStyle()
            switch key {
            case "c": onCopy(document)
            case "s": onSave(document)
            case "z": if modifiers.contains(.shift) { document.redo() } else { document.undo() }; changed()
            default: return false
            }
            return true
        }
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return false }
        if let document, [51, 117].contains(code), let id = selectedAnnotationID {
            document.removeAnnotation(id: id); selectedAnnotationID = nil; changed(); return true
        }
        if let document, [123, 124, 125, 126].contains(code) {
            let step: CGFloat = modifiers.contains(.shift) ? 10 : 1
            let delta = CGSize(width: code == 123 ? -step : code == 124 ? step : 0,
                height: code == 126 ? -step : code == 125 ? step : 0)
            let bounds = CGRect(x: 0, y: 0, width: document.image.width, height: document.image.height)
            if cropMode {
                document.change { $0.crop = OverlayGeometry.moved($0.crop, by: delta, in: bounds) }
            } else if let annotation = selectedAnnotation {
                let rect = AnnotationGeometry.bounds(for: annotation)
                let moved = OverlayGeometry.moved(rect, by: delta, in: bounds)
                document.updateAnnotation(id: annotation.id) { $0 = annotation.translated(by: CGSize(width: moved.minX - rect.minX, height: moved.minY - rect.minY)) }
            } else { return false }
            changed(); return true
        }
        let tool: CaptureAnnotation.Kind?
        switch characters?.lowercased() {
        case "a": tool = .arrow
        case "r": tool = .rectangle
        case "t": tool = .text
        case "x": tool = .redact
        case "h": tool = .highlighter
        case "n": tool = .numberedStep
        case "s": tool = .spotlight
        case "v": tool = nil
        default: return false
        }
        annotationTool = tool; selectedAnnotationID = nil; cropMode = false
        return true
    }
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
        let traceRunID = latencyTraceRunID
        actions.selectionCommitted?()
        CaptureLatencyTrace.shared.mark(.selectionCommitted, for: traceRunID)
        let document = CaptureDocument(image: screen.image, edits: CaptureEdits(crop: crop, style: initialStyle))
        imagePlacement = nil
        activeScreenID = screen.id
        self.document = document
        cropMode = false
        status = ""
        actions.selectedRegion(screen, crop)
        onDocument(document)
        CaptureLatencyTrace.shared.mark(.selectionCallbacksFinished, for: traceRunID)
        if mode == .ocr { onOCR(document) }
    }

    func select(window: FrozenWindow, on screen: FrozenScreen) {
        let traceRunID = latencyTraceRunID
        actions.selectionCommitted?()
        CaptureLatencyTrace.shared.mark(.selectionCommitted, for: traceRunID)
        if window.snapshot == nil {
            guard windowTask == nil else { return }
            status = "Capturing window now…"; statusIsError = false
            windowTask = Task { [weak self] in
                guard let self else { return }
                defer { self.windowTask = nil }
                do {
                    let captured = try await self.actions.captureWindow(window.id, screen.id)
                    try Task.checkCancellation()
                    guard captured.frame == window.frame,
                          window.ownerPID == nil || captured.ownerPID == window.ownerPID else {
                        throw CaptureError.failed("This window moved or was replaced. Refresh the window list and select it again.")
                    }
                    self.select(window: captured, on: screen)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.status = "\(error.localizedDescription) Choose another window or press Esc."
                    self.statusIsError = true
                }
            }
            return
        }
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
        CaptureLatencyTrace.shared.mark(.selectionCallbacksFinished, for: traceRunID)
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

    /// Places an expanded inspector beside the selected canvas whenever the
    /// display has room. If the canvas fills the display, choose the edge
    /// with the smallest canvas/toolbar overlap instead of covering its center.
    static func inspectorFrame(canvas: CGRect, toolbar: CGRect, size: CGSize,
                               screen: CGSize, topInset: CGFloat) -> CGRect {
        let margin: CGFloat = 14
        let gap: CGFloat = 16
        let bounds = CGRect(x: margin, y: max(margin, topInset),
                            width: max(1, screen.width - margin * 2),
                            height: max(1, screen.height - max(margin, topInset) - margin))
        let panelSize = CGSize(width: min(size.width, bounds.width), height: min(size.height, bounds.height))
        let target = canvas.standardized.intersection(bounds)
        let centeredSideY = min(max(target.midY - panelSize.height / 2, bounds.minY), bounds.maxY - panelSize.height)
        let sideX = min(max(target.midX - panelSize.width / 2, bounds.minX), bounds.maxX - panelSize.width)
        func sideY(for x: CGFloat) -> CGFloat {
            let positions = [centeredSideY, bounds.minY, bounds.maxY - panelSize.height]
            return positions.min { lhs, rhs in
                let left = CGRect(origin: CGPoint(x: x, y: lhs), size: panelSize)
                let right = CGRect(origin: CGPoint(x: x, y: rhs), size: panelSize)
                let leftOverlap = max(0, left.intersection(toolbar).width) * max(0, left.intersection(toolbar).height)
                let rightOverlap = max(0, right.intersection(toolbar).width) * max(0, right.intersection(toolbar).height)
                return leftOverlap < rightOverlap
            } ?? centeredSideY
        }
        var candidates: [CGRect] = []
        if target.minX - gap - panelSize.width >= bounds.minX {
            let x = target.minX - gap - panelSize.width
            candidates.append(CGRect(origin: CGPoint(x: x, y: sideY(for: x)), size: panelSize))
        }
        if target.maxX + gap + panelSize.width <= bounds.maxX {
            let x = target.maxX + gap
            candidates.append(CGRect(origin: CGPoint(x: x, y: sideY(for: x)), size: panelSize))
        }
        if target.minY - gap - panelSize.height >= bounds.minY {
            candidates.append(CGRect(origin: CGPoint(x: sideX, y: target.minY - gap - panelSize.height), size: panelSize))
        }
        if target.maxY + gap + panelSize.height <= bounds.maxY {
            candidates.append(CGRect(origin: CGPoint(x: sideX, y: target.maxY + gap), size: panelSize))
        }
        candidates.append(contentsOf: [
            CGRect(origin: CGPoint(x: bounds.minX, y: sideY(for: bounds.minX)), size: panelSize),
            CGRect(origin: CGPoint(x: bounds.maxX - panelSize.width, y: sideY(for: bounds.maxX - panelSize.width)), size: panelSize),
            CGRect(origin: CGPoint(x: sideX, y: bounds.minY), size: panelSize),
            CGRect(origin: CGPoint(x: sideX, y: bounds.maxY - panelSize.height), size: panelSize)
        ])
        func area(_ rect: CGRect) -> CGFloat { max(0, rect.width) * max(0, rect.height) }
        let safeCanvas = target.isNull ? .zero : target
        let safeToolbar = toolbar.intersection(bounds)
        return candidates.enumerated().min { lhs, rhs in
            let leftScore = area(lhs.element.intersection(safeCanvas)) * 10
                + area(lhs.element.intersection(safeToolbar)) * 100
                + CGFloat(lhs.offset) * 0.001
            let rightScore = area(rhs.element.intersection(safeCanvas)) * 10
                + area(rhs.element.intersection(safeToolbar)) * 100
                + CGFloat(rhs.offset) * 0.001
            return leftScore < rightScore
        }?.element ?? CGRect(origin: bounds.origin, size: panelSize)
    }

    static func moved(_ rect: CGRect, by delta: CGSize, in bounds: CGRect) -> CGRect {
        // Oversized annotations may straddle a crop. Keep that viewport overlap
        // without snapping them to the opposite edge on their first nudge.
        CGRect(x: min(max(min(bounds.minX, bounds.maxX - rect.width), rect.minX + delta.width), max(bounds.minX, bounds.maxX - rect.width)),
               y: min(max(min(bounds.minY, bounds.maxY - rect.height), rect.minY + delta.height), max(bounds.minY, bounds.maxY - rect.height)),
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
