import AppKit
import XCTest
@testable import SwiftShot

@MainActor
final class HistoryRefreshRegressionTests: XCTestCase {
    func testUnchangedCloseCopyAndNextCaptureDoNotReloadSettledHistory() async throws {
        let fixture = try HistoryRefreshFixture()
        defer { fixture.cleanUp() }
        try await fixture.prepare(query: "")
        var reloads = 0, completions = 0
        fixture.model.refreshObserver = { event in
            switch event {
            case .reloadStarted: reloads += 1
            case .recoveryObservationFinished: completions += 1
            }
        }
        fixture.app.lastDocument = fixture.original
        fixture.app.closeEditor()
        let settled = await eventually { completions == 1 }
        XCTAssertTrue(settled)
        reloads = 0

        fixture.app.closeEditor()
        let copied = await fixture.app.copy(fixture.original)
        XCTAssertTrue(copied)
        await fixture.app.capture(mode: .region, respectImmediatePreference: false)
        let reloadedUnchangedCapture = await eventually { reloads > 0 }
        XCTAssertFalse(reloadedUnchangedCapture,
            "An already-owned unchanged capture restarted durability observation and History reloads")
        XCTAssertEqual(fixture.model.entries.map(\.id), [fixture.original.id])
        _ = await fixture.app.prepareToQuit()
    }

    func testAdmissionCoalescingStillPersistsChangedRevisionAndSavedURL() async throws {
        let fixture = try HistoryRefreshFixture()
        defer { fixture.cleanUp() }
        try await fixture.prepare(query: "")
        let document = fixture.original
        await fixture.copy(document)
        let originalSettled = await eventually { fixture.model.entries.first?.record.revision == 0 }
        XCTAssertTrue(originalSettled)

        document.change { $0.crop = CGRect(x: 0, y: 0, width: 16, height: 12) }
        await fixture.copy(document)
        let edited = await eventually {
            fixture.model.entries.first?.record.revision == 1 &&
                fixture.model.entries.first?.record.edits.crop == CGRect(x: 0, y: 0, width: 16, height: 12)
        }
        XCTAssertTrue(edited, "Coalescing suppressed a changed immutable edit snapshot")

        document.savedURL = fixture.root.appendingPathComponent("saved-without-another-edit.png")
        await fixture.copy(document)
        let saved = await eventually {
            fixture.model.entries.first?.record.savedPath == document.savedURL?.path
        }
        XCTAssertTrue(saved, "A save-path change at the same revision must still reach recovery")
        _ = await fixture.app.prepareToQuit()
    }

    func testAdmissionCoalescingDoesNotSkipPrivateClassificationAtTheSameRevision() async throws {
        let fixture = try HistoryRefreshFixture()
        defer { fixture.cleanUp() }
        try await fixture.prepare(query: "")
        let document = fixture.original
        await fixture.copy(document)
        document.isPrivate = true
        await fixture.copy(document)

        // A private classification permanently excludes this owned capture from
        // later recovery writes, including a later toggle back to public.
        document.isPrivate = false
        document.change { $0.crop = CGRect(x: 0, y: 0, width: 16, height: 12) }
        await fixture.copy(document)
        _ = await fixture.app.prepareToQuit()
        let records = try await fixture.store.records()
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.revision, 0,
            "Skipping a privacy-only admission allowed later private pixels to be persisted")
    }

    func testUnchangedCaptureCanRetryIndexingAfterRecognitionFailure() async throws {
        let recognizer = HistoryRefreshGatedRecognizer(failingCalls: [1])
        let fixture = try HistoryRefreshFixture(indexingEnabled: true, recognizer: recognizer)
        defer { fixture.cleanUp(); Task { await recognizer.releaseAll() } }
        try await fixture.prepare(query: "")
        var completions = 0
        fixture.model.refreshObserver = { event in
            if case .recoveryObservationFinished = event { completions += 1 }
        }
        let document = CaptureDocument(image: fixture.original.image)
        await fixture.copy(document)
        let started = await recognizer.waitUntilStarted(1)
        XCTAssertTrue(started)
        let observed = await eventually { completions > 0 }
        XCTAssertTrue(observed)
        await recognizer.release(1)
        let failed = await eventually { fixture.model.errorMessage?.contains("indexing couldn't finish") == true }
        XCTAssertTrue(failed)

        await fixture.copy(document)
        let retried = await recognizer.waitUntilStarted(2)
        XCTAssertTrue(retried, "An accepted-but-failed OCR admission was incorrectly cached as complete")
        await recognizer.release(2)
        let indexed = await eventually {
            fixture.model.entries.contains { $0.id == document.id && $0.record.ocrText == "Copper river" }
        }
        XCTAssertTrue(indexed)
        _ = await fixture.app.prepareToQuit()
    }

    func testCompletedIndexingFailureBeforeObservationCanRetryUnchangedCapture() async throws {
        let recognizer = HistoryRefreshGatedRecognizer(failingCalls: [1])
        let fixture = try HistoryRefreshFixture(indexingEnabled: true, recognizer: recognizer)
        defer { fixture.cleanUp(); Task { await recognizer.releaseAll() } }
        try await fixture.prepare(query: "")
        let indexing = fixture.indexing
        let gate = HistoryRefreshStoreGate()
        defer { gate.release() }
        var completedFailure: Task<HistoryIndexingStatus, Never>?
        fixture.model.refreshObserver = { event in
            guard case .reloadStarted = event else { return }
            fixture.model.refreshObserver = nil
            // The durability observer has already sampled pending OCR, but has
            // not yet created its indexing observer. Keep the main actor here
            // until the independent OCR actor has completely ended its worker.
            completedFailure = Task.detached {
                _ = await recognizer.waitUntilStarted(1)
                await recognizer.release(1)
                try? await indexing.flush()
                let status = await indexing.status()
                gate.release()
                return status
            }
            gate.hold()
        }
        let document = CaptureDocument(image: fixture.original.image)
        await fixture.copy(document)
        let failureWasScheduled = await eventually { completedFailure != nil }
        XCTAssertTrue(failureWasScheduled)
        let failureTask = try XCTUnwrap(completedFailure)
        let terminal = await failureTask.value
        XCTAssertEqual(terminal.pendingCount, 0)
        XCTAssertNotNil(terminal.lastFailure, "The failed worker must be finished before AppState resumes observation")
        let warningAppeared = await eventually {
            fixture.model.errorMessage?.contains("indexing couldn't finish") == true
        }
        XCTAssertTrue(warningAppeared, "A completed OCR error was lost because flush had no remaining worker to await")

        await fixture.copy(document)
        let retried = await recognizer.waitUntilStarted(2)
        XCTAssertTrue(retried, "A fast OCR failure left an accepted admission cached and suppressed unchanged retries")
        await recognizer.release(2)
        let indexed = await eventually {
            fixture.model.entries.contains { $0.id == document.id && $0.record.ocrText == "Copper river" }
        }
        XCTAssertTrue(indexed)
        _ = await fixture.app.prepareToQuit()
    }

    func testUnchangedCaptureCanBeIndexedAgainAfterDisableAndEnable() async throws {
        let fixture = try HistoryRefreshFixture(indexingEnabled: true)
        defer { fixture.cleanUp() }
        try await fixture.prepare(query: "")
        let document = CaptureDocument(image: fixture.original.image)
        await fixture.copy(document)
        let indexed = await eventually {
            fixture.model.entries.contains { $0.id == document.id && $0.record.ocrText == "Copper river" }
        }
        XCTAssertTrue(indexed)
        await fixture.app.setHistoryIndexing(false)
        XCTAssertTrue(fixture.model.entries.allSatisfy { $0.record.ocrText == nil })
        await fixture.app.setHistoryIndexing(true)
        await fixture.copy(document)
        let reindexed = await eventually {
            fixture.model.entries.contains { $0.id == document.id && $0.record.ocrText == "Copper river" }
        }
        XCTAssertTrue(reindexed, "The pre-disable admission stamp suppressed indexing after its queue and text were cleared")
        _ = await fixture.app.prepareToQuit()
    }

    func testIndexingCapacityRejectionDoesNotSuppressLaterUnchangedRetry() async throws {
        let recognizer = HistoryRefreshGatedRecognizer()
        let fixture = try HistoryRefreshFixture(indexingEnabled: true, recognizer: recognizer)
        defer { fixture.cleanUp(); Task { await recognizer.releaseAll() } }
        try await fixture.prepare(query: "")
        let documents = (0..<5).map { _ in CaptureDocument(image: fixture.original.image) }
        await fixture.copy(documents[0])
        let firstStarted = await recognizer.waitUntilStarted(1)
        XCTAssertTrue(firstStarted)
        // The first recognizer is held, so the real four-job coordinator cannot
        // admit the fifth capture even though recovery can own all five.
        for document in documents.dropFirst() { await fixture.copy(document) }
        let allDurable = await eventually {
            documents.allSatisfy { document in fixture.model.entries.contains { $0.id == document.id } }
        }
        XCTAssertTrue(allDurable)
        for call in 1...4 {
            let started = await recognizer.waitUntilStarted(call)
            XCTAssertTrue(started)
            await recognizer.release(call)
        }
        let acceptedJobsFinished = await eventually {
            documents.prefix(4).allSatisfy { document in
                fixture.model.entries.contains { $0.id == document.id && $0.record.ocrText != nil }
            }
        }
        XCTAssertTrue(acceptedJobsFinished)
        let rejected = documents[4]
        XCTAssertNil(fixture.model.entries.first { $0.id == rejected.id }?.record.ocrText)

        await fixture.copy(rejected)
        let retried = await recognizer.waitUntilStarted(5)
        XCTAssertTrue(retried, "A bounded-out optional job was incorrectly cached as admitted")
        await recognizer.release(5)
        let indexed = await eventually {
            fixture.model.entries.contains { $0.id == rejected.id && $0.record.ocrText == "Copper river" }
        }
        XCTAssertTrue(indexed)
        _ = await fixture.app.prepareToQuit()
    }

    func testRecoveryObservationReloadsHistoryOnlyOnceWhenIndexingIsDisabled() async throws {
        let fixture = try HistoryRefreshFixture()
        defer { fixture.cleanUp() }
        try await fixture.prepare(query: "")
        var reloads = 0, completions = 0
        fixture.model.refreshObserver = { event in
            switch event {
            case .reloadStarted: reloads += 1
            case .recoveryObservationFinished: completions += 1
            }
        }
        fixture.app.lastDocument = fixture.original
        fixture.app.closeEditor()
        let completed = await eventually { completions == 1 }
        XCTAssertTrue(completed)
        XCTAssertEqual(reloads, 1, "Disabled OCR caused a redundant second history reload and full storage scan")
        _ = await fixture.app.prepareToQuit()
    }

    func testRecoveryObservationReloadsOnlyOnceWhenEnabledIndexingAdmitsNoJobs() async throws {
        let fixture = try HistoryRefreshFixture(indexingEnabled: true)
        defer { fixture.cleanUp() }
        try await fixture.prepare(query: "")
        var reloads = 0, completions = 0
        fixture.model.refreshObserver = { event in
            switch event {
            case .reloadStarted: reloads += 1
            case .recoveryObservationFinished: completions += 1
            }
        }
        let privateCapture = CaptureDocument(image: fixture.original.image)
        privateCapture.isPrivate = true
        fixture.app.lastDocument = privateCapture
        fixture.app.closeEditor()
        let completed = await eventually { completions == 1 }
        XCTAssertTrue(completed)
        XCTAssertEqual(reloads, 1, "Enabled OCR with no admitted jobs must not cause a second scan")
        XCTAssertEqual(fixture.model.entries.map(\.id), [fixture.original.id])
        _ = await fixture.app.prepareToQuit()
    }

    func testOCRAdmittedAfterFirstHistoryRefreshStartsStillRefreshesSearch() async throws {
        let fixture = try HistoryRefreshFixture(indexingEnabled: true)
        defer { fixture.model.refreshObserver = nil; fixture.cleanUp() }
        try await fixture.prepare(query: "Copper river")
        let privateCapture = CaptureDocument(image: fixture.original.image)
        privateCapture.isPrivate = true
        let nextCapture = CaptureDocument(image: fixture.original.image)
        fixture.model.refreshObserver = { event in
            guard case .reloadStarted = event else { return }
            fixture.model.refreshObserver = nil
            // The first observation had no indexable capture. Submit new work
            // only once its first refresh has started, after the pending snapshot.
            fixture.app.lastDocument = nextCapture
            fixture.app.closeEditor()
        }
        fixture.app.lastDocument = privateCapture
        fixture.app.closeEditor()
        let refreshed = await eventually {
            fixture.model.entries.contains { $0.id == nextCapture.id && $0.record.ocrText == "Copper river" }
        }
        XCTAssertTrue(refreshed, "An indexing admission after the no-pending snapshot was missed by observation")
        XCTAssertFalse(fixture.model.entries.contains { $0.id == privateCapture.id })
        _ = await fixture.app.prepareToQuit()
    }

    func testCachedHistoryMetadataReloadDoesNotEnumerateCaptureFolders() async throws {
        let fixture = try HistoryRefreshFixture()
        defer { fixture.cleanUp() }
        try await fixture.prepare(query: "")
        let previousBytes = try XCTUnwrap(fixture.model.storage).totalBytes
        let recoveryRoot = await fixture.store.root
        let folder = recoveryRoot.appendingPathComponent(fixture.original.id.uuidString)
        let displaced = fixture.root.appendingPathComponent("temporarily-displaced-capture")
        try FileManager.default.moveItem(at: folder, to: displaced)
        try Data([0]).write(to: folder)

        // The store already owns these metadata values. A metadata-only reload
        // must not need to enumerate each capture folder just to redisplay them.
        await fixture.model.reload(refreshStorage: false)
        XCTAssertNil(fixture.model.errorMessage, "Cached metadata reload unnecessarily enumerated an unavailable capture folder")
        XCTAssertEqual(fixture.model.entries.map(\.id), [fixture.original.id])
        XCTAssertEqual(fixture.model.storage?.totalBytes, previousBytes)
        _ = await fixture.app.prepareToQuit()
    }

    func testEditorEditSynchronouslyRemovesOldRecognizedTextAndSelection() async throws {
        let fixture = try HistoryRefreshFixture()
        defer { fixture.cleanUp() }
        try await fixture.prepare(query: "Copper river 4827")
        await fixture.app.reopenRecovery(fixture.original.id)
        let document = try XCTUnwrap(fixture.app.lastDocument)
        XCTAssertEqual(fixture.model.selectedEntries.first?.record.ocrText, "Copper river 4827")

        document.change { $0.annotations.append(CaptureAnnotation(kind: .redact, start: .zero, end: CGPoint(x: 32, y: 24))) }
        fixture.presenter.changed(document)

        // No await: sensitive old text and its thumbnail disappear before the
        // debounced recovery write or any optional OCR work can run.
        XCTAssertTrue(fixture.model.entries.isEmpty, "Editing left the old searchable text and thumbnail visible")
        XCTAssertTrue(fixture.model.selectedEntries.isEmpty)
        XCTAssertTrue(fixture.model.selection.isEmpty)
        _ = await fixture.app.prepareToQuit()
    }

    func testRevisionBarrierRejectsReloadBeforeEditedRevisionIsDurable() async throws {
        let fixture = try HistoryRefreshFixture()
        defer { fixture.cleanUp() }
        try await fixture.prepare(query: "Copper river 4827")
        fixture.model.invalidate(id: fixture.original.id, minimumRevision: 1)
        await fixture.model.reload()
        XCTAssertTrue(fixture.model.entries.isEmpty, "A disk reload reintroduced text from the pre-edit revision")
        XCTAssertTrue(fixture.model.selection.isEmpty)

        var edits = fixture.original.edits
        edits.annotations.append(CaptureAnnotation(kind: .redact, start: .zero, end: CGPoint(x: 32, y: 24)))
        try await fixture.store.persist(id: fixture.original.id, image: fixture.original.image,
            edits: edits, revision: 1, savedURL: nil)
        fixture.model.acknowledgeDurableRecords(try await fixture.store.records())
        fixture.model.query = ""
        await fixture.model.reload()
        XCTAssertEqual(fixture.model.entries.first?.record.revision, 1)
        XCTAssertNil(fixture.model.entries.first?.record.ocrText)
        _ = await fixture.app.prepareToQuit()
    }

    func testInFlightReloadCannotRestoreEntryAfterSynchronousInvalidation() async throws {
        let fixture = try HistoryRefreshFixture()
        defer { fixture.cleanUp() }
        try await fixture.prepare(query: "Copper river 4827")
        let gate = HistoryRefreshStoreGate()
        defer { gate.release() }
        let hold = Task.detached { await fixture.store.holdForHistoryRefreshTest(gate) }
        let storeIsHeld = await eventually { gate.started }
        XCTAssertTrue(storeIsHeld)
        let reload = Task { await fixture.model.reload() }
        let reloadStarted = await eventually { fixture.model.isLoading }
        XCTAssertTrue(reloadStarted)
        fixture.model.invalidate(id: fixture.original.id, minimumRevision: 1)
        gate.release()
        await hold.value
        await reload.value
        XCTAssertTrue(fixture.model.entries.isEmpty, "The older in-flight query restored invalidated OCR text")
        XCTAssertTrue(fixture.model.selection.isEmpty)
        _ = await fixture.app.prepareToQuit()
    }

    func testSaveAutomaticallyRefreshesAlreadyLoadedHistoryMetadata() async throws {
        let fixture = try HistoryRefreshFixture()
        defer { fixture.cleanUp() }
        try await fixture.prepare(query: "")
        XCTAssertNil(fixture.model.entries.first?.record.savedPath)
        await fixture.app.reopenRecovery(fixture.original.id)
        let document = try XCTUnwrap(fixture.app.lastDocument)
        await fixture.app.save(document)
        let saved = try XCTUnwrap(document.savedURL)
        XCTAssertEqual(fixture.model.entries.first?.record.savedPath, saved.path,
            "Save refreshed the menu records but left the existing history browser marked Unsaved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        _ = await fixture.app.prepareToQuit()
    }

    func testOCRCompletionRefreshesCurrentQueryIncludingNewerJobAdmittedMidFlight() async throws {
        let recognizer = HistoryRefreshGatedRecognizer()
        let fixture = try HistoryRefreshFixture(indexingEnabled: true, recognizer: recognizer)
        defer { fixture.cleanUp(); Task { await recognizer.releaseAll() } }
        try await fixture.prepare(query: "Copper river")
        await fixture.app.reopenRecovery(fixture.original.id)
        let document = try XCTUnwrap(fixture.app.lastDocument)
        document.change { $0.annotations.append(CaptureAnnotation(kind: .redact, start: .zero, end: CGPoint(x: 16, y: 12))) }
        fixture.presenter.changed(document)
        let firstStarted = await recognizer.waitUntilStarted(1)
        XCTAssertTrue(firstStarted)

        document.change { $0.crop = CGRect(x: 0, y: 0, width: 16, height: 12) }
        fixture.presenter.changed(document)
        // Copy admits the newer revision immediately; it must not wait for the
        // old, intentionally gated OCR job or for a history refresh.
        let copied = await fixture.app.copy(document)
        XCTAssertTrue(copied)
        XCTAssertEqual(document.revision, 2)
        await recognizer.release(1)
        let secondStarted = await recognizer.waitUntilStarted(2)
        XCTAssertTrue(secondStarted)
        await recognizer.release(2)

        let refreshed = await eventually {
            fixture.model.entries.first?.record.revision == 2 &&
                fixture.model.entries.first?.record.ocrText == "Copper river"
        }
        XCTAssertTrue(refreshed, "Committed OCR did not refresh the existing query after a newer indexing job arrived")
        let records = try await fixture.store.records()
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.ocrRevision, 2)
        XCTAssertEqual(record.ocrText, "Copper river")
        XCTAssertFalse(fixture.model.entries.contains { $0.record.ocrText?.contains("4827") == true })
        _ = await fixture.app.prepareToQuit()
    }

    func testDurableCaptureAppearsInHistoryWhileOlderOCRIsStillRunning() async throws {
        let recognizer = HistoryRefreshGatedRecognizer()
        let fixture = try HistoryRefreshFixture(indexingEnabled: true, recognizer: recognizer)
        defer { fixture.cleanUp(); Task { await recognizer.releaseAll() } }
        try await fixture.prepare(query: "")
        await fixture.app.reopenRecovery(fixture.original.id)
        let first = try XCTUnwrap(fixture.app.lastDocument)
        first.change { $0.annotations.append(CaptureAnnotation(kind: .redact, start: .zero, end: CGPoint(x: 16, y: 12))) }
        fixture.presenter.changed(first)
        let firstOCRStarted = await recognizer.waitUntilStarted(1)
        XCTAssertTrue(firstOCRStarted)
        let firstMetadataRefreshed = await eventually {
            fixture.model.entries.contains { $0.id == first.id && $0.record.revision == 1 }
        }
        XCTAssertTrue(firstMetadataRefreshed)

        let second = CaptureDocument(image: fixture.original.image)
        let copied = await fixture.app.copy(second)
        XCTAssertTrue(copied, "Copy must remain independent from optional OCR")
        var secondIsDurable = false
        for _ in 0..<300 {
            let records = try await fixture.store.records()
            if records.contains(where: { $0.id == second.id }) { secondIsDurable = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(secondIsDurable)
        let visibleBeforeFirstOCRFinishes = await eventually {
            fixture.model.entries.contains { $0.id == second.id }
        }
        XCTAssertTrue(visibleBeforeFirstOCRFinishes,
            "A durable capture stayed absent from History until an unrelated older OCR job finished")

        // Release OCR only after checking visibility: otherwise the old combined
        // observer would make this regression pass for the wrong reason.
        await recognizer.release(1)
        let secondOCRStarted = await recognizer.waitUntilStarted(2)
        XCTAssertTrue(secondOCRStarted)
        await recognizer.release(2)
        _ = await fixture.app.prepareToQuit()
    }

    func testDisablingIndexingClearsAlreadyDisplayedRecognizedText() async throws {
        let fixture = try HistoryRefreshFixture()
        defer { fixture.cleanUp() }
        try await fixture.prepare(query: "Copper river")
        XCTAssertEqual(fixture.model.entries.count, 1)
        await fixture.app.setHistoryIndexing(false)
        XCTAssertTrue(fixture.model.entries.isEmpty, "Cleared disk OCR remained visible in the open history model")
        XCTAssertTrue(fixture.model.selection.isEmpty)
        _ = await fixture.app.prepareToQuit()
    }

    func testDurabilityAcknowledgmentReleasesBoundedRevisionBarriers() async throws {
        let fixture = try HistoryRefreshFixture()
        defer { fixture.cleanUp() }
        try await fixture.prepare(query: "")
        let model = fixture.makeModel(maximumPendingRevisions: 1)
        let second = CaptureDocument(image: fixture.original.image)
        try await fixture.store.persist(id: second.id, image: second.image, edits: second.edits, revision: 0, savedURL: nil)
        await model.reload()
        model.invalidate(id: fixture.original.id, minimumRevision: 1)
        await model.reload()
        XCTAssertEqual(model.entries.map(\.id), [second.id])
        try await fixture.store.persist(id: fixture.original.id, image: fixture.original.image,
            edits: fixture.original.edits, revision: 1, savedURL: nil)
        model.acknowledgeDurableRecords(try await fixture.store.records())

        model.invalidate(id: second.id, minimumRevision: 1)
        try await fixture.store.persist(id: second.id, image: second.image, edits: second.edits, revision: 1, savedURL: nil)
        model.acknowledgeDurableRecords(try await fixture.store.records())
        await model.reload()
        XCTAssertEqual(Set(model.entries.map(\.id)), [fixture.original.id, second.id],
            "Acknowledged barriers must release capacity for later edits")
        XCTAssertTrue(model.entries.allSatisfy { $0.record.revision == 1 })
        XCTAssertNil(model.errorMessage)
        _ = await fixture.app.prepareToQuit()
    }

    func testSuccessfulDeletionReleasesRevisionBarrierCapacity() async throws {
        let fixture = try HistoryRefreshFixture()
        defer { fixture.cleanUp() }
        try await fixture.prepare(query: "")
        let store = fixture.store
        let model = CaptureHistoryModel(store: store, maximumPendingRevisions: 1,
            onOpen: { _ in }, onPin: { _ in }, onDelete: { try await store.discard(id: $0) },
            onCombine: { _, _ in }, onRetentionChange: { _ in })
        let second = CaptureDocument(image: fixture.original.image)
        try await store.persist(id: second.id, image: second.image, edits: second.edits, revision: 0, savedURL: nil)
        await model.reload()
        model.invalidate(id: fixture.original.id, minimumRevision: 1)

        // The invalidated edit is never persisted: successful explicit deletion
        // is the only event that can release this capture's pending barrier.
        await model.delete(ids: [fixture.original.id])
        let recoveryRoot = await store.root
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            recoveryRoot.appendingPathComponent(fixture.original.id.uuidString).path))
        XCTAssertEqual(model.entries.map(\.id), [second.id])

        model.invalidate(id: second.id, minimumRevision: 1)
        try await store.persist(id: second.id, image: second.image, edits: second.edits, revision: 1, savedURL: nil)
        model.acknowledgeDurableRecords(try await store.records())
        await model.reload()
        XCTAssertEqual(model.entries.map(\.id), [second.id],
            "A successfully deleted capture retained its barrier and exhausted capacity for the next edit")
        XCTAssertEqual(model.entries.first?.record.revision, 1)
        XCTAssertNil(model.errorMessage)
        _ = await fixture.app.prepareToQuit()
    }

    func testFailedDeletionRetainsRevisionBarrierAgainstOldTextReappearing() async throws {
        let fixture = try HistoryRefreshFixture()
        defer { fixture.cleanUp() }
        try await fixture.prepare(query: "")
        let store = fixture.store
        let model = CaptureHistoryModel(store: store, maximumPendingRevisions: 1,
            onOpen: { _ in }, onPin: { _ in },
            onDelete: { _ in throw CaptureError.failed("Deletion was refused by the test storage boundary") },
            onCombine: { _, _ in }, onRetentionChange: { _ in })
        let second = CaptureDocument(image: fixture.original.image)
        try await store.persist(id: second.id, image: second.image, edits: second.edits, revision: 0, savedURL: nil)
        await model.reload()
        model.invalidate(id: fixture.original.id, minimumRevision: 1)
        await model.delete(ids: [fixture.original.id])
        XCTAssertNotNil(model.errorMessage)
        let records = try await store.records()
        XCTAssertEqual(Set(records.map(\.id)), [fixture.original.id, second.id])

        // Releasing A's barrier despite the error would let its old, sensitive
        // revision reappear when the next edit consumes the sole free slot.
        model.invalidate(id: second.id, minimumRevision: 1)
        await model.reload()
        XCTAssertTrue(model.entries.isEmpty, "A failed delete released protection and exposed old text again")
        XCTAssertNotNil(model.errorMessage)
        _ = await fixture.app.prepareToQuit()
    }

    func testRevisionBarrierCapacityFailsClosedInsteadOfEvictingProtection() async throws {
        let fixture = try HistoryRefreshFixture()
        defer { fixture.cleanUp() }
        try await fixture.prepare(query: "")
        let model = fixture.makeModel(maximumPendingRevisions: 1)
        let second = CaptureDocument(image: fixture.original.image)
        try await fixture.store.persist(id: second.id, image: second.image, edits: second.edits, revision: 0, savedURL: nil)
        await model.reload()
        model.invalidate(id: fixture.original.id, minimumRevision: 1)
        model.invalidate(id: second.id, minimumRevision: 1)
        await model.reload()
        XCTAssertTrue(model.entries.isEmpty, "Capacity pressure must not evict a barrier and redisplay outdated sensitive pixels")
        XCTAssertNotNil(model.errorMessage)
        _ = await fixture.app.prepareToQuit()
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }
}

@MainActor
private struct HistoryRefreshFixture {
    let root: URL
    let suite = "SwiftShotHistoryRefresh.\(UUID())"
    let defaults: UserDefaults
    let original: CaptureDocument
    let store: RecoveryStore
    let recoveryCoordinator: RecoveryCoordinator
    let indexing: HistoryIndexingCoordinator
    let window: HistoryWindowController
    let presenter = HistoryRefreshPresenter()
    let app: AppState
    var model: CaptureHistoryModel { window.model }

    init(indexingEnabled: Bool = false, recognizer: any TextRecognizing = HistoryRefreshRecognizer()) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftShotHistoryRefresh-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        original = CaptureDocument(image: try XCTUnwrap(context.makeImage()))
        store = RecoveryStore(root: root.appendingPathComponent("recovery"))
        recoveryCoordinator = RecoveryCoordinator(store: store)
        indexing = HistoryIndexingCoordinator(store: store, recovery: recoveryCoordinator,
            recognizer: recognizer, enabled: indexingEnabled)
        window = HistoryWindowController(store: store, onOpen: { _ in }, onPin: { _ in }, onDelete: { _ in },
            onCombine: { _, _ in }, onRetentionChange: { _ in })
        var settings = AppSettings.default
        settings.saveDirectory = root.path
        settings.historyIndexingEnabled = indexingEnabled
        try defaults.set(JSONEncoder().encode(settings), forKey: "com.swiftshot.settings")
        app = AppState(defaults: defaults, recovery: store,
            backgrounds: BackgroundLibrary(rootURL: root.appendingPathComponent("backgrounds")),
            clipboard: HistoryRefreshClipboard(), presentsUI: false, persistUnsavedCaptures: true,
            captureService: HistoryRefreshCaptureService(), textRecognizer: recognizer,
            overlay: presenter, diagnostics: nil, recoveryCoordinator: recoveryCoordinator,
            indexingCoordinator: indexing, historyWindow: window)
    }

    func prepare(query: String) async throws {
        try await store.persist(id: original.id, image: original.image, edits: original.edits, revision: 0, savedURL: nil)
        try await store.indexOCR(id: original.id, text: "Copper river 4827", revision: 0, privateCapture: false)
        model.query = query
        await model.reload()
        model.selection = [original.id]
        XCTAssertNil(window.window, "This fixture must not construct or display a native window")
    }

    func makeModel(maximumPendingRevisions: Int) -> CaptureHistoryModel {
        CaptureHistoryModel(store: store, maximumPendingRevisions: maximumPendingRevisions,
            onOpen: { _ in }, onPin: { _ in }, onDelete: { _ in }, onCombine: { _, _ in }, onRetentionChange: { _ in })
    }

    func copy(_ document: CaptureDocument, file: StaticString = #filePath, line: UInt = #line) async {
        let copied = await app.copy(document)
        XCTAssertTrue(copied, "The fixture's image should be copied successfully", file: file, line: line)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class HistoryRefreshPresenter: CapturePresenting {
    var activeDocument: CaptureDocument?
    private var onDocument: ((CaptureDocument) -> Void)?
    func changed(_ document: CaptureDocument) { onDocument?(document) }
    func configure(actions: CaptureActions) {}
    func present(screens: [FrozenScreen], mode: CaptureMode, style: CaptureStyle, library: BackgroundLibrary,
                 onDocument: @escaping (CaptureDocument) -> Void, onCopy: @escaping (CaptureDocument) -> Void,
                 onSave: @escaping (CaptureDocument) -> Void, onOCR: @escaping (CaptureDocument) -> Void,
                 onCancel: @escaping () -> Void, onDiscard: @escaping (CaptureDocument) -> Void) { self.onDocument = onDocument }
    func reopen(document: CaptureDocument, library: BackgroundLibrary, onCopy: @escaping (CaptureDocument) -> Void,
                onSave: @escaping (CaptureDocument) -> Void, onCancel: @escaping () -> Void,
                onDocument: @escaping (CaptureDocument) -> Void, onDiscard: @escaping (CaptureDocument) -> Void) {
        activeDocument = document
        self.onDocument = onDocument
    }
    func dismiss() { activeDocument = nil }
    func showStatus(_ message: String, isError: Bool) {}
}

@MainActor
private final class HistoryRefreshClipboard: CaptureClipboard {
    func copyPNGData(_ data: Data) -> Bool { true }
    func copyText(_ text: String) -> Bool { true }
}

@MainActor
private final class HistoryRefreshCaptureService: ScreenCaptureProviding {
    func freeze(mode: CaptureMode) async throws -> [FrozenScreen] { [] }
}

private actor HistoryRefreshRecognizer: TextRecognizing {
    func recognizeText(in image: CGImage) async throws -> String { "Copper river" }
}

private actor HistoryRefreshGatedRecognizer: TextRecognizing {
    private var calls = 0
    private let failingCalls: Set<Int>
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    init(failingCalls: Set<Int> = []) { self.failingCalls = failingCalls }
    func recognizeText(in image: CGImage) async throws -> String {
        calls += 1
        let call = calls
        await withCheckedContinuation { continuations[call] = $0 }
        if failingCalls.contains(call) { throw CaptureError.failed("Recognition failed at the test boundary") }
        return call == 1 ? "superseded OCR" : "Copper river"
    }
    func waitUntilStarted(_ count: Int) async -> Bool {
        for _ in 0..<300 {
            if calls >= count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return calls >= count
    }
    func release(_ call: Int) { continuations.removeValue(forKey: call)?.resume() }
    func releaseAll() {
        for continuation in continuations.values { continuation.resume() }
        continuations.removeAll()
    }
}

private final class HistoryRefreshStoreGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var didStart = false
    private var released = false
    var started: Bool { condition.lock(); defer { condition.unlock() }; return didStart }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func hold() {
        condition.lock(); defer { condition.unlock() }
        didStart = true
        let deadline = Date().addingTimeInterval(5)
        while !released { if !condition.wait(until: deadline) { return } }
    }
}

extension RecoveryStore {
    fileprivate func holdForHistoryRefreshTest(_ gate: HistoryRefreshStoreGate) { gate.hold() }
}
