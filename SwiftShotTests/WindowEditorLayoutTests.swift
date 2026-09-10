import AppKit
import SwiftUI
import XCTest
@testable import SwiftShot

/// Real controller, panel, session, SwiftUI root, layout and presentation observer.
/// Only external Window pixel acquisition is held behind a continuation. Eventual
/// software presentation is the contract, not synchronous layout, a latency
/// threshold, or physical-display readiness. No input or screen capture is injected.
@MainActor
final class WindowEditorLayoutTests: XCTestCase {
    // Break: live acquisition publishes a placeholder/resampled image, wrong
    // placement, or an editor that never produces a real presentation receipt.
    func testSuccessfulLiveWindowAcquisitionEventuallyPresentsExactNativeEditor() async throws {
        let fixture = try WindowEditorLayoutFixture()
        defer { fixture.close() }
        let (panel, hosting) = try fixture.present()
        let task = try await fixture.beginAcquisition()

        fixture.releaseAcquisition()
        await task.value

        let document = try XCTUnwrap(fixture.controller.activeDocument)
        XCTAssertTrue(document.image === fixture.acquiredImage)
        XCTAssertEqual(document.image.width, 800)
        XCTAssertEqual(document.image.height, 600)
        XCTAssertEqual(document.edits.crop, CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(hosting.rootView.session.imagePlacement, CGRect(x: 80, y: 100, width: 400, height: 300))
        XCTAssertNil(hosting.rootView.session.windowTask)
        try await fixture.waitForReceipt(from: .original)
        try assertReceipt(fixture, from: .original, document: document, image: fixture.acquiredImage,
            crop: CGRect(x: 0, y: 0, width: 800, height: 600),
            placement: CGRect(x: 80, y: 100, width: 400, height: 300),
            screenID: fixture.screen.id, panel: panel, hosting: hosting)
    }

    // Break: a hidden capture advertises editor readiness despite having no
    // visible native surface. Publishing the acquired document itself is valid.
    func testHiddenPanelDoesNotAdvertiseEditorReadiness() async throws {
        let fixture = try WindowEditorLayoutFixture()
        defer { fixture.close() }
        let (panel, hosting) = try fixture.present()
        let task = try await fixture.beginAcquisition()
        panel.orderOut(nil)

        fixture.releaseAcquisition()
        await task.value
        try await fixture.settlePresentations()

        XCTAssertTrue(fixture.controller.activeDocument?.image === fixture.acquiredImage)
        XCTAssertNil(hosting.rootView.session.windowTask)
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(fixture.receipts(from: .original).isEmpty,
            "A hidden acquired document is not a presented editor")
    }

    // Break: a cancellation-insensitive external acquisition publishes late
    // pixels or readiness after the owning session was canceled and dismissed.
    func testDismissedSessionRejectsLatePixelsAndEditorReadiness() async throws {
        let fixture = try WindowEditorLayoutFixture()
        defer { fixture.close() }
        let (panel, hosting) = try fixture.present()
        let task = try await fixture.beginAcquisition()
        fixture.controller.dismiss()

        fixture.releaseAcquisition()
        await task.value
        try await fixture.settlePresentations()

        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(fixture.controller.activeDocument)
        XCTAssertNil(hosting.rootView.session.document)
        XCTAssertNil(hosting.rootView.session.windowTask)
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(fixture.receipts(from: .original).isEmpty)
    }

    // Break: old late pixels overwrite a replacement or its ready callback is
    // attributed to the old session rather than the actual replacement editor.
    func testReplacementEditorSurvivesLatePreviousSessionAcquisition() async throws {
        let fixture = try WindowEditorLayoutFixture()
        defer { fixture.close() }
        let (panel, hosting) = try fixture.present()
        let task = try await fixture.beginAcquisition()
        let replacement = CaptureDocument(image: fixture.replacementImage)
        fixture.reopenReplacement(replacement)

        fixture.releaseAcquisition()
        await task.value
        try await fixture.waitForReceipt(from: .replacement)

        XCTAssertTrue(fixture.controller.activeDocument === replacement)
        XCTAssertNil(hosting.rootView.session.document)
        XCTAssertNil(hosting.rootView.session.windowTask)
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(fixture.receipts(from: .original).isEmpty)
        let (replacementPanel, replacementHost) = try fixture.replacementSurface()
        try assertReceipt(fixture, from: .replacement, document: replacement, image: fixture.replacementImage,
            crop: CGRect(x: 0, y: 0, width: 64, height: 40), placement: nil,
            screenID: 0, panel: replacementPanel, hosting: replacementHost)
    }

    // Break: UUID-only observations accept the originally acquired pixels even
    // though onDocument replaced the actual document with a same-ID image.
    func testSameIDDocumentReplacementPresentsOnlyTheActualReplacementPixels() async throws {
        let fixture = try WindowEditorLayoutFixture()
        defer { fixture.close() }
        let (panel, hosting) = try fixture.present()
        let session = hosting.rootView.session
        var original: CaptureDocument?
        var replacement: CaptureDocument?
        fixture.onDocument = { document in
            original = document
            let next = CaptureDocument(id: document.id, image: fixture.replacementImage)
            replacement = next
            session.document = next
        }
        let task = try await fixture.beginAcquisition()

        fixture.releaseAcquisition()
        await task.value
        try await fixture.waitForReceipt(from: .original)

        let current = try XCTUnwrap(fixture.controller.activeDocument)
        XCTAssertTrue(current === replacement)
        XCTAssertFalse(current === original)
        XCTAssertEqual(current.id, original?.id)
        XCTAssertTrue(current.image === fixture.replacementImage)
        try assertReceipt(fixture, from: .original, document: current, image: fixture.replacementImage,
            crop: CGRect(x: 0, y: 0, width: 64, height: 40),
            placement: CGRect(x: 80, y: 100, width: 400, height: 300),
            screenID: fixture.screen.id, panel: panel, hosting: hosting)
    }

    // Break: treating cancellation after the document callback as if publication
    // never happened leaves a healthy committed editor without a ready receipt.
    func testCancellationInsideDocumentCallbackStillPresentsCommittedEditor() async throws {
        let fixture = try WindowEditorLayoutFixture()
        defer { fixture.close() }
        let (panel, hosting) = try fixture.present()
        let session = hosting.rootView.session
        fixture.onDocument = { _ in session.windowTask?.cancel() }
        let task = try await fixture.beginAcquisition()

        fixture.releaseAcquisition()
        await task.value
        try await fixture.waitForReceipt(from: .original)

        XCTAssertTrue(task.isCancelled)
        let document = try XCTUnwrap(fixture.controller.activeDocument)
        XCTAssertTrue(document.image === fixture.acquiredImage,
            "onDocument is after publication; cancellation must not erase the committed document")
        XCTAssertNil(session.windowTask)
        try assertReceipt(fixture, from: .original, document: document, image: fixture.acquiredImage,
            crop: CGRect(x: 0, y: 0, width: 800, height: 600),
            placement: CGRect(x: 80, y: 100, width: 400, height: 300),
            screenID: fixture.screen.id, panel: panel, hosting: hosting)
    }

    // Break: an old acquired editor announces readiness after onDocument opens
    // a different owned session. The new editor must still actually present.
    func testDocumentCallbackReopeningAnotherSessionPresentsOnlyTheNewEditor() async throws {
        let fixture = try WindowEditorLayoutFixture()
        defer { fixture.close() }
        let (panel, hosting) = try fixture.present()
        let replacement = CaptureDocument(image: fixture.replacementImage)
        fixture.onDocument = { _ in fixture.reopenReplacement(replacement) }
        let task = try await fixture.beginAcquisition()

        fixture.releaseAcquisition()
        await task.value
        try await fixture.waitForReceipt(from: .replacement)

        XCTAssertTrue(fixture.controller.activeDocument === replacement)
        XCTAssertTrue(hosting.rootView.session.document?.image === fixture.acquiredImage,
            "The old callback is reached only after pixels were committed to its own session")
        XCTAssertNil(hosting.rootView.session.windowTask)
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(fixture.receipts(from: .original).isEmpty)
        let (replacementPanel, replacementHost) = try fixture.replacementSurface()
        try assertReceipt(fixture, from: .replacement, document: replacement, image: fixture.replacementImage,
            crop: CGRect(x: 0, y: 0, width: 64, height: 40), placement: nil,
            screenID: 0, panel: replacementPanel, hosting: replacementHost)
    }

    // Break: a detached hosting subtree reports readiness merely because its
    // session owns a document. Keep that real subtree alive through observation.
    func testDocumentCallbackDetachingContentViewDoesNotAdvertiseDetachedEditor() async throws {
        let fixture = try WindowEditorLayoutFixture()
        defer { fixture.close() }
        let (panel, hosting) = try fixture.present()
        fixture.onDocument = { _ in panel.contentView = nil }
        let task = try await fixture.beginAcquisition()

        fixture.releaseAcquisition()
        await task.value
        try await fixture.settlePresentations()

        XCTAssertTrue(fixture.controller.activeDocument?.image === fixture.acquiredImage)
        XCTAssertNil(panel.contentView)
        XCTAssertNil(hosting.window)
        XCTAssertNil(hosting.rootView.session.windowTask)
        XCTAssertTrue(fixture.receipts(from: .original).isEmpty,
            "A detached subtree cannot advertise visible editor readiness")
    }

    // Break: the original session claims another session's visible editor as
    // its own. Observe the foreign editor's real receipt as a positive control.
    func testDocumentCallbackReplacingContentViewPresentsOnlyTheForeignEditor() async throws {
        let fixture = try WindowEditorLayoutFixture()
        defer { fixture.close() }
        let (panel, hosting) = try fixture.present()
        let foreignDocument = CaptureDocument(image: fixture.replacementImage)
        let foreignSession = OverlaySession(mode: .window, style: CaptureStyle(), library: fixture.library,
            onDocument: { _ in }, onCopy: { _ in }, onSave: { _ in }, onOCR: { _ in }, onCancel: {})
        foreignSession.document = foreignDocument
        foreignSession.activeScreenID = fixture.screen.id
        foreignSession.imagePlacement = CGRect(x: 80, y: 100, width: 400, height: 300)
        let foreignHost = WindowEditorLayoutHosting(rootView: CaptureOverlayView(screen: fixture.screen, session: foreignSession))
        foreignHost.sizingOptions = []
        foreignHost.frame = CGRect(origin: .zero, size: fixture.screen.frame.size)
        foreignHost.autoresizingMask = [.width, .height]
        foreignSession.actions.editorPresented = { [weak fixture, weak foreignHost] in
            fixture?.recordReceipt(from: .foreign, hosting: foreignHost)
        }
        fixture.onDocument = { _ in panel.contentView = foreignHost }
        let task = try await fixture.beginAcquisition()

        fixture.releaseAcquisition()
        await task.value
        try await fixture.waitForReceipt(from: .foreign)

        XCTAssertTrue(fixture.controller.activeDocument?.image === fixture.acquiredImage)
        XCTAssertTrue(panel.contentView === foreignHost)
        XCTAssertNil(hosting.window)
        XCTAssertFalse(foreignHost.rootView.session === hosting.rootView.session)
        XCTAssertNil(hosting.rootView.session.windowTask)
        XCTAssertTrue(fixture.receipts(from: .original).isEmpty,
            "A foreign editor receipt cannot complete the originating session")
        try assertReceipt(fixture, from: .foreign, document: foreignDocument, image: fixture.replacementImage,
            crop: CGRect(x: 0, y: 0, width: 64, height: 40),
            placement: CGRect(x: 80, y: 100, width: 400, height: 300),
            screenID: fixture.screen.id, panel: panel, hosting: foreignHost)
    }

    // Break: a surface with a nonmatching active display shows/reports another
    // display's editor. It is still attached and visible, so visibility alone fails.
    func testDocumentCallbackChangingActiveScreenDoesNotAdvertiseWrongScreenEditor() async throws {
        let fixture = try WindowEditorLayoutFixture()
        defer { fixture.close() }
        let (panel, hosting) = try fixture.present()
        let otherScreenID = fixture.screen.id ^ 0x80000000
        fixture.onDocument = { _ in hosting.rootView.session.activeScreenID = otherScreenID }
        let task = try await fixture.beginAcquisition()

        fixture.releaseAcquisition()
        await task.value
        try await fixture.settlePresentations()

        XCTAssertTrue(panel.contentView === hosting)
        XCTAssertTrue(hosting.window === panel)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(fixture.controller.activeDocument?.image === fixture.acquiredImage)
        XCTAssertNil(hosting.rootView.session.windowTask)
        XCTAssertEqual(hosting.rootView.screen.id, fixture.screen.id)
        XCTAssertEqual(hosting.rootView.session.activeScreenID, otherScreenID)
        XCTAssertFalse(WindowEditorLayoutHosting.containsPresentationView(hosting))
        XCTAssertTrue(fixture.receipts(from: .original).isEmpty,
            "An attached surface for a different active display cannot advertise this editor")
    }

    // Break: session identity alone authorizes an editor receipt after its host
    // root was changed to represent a different screen.
    func testDocumentCallbackChangingHostedScreenDoesNotAdvertiseWrongRootEditor() async throws {
        let fixture = try WindowEditorLayoutFixture()
        defer { fixture.close() }
        let (panel, hosting) = try fixture.present()
        let session = hosting.rootView.session
        let otherScreenID = fixture.screen.id ^ 0x80000000
        let otherScreen = FrozenScreen(id: otherScreenID, frame: fixture.screen.frame,
            image: fixture.screen.image, windows: [], isLive: true)
        fixture.onDocument = { _ in
            hosting.rootView = CaptureOverlayView(screen: otherScreen, session: session)
        }
        let task = try await fixture.beginAcquisition()

        fixture.releaseAcquisition()
        await task.value
        try await fixture.settlePresentations()

        XCTAssertTrue(panel.contentView === hosting)
        XCTAssertTrue(hosting.window === panel)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(hosting.rootView.session === session)
        XCTAssertTrue(fixture.controller.activeDocument?.image === fixture.acquiredImage)
        XCTAssertNil(session.windowTask)
        XCTAssertEqual(session.activeScreenID, fixture.screen.id)
        XCTAssertEqual(hosting.rootView.screen.id, otherScreenID)
        XCTAssertFalse(WindowEditorLayoutHosting.containsPresentationView(hosting))
        XCTAssertTrue(fixture.receipts(from: .original).isEmpty,
            "An editor receipt must belong to the host's actual display")
    }

    // Break: the preacquired path stops presenting the native image because it
    // was mistakenly made dependent on an asynchronous acquisition task.
    func testPreacquiredSnapshotSelectionEventuallyPresentsExactNativeEditor() async throws {
        let fixture = try WindowEditorLayoutFixture()
        defer { fixture.close() }
        let (panel, hosting) = try fixture.present()
        hosting.rootView.session.select(window: fixture.acquiredWindow, on: fixture.screen)

        let document = try XCTUnwrap(fixture.controller.activeDocument)
        XCTAssertTrue(document.image === fixture.acquiredImage)
        XCTAssertNil(hosting.rootView.session.windowTask)
        try await fixture.waitForReceipt(from: .original)
        try assertReceipt(fixture, from: .original, document: document, image: fixture.acquiredImage,
            crop: CGRect(x: 0, y: 0, width: 800, height: 600),
            placement: CGRect(x: 80, y: 100, width: 400, height: 300),
            screenID: fixture.screen.id, panel: panel, hosting: hosting)
    }

    private func assertReceipt(_ fixture: WindowEditorLayoutFixture, from source: WindowEditorLayoutFixture.ReceiptSource,
        document: CaptureDocument, image: CGImage, crop: CGRect, placement: CGRect?, screenID: UInt32,
        panel: NSWindow, hosting: WindowEditorLayoutHosting, file: StaticString = #filePath, line: UInt = #line) throws {
        let expectedFrame = source == .replacement ? try XCTUnwrap(fixture.replacementExpectedFrame, file: file, line: line) : fixture.screen.frame
        let receipts = fixture.receipts(from: source)
        XCTAssertEqual(receipts.count, 1, "Exactly one actual editor presentation must complete", file: file, line: line)
        let receipt = try XCTUnwrap(receipts.first, file: file, line: line)
        XCTAssertFalse(receipt.acquisitionStillActive,
            "Readiness must come from the asynchronous presentation observer, not document publication", file: file, line: line)
        let facts = try XCTUnwrap(receipt.facts, "A callback without its actual host is not a valid ready receipt", file: file, line: line)
        let layout = try XCTUnwrap(receipt.lastCompletedEditorLayout,
            "The real host must complete editor layout before readiness", file: file, line: line)
        for observation in [layout, facts] {
            XCTAssertTrue(observation.document === document, "Document reference, not UUID, owns these pixels", file: file, line: line)
            XCTAssertTrue(observation.image === image, "Presentation must retain the exact native image", file: file, line: line)
            XCTAssertEqual(observation.image?.width, Int(crop.width), file: file, line: line)
            XCTAssertEqual(observation.image?.height, Int(crop.height), file: file, line: line)
            XCTAssertEqual(observation.crop, crop, file: file, line: line)
            XCTAssertEqual(observation.placement, placement, file: file, line: line)
            XCTAssertEqual(observation.activeScreenID, screenID, file: file, line: line)
            XCTAssertEqual(observation.hostedScreenID, screenID, file: file, line: line)
            XCTAssertEqual(observation.windowNumber, panel.windowNumber, file: file, line: line)
            XCTAssertTrue(observation.wasVisible, file: file, line: line)
            XCTAssertEqual(observation.hostBounds, CGRect(origin: .zero, size: expectedFrame.size), file: file, line: line)
            XCTAssertTrue(observation.hasEditorPresentationView,
                "Calling layout alone is insufficient: the real editor receipt view must exist", file: file, line: line)
        }
        XCTAssertTrue(hosting.window === panel, file: file, line: line)
        XCTAssertTrue(panel.contentView === hosting, file: file, line: line)
    }
}

@MainActor
private final class WindowEditorLayoutHosting: NSHostingView<CaptureOverlayView> {
    struct CompletedLayout {
        let document: CaptureDocument?
        let image: CGImage?
        let crop: CGRect?
        let placement: CGRect?
        let activeScreenID: UInt32?
        let hostedScreenID: UInt32
        let windowNumber: Int?
        let wasVisible: Bool
        let hostBounds: CGRect
        let hasEditorPresentationView: Bool
    }

    private(set) var editorLayouts: [CompletedLayout] = []
    private(set) var completedLayoutCount = 0

    override func layout() {
        super.layout()
        completedLayoutCount += 1
        if rootView.session.document != nil { editorLayouts.append(presentationFacts()) }
    }

    func presentationFacts() -> CompletedLayout {
        let session = rootView.session
        return CompletedLayout(document: session.document, image: session.document?.image,
            crop: session.document?.edits.crop, placement: session.imagePlacement,
            activeScreenID: session.activeScreenID, hostedScreenID: rootView.screen.id,
            windowNumber: window?.windowNumber, wasVisible: window?.isVisible == true,
            hostBounds: bounds, hasEditorPresentationView: Self.containsPresentationView(self))
    }

    static func containsPresentationView(_ view: NSView) -> Bool {
        view is CapturePresentationView || view.subviews.contains(where: containsPresentationView)
    }
}

/// Test-owned native surfaces only. Never finds or manipulates a preexisting
/// panel, installed application, user defaults, clipboard, or history record.
@MainActor
private final class WindowEditorLayoutFixture {
    enum ReceiptSource { case original, replacement, foreign }
    struct EditorReceipt {
        let source: ReceiptSource
        let facts: WindowEditorLayoutHosting.CompletedLayout?
        let lastCompletedEditorLayout: WindowEditorLayoutHosting.CompletedLayout?
        let acquisitionStillActive: Bool
    }

    let controller = CaptureOverlayController()
    let screen: FrozenScreen
    let acquiredImage: CGImage
    let replacementImage: CGImage
    let library: BackgroundLibrary
    let root: URL
    let gate = WindowEditorAcquisitionGate()
    var onDocument: ((CaptureDocument) -> Void)?
    private(set) var editorReceipts: [EditorReceipt] = []
    private var hosting: WindowEditorLayoutHosting?
    private var replacementHosting: WindowEditorLayoutHosting?
    private(set) var replacementExpectedFrame: CGRect?
    private var closed = false

    var selectedWindow: FrozenWindow {
        FrozenWindow(id: 4141, title: "Synthetic live Window layout source",
            frame: CGRect(x: 80, y: 100, width: 400, height: 300), ownerPID: 8181)
    }
    var acquiredWindow: FrozenWindow {
        FrozenWindow(id: 4141, title: "Synthetic live Window layout source",
            frame: CGRect(x: 80, y: 100, width: 400, height: 300), snapshot: acquiredImage, ownerPID: 8181)
    }

    init() throws {
        _ = NSApplication.shared
        let display = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first,
            "SETUP: actual controller hosting requires an available native display")
        _ = try XCTUnwrap(display.frame.width >= 560 && display.frame.height >= 460 ? display : nil,
            "SETUP: native display must contain the literal synthetic Window placement")
        let number = try XCTUnwrap(display.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
        acquiredImage = try Self.makeImage(width: 800, height: 600, color: CGColor(red: 0.1, green: 0.7, blue: 0.2, alpha: 1))
        replacementImage = try Self.makeImage(width: 64, height: 40, color: CGColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1))
        let placeholder = try Self.makeImage(width: 1, height: 1, color: CGColor(gray: 0, alpha: 0))
        screen = FrozenScreen(id: number.uint32Value, frame: display.frame, image: placeholder, windows: [], isLive: true)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftShot-WindowEditorLayout-\(UUID())", isDirectory: true)
        library = BackgroundLibrary(rootURL: root.appendingPathComponent("library"),
            bundleURL: root.appendingPathComponent("no-bundled-backgrounds"))
    }

    func present() throws -> (NSWindow, WindowEditorLayoutHosting) {
        _ = try XCTUnwrap(library.errorMessage == nil ? library : nil,
            "SETUP: isolated background-library directory must be usable")
        let existing = Set(NSApp.windows.map { ObjectIdentifier($0) })
        var actions = CaptureActions()
        actions.returnApplication = NSRunningApplication.current
        actions.captureWindow = { [weak self] windowID, screenID in
            guard let self, windowID == 4141, screenID == self.screen.id else {
                throw CaptureError.failed("Unexpected synthetic acquisition target")
            }
            return try await self.gate.acquire()
        }
        // No selector observer: an actual CapturePresentationView here belongs
        // to the editor branch. Never call editorPresented from the fixture.
        actions.editorPresented = { [weak self] in
            guard let self else { return }
            self.recordReceipt(from: .original, hosting: self.hosting)
        }
        controller.configure(actions: actions)
        controller.present(screens: [screen], mode: .window, style: CaptureStyle(), library: library,
            onDocument: { [weak self] in self?.onDocument?($0) }, onCopy: { _ in }, onSave: { _ in },
            onOCR: { _ in }, onCancel: { [weak self] in self?.controller.dismiss() })
        let owned = NSApp.windows.filter { window in
            guard !existing.contains(ObjectIdentifier(window)),
                  let candidate = window.contentView as? NSHostingView<CaptureOverlayView> else { return false }
            return candidate.rootView.screen.image === screen.image
        }
        _ = try XCTUnwrap(owned.count == 1 ? owned.first : nil,
            "SETUP: the real controller must create exactly one owned synthetic panel")
        let panel = try XCTUnwrap(owned.first)
        let original = try XCTUnwrap(panel.contentView as? NSHostingView<CaptureOverlayView>)
        let observed = installObservedHost(original, in: panel)
        hosting = observed
        // Settle only the initial selector, never force the acquired editor's
        // first layout or invoke any presentation callback to satisfy a test.
        observed.needsLayout = true
        observed.layoutSubtreeIfNeeded()
        _ = try XCTUnwrap(panel.isVisible && observed.window === panel &&
            observed.completedLayoutCount > 0 && observed.bounds.size == screen.frame.size ? panel : nil,
            "SETUP: the real owning panel must remain visible, attached, and laid out")
        XCTAssertFalse(WindowEditorLayoutHosting.containsPresentationView(observed),
            "SETUP: there must be no editor presentation view in the unselected live selector")
        return (panel, observed)
    }

    func beginAcquisition() async throws -> Task<Void, Never> {
        let hosting = try XCTUnwrap(hosting)
        hosting.rootView.session.select(window: selectedWindow, on: screen)
        let task = try XCTUnwrap(hosting.rootView.session.windowTask,
            "SETUP: snapshot-free Window selection must create a real acquisition task")
        try await waitUntil { self.gate.started }
        XCTAssertNil(controller.activeDocument)
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
        return task
    }

    func releaseAcquisition() { gate.release(.success(acquiredWindow)) }

    func reopenReplacement(_ document: CaptureDocument) {
        let existing = Set(NSApp.windows.map { ObjectIdentifier($0) })
        replacementExpectedFrame = (NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main)?.frame
        var actions = CaptureActions()
        actions.returnApplication = NSRunningApplication.current
        actions.editorPresented = { [weak self] in
            guard let self else { return }
            self.recordReceipt(from: .replacement, hosting: self.replacementHosting)
        }
        controller.configure(actions: actions)
        controller.reopen(document: document, library: library, onCopy: { _ in }, onSave: { _ in },
            onCancel: { [weak self] in self?.controller.dismiss() })
        let owned = NSApp.windows.filter { window in
            guard !existing.contains(ObjectIdentifier(window)),
                  let candidate = window.contentView as? NSHostingView<CaptureOverlayView> else { return false }
            return candidate.rootView.session.document === document
        }
        guard owned.count == 1, let panel = owned.first,
              let original = panel.contentView as? NSHostingView<CaptureOverlayView> else {
            XCTFail("SETUP: reopen must create exactly one owned real replacement editor")
            return
        }
        replacementHosting = installObservedHost(original, in: panel)
    }

    func replacementSurface() throws -> (NSWindow, WindowEditorLayoutHosting) {
        let hosting = try XCTUnwrap(replacementHosting)
        return (try XCTUnwrap(hosting.window), hosting)
    }

    private func installObservedHost(_ original: NSHostingView<CaptureOverlayView>, in panel: NSWindow) -> WindowEditorLayoutHosting {
        let observed = WindowEditorLayoutHosting(rootView: original.rootView)
        observed.sizingOptions = []
        observed.frame = CGRect(origin: .zero, size: original.rootView.screen.frame.size)
        observed.autoresizingMask = [.width, .height]
        panel.contentView = observed
        return observed
    }

    func recordReceipt(from source: ReceiptSource, hosting: WindowEditorLayoutHosting?) {
        // Keep even malformed/detached callbacks. Dropping them here would mask
        // exactly the ownership and readiness defects these scenarios exercise.
        editorReceipts.append(EditorReceipt(source: source, facts: hosting?.presentationFacts(),
            lastCompletedEditorLayout: hosting?.editorLayouts.last,
            acquisitionStillActive: hosting?.rootView.session.windowTask != nil))
    }

    func receipts(from source: ReceiptSource) -> [EditorReceipt] {
        editorReceipts.filter { $0.source == source }
    }

    func waitForReceipt(from source: ReceiptSource) async throws {
        try await waitUntil { !self.receipts(from: source).isEmpty }
        try await settlePresentations()
    }

    func settlePresentations() async throws {
        // A bounded functional observation window lets queued AppKit layout,
        // transaction completions and duplicate/stale receipts run. This is not
        // a latency gate and does not force layout or fabricate a ready callback.
        for _ in 0..<10 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        // Functional fixture timeout only; no product latency target is asserted.
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "WindowEditorLayoutFixtureTimeout", code: 1)
    }

    func close() {
        guard !closed else { return }
        closed = true
        onDocument = nil
        controller.dismiss()
        gate.release(.failure(CancellationError()))
        hosting = nil
        replacementHosting = nil
        try? FileManager.default.removeItem(at: root)
    }

    private static func makeImage(width: Int, height: Int, color: CGColor) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}

@MainActor
private final class WindowEditorAcquisitionGate {
    private var continuation: CheckedContinuation<FrozenWindow, Error>?
    private var result: Result<FrozenWindow, Error>?
    private(set) var started = false

    func acquire() async throws -> FrozenWindow {
        guard !started else { throw CaptureError.failed("Duplicate synthetic Window acquisition") }
        started = true
        if let result { return try result.get() }
        // Deliberately cancellation-insensitive: production must reject late
        // pixels and clean up its own task after cancellation.
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func release(_ result: Result<FrozenWindow, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}
