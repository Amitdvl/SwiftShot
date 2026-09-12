import AppKit
import SwiftUI
import XCTest
@testable import SwiftShot

/// Catches an inspector ScrollView whose unpainted, fixed-height tail swallows
/// drags intended for the screenshot. Real SwiftUI gestures receive process-local
/// NSEvents; no product gesture/action methods or global input APIs are invoked.
@MainActor
final class InspectorHitTestingTests: XCTestCase {
    func testPrimaryTargetsStayFixedAcrossInspectorChangesAboveAndBelow() async throws {
        for placement in [CGRect(x: 29, y: 34, width: 610, height: 816),
                          CGRect(x: 500, y: 500, width: 320, height: 180)] {
            let fixture = try await InspectorHitTestingFixture(captureFrame: placement)
            defer { fixture.close() }
            try await fixture.clickInspectorButton(label: "Annotate")
            let copy = try fixture.primaryButtonFrame(label: "Copy")
            let redact = try fixture.primaryButtonFrame(label: "Redact Screenshot")
            for label in ["More", "Background & Style", "Annotate", "Annotate"] {
                try await fixture.clickInspectorButton(label: label)
                XCTAssertEqual(try fixture.primaryButtonFrame(label: "Copy"), copy,
                    "Opening or closing \(label) must not move Copy's actual native hit target")
                XCTAssertEqual(try fixture.primaryButtonFrame(label: "Redact Screenshot"), redact)
                XCTAssertTrue(fixture.document.edits.annotations.isEmpty)
            }
        }
    }

    func testUnpaintedInspectorTailDoesNotSwallowReleasedArrowDrag() async throws {
        let fixture = try await InspectorHitTestingFixture()
        defer { fixture.close() }
        try await fixture.proveCanvasDelivery()

        // Native acceptance uses y=500. y=470 is in the same blank tail with
        // either the ordinary top inset or a notched display's larger inset.
        // This keeps the regression independent of the machine's screen model.
        try await fixture.drag(from: CGPoint(x: 200, y: 470), to: CGPoint(x: 500, y: 650))

        XCTAssertEqual(fixture.document.edits.annotations.count, 1,
            "An invisible annotation-inspector viewport swallowed a released canvas drag")
        let arrow = try XCTUnwrap(fixture.document.edits.annotations.first)
        XCTAssertEqual(arrow.kind, .arrow)
        // Independent oracle: 1220×1632 pixels placed at (29,34), 610×816 pt.
        XCTAssertEqual(arrow.start.x, 342, accuracy: 0.001)
        XCTAssertEqual(arrow.start.y, 872, accuracy: 0.001)
        XCTAssertEqual(arrow.end.x, 942, accuracy: 0.001)
        XCTAssertEqual(arrow.end.y, 1232, accuracy: 0.001)
        XCTAssertTrue(fixture.document.canUndo)
        XCTAssertFalse(fixture.session.isDragging, "Mouse-up must end the actual canvas gesture")
        XCTAssertEqual(fixture.session.activePopover, .annotations)
        XCTAssertEqual(fixture.session.annotationTool, .arrow)
    }

    func testActualInspectorControlsStillConsumeClicksWithoutDrawingOnCanvas() async throws {
        let fixture = try await InspectorHitTestingFixture()
        defer { fixture.close() }
        try await fixture.proveCanvasDelivery()

        // Resolve this real button's bounds from only our hosted accessibility
        // tree, then click via normal window hit testing, not accessibility Press.
        try await fixture.clickInspectorButton(label: "Rectangle")
        XCTAssertEqual(fixture.session.annotationTool, .rectangle,
            "A hit-testing fix must not disable the inspector's real controls")
        XCTAssertEqual(fixture.session.activePopover, .annotations)
        XCTAssertTrue(fixture.document.edits.annotations.isEmpty,
            "Clicking an inspector tool must not also create an annotation underneath it")
        XCTAssertFalse(fixture.document.canUndo)

        try await fixture.clickInspectorButton(label: "Arrow")
        XCTAssertEqual(fixture.session.annotationTool, .arrow)
        XCTAssertTrue(fixture.document.edits.annotations.isEmpty)
        XCTAssertFalse(fixture.session.isDragging)
    }

    // Catches replacing the overflow ScrollView with a clipped fixed-height
    // inspector, stale sizing after auxiliary rows change, or inaccessible
    // selected-annotation controls after the viewport becomes smaller.
    func testCompactInspectorScrollsAndResizesAroundTextAndStatusRows() async throws {
        let fixture = try await InspectorHitTestingFixture(logicalHeight: 480, selectedText: true)
        defer { fixture.close() }
        let original = fixture.document.edits.annotations
        XCTAssertEqual(original.count, 2)
        let selectedID = try XCTUnwrap(fixture.session.selectedAnnotationID)
        let unselected = try XCTUnwrap(original.first(where: { $0.id != selectedID }))
        fixture.session.status = "Synthetic compact inspector status"
        try await fixture.settleLayout()
        let statusHeight = try fixture.inspectorViewportHeight()
        let statusViewport = try fixture.inspectorViewportFrame()

        // Real Text-tool canvas click creates the private view-owned entry row.
        // No test hook sets textAnchor or bypasses the actual gesture handler.
        try await fixture.clickCanvas(at: CGPoint(x: 100, y: 430))
        XCTAssertTrue(fixture.isTextEditorFocused,
            "The canvas Text click must focus an editor in the owned test window")
        let textAndStatusHeight = try fixture.inspectorViewportHeight()
        XCTAssertLessThan(textAndStatusHeight, statusHeight)
        XCTAssertEqual(fixture.document.edits.annotations, original,
            "Opening an unsubmitted text entry must not modify the document")

        try await fixture.clickInspectorButton(label: "Cancel Text")
        XCTAssertFalse(fixture.isTextEditorFocused,
            "Cancel Text must release the entry field's focus")
        XCTAssertEqual(try fixture.inspectorViewportHeight(), statusHeight, accuracy: 1,
            "Removing the text row must return its space to the inspector")
        fixture.session.status = ""
        try await fixture.settleLayout()
        // Fitting content is allowed to leave the scrolling branch entirely.
        // Its bottom control must become reachable in the newly freed space.
        XCTAssertGreaterThan(try fixture.visibleButtonFrame(label: "Done").maxY, statusViewport.maxY,
            "Removing the status row must make the lower inspector content reachable")

        fixture.session.status = "Synthetic compact inspector status"
        try await fixture.settleLayout()
        XCTAssertEqual(try fixture.inspectorViewportHeight(), statusHeight, accuracy: 1,
            "Restoring the status row must reestablish its bounded scrolling viewport")
        XCTAssertFalse(try fixture.isInspectorButtonFullyVisible(label: "Done"),
            "The overflow fixture must begin with its bottom control clipped")
        try await fixture.scrollInspectorToBottom()
        XCTAssertTrue(try fixture.isInspectorButtonFullyVisible(label: "Done"))
        XCTAssertTrue(try fixture.isInspectorButtonFullyVisible(label: "Delete"))
        let expandedViewport = try fixture.inspectorViewportFrame()

        try await fixture.clickInspectorButton(label: "Delete")
        XCTAssertEqual(fixture.document.edits.annotations, [unselected],
            "Clicking the scrolled-to Delete control must remove only the selected text annotation")
        XCTAssertNil(fixture.session.selectedAnnotationID)
        XCTAssertTrue(fixture.document.canUndo)
        XCTAssertLessThan(try fixture.visibleButtonFrame(label: "Done").maxY, expandedViewport.maxY,
            "Removing selected-text controls must shrink the visible inspector instead of leaving a blank tail")
        XCTAssertFalse(fixture.session.isDragging)
    }
}

@MainActor
private final class InspectorHitTestingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class InspectorHitTestingFixture {
    let document: CaptureDocument
    let session: OverlaySession
    private let window: InspectorHitTestingWindow
    private let hosting: NSHostingView<CaptureOverlayView>
    private let root: URL
    private let originalActivationPolicy: NSApplication.ActivationPolicy
    private var eventMonitor: Any?
    private var nextEventNumber = 1
    private var pendingEventNumbers: Set<Int> = []
    private var closed = false

    init(logicalHeight: CGFloat = 956, selectedText: Bool = false, captureFrame: CGRect? = nil) async throws {
        _ = NSApplication.shared
        originalActivationPolicy = NSApp.activationPolicy()
        let display = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first,
            "SETUP: native hosting needs an available display; no particular size or notch is required")
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 1220, height: 1632,
            bitsPerComponent: 8, bytesPerRow: 1220 * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.12, green: 0.18, blue: 0.24, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1220, height: 1632))
        let image = try XCTUnwrap(context.makeImage())
        let text = CaptureAnnotation(kind: .text, start: CGPoint(x: 100, y: 100),
            end: CGPoint(x: 100, y: 100), text: "Synthetic overflow text")
        let rectangle = CaptureAnnotation(kind: .rectangle, start: CGPoint(x: 20, y: 20),
            end: CGPoint(x: 80, y: 80))
        document = CaptureDocument(image: image, edits: CaptureEdits(
            crop: CGRect(x: 0, y: 0, width: 1220, height: 1632),
            annotations: selectedText ? [text, rectangle] : [], style: CaptureStyle()))
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftShot-InspectorHitTesting-\(UUID())", isDirectory: true)
        let library = BackgroundLibrary(rootURL: root.appendingPathComponent("library"),
            bundleURL: root.appendingPathComponent("no-bundled-backgrounds"))
        session = OverlaySession(mode: .window, style: CaptureStyle(), library: library,
            onDocument: { _ in }, onCopy: { _ in }, onSave: { _ in },
            onOCR: { _ in }, onCancel: {})
        let screen = FrozenScreen(id: 424242,
            frame: CGRect(x: 0, y: 0, width: 1470, height: logicalHeight), image: image,
            windows: [], isLive: true)
        session.document = document
        session.activeScreenID = screen.id
        session.imagePlacement = captureFrame ?? CGRect(x: 29, y: 34, width: 610, height: 816)
        session.annotationTool = selectedText ? .text : .arrow
        session.selectedAnnotationID = selectedText ? text.id : nil
        session.cropMode = false
        session.activePopover = .annotations
        hosting = NSHostingView(rootView: CaptureOverlayView(screen: screen, session: session))
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: screen.frame.size)
        hosting.autoresizingMask = [.width, .height]
        window = InspectorHitTestingWindow(contentRect: CGRect(origin: display.frame.origin, size: screen.frame.size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "SwiftShot Inspector Hit Testing \(document.id.uuidString.prefix(8))"
        window.contentView = hosting
        window.setContentSize(screen.frame.size)
        do {
            _ = try XCTUnwrap(library.errorMessage == nil ? library : nil,
                "SETUP: the isolated background-library directory must be usable")
            // AppDelegate may already have established `.regular` for XCTest;
            // AppKit returns false when no policy transition was needed.
            NSApp.setActivationPolicy(.regular)
            XCTAssertEqual(NSApp.activationPolicy(), .regular,
                "SETUP: could not establish the regular, process-local test host")
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(150))
            _ = NSRunningApplication.current.activate(options: [])
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(200))
            for _ in 0..<100 {
                if NSApp.isActive, NSApp.keyWindow === window, window.isKeyWindow { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try requireOwnedKeyWindow()
            _ = try XCTUnwrap(hosting.bounds.size == screen.frame.size ? hosting : nil,
                "SETUP: native hosting must preserve its fixed logical coordinate surface")
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                self.pendingEventNumbers.remove(event.eventNumber)
                return event
            }
            _ = try XCTUnwrap(eventMonitor, "SETUP: could not observe delivery to the owned test window")
            recordViewportEvidence()
        } catch {
            close()
            throw error
        }
    }

    /// A positive control outside the inspector distinguishes a failed event
    /// fixture from the production regression. Undo restores an empty document;
    /// it does not substitute for either tested mouse gesture.
    func proveCanvasDelivery() async throws {
        try await drag(from: CGPoint(x: 100, y: 600), to: CGPoint(x: 500, y: 720))
        let annotations = document.edits.annotations
        _ = try XCTUnwrap(annotations.count == 1 ? annotations.first : nil,
            "SETUP: the unobstructed real-canvas control drag must commit exactly one annotation before testing inspector interception")
        let arrow = try XCTUnwrap(annotations.first)
        // Screen↔view transforms can round an integral endpoint by a few ULPs.
        // Use the same subpixel tolerance as the actual regression, not exact
        // floating-point equality (observed 941.9999999999998 for 942).
        _ = try XCTUnwrap(arrow.kind == .arrow
            && abs(arrow.start.x - 142) <= 0.001 && abs(arrow.start.y - 1132) <= 0.001
            && abs(arrow.end.x - 942) <= 0.001 && abs(arrow.end.y - 1372) <= 0.001
            && !session.isDragging ? document : nil,
            "SETUP: the control gesture must prove source-pixel coordinates and released mouse state; kind=\(arrow.kind) start=\(arrow.start) end=\(arrow.end) dragging=\(session.isDragging)")
        document.undo()
        try await settle()
        _ = try XCTUnwrap(document.edits.annotations.isEmpty && !document.canUndo ? document : nil,
            "SETUP: undo must clear the control annotation before the actual regression")
    }

    func drag(from start: CGPoint, to end: CGPoint) async throws {
        var steps: [(NSEvent.EventType, CGPoint)] = [(.leftMouseDown, start)]
        for step in 1...12 {
            let fraction = CGFloat(step) / 12
            steps.append((.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction)))
        }
        steps.append((.leftMouseUp, end))
        try await dispatch(steps)
    }

    func clickInspectorButton(label: String) async throws {
        let frame = try inspectorButtonFrame(label: label)
        let point = CGPoint(x: frame.midX, y: frame.midY)
        try await dispatch([(.leftMouseDown, point), (.leftMouseUp, point)])
    }

    func clickCanvas(at point: CGPoint) async throws {
        try await dispatch([(.leftMouseDown, point), (.leftMouseUp, point)])
    }

    func settleLayout() async throws { try await settle() }

    var isTextEditorFocused: Bool {
        guard let text = window.firstResponder as? NSTextView else { return false }
        return text.window === window
    }

    func inspectorViewportHeight() throws -> CGFloat {
        try ownedInspectorScrollView().contentView.bounds.height
    }

    func inspectorViewportFrame() throws -> CGRect {
        topDownFrame(of: try ownedInspectorScrollView().contentView)
    }

    func visibleButtonFrame(label: String) throws -> CGRect {
        let frame = try inspectorButtonFrame(label: label)
        for scroll in inspectorScrollViews() {
            _ = try XCTUnwrap(topDownFrame(of: scroll.contentView).contains(frame) ? scroll : nil,
                "The lower inspector control must be inside the actual clip viewport, not merely inside the window")
        }
        return frame
    }

    func primaryButtonFrame(label: String) throws -> CGRect {
        try inspectorButtonFrame(label: label)
    }

    func isInspectorButtonFullyVisible(label: String) throws -> Bool {
        let scroll = try ownedInspectorScrollView()
        let viewport = topDownFrame(of: scroll.contentView)
        let button = try inspectorButtonFrame(label: label, allowClipped: true)
        return viewport.contains(button)
    }

    func scrollInspectorToBottom() async throws {
        let scroll = try ownedInspectorScrollView()
        let content = try XCTUnwrap(scroll.documentView,
            "The compact inspector must have real scrollable content")
        XCTAssertGreaterThan(content.bounds.height, scroll.contentView.bounds.height,
            "The selected-text fixture must exercise actual overflow, not a fitting inspector")
        let originalVisible = scroll.documentVisibleRect
        for _ in 0..<8 {
            try requireOwnedKeyWindow()
            _ = try XCTUnwrap(scroll.window === window && scroll.isDescendant(of: hosting) ? scroll : nil,
                "SETUP: wheel input may only reach this fixture's exact inspector scroll view")
            let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 1, wheel1: -180, wheel2: 0, wheel3: 0))
            let inWindow = scroll.contentView.convert(CGPoint(x: scroll.contentView.bounds.midX,
                y: scroll.contentView.bounds.midY), to: nil)
            let inScreen = window.convertPoint(toScreen: inWindow)
            let primary = try XCTUnwrap(NSScreen.screens.first,
                "SETUP: constructing the local wheel needs the screen-coordinate origin")
            wheel.location = CGPoint(x: inScreen.x, y: primary.frame.maxY - inScreen.y)
            let event = try XCTUnwrap(NSEvent(cgEvent: wheel))
            _ = try XCTUnwrap(event.type == .scrollWheel && event.scrollingDeltaY < 0 ? event : nil,
                "SETUP: the native wheel factory must produce a downward scroll event")
            // Direct native responder delivery, scoped to the exact owned view.
            // CGEvent is only the public event constructor: never post it. This
            // tests functional scrolling, not window-level wheel hit targeting.
            scroll.scrollWheel(with: event)
            try await settle()
            let visible = scroll.documentVisibleRect
            let atBottom = content.isFlipped ? visible.maxY >= content.bounds.maxY - 1
                : visible.minY <= content.bounds.minY + 1
            if atBottom { break }
        }
        XCTAssertNotEqual(scroll.documentVisibleRect.origin, originalVisible.origin,
            "Native wheel delivery must move the actual viewport; clipping alone is not functional scrolling")
        XCTAssertTrue(try isInspectorButtonFullyVisible(label: "Done"),
            "Bounded native scrolling must expose the inspector's bottom control")
    }

    private func ownedInspectorScrollView() throws -> NSScrollView {
        let found = inspectorScrollViews()
        _ = try XCTUnwrap(found.count == 1 ? found.first : nil,
            "The hosted overlay must contain one real inspector scroll view, excluding any field editor")
        return try XCTUnwrap(found.first)
    }

    private func inspectorScrollViews() -> [NSScrollView] {
        var queue: [NSView] = [hosting]
        var found: [NSScrollView] = []
        var visited = 0
        while !queue.isEmpty, visited < 512 {
            let view = queue.removeFirst()
            visited += 1
            if let scroll = view as? NSScrollView, scroll.window === window,
               !scroll.isHiddenOrHasHiddenAncestor,
               (scroll.documentView as? NSTextView)?.isFieldEditor != true {
                found.append(scroll)
            }
            queue.append(contentsOf: view.subviews)
        }
        return found
    }

    private func topDownFrame(of view: NSView) -> CGRect {
        let frame = hosting.convert(view.bounds, from: view)
        return hosting.isFlipped ? frame : CGRect(x: frame.minX,
            y: hosting.bounds.height - frame.maxY, width: frame.width, height: frame.height)
    }

    private func dispatch(_ steps: [(NSEvent.EventType, CGPoint)]) async throws {
        try requireOwnedKeyWindow()
        _ = try XCTUnwrap(pendingEventNumbers.isEmpty ? window : nil,
            "SETUP: no earlier synthetic mouse sequence may still be queued")
        let started = ProcessInfo.processInfo.systemUptime
        var events: [NSEvent] = []
        for (offset, step) in steps.enumerated() {
            let local = hosting.isFlipped ? step.1 : CGPoint(x: step.1.x, y: hosting.bounds.height - step.1.y)
            _ = try XCTUnwrap(hosting.bounds.contains(local) ? hosting : nil,
                "SETUP: every test event must stay inside its owned content view")
            let location = hosting.convert(local, to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: step.0, location: location,
                modifierFlags: [], timestamp: started + Double(offset) * 0.01,
                windowNumber: window.windowNumber, context: nil, eventNumber: nextEventNumber,
                clickCount: 1, pressure: step.0 == .leftMouseUp ? 0 : 1))
            nextEventNumber += 1
            // AppKit is allowed to coalesce intermediate drag samples. Require
            // the down/up boundaries; the exact committed Arrow geometry below
            // proves that real movement reached the canvas recognizer.
            if step.0 != .leftMouseDragged { pendingEventNumbers.insert(event.eventNumber) }
            events.append(event)
        }
        // Queue the complete released gesture before yielding: AppKit controls
        // can enter a tracking loop during mouseDown. This is NSApplication's
        // process-local queue, never CGEvent.post or a system/global event tap.
        for event in events { NSApp.postEvent(event, atStart: false) }
        for _ in 0..<100 {
            if pendingEventNumbers.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try XCTUnwrap(pendingEventNumbers.isEmpty ? window : nil,
            "SETUP: the owned window did not receive both boundaries of the released synthetic mouse sequence")
        try await settle()
        try requireOwnedKeyWindow()
    }

    private func requireOwnedKeyWindow() throws {
        _ = try XCTUnwrap(!closed && NSApp.isActive && window.isVisible && window.isKeyWindow
            && NSApp.keyWindow === window && window.contentView === hosting ? window : nil,
            "SETUP: process-local input requires this exact visible/key test window, never another app or preexisting window")
    }

    private func settle() async throws {
        // Let AppKit finish dispatch and SwiftUI finish its own update; do not
        // force recursive layout from the event/gesture stack.
        try await Task.sleep(for: .milliseconds(100))
    }

    private func inspectorButtonFrame(label: String, allowClipped: Bool = false) throws -> CGRect {
        var queue: [Any] = [hosting]
        var seen = Set<ObjectIdentifier>()
        var found: [CGRect] = []
        var evidence: [String] = []
        while !queue.isEmpty, seen.count < 2048 {
            let value = queue.removeFirst()
            guard let object = value as? NSObject,
                  seen.insert(ObjectIdentifier(object)).inserted else { continue }
            // SwiftUI's virtual accessibility nodes can expose these Objective-C
            // getters without declaring the complete NSAccessibilityProtocol.
            // KVC boxes struct getters (the frame becomes NSValue); invoke only
            // getters this exact, owned-tree object says it implements.
            let role = accessibilityValue(object, key: "accessibilityRole") as? String
            let elementLabel = accessibilityValue(object, key: "accessibilityLabel") as? String
            let elementFrame = (accessibilityValue(object, key: "accessibilityFrame") as? NSValue)?.rectValue
            if evidence.count < 40 {
                evidence.append("type=\(String(describing: type(of: object))) protocol=\(object is any NSAccessibilityProtocol) role=\(role ?? "nil") label=\(elementLabel ?? "nil") frame=\(String(describing: elementFrame))")
            }
            if role == NSAccessibility.Role.button.rawValue, elementLabel == label, let elementFrame {
                let inWindow = window.convertFromScreen(elementFrame)
                let inHosting = hosting.convert(inWindow, from: nil)
                let topDown = hosting.isFlipped ? inHosting : CGRect(x: inHosting.minX,
                    y: hosting.bounds.height - inHosting.maxY, width: inHosting.width, height: inHosting.height)
                if topDown.width > 0, topDown.height > 0,
                   (allowClipped || CGRect(origin: .zero, size: hosting.bounds.size).contains(topDown)) { found.append(topDown) }
            }
            queue.append(contentsOf: accessibilityValue(object, key: "accessibilityChildren") as? [Any] ?? [])
        }
        if found.count != 1 {
            print("InspectorHitTesting AX lookup=\(label) found=\(found.count) visited=\(seen.count) remaining=\(queue.count)")
            for line in evidence { print("InspectorHitTesting AX \(line)") }
        }
        _ = try XCTUnwrap(found.count == 1 ? found.first : nil,
            "SETUP: the owned inspector must expose exactly one visible \(label) button for real mouse targeting")
        return try XCTUnwrap(found.first)
    }

    private func accessibilityValue(_ object: NSObject, key: String) -> Any? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key)
    }

    private func recordViewportEvidence() {
        var queue: [NSView] = [hosting]
        var visited = 0
        while !queue.isEmpty, visited < 512 {
            let view = queue.removeFirst()
            visited += 1
            if let scroll = view as? NSScrollView {
                let frame = hosting.convert(scroll.bounds, from: scroll)
                let topDown = hosting.isFlipped ? frame : CGRect(x: frame.minX,
                    y: hosting.bounds.height - frame.maxY, width: frame.width, height: frame.height)
                print("InspectorHitTesting viewport=\(topDown) documentBounds=\(String(describing: scroll.documentView?.bounds))")
            }
            queue.append(contentsOf: view.subviews)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        if NSApp.activationPolicy() != originalActivationPolicy {
            XCTAssertTrue(NSApp.setActivationPolicy(originalActivationPolicy),
                "Fixture cleanup must restore the host's activation policy")
        }
        do { try FileManager.default.removeItem(at: root) }
        catch { XCTFail("Fixture cleanup could not remove its isolated library: \(error)") }
    }
}
