import XCTest
import AppKit
import ImageIO
@testable import SwiftShot

@MainActor
final class CaptureWorkflowTests: XCTestCase {
    func testFailedSaveRetainsOriginalAndCanRetryWithAnotherFolder() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = RecoveryStore(root: root.appendingPathComponent("recovery"))
        let clipboard = TestClipboard()
        let app = makeState(root: root, recovery: recovery, clipboard: clipboard)
        let destinationFile = root.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: destinationFile)
        app.appSettings.saveDirectory = destinationFile.path
        let document = CaptureDocument(image: try fixture())
        app.lastDocument = document
        await app.save(document)
        XCTAssertNil(document.savedURL)
        XCTAssertTrue(app.statusMessage?.contains("Save failed") == true)
        let preserved = try await recovery.load(id: document.id)
        XCTAssertEqual(preserved.image.width, 120)
        XCTAssertEqual(preserved.record.edits, document.edits)
        app.appSettings.saveDirectory = root.appendingPathComponent("exports").path
        await app.save(document)
        XCTAssertNotNil(document.savedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(document.savedURL).path))
        let record = try await recovery.load(id: document.id).record
        XCTAssertNotNil(record.savedPath)
    }

    func testCopyFailureRetainsCaptureAndSuccessfulCopyCanThenSaveSamePNG() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = RecoveryStore(root: root.appendingPathComponent("recovery"))
        let clipboard = TestClipboard()
        let app = makeState(root: root, recovery: recovery, clipboard: clipboard)
        let document = CaptureDocument(image: try fixture())
        app.lastDocument = document
        clipboard.succeeds = false
        await app.copy(document)
        XCTAssertTrue(app.statusMessage?.contains("clipboard") == true)
        let records = try await recovery.records()
        XCTAssertEqual(records.map(\.id), [document.id])
        clipboard.succeeds = true
        await app.copy(document)
        let copied = try XCTUnwrap(clipboard.png)
        await app.save(document)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(document.savedURL)), copied)
    }

    func testUnsavedCopyStaysOffDiskUntilExplicitSave() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = RecoveryStore(root: root.appendingPathComponent("recovery"))
        let clipboard = TestClipboard()
        let app = makeState(root: root, recovery: recovery, clipboard: clipboard, persistUnsavedCaptures: false)
        let document = CaptureDocument(image: try fixture())
        app.lastDocument = document

        let copied = await app.copy(document)
        XCTAssertTrue(copied)
        let transientRecords = try await recovery.records()
        XCTAssertTrue(transientRecords.isEmpty,
                      "Clipboard-only captures must not create recovery files")

        await app.save(document)
        let records = try await recovery.records()
        XCTAssertEqual(records.map(\.id), [document.id])
        XCTAssertNotNil(records.first?.savedPath)
    }

    func testRapidCapturesAreIndependentAndStaleRevisionCannotOverwriteNewEdits() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root)
        let a = CaptureDocument(image: try fixture())
        let b = CaptureDocument(image: try fixture())
        let originalA = a.edits
        a.change { $0.crop = CGRect(x: 10, y: 20, width: 40, height: 30) }
        try await store.persist(id: a.id, image: a.image, edits: a.edits, revision: a.revision, savedURL: nil)
        try await store.persist(id: b.id, image: b.image, edits: b.edits, revision: b.revision, savedURL: nil)
        try await store.persist(id: a.id, image: a.image, edits: originalA, revision: 0, savedURL: nil)
        let records = try await store.records()
        XCTAssertEqual(Set(records.map(\.id)), Set([a.id, b.id]))
        let loaded = try await store.load(id: a.id)
        XCTAssertEqual(loaded.record.edits.crop, a.edits.crop)
        let reopened = CaptureDocument(id: loaded.record.id, image: loaded.image, edits: loaded.record.edits, revision: loaded.record.revision)
        reopened.change { $0.style.padding = 80 }
        try await store.persist(id: reopened.id, image: reopened.image, edits: reopened.edits, revision: reopened.revision, savedURL: nil)
        let reloaded = try await store.load(id: a.id)
        XCTAssertEqual(reloaded.record.edits.style.padding, 80)
    }

    func testPruningOnlyRemovesSavedCaptures() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root)
        let image = try fixture()
        let unsaved = UUID(), oldSaved = UUID(), newest = UUID()
        let edits = CaptureEdits(crop: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for id in [unsaved, oldSaved, newest] {
            try await store.persist(id: id, image: image, edits: edits, revision: 0, savedURL: id == unsaved ? nil : root.appendingPathComponent("saved.png"))
        }
        try await store.pruneSaved(except: newest)
        let records = try await store.records()
        XCTAssertEqual(Set(records.map(\.id)), Set([unsaved, newest]))
    }

    func testUndoRedoRestoresCropAnnotationsAndStyleAndInvalidatesSavedVersion() throws {
        let document = CaptureDocument(image: try fixture())
        let original = document.edits
        document.savedURL = URL(fileURLWithPath: "/tmp/saved.png")
        document.change {
            $0.crop = CGRect(x: 10, y: 10, width: 80, height: 40)
            $0.style.backgroundID = "bundled:blue"
            $0.annotations = [CaptureAnnotation(kind: .redact, start: CGPoint(x: 15, y: 15), end: CGPoint(x: 30, y: 30))]
        }
        let edited = document.edits
        XCTAssertNil(document.savedURL)
        document.undo()
        XCTAssertEqual(document.edits, original)
        document.redo()
        XCTAssertEqual(document.edits, edited)
        document.undo()
        document.change { $0.style.padding = 100 }
        XCTAssertFalse(document.canRedo)
    }

    func testLegacyPreferencesMigrateShortcutAndBackgroundWithoutLosingFolder() throws {
        let legacy = #"{"saveDirectory":"/custom/folder","backgroundName":"green","shortcuts":[{"mode":"region","keyCode":19,"modifiers":2304,"enabled":true,"displayString":"⌘⇧2"}]}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(settings.saveDirectory, "/custom/folder")
        XCTAssertEqual(settings.style.backgroundID, "bundled:green")
        XCTAssertEqual(settings.shortcuts[0].modifiers, 0x300)
        XCTAssertEqual(settings.shortcuts[0].displayString, "⌘⇧2")
        var current = settings
        current.shortcuts[0].modifiers = 0x900
        current.shortcuts[0].refreshLabel()
        let roundtrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(roundtrip.shortcuts[0].modifiers, 0x900)
        XCTAssertEqual(roundtrip.shortcuts[0].displayString, "⌥⌘2")
    }

    func testExportCreatesDistinctFilesAndRejectsEmptyData() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exporter = ExportService()
        let data = Data([137, 80, 78, 71])
        let a = try exporter.savePNGData(data, to: root.path)
        let b = try exporter.savePNGData(data, to: root.path)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(try Data(contentsOf: a), data)
        XCTAssertThrowsError(try exporter.savePNGData(Data(), to: root.path))
    }

    private func makeState(root: URL, recovery: RecoveryStore, clipboard: TestClipboard,
                           persistUnsavedCaptures: Bool = true) -> AppState {
        let defaults = UserDefaults(suiteName: "SwiftShotTests.\(UUID())")!
        let state = AppState(defaults: defaults, recovery: recovery,
                             backgrounds: BackgroundLibrary(rootURL: root.appendingPathComponent("backgrounds")),
                             clipboard: clipboard, presentsUI: false,
                             persistUnsavedCaptures: persistUnsavedCaptures)
        state.appSettings.saveDirectory = root.appendingPathComponent("exports").path
        return state
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftShotTests-\(UUID())")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixture() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        return try XCTUnwrap(context.makeImage())
    }
}

@MainActor
private final class TestClipboard: CaptureClipboard {
    var succeeds = true
    var png: Data?
    func copyPNGData(_ data: Data) -> Bool { if succeeds { png = data }; return succeeds }
    func copyText(_ text: String) -> Bool { succeeds }
}
