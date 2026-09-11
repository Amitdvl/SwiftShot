import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import SwiftShot

/// Synthetic, in-memory marked inputs; actual renderer PNGs and actual private
/// Copy/Save exports. No screen, native clipboard, user history, or UI is used.
/// Existing behavior may already pass: the lead must run the named mutations
/// before treating these tests as demonstrated regression protection.
final class ExportContainerPrivacyTests: XCTestCase {
    // Break: the raw zero-copy bitmap fast path forwards its source PNG container
    // or source metadata instead of encoding only the immutable image pixels.
    func testRawZeroCopyExportStripsMarkedMetadataAndEmbeddedOriginalContainer() async throws {
        let fixture = try MarkedPNGFixture.make()
        let result = try await ImageRenderer().render(RenderRequest(image: fixture.image,
            edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 16, height: 12)), backgroundURL: nil))

        XCTAssertTrue(result.image === fixture.image, "Raw rendering may share pixels, never the marked source container")
        let decoded = try assertPrivatePayloadAbsent(result.png, fixture: fixture, width: 16, height: 12)
        let pixels = try rgba(decoded)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            XCTAssertEqual(Array(pixels[offset..<offset + 4]), [255, 0, 255, 255])
        }
    }

    // Break: a same-ID/revision raw cache entry hides changed crop/redaction
    // edits, encoding the unredacted original or a translucent redaction.
    func testWarmRawCacheCannotLeakOriginalIntoCroppedRedactedNativePNG() async throws {
        let fixture = try MarkedPNGFixture.make()
        let renderer = ImageRenderer()
        let id = UUID()
        var unredactedEdits = Self.redactedEdits
        unredactedEdits.annotations = []
        _ = try await renderer.render(RenderRequest(image: fixture.image,
            edits: unredactedEdits,
            backgroundURL: nil, documentID: id, revision: 9))
        let result = try await renderer.render(RenderRequest(image: fixture.image, edits: Self.redactedEdits,
            backgroundURL: nil, documentID: id, revision: 9))

        XCTAssertEqual(result.image.width, 8)
        XCTAssertEqual(result.image.height, 8)
        let decoded = try assertPrivatePayloadAbsent(result.png, fixture: fixture, width: 8, height: 8)
        // Original crop [4,2,8,8], redaction [6,4]→[10,8]: literal output mask
        // x=2..<6,y=2..<6. Derive nothing from production annotation geometry.
        try assertOpaqueMask(decoded, size: 8, covered: 2..<6, exactOutsideMagenta: true)
    }

    // Break: output policy is omitted from the cache key, or downsampling/PNG
    // encoding exposes source pixels or alpha inside the final redaction mask.
    func testSmallerPNGAfterNativeExportRetainsOnlyFlattenedOpaqueRedaction() async throws {
        let fixture = try MarkedPNGFixture.make()
        let renderer = ImageRenderer()
        let id = UUID()
        _ = try await renderer.render(RenderRequest(image: fixture.image, edits: Self.redactedEdits,
            backgroundURL: nil, documentID: id, revision: 9))
        let result = try await renderer.render(RenderRequest(image: fixture.image, edits: Self.redactedEdits,
            backgroundURL: nil, documentID: id, revision: 9, output: .smallerShare(maxPixelDimension: 4)))

        XCTAssertEqual(result.image.width, 4)
        XCTAssertEqual(result.image.height, 4)
        let decoded = try assertPrivatePayloadAbsent(result.png, fixture: fixture, width: 4, height: 4)
        // The independent 1/2 mapping gives x=1..<3,y=1..<3. Outside the mask,
        // interpolation may change magenta, but must not expand the black mask.
        try assertOpaqueMask(decoded, size: 4, covered: 1..<3, exactOutsideMagenta: false)
    }

    // Break: AppState Copy/Save bypasses the flattened renderer output, disagrees
    // on native/smaller policy, or reuses original/container bytes at publication.
    @MainActor func testPrivateCopyAndSavePublishIdenticalCleanCachedNativeAndSmallerPNGs() async throws {
        let fixture = try MarkedPNGFixture.make()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftShotExportPrivacy-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "SwiftShotExportPrivacy.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = RecoveryStore(root: root.appendingPathComponent("recovery", isDirectory: true))
        let renderer = ImageRenderer()
        let clipboard = PrivacyClipboardSink()
        let app = AppState(defaults: defaults, recovery: store,
            backgrounds: BackgroundLibrary(rootURL: root.appendingPathComponent("backgrounds"),
                bundleURL: root.appendingPathComponent("no-bundled-backgrounds")),
            exporter: ExportService(), clipboard: clipboard, presentsUI: false, persistUnsavedCaptures: true,
            renderer: renderer, diagnostics: nil)
        app.appSettings.saveDirectory = root.appendingPathComponent("exports", isDirectory: true).path
        app.appSettings.shareMaxDimension = 4
        app.appSettings.historyIndexingEnabled = false
        app.appSettings.showRecentThumbnail = false
        let document = CaptureDocument(image: fixture.image, edits: Self.redactedEdits, revision: 9)
        document.isPrivate = true

        // Await real coordinator shutdown before removing isolated state on both
        // success and thrown-assertion paths. Do not launch AppState.start().
        do {
            let copiedNative = await app.copy(document)
            XCTAssertTrue(copiedNative)
            let nativeCopy = try XCTUnwrap(clipboard.png)
            try assertOpaqueMask(assertPrivatePayloadAbsent(nativeCopy, fixture: fixture, width: 8, height: 8),
                size: 8, covered: 2..<6, exactOutsideMagenta: true)
            await app.save(document)
            let nativeURL = try XCTUnwrap(document.savedURL)
            XCTAssertEqual(nativeURL.deletingLastPathComponent().path, app.appSettings.saveDirectory)
            let nativeSaved = try Data(contentsOf: nativeURL)
            XCTAssertEqual(nativeSaved, nativeCopy, "Actual disk Save must publish the same cached flattened PNG as Copy")
            _ = try assertPrivatePayloadAbsent(nativeSaved, fixture: fixture, width: 8, height: 8)
            let nativeStatistics = await renderer.cacheStatistics
            XCTAssertEqual(nativeStatistics.encodes, 1)
            XCTAssertEqual(nativeStatistics.pngHits, 1, "Save must reuse this unchanged native Copy result")

            let copiedSmaller = await app.copy(document, smaller: true)
            XCTAssertTrue(copiedSmaller)
            let smallerCopy = try XCTUnwrap(clipboard.png)
            try assertOpaqueMask(assertPrivatePayloadAbsent(smallerCopy, fixture: fixture, width: 4, height: 4),
                size: 4, covered: 1..<3, exactOutsideMagenta: false)
            await app.save(document, smaller: true)
            let smallerURL = try XCTUnwrap(document.savedURL)
            XCTAssertNotEqual(smallerURL, nativeURL)
            XCTAssertEqual(smallerURL.deletingLastPathComponent().path, app.appSettings.saveDirectory)
            let smallerSaved = try Data(contentsOf: smallerURL)
            XCTAssertEqual(smallerSaved, smallerCopy)
            _ = try assertPrivatePayloadAbsent(smallerSaved, fixture: fixture, width: 4, height: 4)
            XCTAssertEqual(try Data(contentsOf: nativeURL), nativeCopy, "Smaller Save must not overwrite the native export")
            let smallerStatistics = await renderer.cacheStatistics
            XCTAssertEqual(smallerStatistics.encodes, 2)
            XCTAssertEqual(smallerStatistics.pngHits, 2)
            let records = try await store.records()
            XCTAssertTrue(records.isEmpty, "Explicit private export must not create an editable recovery original")
            XCTAssertNil(app.recoveryProblem)
        } catch {
            _ = await app.prepareToQuit()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        let prepared = await app.prepareToQuit()
        XCTAssertTrue(prepared, "Isolated export work must finish before cleanup")
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }

    private static var redactedEdits: CaptureEdits {
        var redaction = CaptureAnnotation(kind: .redact, start: CGPoint(x: 6, y: 4), end: CGPoint(x: 10, y: 8))
        redaction.color = AnnotationColor(red: 1, green: 0, blue: 1, alpha: 0.05)
        return CaptureEdits(crop: CGRect(x: 4, y: 2, width: 8, height: 8), annotations: [redaction])
    }

    private func assertPrivatePayloadAbsent(_ png: Data, fixture: MarkedPNGFixture, width: Int, height: Int,
        file: StaticString = #filePath, line: UInt = #line) throws -> CGImage {
        let chunks = try PNGChunks.read(png)
        // Preserve legitimate color/format metadata, including generated eXIf
        // color/dimension tags. Private source descriptions are checked below;
        // an eXIf chunk's mere existence is not a privacy violation.
        let allowed: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "tRNS", "iCCP", "sRGB", "cHRM", "gAMA",
            "sBIT", "pHYs", "bKGD", "hIST", "cICP", "mDCv", "cLLi", "eXIf"]
        XCTAssertTrue(chunks.allSatisfy { allowed.contains($0.type) },
            "Unexpected output payload chunks: \(chunks.map(\.type))", file: file, line: line)
        for forbidden in ["tEXt", "iTXt", "zTXt", "orIG", "acTL", "fcTL", "fdAT"] {
            XCTAssertFalse(chunks.contains { $0.type == forbidden }, "Leaked container chunk \(forbidden)", file: file, line: line)
        }
        for marker in MarkedPNGFixture.markers {
            XCTAssertNil(png.range(of: Data(marker.utf8)), "Private marker survived export: \(marker)", file: file, line: line)
        }
        XCTAssertNil(png.range(of: fixture.embeddedOriginalPNG), "A complete original PNG survived inside the export", file: file, line: line)
        XCTAssertNotEqual(png, fixture.markedPNG, file: file, line: line)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil), file: file, line: line)
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png", file: file, line: line)
        XCTAssertEqual(CGImageSourceGetCount(source), 1, file: file, line: line)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil), file: file, line: line)
        let propertyDescription = String(describing: properties)
        for marker in MarkedPNGFixture.markers {
            XCTAssertFalse(propertyDescription.contains(marker), "ImageIO still exposes source metadata", file: file, line: line)
        }
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let xmp = CGImageMetadataCreateXMPData(metadata, nil) {
            let text = String(decoding: xmp as Data, as: UTF8.self)
            for marker in MarkedPNGFixture.markers {
                XCTAssertFalse(text.contains(marker), "Serialized output metadata retains a private marker", file: file, line: line)
            }
        }
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), file: file, line: line)
        XCTAssertEqual(image.width, width, file: file, line: line)
        XCTAssertEqual(image.height, height, file: file, line: line)
        XCTAssertEqual(image.bitsPerComponent, 8, file: file, line: line)
        XCTAssertEqual(image.colorSpace?.model, .rgb, file: file, line: line)
        return image
    }

    private func assertOpaqueMask(_ image: CGImage, size: Int, covered: Range<Int>, exactOutsideMagenta: Bool,
        file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(image.width, size, file: file, line: line)
        XCTAssertEqual(image.height, size, file: file, line: line)
        let pixels = try rgba(image)
        guard image.width == size && image.height == size else { return }
        for y in 0..<size { for x in 0..<size {
            let offset = (y * size + x) * 4
            let pixel = Array(pixels[offset..<offset + 4])
            if covered.contains(x) && covered.contains(y) {
                XCTAssertEqual(pixel, [0, 0, 0, 255], "Redaction pixel \(x),\(y) is not opaque black", file: file, line: line)
            } else {
                XCTAssertEqual(pixel[3], 255, file: file, line: line)
                if exactOutsideMagenta { XCTAssertEqual(pixel, [255, 0, 255, 255], file: file, line: line) }
                else { XCTAssertNotEqual(pixel, [0, 0, 0, 255], "Redaction expanded outside its literal mask", file: file, line: line) }
            }
        } }
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        // The literal central masks are vertically symmetric; this test does
        // not characterize Quartz row orientation or general annotation placement.
        return Array(UnsafeBufferPointer(start: bytes, count: image.width * image.height * 4))
    }
}

@MainActor
private final class PrivacyClipboardSink: CaptureClipboard {
    var png: Data?
    func copyPNGData(_ data: Data) -> Bool { png = data; return true }
    func copyText(_ text: String) -> Bool { XCTFail("Image export must not publish text"); return false }
}

private struct MarkedPNGFixture {
    static let textMarker = "SWIFTSHOT_TEXT_SECRET_4827"
    static let xmpMarker = "SWIFTSHOT_XMP_SECRET_6158"
    static let exifMarker = "SWIFTSHOT_EXIF_SECRET_8291"
    static let originalMarker = "SWIFTSHOT_ORIGINAL_SECRET_7392"
    static let markers = [textMarker, xmpMarker, exifMarker, originalMarker]
    let image: CGImage
    let markedPNG: Data
    let embeddedOriginalPNG: Data

    static func make() throws -> Self {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 12, bitsPerComponent: 8,
            bytesPerRow: 64, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: [1, 0, 1, 1])))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        let sourceBytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertTrue((0..<192).allSatisfy { pixel in
            let offset = pixel * 4
            return Array(UnsafeBufferPointer(start: sourceBytes + offset, count: 4)) == [255, 0, 255, 255]
        }, "Source fixture must contain literal sRGB magenta before encoding or product calls")
        let bitmap = try XCTUnwrap(context.makeImage())
        let cleanData = NSMutableData()
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithData(cleanData, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, bitmap, nil)
        XCTAssertTrue(CGImageDestinationFinalize(encoder), "Fixture PNG must encode before any product call")
        let cleanChunks = try PNGChunks.read(cleanData as Data)
        // ImageIO's independently generated chunk CRCs above and this standard
        // literal anchor prevent a mutually wrong writer/parser from validating itself.
        XCTAssertEqual(PNGChunks.crc(Data("IEND".utf8)), 0xAE426082)
        let text = Data("Comment\0\(textMarker)".utf8)
        let originalText = Data("Comment\0\(originalMarker)".utf8)
        let xmpXML = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title><rdf:Alt><rdf:li xml:lang="x-default">\(xmpMarker)</rdf:li></rdf:Alt></dc:title></rdf:Description></rdf:RDF></x:xmpmeta>
        """
        // PNG iTXt: keyword NUL, uncompressed flag/method, empty language and
        // translated keyword; the remaining bytes are the UTF-8 XMP packet.
        let xmpHeader = Data("XML:com.adobe.xmp".utf8) + Data([0, 0, 0, 0, 0])
        let xmp = xmpHeader + Data(xmpXML.utf8)
        // Little-endian TIFF: IFD at8, one ASCII ImageDescription tag (0x010E),
        // count27, data offset26, no next IFD. Payload is marker+NUL, not Exif\0\0.
        let tiffHeader = Data([0x49, 0x49, 0x2A, 0, 8, 0, 0, 0, 1, 0,
            0x0E, 1, 2, 0, 27, 0, 0, 0, 26, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(exifMarker.utf8.count + 1, 27)
        let exif = tiffHeader + Data(exifMarker.utf8) + Data([0])
        let original = PNGChunks.inserting([.init(type: "tEXt", payload: originalText)], into: cleanChunks)
        let marked = PNGChunks.inserting([.init(type: "tEXt", payload: text), .init(type: "iTXt", payload: xmp),
            .init(type: "eXIf", payload: exif), .init(type: "orIG", payload: original)], into: cleanChunks)
        let chunks = try PNGChunks.read(marked)
        for (type, expected) in [("tEXt", text), ("iTXt", xmp), ("eXIf", exif), ("orIG", original)] {
            let matches = chunks.filter { $0.type == type }
            XCTAssertEqual(matches.count, 1, "Fixture must contain the actual marked \(type) chunk")
            XCTAssertEqual(matches.first?.payload, expected)
        }
        XCTAssertEqual(exif.count, 53)
        XCTAssertEqual(Array(exif.prefix(8)), [0x49, 0x49, 0x2A, 0, 8, 0, 0, 0])
        XCTAssertEqual(Data(exif.dropFirst(26)), Data(exifMarker.utf8) + Data([0]))
        let originalChunks = try PNGChunks.read(original)
        XCTAssertEqual(originalChunks.filter { $0.type == "tEXt" }.first?.payload, originalText)
        let embeddedSource = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(embeddedSource), 1)
        let embeddedImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(embeddedSource, 0, nil))
        XCTAssertEqual(embeddedImage.width, 16)
        XCTAssertEqual(embeddedImage.height, 12)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(marked as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 16)
        XCTAssertEqual(decoded.height, 12)
        // Independent ImageIO metadata decoding must recognize the marked TIFF
        // and XMP, rather than merely finding arbitrary bytes in private chunks.
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil))
        XCTAssertTrue(String(describing: properties).contains(exifMarker), "Fixture TIFF ImageDescription must decode through ImageIO")
        let metadata = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        let packet = try XCTUnwrap(CGImageMetadataCreateXMPData(metadata, nil))
        XCTAssertTrue(String(decoding: packet as Data, as: UTF8.self).contains(xmpMarker), "Fixture XMP must decode through ImageIO")
        for marker in markers { XCTAssertNotNil(marked.range(of: Data(marker.utf8))) }
        return Self(image: decoded, markedPNG: marked, embeddedOriginalPNG: original)
    }
}

/// Small bounded PNG envelope reader, not a production parser. Checks CRCs,
/// one header/end, IDAT presence and exact EOF; trailing originals cannot hide.
private enum PNGChunks {
    struct Chunk { let type: String; let payload: Data }
    private static let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
    static func read(_ data: Data) throws -> [Chunk] {
        guard data.count >= 20, data.count <= 1_048_576, data.prefix(8) == signature else { throw invalid() }
        var position = 8, result: [Chunk] = []
        while position < data.count {
            guard data.count - position >= 12 else { throw invalid() }
            let length = Int(word(data, at: position))
            guard length <= data.count - position - 12 else { throw invalid() }
            let typeBytes = Data(data[(position + 4)..<(position + 8)])
            guard typeBytes.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
                  let type = String(data: typeBytes, encoding: .ascii) else { throw invalid() }
            let payload = Data(data[(position + 8)..<(position + 8 + length)])
            guard crc(typeBytes + payload) == word(data, at: position + 8 + length) else { throw invalid() }
            result.append(Chunk(type: type, payload: payload))
            position += length + 12
            if type == "IEND" {
                guard length == 0, position == data.count, result.first?.type == "IHDR",
                      result.first?.payload.count == 13, result.filter({ $0.type == "IHDR" }).count == 1,
                      result.contains(where: { $0.type == "IDAT" }) else { throw invalid() }
                return result
            }
        }
        throw invalid()
    }
    static func inserting(_ metadata: [Chunk], into original: [Chunk]) -> Data {
        // Remove generated source metadata of the same kinds before inserting
        // one valid witness of each; retain legitimate image/color chunks.
        let kept = original.filter { !["tEXt", "iTXt", "zTXt", "eXIf", "orIG"].contains($0.type) }
        var output = signature
        for (index, chunk) in kept.enumerated() {
            output.append(encoded(chunk))
            if index == 0 { for value in metadata { output.append(encoded(value)) } }
        }
        return output
    }
    static func crc(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xFFFFFFFF
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xEDB88320 : value >> 1 }
        }
        return value ^ 0xFFFFFFFF
    }
    private static func encoded(_ chunk: Chunk) -> Data {
        let type = Data(chunk.type.utf8)
        var result = bigEndian(UInt32(chunk.payload.count))
        result.append(type); result.append(chunk.payload); result.append(bigEndian(crc(type + chunk.payload)))
        return result
    }
    private static func word(_ data: Data, at index: Int) -> UInt32 {
        data[index..<index + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    private static func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
    }
    private static func invalid() -> NSError { NSError(domain: "SyntheticPNGEnvelope", code: 1) }
}
