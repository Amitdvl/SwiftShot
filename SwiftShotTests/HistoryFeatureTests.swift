import AppKit
import XCTest
@testable import SwiftShot

@MainActor
final class HistoryFeatureTests: XCTestCase {
    // Opening and selecting history must never implicitly delete original pixels.
    func testHistoryDeletionOccursOnlyThroughExplicitCallback() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root), id = UUID()
        try await persist(store, id: id)
        var deleted: [UUID] = []
        let model = CaptureHistoryModel(store: store, onOpen: { _ in }, onPin: { _ in },
            onDelete: { id in deleted.append(id); try await store.discard(id: id) },
            onCombine: { _, _ in }, onRetentionChange: { _ in })
        await model.reload()
        model.selection = [id]
        XCTAssertTrue(deleted.isEmpty)
        let before = try await store.records()
        XCTAssertEqual(before.map(\.id), [id])
        await model.deleteSelected()
        XCTAssertEqual(deleted, [id])
        let after = try await store.records()
        XCTAssertTrue(after.isEmpty)
        XCTAssertTrue(model.selection.isEmpty)
    }

    func testHistorySearchFiltersLocalOCRAndKeepsSelectionValid() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root), invoice = UUID(), other = UUID()
        try await persist(store, id: invoice)
        try await persist(store, id: other)
        try await store.indexOCR(id: invoice, text: "Invoice 123", revision: 0, privateCapture: false)
        let model = CaptureHistoryModel(store: store, onOpen: { _ in }, onPin: { _ in },
            onDelete: { _ in }, onCombine: { _, _ in }, onRetentionChange: { _ in })
        await model.reload()
        model.selection = [other]
        model.query = "invoice"
        await model.reload()
        XCTAssertEqual(model.entries.map(\.id), [invoice])
        XCTAssertTrue(model.selection.isEmpty)
    }

    func testRetentionChoiceIsCallbackOnlyAndProtectPinPersists() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root), id = UUID()
        try await persist(store, id: id)
        var policies: [RecoveryRetentionPolicy] = []
        let model = CaptureHistoryModel(store: store, onOpen: { _ in }, onPin: { _ in },
            onDelete: { _ in }, onCombine: { _, _ in }, onRetentionChange: { policies.append($0) })
        await model.reload()
        await model.toggleKeep(id: id)
        let saved = try await store.load(id: id)
        XCTAssertTrue(saved.record.isPinned)
        await model.applyRetention(RecoveryRetentionPolicy(maximumSavedCount: 100))
        XCTAssertEqual(policies, [RecoveryRetentionPolicy(maximumSavedCount: 100)])
        let remaining = try await store.records()
        XCTAssertEqual(remaining.count, 1, "UI delegates retention; it never runs a second hidden deletion")
    }

    func testHistoryCombineUsesVisibleTopToBottomOrder() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root), first = UUID(), second = UUID()
        try await persist(store, id: first)
        try await persist(store, id: second)
        var combined: [UUID] = [], axis: HistoryCombineAxis?
        let model = CaptureHistoryModel(store: store, onOpen: { _ in }, onPin: { _ in },
            onDelete: { _ in }, onCombine: { ids, chosen in combined = ids; axis = chosen }, onRetentionChange: { _ in })
        await model.reload()
        model.selection = [first, second]
        await model.combineSelected(axis: .vertical)
        XCTAssertEqual(combined, [second, first])
        XCTAssertEqual(axis, .vertical)
    }

    func testIndexingUsesEditedBitmapWithoutPNGEncoding() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root), id = UUID(), image = try fixture()
        let edits = CaptureEdits(crop: CGRect(x: 0, y: 0, width: 16, height: 12), annotations: [
            CaptureAnnotation(kind: .redact, start: .zero, end: CGPoint(x: 16, y: 12))])
        let snapshot = RecoverySnapshot(id: id, image: image, edits: edits, revision: 0, savedURL: nil)
        try await store.persist(id: id, image: image, edits: edits, revision: 0, savedURL: nil)
        let renderer = ImageRenderer(cacheByteLimit: 0, cacheEntryLimit: 0)
        let recognizer = InspectingHistoryRecognizer()
        let indexing = HistoryIndexingCoordinator(store: store, renderer: renderer, recognizer: recognizer)
        let admitted = await indexing.enqueue(snapshot)
        XCTAssertTrue(admitted)
        try await indexing.flush()
        let records = try await store.searchOCR("redacted")
        XCTAssertEqual(records.map(\.id), [id])
        _ = await indexing.enqueue(snapshot)
        try await indexing.flush()
        let statistics = await renderer.cacheStatistics
        XCTAssertEqual(statistics.encodes, 0)
        XCTAssertEqual(statistics.renders, 1, "Already-indexed durable revisions must not rerender for another Copy/Save")
        let observed = await recognizer.observed
        XCTAssertEqual(observed?.width, 16)
        XCTAssertEqual(observed?.height, 12)
        XCTAssertEqual(observed?.firstRed, 0)
    }

    func testDisabledIndexingCancelsLateOCRAndClearsPreviouslyStoredText() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root), id = UUID(), image = try fixture()
        let edits = CaptureEdits(crop: CGRect(x: 0, y: 0, width: 32, height: 24))
        try await store.persist(id: id, image: image, edits: edits, revision: 0, savedURL: nil)
        let previous = UUID()
        try await persist(store, id: previous)
        try await store.indexOCR(id: previous, text: "previous indexed phrase", revision: 0, privateCapture: false)
        let recognizer = GatedHistoryRecognizer()
        let indexing = HistoryIndexingCoordinator(store: store, recognizer: recognizer)
        _ = await indexing.enqueue(RecoverySnapshot(id: id, image: image, edits: edits, revision: 0, savedURL: nil))
        try await recognizer.waitUntilStarted()
        try await indexing.setEnabled(false, clearExistingIndex: true)
        await recognizer.release()
        try await indexing.flush()
        let results = try await store.searchOCR("phrase")
        XCTAssertTrue(results.isEmpty, "Late OCR may not recreate text after the setting was disabled")
        let status = await indexing.status()
        XCTAssertFalse(status.isEnabled)
        XCTAssertEqual(status.pendingCount, 0)
    }

    func testPrivateIndexJobIsNeverAdmittedAndCreatesNoFiles() async throws {
        let parent = try directory(), root = parent.appendingPathComponent("private")
        defer { try? FileManager.default.removeItem(at: parent) }
        let indexing = HistoryIndexingCoordinator(store: RecoveryStore(root: root))
        let admitted = await indexing.enqueue(RecoverySnapshot(id: UUID(), image: try fixture(),
            edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 32, height: 24)), revision: 0, savedURL: nil, privateCapture: true))
        XCTAssertFalse(admitted)
        try await indexing.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testClearingIndexRemovesTextWithoutChangingRecoveryPixelsOrPins() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root), id = UUID()
        try await persist(store, id: id)
        try await store.setPinned(id: id, isPinned: true)
        try await store.indexOCR(id: id, text: "sensitive phrase", revision: 0, privateCapture: false)
        let original = root.appendingPathComponent(id.uuidString).appendingPathComponent("original.png")
        let before = try Data(contentsOf: original)
        try await store.clearOCRIndex()
        let records = try await RecoveryStore(root: root).records()
        XCTAssertEqual(records.map(\.id), [id])
        XCTAssertTrue(records[0].isPinned)
        XCTAssertNil(records[0].ocrText)
        XCTAssertNil(records[0].ocrRevision)
        XCTAssertEqual(try Data(contentsOf: original), before)
    }

    func testIndexCapacityDeclinesOptionalWorkWithoutCreatingHistory() async throws {
        let parent = try directory(), root = parent.appendingPathComponent("bounded")
        defer { try? FileManager.default.removeItem(at: parent) }
        let indexing = HistoryIndexingCoordinator(store: RecoveryStore(root: root), maximumJobs: 0)
        let accepted = await indexing.enqueue(RecoverySnapshot(id: UUID(), image: try fixture(),
            edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 32, height: 24)), revision: 0, savedURL: nil))
        XCTAssertFalse(accepted)
        let status = await indexing.status()
        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertEqual(status.retainedBytes, 0)
        XCTAssertEqual(status.skippedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testCanceledOCRTaskCannotWriteThroughStorageBoundary() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root), id = UUID()
        try await persist(store, id: id)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.indexOCR(id: id, text: "canceled private phrase", revision: 0, privateCapture: false)
        }
        do { try await task.value } catch is CancellationError { }
        let matches = try await store.searchOCR("canceled")
        XCTAssertTrue(matches.isEmpty, "An already-scheduled canceled OCR call must not recreate cleared text")
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftShotHistoryTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func persist(_ store: RecoveryStore, id: UUID) async throws {
        try await store.persist(id: id, image: fixture(),
            edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 32, height: 24)), revision: 0, savedURL: nil)
    }

    private func fixture() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        return try XCTUnwrap(context.makeImage())
    }
}

private actor InspectingHistoryRecognizer: TextRecognizing {
    struct Observation: Sendable { let width: Int; let height: Int; let firstRed: UInt8 }
    var observed: Observation?
    func recognizeText(in image: CGImage) async throws -> String {
        let data = image.dataProvider!.data!
        observed = Observation(width: image.width, height: image.height, firstRed: CFDataGetBytePtr(data)![0])
        return "redacted bitmap phrase"
    }
}

private actor GatedHistoryRecognizer: TextRecognizing {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func recognizeText(in image: CGImage) async throws -> String {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return "late indexed phrase"
    }
    func waitUntilStarted() async throws {
        for _ in 0..<300 {
            if started { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CaptureError.failed("The OCR test gate was never reached")
    }
    func release() { continuation?.resume(); continuation = nil }
}
