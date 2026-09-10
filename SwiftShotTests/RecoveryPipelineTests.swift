import AppKit
import XCTest
@testable import SwiftShot

final class RecoveryPipelineTests: XCTestCase {
    // Rewriting a durable revision would move updatedAt and incur unnecessary I/O.
    func testIdenticalDurableRevisionDoesNotRewriteMetadata() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root)
        let id = UUID(), image = try fixture()
        let edits = CaptureEdits(crop: CGRect(x: 0, y: 0, width: 32, height: 24))
        try await store.persist(id: id, image: image, edits: edits, revision: 7, savedURL: nil)
        let metadata = root.appendingPathComponent(id.uuidString).appendingPathComponent("capture.json")
        let before = try Data(contentsOf: metadata)
        try await store.persist(id: id, image: image, edits: edits, revision: 7, savedURL: nil)
        XCTAssertEqual(try Data(contentsOf: metadata), before,
                       "A durable, unchanged revision must not be rewritten merely to navigate or copy")
    }

    // An interrupted metadata write must not make an intact original disappear from history.
    func testOrphanOriginalIsReconciledWithoutLosingItsPixels() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root)
        let id = UUID(), image = try fixture()
        try await store.persist(id: id, image: image,
                                edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 32, height: 24)),
                                revision: 0, savedURL: nil)
        try FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString).appendingPathComponent("capture.json"))
        let restarted = RecoveryStore(root: root)
        let records = try await restarted.records()
        XCTAssertEqual(records.map(\.id), [id], "The intact original must be offered for recovery")
        if records.count == 1 {
            let recovered = try await restarted.load(id: id)
            XCTAssertEqual(recovered.image.width, 32)
            XCTAssertEqual(recovered.image.height, 24)
        }
    }

    func testCorruptMetadataIsBackedUpAndOriginalRemainsRecoverable() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root), id = UUID()
        try await persist(store, id: id)
        let folder = root.appendingPathComponent(id.uuidString)
        let damaged = Data("interrupted metadata".utf8)
        try damaged.write(to: folder.appendingPathComponent("capture.json"))
        let restarted = RecoveryStore(root: root)
        let report = try await restarted.reconcile()
        XCTAssertEqual(report.repairedIDs, [id])
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let backup = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("capture.corrupt.") })
        XCTAssertEqual(try Data(contentsOf: backup), damaged)
        let recovered = try await restarted.load(id: id)
        XCTAssertEqual(recovered.image.width, 32)
    }

    func testUnrecoverableOriginalIsReportedWithoutDeletingEvidence() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root), id = UUID()
        try await persist(store, id: id)
        let original = root.appendingPathComponent(id.uuidString).appendingPathComponent("original.png")
        try Data("damaged pixels".utf8).write(to: original)
        let restarted = RecoveryStore(root: root)
        let report = try await restarted.reconcile()
        XCTAssertEqual(report.issues.map(\.id), [id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testPinnedAndUnsavedCapturesSurviveExplicitRetention() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root)
        let pinned = UUID(), unsaved = UUID(), saved = UUID(), protected = UUID()
        for id in [pinned, saved, protected] { try await persist(store, id: id, savedURL: root.appendingPathComponent("export.png")) }
        try await persist(store, id: unsaved)
        try await store.setPinned(id: pinned, isPinned: true)
        _ = try await store.applyRetention(RecoveryRetentionPolicy(maximumSavedCount: 0), protected: [protected])
        let ids = Set(try await store.records().map(\.id))
        XCTAssertEqual(ids, [pinned, unsaved, protected])
        let reopened = try await RecoveryStore(root: root).load(id: pinned)
        XCTAssertTrue(reopened.record.isPinned)
    }

    func testPrivateCaptureCreatesNeitherRecoveryFolderNorSearchIndex() async throws {
        let parent = try directory(), root = parent.appendingPathComponent("private-must-not-exist")
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = RecoveryStore(root: root), coordinator = RecoveryCoordinator(store: store)
        let id = UUID(), image = try fixture()
        try await coordinator.enqueue(RecoverySnapshot(id: id, image: image,
            edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 32, height: 24)), revision: 0,
            savedURL: nil, privateCapture: true))
        try await coordinator.flush()
        try await store.indexOCR(id: id, text: "private phrase", revision: 0, privateCapture: true)
        let results = try await store.searchOCR("private")
        XCTAssertTrue(results.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testOCRSearchDropsTextWhenEditedRevisionChanges() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root), id = UUID()
        try await persist(store, id: id)
        try await store.indexOCR(id: id, text: "Résumé Invoice 123", revision: 0, privateCapture: false)
        let matches = try await store.searchOCR("resume invoice")
        XCTAssertEqual(matches.map(\.id), [id])
        try await persist(store, id: id, revision: 1)
        let stale = try await store.searchOCR("invoice")
        XCTAssertTrue(stale.isEmpty, "A later crop/redaction must invalidate old OCR text")
        try await store.indexOCR(id: id, text: "late stale text", revision: 0, privateCapture: false)
        let late = try await store.searchOCR("stale")
        XCTAssertTrue(late.isEmpty)
    }

    func testFailedDurabilityRetainsSnapshotAndRetryFlushesIt() async throws {
        let root = try directory(), occupied = root.appendingPathComponent("recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("occupied".utf8).write(to: occupied)
        let store = RecoveryStore(root: occupied), coordinator = RecoveryCoordinator(store: store)
        let id = UUID()
        try await coordinator.enqueue(RecoverySnapshot(id: id, image: try fixture(),
            edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 32, height: 24)), revision: 2, savedURL: nil))
        do { try await coordinator.flush(); XCTFail("Failed storage must not look durable") } catch { }
        let failed = await coordinator.status()
        XCTAssertEqual(failed.pendingCount, 1)
        XCTAssertGreaterThan(failed.pendingBytes, 0)
        XCTAssertNotNil(failed.lastFailure)
        try FileManager.default.removeItem(at: occupied)
        try await coordinator.retry()
        let durable = await coordinator.status()
        XCTAssertEqual(durable.pendingCount, 0)
        XCTAssertNil(durable.lastFailure)
        let recovered = try await store.load(id: id)
        XCTAssertEqual(recovered.record.revision, 2)
    }

    func testShutdownFlushesLatestRevisionAndRejectsFurtherWrites() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root), coordinator = RecoveryCoordinator(store: store)
        let id = UUID(), image = try fixture()
        for revision in 0...20 {
            try await coordinator.enqueue(RecoverySnapshot(id: id, image: image,
                edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 32, height: 24)), revision: revision, savedURL: nil))
        }
        try await coordinator.shutdown()
        let loaded = try await store.load(id: id)
        XCTAssertEqual(loaded.record.revision, 20)
        do {
            try await coordinator.enqueue(RecoverySnapshot(id: UUID(), image: image,
                edits: loaded.record.edits, revision: 0, savedURL: nil))
            XCTFail("Shutdown must close the write admission boundary")
        } catch { }
    }

    func testFailedShutdownReopensAdmissionAndRetainsBothSnapshotsForRetry() async throws {
        let root = try directory(), occupied = root.appendingPathComponent("recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("occupied".utf8).write(to: occupied)
        let store = RecoveryStore(root: occupied), coordinator = RecoveryCoordinator(store: store)
        let image = try fixture(), first = UUID(), second = UUID()
        let edits = CaptureEdits(crop: CGRect(x: 0, y: 0, width: 32, height: 24))
        try await coordinator.enqueue(RecoverySnapshot(id: first, image: image, edits: edits, revision: 0, savedURL: nil))
        do { try await coordinator.shutdown(); XCTFail("The disk failure must prevent quit") } catch { }
        let status = await coordinator.status()
        XCTAssertFalse(status.isShuttingDown)
        try await coordinator.enqueue(RecoverySnapshot(id: second, image: image, edits: edits, revision: 0, savedURL: nil))
        try FileManager.default.removeItem(at: occupied)
        try await coordinator.retry()
        let ids = Set(try await store.records().map(\.id))
        XCTAssertEqual(ids, [first, second])
    }

    func testOwnershipCapacityRefusesWithoutDroppingAlreadyQueuedOriginal() async throws {
        let root = try directory(), occupied = root.appendingPathComponent("recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("occupied".utf8).write(to: occupied)
        let store = RecoveryStore(root: occupied), image = try fixture()
        let coordinator = RecoveryCoordinator(store: store, maximumPendingBytes: image.bytesPerRow * image.height)
        let id = UUID(), edits = CaptureEdits(crop: CGRect(x: 0, y: 0, width: 32, height: 24))
        try await coordinator.enqueue(RecoverySnapshot(id: id, image: image, edits: edits, revision: 0, savedURL: nil))
        do {
            try await coordinator.enqueue(RecoverySnapshot(id: UUID(), image: image, edits: edits, revision: 0, savedURL: nil))
            XCTFail("Memory limits must reject admission, never evict the first undurable original")
        } catch { }
        try FileManager.default.removeItem(at: occupied)
        try await coordinator.handleMemoryPressure()
        let records = try await store.records()
        XCTAssertEqual(records.map(\.id), [id])
    }

    func testDiscardAfterFailedWriteClearsPendingOwnershipAndRejectsLateRevision() async throws {
        let root = try directory(), occupied = root.appendingPathComponent("recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("occupied".utf8).write(to: occupied)
        let store = RecoveryStore(root: occupied), coordinator = RecoveryCoordinator(store: store)
        let image = try fixture(), id = UUID()
        let edits = CaptureEdits(crop: CGRect(x: 0, y: 0, width: 32, height: 24))
        try await coordinator.enqueue(RecoverySnapshot(id: id, image: image, edits: edits, revision: 0, savedURL: nil))
        do { try await coordinator.flush(); XCTFail("The write should fail") } catch { }
        try await coordinator.discard(id: id)
        try FileManager.default.removeItem(at: occupied)
        try await coordinator.enqueue(RecoverySnapshot(id: id, image: image, edits: edits, revision: 1, savedURL: nil))
        try await coordinator.flush()
        let status = await coordinator.status()
        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertNil(status.lastFailure)
        let records = try await store.records()
        XCTAssertTrue(records.isEmpty)
    }

    func testThumbnailRespectsCropAndOpaqueRedaction() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root), id = UUID()
        let crop = CGRect(x: 0, y: 0, width: 16, height: 12)
        let edits = CaptureEdits(crop: crop, annotations: [CaptureAnnotation(kind: .redact,
            start: .zero, end: CGPoint(x: 16, y: 12))])
        try await store.persist(id: id, image: try fixture(), edits: edits, revision: 1, savedURL: nil)
        let image = try await store.thumbnail(id: id, maximumPixelSize: 64)
        XCTAssertEqual(image.width, 16)
        XCTAssertEqual(image.height, 12)
        let bytes = try XCTUnwrap(image.dataProvider?.data)
        let values = try XCTUnwrap(CFDataGetBytePtr(bytes))
        XCTAssertEqual(values[0], 0)
        XCTAssertEqual(values[1], 0)
        XCTAssertEqual(values[2], 0)
        XCTAssertEqual(values[3], 255)
        let usage = try await store.storageUsage()
        XCTAssertGreaterThan(usage.totalBytes, 0)
        XCTAssertEqual(usage.captureCount, 1)
    }

    private func persist(_ store: RecoveryStore, id: UUID, revision: Int = 0, savedURL: URL? = nil) async throws {
        try await store.persist(id: id, image: fixture(),
            edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 32, height: 24)),
            revision: revision, savedURL: savedURL)
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftShotRecoveryTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
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
