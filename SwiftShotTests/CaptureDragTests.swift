import XCTest
import AppKit
import ImageIO
@testable import SwiftShot

final class CaptureDragTests: XCTestCase {
    @MainActor func testCanceledOrRejectedNativeDragDoesNotReportSuccessfulDelivery() {
        var copied = 0, canceled = 0
        for operation: NSDragOperation in [[], .move, .link] {
            CaptureDragCompletion.dispatch(operation: operation, onCopied: { copied += 1 }, onCanceled: { canceled += 1 })
        }
        XCTAssertEqual(copied, 0, "Unaccepted drops must not close the editor as a successful copy")
        XCTAssertEqual(canceled, 3)
    }

    @MainActor func testAcceptedNativeCopyUsesExistingSuccessCallbackOnce() {
        var copied = 0, canceled = 0
        CaptureDragCompletion.dispatch(operation: [.copy, .link], onCopied: { copied += 1 }, onCanceled: { canceled += 1 })
        XCTAssertEqual(copied, 1)
        XCTAssertEqual(canceled, 0)
    }

    private func source() -> CGImage {
        let context = CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 320,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        XCTAssertEqual(Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: 4)), [255, 0, 0, 255])
        return context.makeImage()!
    }
    @MainActor func testPreparedNativeDragContainsOnlyFlattenedPNGAndFilePromiseTypes() async throws {
        let renderer = ImageRenderer()
        let request = RenderRequest(image: source(), edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 80, height: 40),
            annotations: [CaptureAnnotation(kind: .redact, start: .zero, end: CGPoint(x: 20, y: 20))]), backgroundURL: nil)
        let prepared = try await PreparedCaptureDrag.prepare(request: request, renderer: renderer)
        let provider = CaptureDragPasteboardWriter(png: prepared.png)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(provider.writableTypes(for: pasteboard).contains(.png))
        XCTAssertFalse(provider.writableTypes(for: pasteboard).contains(.fileURL))
        XCTAssertFalse(provider.writableTypes(for: pasteboard).contains(.tiff))
        XCTAssertTrue(provider.writingOptions(forType: .png, pasteboard: pasteboard).contains(.promised))
        XCTAssertEqual(provider.pasteboardPropertyList(forType: .png) as? Data, prepared.png)
        XCTAssertEqual(provider.fileType, "public.png")
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(prepared.png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        let context = CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 320,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 80, height: 40))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: bytes + (10 * 80 + 10) * 4, count: 4)), [0, 0, 0, 255])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: bytes + (30 * 80 + 50) * 4, count: 4)), [255, 0, 0, 255])
    }
    @MainActor func testUnsafeDragIsRefusedBeforeRendering() async {
        let renderer = ImageRenderer()
        let request = RenderRequest(image: source(), edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 80, height: 40),
            style: CaptureStyle(backgroundID: "background", padding: 16_384)), backgroundURL: nil)
        do { _ = try await PreparedCaptureDrag.prepare(request: request, renderer: renderer); XCTFail("Unsafe drag was prepared") }
        catch { }
        let statistics = await renderer.cacheStatistics
        XCTAssertEqual(statistics.renders, 0)
        XCTAssertEqual(statistics.encodes, 0)
    }
    func testPromiseWritesOnlySuppliedDestinationAndRefusesOverwriteOrInvalidPayload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftShotDropTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("UserDrop.png")
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3])
        try CaptureDragFileWriter.write(png: png, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), png)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["UserDrop.png"])
        XCTAssertThrowsError(try CaptureDragFileWriter.write(png: png + Data([4]), to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), png)
        XCTAssertThrowsError(try CaptureDragFileWriter.write(png: Data([1]), to: directory.appendingPathComponent("Invalid.png")))
        XCTAssertThrowsError(try CaptureDragFileWriter.write(png: png, to: directory.appendingPathComponent("Invalid.txt")))
    }
}
