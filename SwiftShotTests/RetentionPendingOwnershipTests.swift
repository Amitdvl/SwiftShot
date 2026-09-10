import AppKit
import XCTest
@testable import SwiftShot

@MainActor
final class RetentionPendingOwnershipTests: XCTestCase {
    func testHistoryRetentionCannotDeleteSavedCaptureWithNewerFailedUnsavedRevision() async throws {
        let fixture = try RetentionOwnershipFixture()
        defer { fixture.cleanUp() }
        let originalID = UUID()
        let savedURL = fixture.root.appendingPathComponent("saved-export.png")
        try await fixture.store.persist(id: originalID, image: fixture.image,
            edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 32, height: 24)),
            revision: 0, savedURL: savedURL)
        let folder = fixture.recoveryRoot.appendingPathComponent(originalID.uuidString)
        try FileManager.default.copyItem(at: folder.appendingPathComponent("original.png"), to: savedURL)
        await fixture.app.reopenRecovery(originalID)
        let original = try XCTUnwrap(fixture.app.lastDocument)
        original.change { $0.crop = CGRect(x: 4, y: 2, width: 16, height: 12) }
        XCTAssertEqual(original.revision, 1)
        XCTAssertNil(original.savedURL)

        // Real filesystem failure leaves the old saved metadata intact while
        // the coordinator owns a genuinely newer, unsaved edit snapshot.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let preserved = await fixture.app.preserve(original)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        XCTAssertFalse(preserved, "The fixture must fail the new metadata write before retention runs")
        let failed = await fixture.coordinator.status()
        XCTAssertEqual(failed.failedIDs, [originalID])
        XCTAssertEqual(failed.pendingCount, 1)
        XCTAssertGreaterThan(failed.pendingBytes, 0)
        let oldMetadata = try JSONDecoder().decode(RecoveryRecord.self,
            from: Data(contentsOf: folder.appendingPathComponent("capture.json")))
        XCTAssertEqual(oldMetadata.revision, 0)
        XCTAssertEqual(oldMetadata.savedPath, savedURL.path)

        // Navigate through AppState's actual capture admission and selection
        // callbacks. A is no longer lastDocument, but recovery still owns it.
        await fixture.app.capture(mode: .region, privateCapture: true, respectImmediatePreference: false)
        let next = CaptureDocument(image: fixture.image)
        fixture.presenter.select(next)
        XCTAssertTrue(fixture.app.lastDocument === next)
        XCTAssertNotNil(fixture.app.recoveryProblem)
        let pendingBeforeRetention = await fixture.coordinator.status()
        XCTAssertEqual(pendingBeforeRetention.failedIDs, [originalID])
        XCTAssertEqual(pendingBeforeRetention.pendingCount, 1)

        // This is the command called by History's real retention callback.
        // Rejecting retention, flushing first, or protecting pending IDs are
        // all valid; deleting the only editable original is not.
        do { try await fixture.app.applyHistoryRetention(RecoveryRetentionPolicy(maximumSavedCount: 0)) }
        catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("original.png").path),
            "Saved-only retention deleted an original whose newer unsaved revision was still owned by recovery")
        try await fixture.coordinator.retry()
        let records = try await fixture.store.records()
        let recovered = try XCTUnwrap(records.first { $0.id == originalID },
            "Retention tombstoned A and retry silently released its newer unsaved snapshot")
        XCTAssertEqual(recovered.revision, 1)
        XCTAssertEqual(recovered.edits.crop, CGRect(x: 4, y: 2, width: 16, height: 12))
        XCTAssertNil(recovered.savedPath)
        let afterRetry = await fixture.coordinator.status()
        XCTAssertEqual(afterRetry.pendingCount, 0)
        _ = await fixture.app.prepareToQuit()
    }

    func testRetentionRemovesSavedRevisionWithoutAllowingOlderOrSameRevisionToResurrectIt() async throws {
        let fixture = try RetentionOwnershipFixture()
        defer { fixture.cleanUp() }
        let id = UUID()
        let savedURL = fixture.root.appendingPathComponent("saved.png")
        let edits = CaptureEdits(crop: CGRect(x: 0, y: 0, width: 32, height: 24))
        try await fixture.store.persist(id: id, image: fixture.image, edits: edits, revision: 3, savedURL: savedURL)
        let removed = try await fixture.store.applyRetention(RecoveryRetentionPolicy(maximumSavedCount: 0))
        XCTAssertEqual(removed, [id])
        let folder = fixture.recoveryRoot.appendingPathComponent(id.uuidString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))

        // A same-revision nil savedURL is a pre-save snapshot, not a new edit.
        // Real document edits increment the revision before clearing savedURL.
        for (revision, url) in [(2, Optional(savedURL)), (2, nil), (3, Optional(savedURL)), (3, nil)] {
            try await fixture.store.persist(id: id, image: fixture.image, edits: edits, revision: revision, savedURL: url)
            let records = try await fixture.store.records()
            XCTAssertFalse(records.contains { $0.id == id }, "A stale revision recreated retained-away history")
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        }
    }

    func testNewerUnsavedRevisionAfterRetentionRehydratesCompleteOriginalAndEdits() async throws {
        let fixture = try RetentionOwnershipFixture()
        defer { fixture.cleanUp() }
        let id = UUID()
        let oldEdits = CaptureEdits(crop: CGRect(x: 0, y: 0, width: 32, height: 24))
        try await fixture.store.persist(id: id, image: fixture.image, edits: oldEdits,
            revision: 3, savedURL: fixture.root.appendingPathComponent("saved.png"))
        _ = try await fixture.store.applyRetention(RecoveryRetentionPolicy(maximumSavedCount: 0))
        let edited = CaptureEdits(crop: CGRect(x: 4, y: 2, width: 16, height: 12))
        // This is the admitted-later side of the retention/producer actor gap.
        try await fixture.coordinator.preserve(RecoverySnapshot(id: id, image: fixture.image,
            edits: edited, revision: 4, savedURL: nil))
        let rehydratedRecords = try await fixture.store.records()
        _ = try XCTUnwrap(rehydratedRecords.first { $0.id == id },
            "Retention's revision floor rejected a genuinely newer unsaved revision")
        let recovered = try await fixture.store.load(id: id)
        XCTAssertEqual(recovered.record.revision, 4)
        XCTAssertEqual(recovered.record.edits.crop, CGRect(x: 4, y: 2, width: 16, height: 12))
        XCTAssertNil(recovered.record.savedPath)
        try assertCompleteWhiteOriginal(recovered.image)

        // Old producer completions must not overwrite the recreated revision.
        try await fixture.store.persist(id: id, image: fixture.image, edits: oldEdits, revision: 3, savedURL: nil)
        let afterStaleWrite = try await fixture.store.load(id: id)
        XCTAssertEqual(afterStaleWrite.record.revision, 4)
        XCTAssertEqual(afterStaleWrite.record.edits.crop, CGRect(x: 4, y: 2, width: 16, height: 12))
    }

    func testFailedNewerRevisionAfterRetentionKeepsPixelsOwnedUntilRetryRehydratesThem() async throws {
        let fixture = try RetentionOwnershipFixture()
        defer { fixture.cleanUp() }
        let id = UUID()
        try await fixture.store.persist(id: id, image: fixture.image,
            edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 32, height: 24)),
            revision: 3, savedURL: fixture.root.appendingPathComponent("saved.png"))
        _ = try await fixture.store.applyRetention(RecoveryRetentionPolicy(maximumSavedCount: 0))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.recoveryRoot.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.recoveryRoot.path) }
        var failure: Error?
        do {
            try await fixture.coordinator.preserve(RecoverySnapshot(id: id, image: fixture.image,
                edits: CaptureEdits(crop: CGRect(x: 4, y: 2, width: 16, height: 12)), revision: 4, savedURL: nil))
        } catch { failure = error }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.recoveryRoot.path)
        XCTAssertNotNil(failure, "A newer revision must attempt durability instead of succeeding through a retention tombstone")
        let failed = await fixture.coordinator.status()
        XCTAssertEqual(failed.failedIDs, [id])
        XCTAssertEqual(failed.pendingCount, 1)
        XCTAssertGreaterThan(failed.pendingBytes, 0)
        try await fixture.coordinator.retry()
        let rehydratedRecords = try await fixture.store.records()
        _ = try XCTUnwrap(rehydratedRecords.first { $0.id == id },
            "Retry silently discarded the newer unsaved revision instead of recreating recovery")
        let recovered = try await fixture.store.load(id: id)
        XCTAssertEqual(recovered.record.revision, 4)
        XCTAssertEqual(recovered.record.edits.crop, CGRect(x: 4, y: 2, width: 16, height: 12))
        XCTAssertNil(recovered.record.savedPath)
        try assertCompleteWhiteOriginal(recovered.image)
        let afterRetry = await fixture.coordinator.status()
        XCTAssertEqual(afterRetry.pendingCount, 0)
        XCTAssertNil(afterRetry.lastFailure)
    }

    func testExplicitDeletionAndPrivateClassificationStillRejectNewerRevisionsAfterRetention() async throws {
        let fixture = try RetentionOwnershipFixture()
        defer { fixture.cleanUp() }
        let edits = CaptureEdits(crop: CGRect(x: 0, y: 0, width: 32, height: 24))
        for makePrivate in [false, true] {
            let id = UUID()
            try await fixture.store.persist(id: id, image: fixture.image, edits: edits,
                revision: 3, savedURL: fixture.root.appendingPathComponent("saved.png"))
            _ = try await fixture.store.applyRetention(RecoveryRetentionPolicy(maximumSavedCount: 0))
            if makePrivate {
                try await fixture.store.persist(id: id, image: fixture.image, edits: edits,
                    revision: 4, savedURL: nil, privateCapture: true)
            } else { try await fixture.store.discard(id: id) }
            try await fixture.store.persist(id: id, image: fixture.image, edits: edits, revision: 5, savedURL: nil)
            try await fixture.store.indexOCR(id: id, text: "must remain absent", revision: 5, privateCapture: false)
            let records = try await fixture.store.records()
            let search = try await fixture.store.searchOCR("must remain absent")
            XCTAssertFalse(records.contains { $0.id == id })
            XCTAssertTrue(search.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.recoveryRoot.appendingPathComponent(id.uuidString).path))
        }
    }

    func testLegacySavedPruningAlsoAllowsOnlyNewerUnsavedRevisionToRehydrate() async throws {
        let fixture = try RetentionOwnershipFixture()
        defer { fixture.cleanUp() }
        let removedID = UUID(), latestID = UUID()
        let oldEdits = CaptureEdits(crop: CGRect(x: 0, y: 0, width: 32, height: 24))
        try await fixture.store.persist(id: removedID, image: fixture.image, edits: oldEdits,
            revision: 3, savedURL: fixture.root.appendingPathComponent("saved.png"))
        try await fixture.store.persist(id: latestID, image: fixture.image, edits: oldEdits, revision: 0, savedURL: nil)
        try await fixture.store.pruneSaved(except: latestID)
        let pruned = try await fixture.store.records()
        XCTAssertEqual(pruned.map(\.id), [latestID])
        try await fixture.store.persist(id: removedID, image: fixture.image, edits: oldEdits, revision: 3, savedURL: nil)
        let afterStaleWrite = try await fixture.store.records()
        XCTAssertEqual(afterStaleWrite.map(\.id), [latestID])
        try await fixture.coordinator.preserve(RecoverySnapshot(id: removedID, image: fixture.image,
            edits: CaptureEdits(crop: CGRect(x: 4, y: 2, width: 16, height: 12)), revision: 4, savedURL: nil))
        let rehydratedRecords = try await fixture.store.records()
        _ = try XCTUnwrap(rehydratedRecords.first { $0.id == removedID },
            "Legacy saved pruning permanently tombstoned a newer unsaved revision")
        let recovered = try await fixture.store.load(id: removedID)
        XCTAssertEqual(recovered.record.revision, 4)
        XCTAssertEqual(recovered.record.edits.crop, CGRect(x: 4, y: 2, width: 16, height: 12))
        XCTAssertNil(recovered.record.savedPath)
        try assertCompleteWhiteOriginal(recovered.image)
    }

    private func assertCompleteWhiteOriginal(_ image: CGImage, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(image.width, 32, file: file, line: line)
        XCTAssertEqual(image.height, 24, file: file, line: line)
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
            bytesPerRow: 128, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), file: file, line: line)
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 24))
        let bytes = try XCTUnwrap(context.data, file: file, line: line)
        XCTAssertEqual(Data(bytes: bytes, count: 3_072), Data(repeating: 255, count: 3_072),
            "Recovery must retain every original pixel, not only the edited crop", file: file, line: line)
    }
}

@MainActor
private struct RetentionOwnershipFixture {
    let root: URL
    let recoveryRoot: URL
    let suite = "SwiftShotRetentionOwnership.\(UUID())"
    let defaults: UserDefaults
    let image: CGImage
    let store: RecoveryStore
    let coordinator: RecoveryCoordinator
    let presenter = RetentionOwnershipPresenter()
    let app: AppState

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftShotRetentionOwnership-\(UUID())")
        recoveryRoot = root.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
            bytesPerRow: 128, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        image = try XCTUnwrap(context.makeImage())
        store = RecoveryStore(root: recoveryRoot)
        coordinator = RecoveryCoordinator(store: store)
        var settings = AppSettings.default
        settings.historyIndexingEnabled = false
        settings.immediateCopy = false
        try defaults.set(JSONEncoder().encode(settings), forKey: "com.swiftshot.settings")
        app = AppState(defaults: defaults, recovery: store,
            backgrounds: BackgroundLibrary(rootURL: root.appendingPathComponent("backgrounds")),
            presentsUI: false, captureService: RetentionOwnershipCapture(image: image),
            overlay: presenter, diagnostics: nil, recoveryCoordinator: coordinator)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class RetentionOwnershipCapture: ScreenCaptureProviding {
    let image: CGImage
    init(image: CGImage) { self.image = image }
    func freeze(mode: CaptureMode) async throws -> [FrozenScreen] {
        [FrozenScreen(id: 7, frame: CGRect(x: 0, y: 0, width: 32, height: 24), image: image, windows: [])]
    }
}

@MainActor
private final class RetentionOwnershipPresenter: CapturePresenting {
    var activeDocument: CaptureDocument?
    private var onDocument: ((CaptureDocument) -> Void)?
    func select(_ document: CaptureDocument) { activeDocument = document; onDocument?(document) }
    func configure(actions: CaptureActions) {}
    func present(screens: [FrozenScreen], mode: CaptureMode, style: CaptureStyle, library: BackgroundLibrary,
                 onDocument: @escaping (CaptureDocument) -> Void, onCopy: @escaping (CaptureDocument) -> Void,
                 onSave: @escaping (CaptureDocument) -> Void, onOCR: @escaping (CaptureDocument) -> Void,
                 onCancel: @escaping () -> Void, onDiscard: @escaping (CaptureDocument) -> Void) {
        self.onDocument = onDocument
    }
    func reopen(document: CaptureDocument, library: BackgroundLibrary, onCopy: @escaping (CaptureDocument) -> Void,
                onSave: @escaping (CaptureDocument) -> Void, onCancel: @escaping () -> Void,
                onDocument: @escaping (CaptureDocument) -> Void, onDiscard: @escaping (CaptureDocument) -> Void) {
        activeDocument = document
        self.onDocument = onDocument
    }
    func dismiss() { activeDocument = nil }
    func showStatus(_ message: String, isError: Bool) {}
}
