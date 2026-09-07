import XCTest
import AppKit
import CoreText
@testable import SwiftShot

@MainActor
final class AsyncWorkflowTests: XCTestCase {
    func testEditingDuringDelayedSaveDoesNotMarkNewRevisionSaved() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exporter = GatedExporter()
        defer { exporter.release() }
        let recovery = RecoveryStore(root: root.appendingPathComponent("recovery"))
        let app = makeState(root: root, recovery: recovery, exporter: exporter)
        let document = CaptureDocument(image: try fixture())
        app.lastDocument = document
        let save = Task { await app.save(document) }
        for _ in 0..<500 {
            if exporter.hasStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(exporter.hasStarted, "Export must reach the controlled suspension")
        document.change { $0.crop = CGRect(x: 5, y: 10, width: 70, height: 40) }
        exporter.release()
        await save.value
        XCTAssertNil(document.savedURL, "The export contains the old revision, not these new edits")
        let preserved = try await recovery.load(id: document.id)
        XCTAssertEqual(preserved.record.revision, document.revision)
        XCTAssertEqual(preserved.record.edits.crop, document.edits.crop)
        XCTAssertNil(preserved.record.savedPath)
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("exports"), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1, "The originally requested export should still succeed")
    }

    func testFailedPreservationPreventsReopeningAndRetainsCurrentOriginal() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let occupied = root.appendingPathComponent("recovery-is-a-file")
        try Data("occupied".utf8).write(to: occupied)
        let app = makeState(root: root, recovery: RecoveryStore(root: occupied))
        let current = CaptureDocument(image: try fixture())
        app.lastDocument = current
        await app.reopenRecovery(UUID())
        XCTAssertTrue(app.lastDocument === current)
        XCTAssertTrue(app.statusMessage?.contains("Recovery couldn't be updated") == true,
                      "Navigation must stop at preservation failure rather than attempt to load another record")
    }

    func testDiscardedDocumentCannotBeResurrectedByLateAppPreservation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = RecoveryStore(root: root.appendingPathComponent("recovery"))
        let app = makeState(root: root, recovery: recovery)
        let document = CaptureDocument(image: try fixture())
        app.lastDocument = document
        _ = await app.preserve(document)
        await app.discard(document)
        document.change { $0.style.padding = 100 }
        _ = await app.preserve(document)
        let records = try await recovery.records()
        XCTAssertTrue(records.isEmpty)
        XCTAssertNil(app.lastDocument)
    }

    func testRecoveryStoreIgnoresPersistenceArrivingAfterExplicitDiscard() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = RecoveryStore(root: root)
        let document = CaptureDocument(image: try fixture())
        try await recovery.persist(id: document.id, image: document.image, edits: document.edits, revision: 0, savedURL: nil)
        try await recovery.discard(id: document.id)
        // Models a persistence task that already crossed its caller's cancellation check.
        try await recovery.persist(id: document.id, image: document.image, edits: document.edits, revision: 0, savedURL: nil)
        let records = try await recovery.records()
        XCTAssertTrue(records.isEmpty, "The storage boundary must not resurrect an explicitly discarded capture")
    }

    func testPruningProtectsOpenSavedCaptureAndAllUnsavedCaptures() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = RecoveryStore(root: root)
        let image = try fixture()
        let open = UUID(), unsaved = UUID(), old = UUID(), latest = UUID()
        let edits = CaptureEdits(crop: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for id in [open, unsaved, old, latest] {
            try await recovery.persist(id: id, image: image, edits: edits, revision: 0,
                                       savedURL: id == unsaved ? nil : root.appendingPathComponent("export.png"))
        }
        try await recovery.pruneSaved(except: latest, protected: [open])
        let records = try await recovery.records()
        XCTAssertEqual(Set(records.map(\.id)), Set([open, unsaved, latest]))
        let reopened = try await recovery.load(id: open)
        XCTAssertEqual(reopened.image.width, image.width)
    }

    func testVisionRecognizesRenderedTextFixture() async throws {
        let image = try fixture(text: "SwiftShot Capture Test")
        let text = try await OCRService.shared.recognizeText(in: image)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("SwiftShot Capture Test"), "Vision returned: \(text)")
    }

    private func makeState(root: URL, recovery: RecoveryStore, exporter: any CaptureExporting = ExportService()) -> AppState {
        let defaults = UserDefaults(suiteName: "SwiftShotAsyncTests.\(UUID())")!
        let app = AppState(defaults: defaults, recovery: recovery,
                           backgrounds: BackgroundLibrary(rootURL: root.appendingPathComponent("backgrounds")),
                           exporter: exporter, clipboard: AsyncTestClipboard(), presentsUI: false)
        app.appSettings.saveDirectory = root.appendingPathComponent("exports").path
        return app
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftShotAsyncTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func fixture(text: String? = nil) throws -> CGImage {
        let width = text == nil ? 120 : 1000
        let height = text == nil ? 80 : 180
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let text {
            let font = CTFontCreateWithName("Helvetica" as CFString, 56, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ]))
            context.textPosition = CGPoint(x: 30, y: 70)
            CTLineDraw(line, context)
        }
        return try XCTUnwrap(context.makeImage())
    }
}

private final class GatedExporter: CaptureExporting, @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false

    var hasStarted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return started
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func savePNGData(_ data: Data, to directory: String) throws -> URL {
        condition.lock()
        started = true
        condition.broadcast()
        let deadline = Date().addingTimeInterval(10)
        while !released {
            if !condition.wait(until: deadline) {
                condition.unlock()
                throw CaptureError.failed("The test did not release its export gate in time")
            }
        }
        condition.unlock()
        return try ExportService().savePNGData(data, to: directory)
    }
}

@MainActor
private final class AsyncTestClipboard: CaptureClipboard {
    func copyPNGData(_ data: Data) -> Bool { true }
    func copyText(_ text: String) -> Bool { true }
}
