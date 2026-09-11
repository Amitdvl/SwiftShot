import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
import SwiftUI
@testable import SwiftShot

private typealias ImageRenderer = SwiftShot.ImageRenderer

final class FloatingCaptureTests: XCTestCase {
    @MainActor func testFloatingPanelIsFramelessAndMovableByItsImageBackground() {
        let panel = FloatingCaptureController.makePanel(kind: .pin, image: source(),
            visible: CGRect(x: 0, y: 0, width: 1470, height: 956))
        defer { panel.close() }

        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertFalse(panel.styleMask.contains(.titled))
        XCTAssertTrue(panel.isMovableByWindowBackground)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.titleVisibility, .hidden)
    }

    @MainActor func testCopyFromRecentThumbnailKeepsOriginalRecentPresentation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftShotRecentHandoff-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "SwiftShotRecentHandoff.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let image = source(width: 80, height: 40)
        let renderer = RecentHandoffRenderer(image: image)
        let clipboard = RecentHandoffClipboard()
        let floating = RecentHandoffFloating()
        let app = AppState(defaults: defaults, recovery: RecoveryStore(root: root.appendingPathComponent("recovery")),
            backgrounds: BackgroundLibrary(rootURL: root.appendingPathComponent("backgrounds")), clipboard: clipboard,
            presentsUI: true, renderer: renderer, overlay: RecentHandoffPresenter(), diagnostics: nil,
            floatingCaptures: floating)
        app.appSettings.showRecentThumbnail = true
        let document = CaptureDocument(image: image)
        document.change { $0.annotations = [CaptureAnnotation(kind: .arrow, start: .zero, end: CGPoint(x: 20, y: 20))] }

        let copied = await app.copy(document)
        XCTAssertTrue(copied)
        XCTAssertEqual(floating.recentCount, 1)
        let copy = try XCTUnwrap(floating.onCopy)
        copy(CaptureDocument(image: image))
        for _ in 0..<100 where clipboard.copyCount < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(clipboard.copyCount, 2)
        XCTAssertEqual(floating.recentCount, 1,
            "Copying the existing thumbnail must not replace its editable source with a flattened recent panel")
        XCTAssertEqual(document.edits.annotations.count, 1)
        _ = await app.prepareToQuit()
        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor func testWidePinHostingCannotExpandPastItsInitialContentSize() async throws {
        let image = source(width: 1412, height: 312)
        let panel = FloatingCaptureController.makePanel(kind: .pin, image: image,
            visible: CGRect(x: 0, y: 0, width: 1470, height: 956))
        defer { panel.close() }
        let intendedSize = panel.contentLayoutRect.size
        XCTAssertLessThanOrEqual(intendedSize.width, 440,
            "Pins should stay compact enough to leave the desktop usable")
        XCTAssertLessThanOrEqual(intendedSize.height, 300)
        let hosting = try installTestContent(image: image, in: panel, isRecent: false)
        try await settleLayout(hosting)
        XCTAssertFalse(panel.isVisible, "This regression must never show a native window")
        XCTAssertLessThanOrEqual(panel.contentLayoutRect.width, intendedSize.width + 1,
            "Native image width overrode the requested pin window size")
        XCTAssertLessThanOrEqual(panel.contentLayoutRect.height, intendedSize.height + 1)
        XCTAssertLessThanOrEqual(hosting.fittingSize.width, intendedSize.width + 1,
            "The image imposed a native-pixel minimum that pushes Close offscreen")
        try assertImageAndCornerControlsFit(hosting)
    }

    @MainActor func testPortraitRecentHostingCannotPushCornerControlsOutsideInitialSize() async throws {
        let image = source(width: 312, height: 1412)
        let panel = FloatingCaptureController.makePanel(kind: .recent, image: image,
            visible: CGRect(x: 0, y: 0, width: 1470, height: 956))
        defer { panel.close() }
        let intendedSize = panel.contentLayoutRect.size
        let hosting = try installTestContent(image: image, in: panel, isRecent: true)
        try await settleLayout(hosting)
        XCTAssertFalse(panel.isVisible)
        XCTAssertLessThanOrEqual(panel.contentLayoutRect.width, intendedSize.width + 1)
        XCTAssertLessThanOrEqual(panel.contentLayoutRect.height, intendedSize.height + 1,
            "Native portrait height expanded the recent capture beyond its control layout")
        XCTAssertLessThanOrEqual(hosting.fittingSize.height, intendedSize.height + 1)
        try assertImageAndCornerControlsFit(hosting)
    }

    @MainActor func testPinCanResizeDownToControlMinimumWithoutChangingNativeImage() async throws {
        let image = source(width: 1412, height: 312)
        let panel = FloatingCaptureController.makePanel(kind: .pin, image: image,
            visible: CGRect(x: 0, y: 0, width: 1470, height: 956))
        defer { panel.close() }
        let hosting = try installTestContent(image: image, in: panel, isRecent: false)
        for size in [NSSize(width: 320, height: 180), NSSize(width: 220, height: 144)] {
            panel.setContentSize(size)
            try await settleLayout(hosting)
            XCTAssertLessThanOrEqual(panel.contentLayoutRect.width, size.width + 1)
            XCTAssertLessThanOrEqual(panel.contentLayoutRect.height, size.height + 1)
            XCTAssertLessThanOrEqual(hosting.fittingSize.width, size.width + 1)
            try assertImageAndCornerControlsFit(hosting)
        }
        let imageView = try XCTUnwrap(imageView(in: hosting))
        XCTAssertEqual(imageView.image?.size, NSSize(width: 1412, height: 312), "UI fitting must not resample export pixels")
        XCTAssertEqual(image.width, 1412)
        XCTAssertEqual(image.height, 312)
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor func testPinRequestedWhileEditorHidesRecentChromeBecomesVisible() async throws {
        let image = source(width: 80, height: 40)
        let controller = FloatingCaptureController(renderer: RecentHandoffRenderer(image: image))
        defer { controller.closeAll() }
        controller.setCaptureHidden(true)

        let document = CaptureDocument(image: image)
        try await controller.pin(document: document, backgroundURL: nil, onCopy: { _ in }, onEdit: { _ in }, onSave: { _ in })
        await Task.yield()

        XCTAssertEqual(controller.pinCount, 1)
        XCTAssertTrue(NSApp.windows.contains {
            guard let panel = $0 as? FloatingCapturePanel else { return false }
            return panel.title == "SwiftShot Pin" && panel.isVisible
        }, "An explicit Pin action must show the pin even while the editor hides recent chrome")

        controller.setCaptureHidden(true)
        XCTAssertTrue(NSApp.windows.contains {
            guard let panel = $0 as? FloatingCapturePanel else { return false }
            return panel.title == "SwiftShot Pin" && panel.isVisible
        }, "Capture hiding must leave user pins available as source content")
    }

    @MainActor private func installTestContent(image: CGImage, in panel: FloatingCapturePanel, isRecent: Bool) throws -> NSView {
        let payload = FloatingCapturePayload(image: image, renderer: ImageRenderer(cacheByteLimit: 0, cacheEntryLimit: 0))
        FloatingCaptureController.installContent(FloatingCaptureContent(image: image, payload: payload, isRecent: isRecent,
            onCopy: {}, onEdit: {}, onSave: {}, onPin: {}, onClose: {}), in: panel)
        return try XCTUnwrap(panel.contentView)
    }

    @MainActor private func settleLayout(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        view.layoutSubtreeIfNeeded()
    }

    @MainActor private func imageView(in view: NSView) -> NSImageView? {
        if let image = view as? NSImageView { return image }
        for child in view.subviews { if let image = imageView(in: child) { return image } }
        return nil
    }

    @MainActor private func assertImageAndCornerControlsFit(_ hosting: NSView, file: StaticString = #filePath, line: UInt = #line) throws {
        let image = try XCTUnwrap(imageView(in: hosting), file: file, line: line)
        let frame = image.convert(image.bounds, to: hosting)
        XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, -1, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, hosting.bounds.maxX + 1, file: file, line: line)
        // Corner controls overlay the image, so they must not impose an extra
        // row or push the image outside the native panel bounds.
        XCTAssertLessThanOrEqual(frame.maxY, hosting.bounds.maxY + 1, file: file, line: line)
        XCTAssertLessThanOrEqual(hosting.fittingSize.width, hosting.bounds.width + 1, file: file, line: line)
    }

    func testClosingUnloadedPayloadReleasesBitmapWhileProviderIsRetained() async throws {
        let tracked = try trackedPayload()
        XCTAssertFalse(tracked.probe.isReleased)
        await tracked.payload.close()
        withExtendedLifetime(tracked.provider) {
            XCTAssertTrue(tracked.probe.isReleased, "Closed item provider still owns its capture bitmap")
        }
    }

    func testClosingEncodedPayloadReleasesBitmapWhileProviderIsRetained() async throws {
        let tracked = try trackedPayload()
        let data = try await tracked.payload.pngData()
        XCTAssertFalse(data.isEmpty)
        XCTAssertFalse(tracked.probe.isReleased)
        await tracked.payload.close()
        withExtendedLifetime(tracked.provider) {
            XCTAssertTrue(tracked.probe.isReleased, "Drained PNG payload still owns its capture bitmap")
        }
    }

    private func trackedPayload() throws -> (payload: FloatingCapturePayload, provider: NSItemProvider, probe: BitmapReleaseProbe) {
        let probe = BitmapReleaseProbe()
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 4)
        bytes.initializeMemory(as: UInt8.self, repeating: 255, count: 16)
        let provider = try XCTUnwrap(CGDataProvider(dataInfo: Unmanaged.passRetained(probe).toOpaque(),
            data: bytes, size: 16, releaseData: { info, data, _ in
                UnsafeMutableRawPointer(mutating: data).deallocate()
                Unmanaged<BitmapReleaseProbe>.fromOpaque(info!).takeRetainedValue().markReleased()
            }))
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let payload = FloatingCapturePayload(image: image, renderer: ImageRenderer(cacheByteLimit: 0, cacheEntryLimit: 0))
        return (payload, payload.itemProvider(), probe)
    }

    private func source(width: Int = 80, height: Int = 40) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        XCTAssertEqual(Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: 4)), [255, 0, 0, 255])
        return context.makeImage()!
    }

    func testPinCapRefusesWithoutEvictingExistingPins() throws {
        var budget = FloatingCaptureBudget(maxPins: 2, maxPixels: 1000, maxBytes: 4000)
        let first = UUID(), second = UUID(), refused = UUID()
        try budget.reserve(id: first, kind: .pin, pixels: 200, bytes: 800)
        try budget.reserve(id: second, kind: .pin, pixels: 200, bytes: 800)
        XCTAssertThrowsError(try budget.reserve(id: refused, kind: .pin, pixels: 200, bytes: 800))
        XCTAssertEqual(budget.pinCount, 2)
        XCTAssertEqual(budget.retainedPixels, 400)
        budget.release(id: first)
        try budget.reserve(id: refused, kind: .pin, pixels: 200, bytes: 800)
        XCTAssertEqual(budget.pinCount, 2)
    }

    func testThumbnailAndPendingPinsSharePixelAndMemoryLimits() throws {
        var budget = FloatingCaptureBudget(maxPins: 8, maxPixels: 1000, maxBytes: 3000)
        let recent = UUID()
        try budget.reserve(id: recent, kind: .recent, pixels: 500, bytes: 2000)
        XCTAssertThrowsError(try budget.reserve(id: UUID(), kind: .pin, pixels: 100, bytes: 1500))
        XCTAssertThrowsError(try budget.reserve(id: UUID(), kind: .pin, pixels: 600, bytes: 500))
        XCTAssertEqual(budget.retainedPixels, 500)
        XCTAssertEqual(budget.retainedBytes, 2000)
        XCTAssertEqual(budget.pinCount, 0)
        budget.release(id: recent)
        XCTAssertEqual(budget.retainedBytes, 0)
    }

    func testInvalidReservationsAndDuplicateRecentDoNotCorruptAccounting() throws {
        var budget = FloatingCaptureBudget(maxPins: 2, maxPixels: 1000, maxBytes: 4000)
        let id = UUID()
        XCTAssertThrowsError(try budget.reserve(id: id, kind: .pin, pixels: -1, bytes: 500))
        try budget.reserve(id: id, kind: .recent, pixels: 100, bytes: 400)
        XCTAssertThrowsError(try budget.reserve(id: id, kind: .pin, pixels: 100, bytes: 400))
        XCTAssertThrowsError(try budget.reserve(id: UUID(), kind: .recent, pixels: 100, bytes: 400))
        budget.release(id: UUID())
        XCTAssertEqual(budget.retainedPixels, 100)
        XCTAssertEqual(budget.retainedBytes, 400)
    }

    @MainActor func testSnapshotFreezesEditsAndPreservesPrivateClassification() {
        let document = CaptureDocument(image: source())
        document.isPrivate = true
        document.isQuickCopy = true
        document.workflow = .quickCopy
        let snapshot = FloatingCaptureSnapshot(document: document, backgroundURL: nil)
        document.change { $0.crop = CGRect(x: 0, y: 0, width: 20, height: 20) }
        let frozen = snapshot.editableDocument()
        XCTAssertEqual(frozen.edits.crop, CGRect(x: 0, y: 0, width: 80, height: 40))
        XCTAssertTrue(frozen.isPrivate)
        XCTAssertTrue(frozen.isQuickCopy)
        XCTAssertEqual(frozen.workflow, .quickCopy)
        XCTAssertNotEqual(frozen.id, document.id)
        let flattened = snapshot.flattenedDocument(image: source())
        XCTAssertTrue(flattened.isPrivate)
        XCTAssertTrue(flattened.isQuickCopy)
        XCTAssertEqual(flattened.workflow, .quickCopy)
    }

    func testItemProviderIsLazyPNGOnlyAndContainsFlattenedRedaction() async throws {
        let renderer = ImageRenderer()
        let redaction = CaptureAnnotation(kind: .redact, start: .zero, end: CGPoint(x: 20, y: 20))
        let edited = try await renderer.renderImage(RenderRequest(image: source(),
            edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 80, height: 40), annotations: [redaction]), backgroundURL: nil))
        let payload = FloatingCapturePayload(image: edited, renderer: renderer)
        let provider = payload.itemProvider()
        XCTAssertEqual(provider.registeredTypeIdentifiers, [UTType.png.identifier])
        let before = await renderer.cacheStatistics
        XCTAssertEqual(before.encodes, 0)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: NSError(domain: "MissingPNG", code: 1)) }
            }
        }
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        let context = CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 320,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 80, height: 40))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: bytes + (10 * 80 + 10) * 4, count: 4)), [0, 0, 0, 255])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: bytes + (30 * 80 + 50) * 4, count: 4)), [255, 0, 0, 255])
        let after = await renderer.cacheStatistics
        XCTAssertEqual(after.encodes, 1)
    }

    func testClosedPayloadCannotRecreatePrivateExportData() async throws {
        let payload = FloatingCapturePayload(image: source(), renderer: ImageRenderer())
        await payload.close()
        do {
            _ = try await payload.pngData()
            XCTFail("Closed payload recreated export data")
        } catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
    }
}

@MainActor
private final class RecentHandoffFloating: FloatingCapturePresenting {
    var recentCount = 0
    var onCopy: ((CaptureDocument) -> Void)?

    func showRecent(document: CaptureDocument, backgroundURL: URL?, renderedImage: CGImage?, title: String,
                    onCopy: @escaping (CaptureDocument) -> Void, onEdit: @escaping (CaptureDocument) -> Void,
                    onSave: @escaping (CaptureDocument) -> Void, onPin: @escaping (CaptureDocument) -> Void) async throws {
        recentCount += 1
        self.onCopy = onCopy
    }
    func pin(document: CaptureDocument, backgroundURL: URL?, onCopy: @escaping (CaptureDocument) -> Void,
             onEdit: @escaping (CaptureDocument) -> Void, onSave: @escaping (CaptureDocument) -> Void) async throws {}
    func setCaptureHidden(_ hidden: Bool) {}
    func closeAll() {}
    func handleMemoryPressure() {}
}

private final class RecentHandoffRenderer: CaptureRendering, @unchecked Sendable {
    let image: CGImage
    init(image: CGImage) { self.image = image }
    func render(_ request: RenderRequest) async throws -> RenderedCapture { RenderedCapture(image: image, png: Data([137, 80, 78, 71])) }
    func renderImage(_ request: RenderRequest) async throws -> CGImage { image }
    func clearCache() async {}
}

@MainActor
private final class RecentHandoffClipboard: CaptureClipboard {
    var copyCount = 0
    func copyPNGData(_ data: Data) -> Bool { copyCount += 1; return true }
    func copyText(_ text: String) -> Bool { true }
}

@MainActor
private final class RecentHandoffPresenter: CapturePresenting {
    var activeDocument: CaptureDocument?
    func configure(actions: CaptureActions) {}
    func present(screens: [FrozenScreen], mode: CaptureMode, style: CaptureStyle, library: BackgroundLibrary,
                 onDocument: @escaping (CaptureDocument) -> Void, onCopy: @escaping (CaptureDocument) -> Void,
                 onSave: @escaping (CaptureDocument) -> Void, onOCR: @escaping (CaptureDocument) -> Void,
                 onCancel: @escaping () -> Void, onDiscard: @escaping (CaptureDocument) -> Void) {}
    func reopen(document: CaptureDocument, library: BackgroundLibrary, onCopy: @escaping (CaptureDocument) -> Void,
                onSave: @escaping (CaptureDocument) -> Void, onCancel: @escaping () -> Void,
                onDocument: @escaping (CaptureDocument) -> Void, onDiscard: @escaping (CaptureDocument) -> Void) {
        activeDocument = document
    }
    func dismiss() { activeDocument = nil }
    func showStatus(_ message: String, isError: Bool) {}
}

private final class BitmapReleaseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    var isReleased: Bool { lock.lock(); defer { lock.unlock() }; return released }
    func markReleased() { lock.lock(); released = true; lock.unlock() }
}
