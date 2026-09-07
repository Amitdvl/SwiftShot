import XCTest
import AppKit
import ImageIO
@testable import SwiftShot

final class BackgroundLibraryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftShotLibraryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult private func fixture(_ directory: URL, name: String = "Forest.png") throws -> URL {
        let url = directory.appendingPathComponent(name)
        let context = CGContext(data: nil, width: 24, height: 18, bitsPerComponent: 8, bytesPerRow: 96,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 18))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    @MainActor func testImportsCopiesAndDistinctIDsSurviveRelaunchAndSourceMove() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(directory)
        let originalData = try Data(contentsOf: source)
        let root = directory.appendingPathComponent("Library")
        let library = BackgroundLibrary(rootURL: root, bundleURL: directory.appendingPathComponent("EmptyBundle"))
        try await library.importFiles([source, source])
        XCTAssertEqual(library.assets.count, 2)
        XCTAssertEqual(Set(library.assets.map(\.id)).count, 2)
        XCTAssertEqual(library.assets.map(\.name), ["Forest", "Forest"])
        XCTAssertTrue(library.assets.allSatisfy { !$0.isBundled && $0.url != source })
        for asset in library.assets { XCTAssertEqual(try Data(contentsOf: asset.url), originalData) }
        XCTAssertEqual(try Data(contentsOf: source), originalData)
        let ids = library.assets.map(\.id)
        try FileManager.default.moveItem(at: source, to: directory.appendingPathComponent("Moved.png"))
        let relaunched = BackgroundLibrary(rootURL: root, bundleURL: directory.appendingPathComponent("EmptyBundle"))
        XCTAssertEqual(relaunched.assets.map(\.id), ids)
        for id in ids { XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(relaunched.url(for: id)).path)) }
    }

    @MainActor func testEditUndoRestoresRemovedBackgroundWithoutReplacingOtherAssets() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(directory)
        let library = BackgroundLibrary(rootURL: directory.appendingPathComponent("Library"), bundleURL: directory.appendingPathComponent("EmptyBundle"))
        try await library.importFiles([source])
        let asset = try XCTUnwrap(library.assets.first)
        try library.remove(id: asset.id)
        try library.restoreForEdit(id: asset.id)
        XCTAssertEqual(library.url(for: asset.id), asset.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.url.path))
        XCTAssertFalse(library.canUndoRemoval)
        XCTAssertThrowsError(try library.restoreForEdit(id: "missing"))
        XCTAssertEqual(library.assets.count, 1)
    }

    @MainActor func testRemovalIsUndoableAcrossRelaunchWithoutDeletingOriginal() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(directory)
        let root = directory.appendingPathComponent("Library")
        let bundle = directory.appendingPathComponent("EmptyBundle")
        let library = BackgroundLibrary(rootURL: root, bundleURL: bundle)
        try await library.importFiles([source])
        let asset = try XCTUnwrap(library.assets.first)
        try library.remove(id: asset.id)
        XCTAssertTrue(library.assets.isEmpty)
        XCTAssertTrue(library.canUndoRemoval)
        XCTAssertFalse(FileManager.default.fileExists(atPath: asset.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let relaunched = BackgroundLibrary(rootURL: root, bundleURL: bundle)
        XCTAssertTrue(relaunched.canUndoRemoval)
        try relaunched.undoRemoval()
        XCTAssertEqual(relaunched.assets, [asset])
        XCTAssertFalse(relaunched.canUndoRemoval)
        XCTAssertEqual(try Data(contentsOf: asset.url), try Data(contentsOf: source))
    }

    @MainActor func testBundledHideUndoAndRestorePersist() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(directory, name: "sunset-glow.png")
        let root = directory.appendingPathComponent("Library")
        let library = BackgroundLibrary(rootURL: root, bundleURL: directory)
        let asset = try XCTUnwrap(library.assets.first)
        XCTAssertEqual(asset.id, "bundled:sunset-glow")
        XCTAssertEqual(asset.name, "Sunset Glow")
        XCTAssertTrue(asset.isBundled)
        try library.remove(id: asset.id)
        XCTAssertTrue(library.assets.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let relaunched = BackgroundLibrary(rootURL: root, bundleURL: directory)
        XCTAssertTrue(relaunched.assets.isEmpty)
        try relaunched.undoRemoval()
        XCTAssertEqual(relaunched.assets, [asset])
        try relaunched.remove(id: asset.id)
        try relaunched.restoreBundled()
        XCTAssertEqual(relaunched.assets, [asset])
        XCTAssertFalse(relaunched.canUndoRemoval)
    }

    @MainActor func testInvalidBatchRollsBackValidFilesAndPreservesExistingLibrary() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(directory)
        let invalid = directory.appendingPathComponent("Broken.png")
        try Data("not an image".utf8).write(to: invalid)
        let root = directory.appendingPathComponent("Library")
        let library = BackgroundLibrary(rootURL: root, bundleURL: directory.appendingPathComponent("EmptyBundle"))
        try await library.importFiles([source])
        let original = library.assets
        do {
            try await library.importFiles([source, invalid])
            XCTFail("Invalid batch should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("readable image"))
        }
        XCTAssertEqual(library.assets, original)
        XCTAssertFalse(library.isImporting)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "png" }.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalid.path))
    }

    @MainActor func testOversizedFileRejectedBeforeDecoding() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Huge.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 51 * 1_024 * 1_024)
        try handle.close()
        let library = BackgroundLibrary(rootURL: directory.appendingPathComponent("Library"), bundleURL: directory.appendingPathComponent("EmptyBundle"))
        do { try await library.importFiles([source]); XCTFail("Oversized image should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("too large")) }
        XCTAssertTrue(library.assets.isEmpty)
    }

    @MainActor func testFailedMetadataWriteRollsBackImportAndRemoval() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(directory)
        let root = directory.appendingPathComponent("Library")
        let library = BackgroundLibrary(rootURL: root, bundleURL: directory.appendingPathComponent("EmptyBundle"))
        try await library.importFiles([source])
        let asset = try XCTUnwrap(library.assets.first)
        // Replacing the manifest with a directory reliably forces atomic-write failure, including as root.
        try FileManager.default.removeItem(at: root.appendingPathComponent("library.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("library.json"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try library.remove(id: asset.id))
        XCTAssertEqual(library.assets, [asset])
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.url.path))
        do { try await library.importFiles([source]); XCTFail("Persistence failure should fail import") } catch { }
        XCTAssertEqual(library.assets, [asset])
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "png" }.count, 1)
    }

    @MainActor func testCorruptManifestReportsErrorAndIsNotOverwritten() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(directory)
        let manifest = directory.appendingPathComponent("library.json")
        let data = Data("corrupted".utf8)
        try data.write(to: manifest)
        let library = BackgroundLibrary(rootURL: directory, bundleURL: directory.appendingPathComponent("EmptyBundle"))
        XCTAssertNotNil(library.errorMessage)
        do { try await library.importFiles([source]); XCTFail("Corrupt store must stay read-only") } catch { }
        XCTAssertEqual(try Data(contentsOf: manifest), data)
    }

    @MainActor func testThumbnailLoadsAsynchronouslyAndIsCached() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try fixture(directory)
        let library = BackgroundLibrary(rootURL: directory.appendingPathComponent("Library"), bundleURL: directory)
        let id = try XCTUnwrap(library.assets.first?.id)
        XCTAssertNil(library.thumbnail(for: id))
        for _ in 0..<100 {
            if library.thumbnail(for: id) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let thumbnail = try XCTUnwrap(library.thumbnail(for: id))
        XCTAssertLessThanOrEqual(max(thumbnail.size.width, thumbnail.size.height), 240)
        XCTAssertTrue(thumbnail === library.thumbnail(for: id))
    }
}
