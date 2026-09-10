import XCTest
import AppKit
@testable import SwiftShot

@MainActor
final class HotPathIntegrationTests: XCTestCase {
    // A restored old editor is not proof that the requested system capture started.
    func testStartIntentRejectsRecoveryAdmissionFailureWhilePreservingOldCapture() async throws {
        let fixture = try HotPathFixture(maximumRecoveryBytes: 0)
        defer { fixture.cleanUp() }
        let previous = CaptureDocument(image: fixture.image)
        fixture.app.lastDocument = previous

        do {
            try await fixture.app.performIntent(.start(mode: .window, quickCopy: false, privateCapture: false))
            XCTFail("Start Capture reported success after recovery refused the new session")
        } catch {
            XCTAssertTrue(error is CaptureError)
        }

        XCTAssertTrue(fixture.presenter.activeDocument === previous, "The rejected action must preserve the old editable capture")
        XCTAssertEqual(fixture.capture.calls, 0, "Recovery refusal must prevent new acquisition")
        XCTAssertNotNil(fixture.app.recoveryProblem)
    }

    // Interactive Start Capture succeeds at selector handoff, before any user selection.
    func testStartIntentAcceptsNewSelectorWithoutClaimingClipboardCompletion() async throws {
        let fixture = try HotPathFixture()
        defer { fixture.cleanUp() }

        try await fixture.app.performIntent(.start(mode: .region, quickCopy: true, privateCapture: true))

        XCTAssertEqual(fixture.capture.calls, 1)
        XCTAssertEqual(fixture.app.phase, .editing)
        XCTAssertNotNil(fixture.presenter.onDocument, "The successful action must actually hand off a selector")
        XCTAssertNil(fixture.app.lastDocument)
        XCTAssertNil(fixture.clipboard.png, "Starting an interactive selector is not a completed Quick Copy")
        fixture.app.closeEditor()
    }

    // A newer selector's editing phase cannot make a superseded intent successful.
    func testSupersededStartIntentRejectsUnrelatedReplacementSelector() async throws {
        let fixture = try HotPathFixture()
        let gate = HotPathWindowGate()
        defer { gate.release(); fixture.cleanUp() }
        fixture.capture.freezeOperation = { await gate.hold() }
        let first = Task { try await fixture.app.performIntent(.start(mode: .window, quickCopy: false, privateCapture: false)) }
        try await wait { gate.started }
        fixture.app.closeEditor()
        fixture.capture.freezeOperation = nil
        await fixture.app.capture(mode: .region)
        XCTAssertEqual(fixture.app.phase, .editing)
        gate.release()

        do {
            try await first.value
            XCTFail("The replaced intent claimed the newer selector's success")
        } catch {
            XCTAssertTrue(error is CaptureError || error is CancellationError)
        }
        XCTAssertEqual(fixture.capture.calls, 2)
        XCTAssertEqual(fixture.presenter.presentedModes, [.region], "Only the replacement selector may be presented")
        XCTAssertEqual(fixture.app.phase, .editing, "Rejecting an old request must not dismiss its replacement")
        fixture.app.closeEditor()
    }

    // Cancellation may arrive after a provider's last check but before UI publication.
    func testCanceledStartIntentDoesNotPublishLateAcquisition() async throws {
        let fixture = try HotPathFixture()
        let gate = HotPathWindowGate()
        defer { gate.release(); fixture.cleanUp() }
        fixture.capture.freezeOperation = { await gate.hold() }
        let operation = Task { try await fixture.app.performIntent(.start(mode: .region, quickCopy: true, privateCapture: true)) }
        try await wait { gate.started }
        operation.cancel()
        gate.release()

        do {
            try await operation.value
            XCTFail("Canceled Start Capture published its late acquisition")
        } catch {
            XCTAssertTrue(error is CaptureError || error is CancellationError)
        }
        XCTAssertNil(fixture.presenter.onDocument, "Cancellation must not publish a selector")
        XCTAssertNil(fixture.app.lastDocument)
        XCTAssertNil(fixture.clipboard.png)
        XCTAssertEqual(fixture.app.phase, .idle)
    }

    // Last Region must not copy pixels returned after its Shortcuts caller canceled.
    func testCanceledLastRegionIntentDoesNotPublishOrCopyLateAcquisition() async throws {
        let fixture = try HotPathFixture()
        let gate = HotPathWindowGate()
        defer { gate.release(); fixture.cleanUp() }
        await fixture.app.capture(mode: .region, privateCapture: true)
        let frame = CGRect(x: 0, y: 0, width: 64, height: 40)
        let screen = FrozenScreen(id: 1, frame: frame, image: fixture.image, windows: [])
        fixture.presenter.actions.selectedRegion(screen, frame)
        XCTAssertNotNil(fixture.app.lastRegion)
        fixture.app.closeEditor()
        fixture.presenter.onDocument = nil
        fixture.capture.regionOperation = { await gate.hold() }
        let operation = Task { try await fixture.app.performIntent(.lastRegion(quickCopy: true)) }
        try await wait { gate.started }
        operation.cancel()
        gate.release()

        do {
            try await operation.value
            XCTFail("Canceled Recapture Last Region copied a late acquisition")
        } catch {
            XCTAssertTrue(error is CaptureError || error is CancellationError)
        }
        XCTAssertNil(fixture.app.lastDocument, "Cancellation must not publish the recaptured pixels")
        XCTAssertNil(fixture.clipboard.png)
        XCTAssertNil(fixture.presenter.activeDocument)
        XCTAssertEqual(fixture.app.phase, .idle)
        _ = await fixture.app.prepareToQuit()
    }

    func testCaptureAndCopyMarkRealBoundariesButNeverInventPasteOrUIReadiness() async throws {
        let diagnostics = PerformanceDiagnostics(recorder: WorkflowPerformance())
        diagnostics.setEnabled(true)
        let run = try XCTUnwrap(diagnostics.beginRun())
        let fixture = try HotPathFixture(diagnostics: diagnostics)
        defer { fixture.cleanUp() }
        await fixture.app.capture(mode: .region)
        XCTAssertTrue(diagnostics.activeStages.contains(.captureRequested))
        XCTAssertFalse(diagnostics.activeStages.contains(.selectorReady), "A presenter return is not a presented frame")
        fixture.presenter.actions.selectorPresented?()
        XCTAssertTrue(diagnostics.activeStages.contains(.selectorReady))
        fixture.presenter.actions.selectionCommitted?()
        let document = CaptureDocument(image: fixture.image)
        fixture.presenter.select(document)
        XCTAssertEqual(document.performanceRunID, run)
        XCTAssertTrue(diagnostics.activeStages.contains(.selectionCommitted))
        XCTAssertFalse(diagnostics.activeStages.contains(.editorReady))
        fixture.presenter.actions.editorPresented?()
        XCTAssertTrue(diagnostics.activeStages.contains(.editorReady))
        let copied = await fixture.app.copy(document)
        XCTAssertTrue(copied)
        XCTAssertTrue(diagnostics.activeStages.contains(.copyRequested))
        XCTAssertTrue(diagnostics.activeStages.contains(.clipboardReady))
        XCTAssertFalse(diagnostics.activeStages.contains(.pasteVerified))
        _ = await fixture.app.prepareToQuit()
    }

    func testOldDocumentCopyDoesNotContaminateNewDiagnosticRun() async throws {
        let diagnostics = PerformanceDiagnostics(recorder: WorkflowPerformance())
        diagnostics.setEnabled(true)
        let first = try XCTUnwrap(diagnostics.beginRun())
        let fixture = try HotPathFixture(diagnostics: diagnostics)
        defer { fixture.cleanUp() }
        await fixture.app.capture(mode: .region)
        let document = CaptureDocument(image: fixture.image)
        fixture.presenter.select(document)
        XCTAssertEqual(document.performanceRunID, first)
        diagnostics.finish(outcome: .canceled, for: first)
        let second = try XCTUnwrap(diagnostics.beginRun())
        let copied = await fixture.app.copy(document)
        XCTAssertTrue(copied)
        XCTAssertEqual(diagnostics.activeRunID, second)
        XCTAssertTrue(diagnostics.activeStages.isEmpty, "Old async work cannot attach itself to the newest run")
        _ = await fixture.app.prepareToQuit()
    }

    // The AppState/provider boundary must carry the armed ID, not choose an untraced overload.
    func testWindowCapturePassesOriginatingDiagnosticIDThroughProviderBoundary() async throws {
        let diagnostics = PerformanceDiagnostics(recorder: WorkflowPerformance())
        diagnostics.setEnabled(true)
        let run = try XCTUnwrap(diagnostics.beginRun())
        let fixture = try HotPathFixture(diagnostics: diagnostics)
        defer { fixture.cleanUp() }
        await fixture.app.capture(mode: .window)

        let result = try await fixture.presenter.actions.captureWindow(41, 1)

        XCTAssertEqual(fixture.capture.windowRequests, [.init(windowID: 41, displayID: 1, traceRunID: run, usedTracedOverload: true)])
        XCTAssertEqual(result.id, 41)
        XCTAssertTrue(try XCTUnwrap(result.snapshot) === fixture.image)
        XCTAssertFalse(diagnostics.activeStages.contains(.editorReady), "Acquisition return is not editor presentation")
    }

    // Starting a new diagnostic run must not relabel already captured callbacks or in-flight work.
    func testWindowCaptureRetainsOriginatingIDAcrossAwaitAndLaterInvocation() async throws {
        let diagnostics = PerformanceDiagnostics(recorder: WorkflowPerformance())
        diagnostics.setEnabled(true)
        let first = try XCTUnwrap(diagnostics.beginRun())
        let fixture = try HotPathFixture(diagnostics: diagnostics)
        let gate = HotPathWindowGate()
        defer { gate.release(); fixture.capture.windowOperation = nil; fixture.cleanUp() }
        let image = fixture.image
        fixture.capture.windowOperation = { id, _, _ in
            await gate.hold()
            return FrozenWindow(id: id, title: "Fixture", frame: CGRect(x: 0, y: 0, width: 64, height: 40), snapshot: image)
        }
        await fixture.app.capture(mode: .window)
        let capturedCallback = fixture.presenter.actions.captureWindow
        let operation = Task { try await capturedCallback(41, 1) }
        try await wait { gate.started }
        diagnostics.finish(outcome: .canceled, for: first)
        let second = try XCTUnwrap(diagnostics.beginRun())
        gate.release()
        let result = try await operation.value
        let laterResult = try await capturedCallback(42, 1)

        XCTAssertEqual(fixture.capture.windowRequests, [
            .init(windowID: 41, displayID: 1, traceRunID: first, usedTracedOverload: true),
            .init(windowID: 42, displayID: 1, traceRunID: first, usedTracedOverload: true)])
        XCTAssertEqual([result.id, laterResult.id], [41, 42])
        XCTAssertEqual(diagnostics.activeRunID, second)
        XCTAssertTrue(diagnostics.activeStages.isEmpty, "Old acquisition callbacks cannot supply the new run's readiness")
    }

    // A selector created without an armed run stays untraced if diagnostics is armed later.
    func testUnarmedWindowCallbackPassesExplicitNilAfterAnotherRunBegins() async throws {
        let diagnostics = PerformanceDiagnostics(recorder: WorkflowPerformance())
        diagnostics.setEnabled(true)
        let fixture = try HotPathFixture(diagnostics: diagnostics)
        defer { fixture.cleanUp() }
        await fixture.app.capture(mode: .window)
        let run = try XCTUnwrap(diagnostics.beginRun())

        _ = try await fixture.presenter.actions.captureWindow(41, 1)

        XCTAssertEqual(fixture.capture.windowRequests, [.init(windowID: 41, displayID: 1, traceRunID: nil, usedTracedOverload: true)])
        XCTAssertEqual(diagnostics.activeRunID, run)
        XCTAssertTrue(diagnostics.activeStages.isEmpty)
    }

    // Adding a traced protocol entry point must preserve legacy-provider success and failure.
    func testWindowCaptureCompatibilityPreservesLegacyProviderResult() async throws {
        let fixture = try HotPathFixture(captureProvider: { HotPathLegacyWindowCapture(image: $0) })
        defer { fixture.cleanUp() }
        await fixture.app.capture(mode: .window)

        let result = try await fixture.presenter.actions.captureWindow(73, 1)

        XCTAssertEqual(result.id, 73)
        XCTAssertTrue(try XCTUnwrap(result.snapshot) === fixture.image)
    }

    func testWindowCaptureCompatibilityPreservesLegacyProviderError() async throws {
        let fixture = try HotPathFixture(captureProvider: { HotPathLegacyWindowCapture(image: $0, fails: true) })
        defer { fixture.cleanUp() }
        await fixture.app.capture(mode: .window)

        do {
            _ = try await fixture.presenter.actions.captureWindow(73, 1)
            XCTFail("The compatibility path swallowed the provider's failure")
        } catch {
            XCTAssertEqual(error as? HotPathWindowError, .intentional)
        }
    }

    // Selector ownership must cross both provider calls even when diagnostics is unarmed.
    func testWindowSelectorTokenFlowsFromFreezeThroughAcquisition() async throws {
        let fixture = try HotPathFixture()
        defer { fixture.cleanUp() }
        await fixture.app.capture(mode: .window)
        _ = try await fixture.presenter.actions.captureWindow(41, 1)

        XCTAssertEqual(fixture.capture.selectorFreezeIDs.count, 1, "Window freeze did not receive a selector owner")
        XCTAssertEqual(fixture.capture.windowSelectorIDs.count, 1, "Window acquisition did not receive a selector owner")
        XCTAssertEqual(fixture.capture.windowSelectorIDs, fixture.capture.selectorFreezeIDs,
                       "Click-time acquisition must use the token that produced this selector")
    }

    // Diagnostic runs may change without replacing the capture selector's ownership.
    func testWindowSelectorTokenDoesNotChangeWhenDiagnosticRunIsReplaced() async throws {
        let diagnostics = PerformanceDiagnostics(recorder: WorkflowPerformance())
        diagnostics.setEnabled(true)
        let first = try XCTUnwrap(diagnostics.beginRun())
        let fixture = try HotPathFixture(diagnostics: diagnostics)
        defer { fixture.cleanUp() }
        await fixture.app.capture(mode: .window)
        let callback = fixture.presenter.actions.captureWindow
        _ = try await callback(41, 1)
        diagnostics.finish(outcome: .canceled, for: first)
        _ = try XCTUnwrap(diagnostics.beginRun())
        _ = try await callback(42, 1)

        XCTAssertEqual(fixture.capture.windowSelectorIDs.count, 2)
        let selector = try XCTUnwrap(fixture.capture.selectorFreezeIDs.first,
                                     "Window freeze did not receive a selector owner")
        XCTAssertNotEqual(selector, first, "Selector lifetime must not be keyed by the diagnostic run")
        XCTAssertEqual(fixture.capture.windowSelectorIDs, [selector, selector])
    }

    // Navigation must release reusable metadata and reject both suspended results and later old clicks.
    func testWindowNavigationInvalidatesMetadataAndRejectsStaleCallbackAtEntryAndReturn() async throws {
        let fixture = try HotPathFixture()
        let gate = HotPathWindowGate()
        defer { gate.release(); fixture.capture.windowOperation = nil; fixture.cleanUp() }
        let image = fixture.image
        fixture.capture.windowOperation = { id, _, _ in
            await gate.hold()
            return FrozenWindow(id: id, title: "Fixture", frame: CGRect(x: 0, y: 0, width: 64, height: 40), snapshot: image)
        }
        await fixture.app.capture(mode: .window)
        let oldCallback = fixture.presenter.actions.captureWindow
        let operation = Task { try await oldCallback(41, 1) }
        try await wait { gate.started }
        let invalidations = fixture.capture.windowMetadataInvalidations
        fixture.app.closeEditor()
        XCTAssertGreaterThan(fixture.capture.windowMetadataInvalidations, invalidations,
                             "Closing/navigation did not invalidate selector metadata")
        gate.release()
        do {
            _ = try await operation.value
            XCTFail("A pre-navigation acquisition result escaped the return-token guard")
        } catch { XCTAssertTrue(error is CancellationError) }

        await fixture.app.capture(mode: .window)
        let requestsBeforeOldClick = fixture.capture.windowRequests.count
        do {
            _ = try await oldCallback(42, 1)
            XCTFail("The old selector callback bypassed the entry-token guard")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.capture.windowRequests.count, requestsBeforeOldClick,
                       "The stale click must be rejected before contacting the capture provider")
        XCTAssertEqual(fixture.capture.selectorFreezeIDs.count, 2)
        if fixture.capture.selectorFreezeIDs.count == 2 {
            XCTAssertNotEqual(fixture.capture.selectorFreezeIDs[0], fixture.capture.selectorFreezeIDs[1])
        }
    }

    func testEditorProvidesDragRendererAndClosesAfterNativeDragEnds() async throws {
        let fixture = try HotPathFixture()
        defer { fixture.cleanUp() }
        await fixture.app.capture(mode: .region)
        let document = CaptureDocument(image: fixture.image)
        fixture.presenter.select(document)
        XCTAssertNotNil(fixture.presenter.actions.dragRenderer)
        fixture.presenter.actions.dragEnded()
        XCTAssertNil(fixture.presenter.activeDocument)
        XCTAssertTrue(fixture.app.lastDocument === document, "Closing a drag must retain the editable original")
        _ = await fixture.app.prepareToQuit()
    }

    // Disk contention must not delay a new selector once a coordinator owns the old pixels.
    func testCaptureStartsWhilePreviousRecoveryDiskWriteIsBlocked() async throws {
        let fixture = try HotPathFixture()
        defer { fixture.cleanUp() }
        fixture.app.lastDocument = CaptureDocument(image: fixture.image)
        let gate = HotPathDiskGate()
        defer { gate.release() }
        let hold = Task.detached { await fixture.store.holdForHotPathTest(gate) }
        try await wait { gate.started }
        let capture = Task { await fixture.app.capture(mode: .region) }
        let started = await eventually { fixture.capture.calls == 1 }
        gate.release()
        await hold.value
        await capture.value
        XCTAssertTrue(started, "Capture waited on disk instead of transferring snapshot ownership")
    }

    // A slow history drive must not extend Copy→clipboard latency.
    func testCopyPublishesBeforeRecoveryDiskUnblocks() async throws {
        let fixture = try HotPathFixture()
        defer { fixture.cleanUp() }
        let document = CaptureDocument(image: fixture.image)
        fixture.app.lastDocument = document
        let gate = HotPathDiskGate()
        defer { gate.release() }
        let hold = Task.detached { await fixture.store.holdForHotPathTest(gate) }
        try await wait { gate.started }
        let copy = Task { await fixture.app.copy(document) }
        let published = await eventually { fixture.clipboard.png != nil }
        gate.release()
        await hold.value
        await copy.value
        XCTAssertTrue(published, "Clipboard readiness must not depend on recovery PNG or directory reads")
    }

    // The private designation must be captured at selection and survive later preference changes.
    func testPrivateSelectionNeverPersistsAfterPreferenceIsTurnedOff() async throws {
        let fixture = try HotPathFixture()
        defer { fixture.cleanUp() }
        fixture.app.appSettings.privateCapture = true
        await fixture.app.capture(mode: .region)
        let document = CaptureDocument(image: fixture.image)
        fixture.presenter.select(document)
        fixture.app.appSettings.privateCapture = false
        _ = await fixture.app.preserve(document)
        let records = try await fixture.store.records()
        XCTAssertTrue(records.isEmpty, "Changing preferences must not make a private original durable")
    }

    // Enabling fast copy must not accidentally apply the editing workflow's decorative preset.
    func testImmediateCopyUsesSeparateRawPreset() async throws {
        let fixture = try HotPathFixture()
        defer { fixture.cleanUp() }
        fixture.app.appSettings.immediateCopy = true
        fixture.app.appSettings.style.backgroundID = "bundled:blue"
        await fixture.app.capture(mode: .region)
        XCTAssertEqual(fixture.presenter.style?.backgroundID, "")
    }

    func testQuitClosesInteractionBeforeAwaitingDiskAndRejectsNewExports() async throws {
        let fixture = try HotPathFixture()
        defer { fixture.cleanUp() }
        await fixture.app.capture(mode: .region)
        let document = CaptureDocument(image: fixture.image)
        fixture.presenter.select(document)
        let gate = HotPathDiskGate()
        defer { gate.release() }
        let hold = Task.detached { await fixture.store.holdForHotPathTest(gate) }
        try await wait { gate.started }
        let quitting = Task { await fixture.app.prepareToQuit() }
        let closed = await eventually { fixture.presenter.activeDocument == nil }
        await fixture.app.copy(document)
        XCTAssertTrue(closed, "Quit must close mutable UI before taking its final snapshot")
        XCTAssertNil(fixture.clipboard.png, "A new export was admitted after shutdown began")
        gate.release(); await hold.value
        let finished = await quitting.value
        XCTAssertTrue(finished)
    }

    func testFailedQuitReopensEditorWithWorkingRecoveryCallbacks() async throws {
        let fixture = try HotPathFixture()
        defer { fixture.cleanUp() }
        // A regular file where a recovery directory belongs creates a real filesystem failure.
        try Data("blocked".utf8).write(to: fixture.root.appendingPathComponent("recovery"))
        await fixture.app.capture(mode: .region)
        let document = CaptureDocument(image: fixture.image)
        fixture.presenter.select(document)
        let finished = await fixture.app.prepareToQuit()
        XCTAssertFalse(finished)
        XCTAssertTrue(fixture.presenter.activeDocument === document)
        document.change { $0.style.padding = 90 }
        fixture.presenter.select(document)
        XCTAssertEqual(fixture.app.appSettings.style.padding, 90, "Failed quit left stale session callbacks installed")
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<50 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func wait(_ condition: @MainActor () -> Bool) async throws {
        if !(await eventually(condition)) { throw NSError(domain: "HotPathFixture", code: 1) }
    }
}

@MainActor
private struct HotPathFixture {
    let root: URL
    let image: CGImage
    let store: RecoveryStore
    let capture: HotPathCapture
    let presenter: HotPathPresenter
    let clipboard: HotPathClipboard
    let app: AppState

    init(diagnostics: PerformanceDiagnostics? = nil, maximumRecoveryBytes: Int? = nil,
         captureProvider: (@MainActor (CGImage) -> any ScreenCaptureProviding)? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftShotHotPath-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
        image = try XCTUnwrap(context.makeImage())
        store = RecoveryStore(root: root.appendingPathComponent("recovery"))
        capture = HotPathCapture(image: image)
        presenter = HotPathPresenter()
        clipboard = HotPathClipboard()
        let recoveryStore = store
        let coordinator = maximumRecoveryBytes.map { RecoveryCoordinator(store: recoveryStore, maximumPendingBytes: $0) }
        app = AppState(defaults: UserDefaults(suiteName: "SwiftShotHotPath.\(UUID())")!, recovery: store,
            backgrounds: BackgroundLibrary(rootURL: root.appendingPathComponent("backgrounds")), clipboard: clipboard,
            presentsUI: false, captureService: captureProvider?(image) ?? capture, overlay: presenter, diagnostics: diagnostics,
            recoveryCoordinator: coordinator)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private final class HotPathCapture: ScreenCaptureProviding {
    struct WindowRequest: Equatable {
        let windowID: UInt32
        let displayID: UInt32
        let traceRunID: UUID?
        let usedTracedOverload: Bool
    }
    let image: CGImage
    var calls = 0
    var windowRequests: [WindowRequest] = []
    var selectorFreezeIDs: [UUID] = []
    var windowSelectorIDs: [UUID] = []
    var windowMetadataInvalidations = 0
    var freezeOperation: (@MainActor () async -> Void)?
    var regionOperation: (@MainActor () async -> Void)?
    var windowOperation: (@MainActor (UInt32, UInt32, UUID?) async throws -> FrozenWindow)?
    init(image: CGImage) { self.image = image }
    func freeze(mode: CaptureMode) async throws -> [FrozenScreen] {
        calls += 1
        if let freezeOperation { await freezeOperation() }
        return [FrozenScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 64, height: 40), image: image, windows: [])]
    }
    // Extra methods before protocol integration keep the initial routing RED compile-safe.
    func freeze(mode: CaptureMode, selectorID: UUID) async throws -> [FrozenScreen] {
        selectorFreezeIDs.append(selectorID)
        return try await freeze(mode: mode)
    }
    func captureWindow(id: UInt32, onDisplayID displayID: UInt32, selectorID: UUID,
                       traceRunID: UUID?) async throws -> FrozenWindow {
        windowSelectorIDs.append(selectorID)
        return try await captureWindow(id: id, onDisplayID: displayID, traceRunID: traceRunID)
    }
    func invalidateWindowMetadata() { windowMetadataInvalidations += 1 }
    func currentDisplayFrame(id: UInt32) -> CGRect? { id == 1 ? CGRect(x: 0, y: 0, width: 64, height: 40) : nil }
    func captureRegion(displayID: UInt32, rect: CGRect) async throws -> CGImage {
        if let regionOperation { await regionOperation() }
        return image
    }
    func captureWindow(id: UInt32, onDisplayID displayID: UInt32) async throws -> FrozenWindow {
        windowRequests.append(.init(windowID: id, displayID: displayID, traceRunID: nil, usedTracedOverload: false))
        return try await acquireWindow(id: id, displayID: displayID, traceRunID: nil)
    }
    // Keep both paths observable so a caller that drops the originating trace ID
    // fails the boundary assertions without changing the returned fixture image.
    func captureWindow(id: UInt32, onDisplayID displayID: UInt32, traceRunID: UUID?) async throws -> FrozenWindow {
        windowRequests.append(.init(windowID: id, displayID: displayID, traceRunID: traceRunID, usedTracedOverload: true))
        return try await acquireWindow(id: id, displayID: displayID, traceRunID: traceRunID)
    }
    private func acquireWindow(id: UInt32, displayID: UInt32, traceRunID: UUID?) async throws -> FrozenWindow {
        if let windowOperation { return try await windowOperation(id, displayID, traceRunID) }
        return FrozenWindow(id: id, title: "Fixture", frame: CGRect(x: 0, y: 0, width: 64, height: 40), snapshot: image)
    }
}

private enum HotPathWindowError: Error, Equatable { case intentional }

@MainActor
private final class HotPathLegacyWindowCapture: ScreenCaptureProviding {
    let image: CGImage
    let fails: Bool
    init(image: CGImage, fails: Bool = false) { self.image = image; self.fails = fails }
    func freeze(mode: CaptureMode) async throws -> [FrozenScreen] {
        [FrozenScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 64, height: 40), image: image, windows: [])]
    }
    func captureWindow(id: UInt32, onDisplayID: UInt32) async throws -> FrozenWindow {
        if fails { throw HotPathWindowError.intentional }
        return FrozenWindow(id: id, title: "Legacy fixture", frame: CGRect(x: 0, y: 0, width: 64, height: 40), snapshot: image)
    }
}

@MainActor
private final class HotPathWindowGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var started = false
    func hold() async {
        started = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

@MainActor
private final class HotPathPresenter: CapturePresenting {
    var presentedModes: [CaptureMode] = []
    var actions = CaptureActions()
    func configure(actions: CaptureActions) { self.actions = actions }
    var activeDocument: CaptureDocument?
    var style: CaptureStyle?
    var onDocument: ((CaptureDocument) -> Void)?
    func select(_ document: CaptureDocument) { activeDocument = document; onDocument?(document) }
    func present(screens: [FrozenScreen], mode: CaptureMode, style: CaptureStyle,
                 library: BackgroundLibrary, onDocument: @escaping (CaptureDocument) -> Void,
                 onCopy: @escaping (CaptureDocument) -> Void, onSave: @escaping (CaptureDocument) -> Void,
                 onOCR: @escaping (CaptureDocument) -> Void, onCancel: @escaping () -> Void,
                 onDiscard: @escaping (CaptureDocument) -> Void) {
        presentedModes.append(mode)
        self.style = style; self.onDocument = onDocument
    }
    func reopen(document: CaptureDocument, library: BackgroundLibrary,
                onCopy: @escaping (CaptureDocument) -> Void, onSave: @escaping (CaptureDocument) -> Void,
                onCancel: @escaping () -> Void, onDocument: @escaping (CaptureDocument) -> Void,
                onDiscard: @escaping (CaptureDocument) -> Void) {
        activeDocument = document; self.onDocument = onDocument
    }
    func dismiss() { activeDocument = nil }
    func showStatus(_ message: String, isError: Bool) {}
}

@MainActor
private final class HotPathClipboard: CaptureClipboard {
    var png: Data?
    func copyPNGData(_ data: Data) -> Bool { png = data; return true }
    func copyText(_ text: String) -> Bool { true }
}

private final class HotPathDiskGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var didStart = false
    private var released = false
    var started: Bool { condition.lock(); defer { condition.unlock() }; return didStart }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func hold() {
        condition.lock()
        defer { condition.unlock() }
        didStart = true
        let deadline = Date().addingTimeInterval(5)
        while !released { if !condition.wait(until: deadline) { return } }
    }
}

extension RecoveryStore {
    fileprivate func holdForHotPathTest(_ gate: HotPathDiskGate) { gate.hold() }
}
