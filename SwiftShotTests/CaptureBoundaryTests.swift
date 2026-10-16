import AppKit
import ImageIO
import SwiftUI
import XCTest
@testable import SwiftShot

/// Editor chrome is presentation state. Rendering that chrome, changing tools,
/// and opening inspectors must never change the native image or exported crop.
@MainActor
final class CaptureBoundaryTests: XCTestCase {
    func testToolboxPresentationAndToolsCannotChangeRawExportPixels() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftShot-CaptureBoundary-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BackgroundLibrary(rootURL: root.appendingPathComponent("library"),
            bundleURL: root.appendingPathComponent("empty-backgrounds"))
        XCTAssertNil(library.errorMessage)
        let renderer = SwiftShot.ImageRenderer()
        let crop = CGRect(x: 8, y: 6, width: 52, height: 34)

        // Light/dark/busy/transparent image edges all belong to the captured
        // image. None may be replaced by the editor's contrasting boundary.
        for content in 0..<4 {
            let image = try sourceImage(content: content)
            let document = CaptureDocument(image: image, edits: CaptureEdits(crop: crop))
            var copies: [RenderRequest] = []
            var saves: [RenderRequest] = []
            let session = OverlaySession(mode: content.isMultiple(of: 2) ? .region : .window,
                style: CaptureStyle(), library: library, onDocument: { _ in },
                onCopy: { copies.append($0.request(backgroundURL: nil)) },
                onSave: { saves.append($0.request(backgroundURL: nil)) },
                onOCR: { _ in }, onCancel: {})
            session.document = document
            session.activeScreenID = 2026
            session.imagePlacement = CGRect(x: 0, y: 0, width: 720, height: 480)
            let screen = FrozenScreen(id: 2026,
                frame: CGRect(x: -800, y: 0, width: 800, height: 600), image: image, windows: [])
            let originalEdits = document.edits
            let originalPixels = try rgba(image)
            let originalRevision = document.revision
            let states: [(OverlaySession.Popover?, CaptureAnnotation.Kind?, Bool)] = [
                (nil, nil, false), (.annotations, .arrow, false),
                (.backgrounds, nil, false), (.more, .redact, false),
                (.annotations, .rectangle, false), (nil, nil, true),
                (.annotations, .text, false), (nil, nil, false)
            ]
            for (panel, tool, cropMode) in states {
                session.activePopover = panel
                session.annotationTool = tool
                session.cropMode = cropMode
                let preview = SwiftUI.ImageRenderer(content: CaptureOverlayView(screen: screen, session: session))
                preview.scale = 1
                let renderedPreview = try XCTUnwrap(preview.cgImage,
                    "The actual SwiftUI editor must render before output isolation is checked")
                XCTAssertEqual(renderedPreview.width, 800)
                XCTAssertEqual(renderedPreview.height, 600)
                XCTAssertEqual(document.edits, originalEdits,
                    "Showing editor controls must not commit an edit")
                XCTAssertEqual(document.revision, originalRevision)
                XCTAssertTrue(document.image === image)
                XCTAssertEqual(try rgba(document.image), originalPixels)
                XCTAssertFalse(document.canUndo, "Presentation changes must not pollute undo history")

                XCTAssertTrue(session.handleKey(code: 8, characters: "c", modifiers: .command,
                    isTextEditing: false, isKeyUp: false))
                XCTAssertTrue(session.handleKey(code: 1, characters: "s", modifiers: .command,
                    isTextEditing: false, isKeyUp: false))
                let copy = try XCTUnwrap(copies.last)
                let save = try XCTUnwrap(saves.last)
                for request in [copy, save] {
                    let output = try await renderer.render(request)
                    let decoded = try decode(output.png)
                    XCTAssertEqual(decoded.width, 52)
                    XCTAssertEqual(decoded.height, 34)
                    let pixels = try rgba(decoded)
                    for y in 0..<34 {
                        for x in 0..<52 {
                            let offset = ((y + 6) * 72 + x + 8) * 4
                            let expected = Array(originalPixels[offset..<(offset + 4)])
                            let actual = Array(pixels[(y * 52 + x) * 4..<(y * 52 + x + 1) * 4])
                            XCTAssertEqual(actual, expected,
                                "Editor chrome leaked into content=\(content), pixel=(\(x),\(y))")
                        }
                    }
                }
            }
            XCTAssertEqual(copies.count, states.count)
            XCTAssertEqual(saves.count, states.count)
        }
    }

    func testHostedOutputBoundaryStaysVisibleAndStationaryWhenToolboxOpens() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftShot-HostedBoundary-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try sourceImage(content: 0)
        let library = BackgroundLibrary(rootURL: root.appendingPathComponent("library"),
            bundleURL: root.appendingPathComponent("empty-backgrounds"))
        let session = OverlaySession(mode: .region, style: CaptureStyle(), library: library,
            onDocument: { _ in }, onCopy: { _ in }, onSave: { _ in }, onOCR: { _ in }, onCancel: {})
        session.document = CaptureDocument(image: image)
        session.activeScreenID = 2026
        session.imagePlacement = CGRect(x: 0, y: 0, width: 720, height: 480)
        let screen = FrozenScreen(id: 2026, frame: CGRect(x: 0, y: 0, width: 800, height: 480),
            image: image, windows: [])
        let recorder = BoundaryFrameRecorder()
        let host = NSHostingView(rootView: CaptureOverlayView(screen: screen, session: session,
            controlFrameObserver: { recorder.frames = $0 }))
        host.sizingOptions = []
        host.frame = screen.frame
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 800, height: 480),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let initial = recorder.frames["Output Bounds"]?.first
        session.activePopover = .annotations
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let attachment = XCTAttachment(image: NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: .zero))
        attachment.name = "Compact display with toolbox open"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let evidence = ProcessInfo.processInfo.environment["SWIFTSHOT_BOUNDARY_EVIDENCE"] {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: evidence).appendingPathComponent("hosted-toolbox.png"))
        }
        let output = try XCTUnwrap(recorder.frames["Output Bounds"]?.first,
            "The actual hosted editor must expose a persistent output-boundary view, including while editing")
        XCTAssertEqual(initial, output, "Opening the toolbox must not shift or scale the export area")
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 800, height: 480).contains(output))
        XCTAssertGreaterThan(output.width, 1)
        XCTAssertGreaterThan(output.height, 1)
        for label in ["Copy", "Redact Screenshot", "Rectangle", "Arrow"] {
            let control = try XCTUnwrap(recorder.frames[label]?.first,
                "Actual control geometry must exist for \(label)")
            XCTAssertTrue(output.intersection(control).isEmpty,
                "Toolbox control \(label) obscures the exported area on a compact display")
        }

        let document = try XCTUnwrap(session.document)
        let layout = CaptureEditorLayout(screen: CGSize(width: 800, height: 480), topInset: 14)
        document.change { $0.crop = CGRect(x: 8, y: 6, width: 52, height: 34) }
        try await Task.sleep(for: .milliseconds(150))
        assertFrame(try XCTUnwrap(recorder.frames["Output Bounds"]?.first),
            matches: layout.fittedCanvas(size: CGSize(width: 520, height: 340)))
        document.change {
            $0.annotations = [CaptureAnnotation(kind: .rectangle, start: CGPoint(x: 20, y: 20),
                end: CGPoint(x: 35, y: 28))]
        }
        session.selectedAnnotationID = document.edits.annotations.first?.id
        session.annotationTool = nil
        try await Task.sleep(for: .milliseconds(150))
        let cropped = try XCTUnwrap(recorder.frames["Output Bounds"]?.first)
        document.change { $0.style = CaptureStyle(backgroundID: "preview-only", padding: 4, cornerRadius: 2, shadow: 1) }
        try await Task.sleep(for: .milliseconds(150))
        let styled = try XCTUnwrap(recorder.frames["Output Bounds"]?.first)
        assertFrame(styled, matches: layout.fittedCanvas(size: CGSize(width: 600, height: 420)))
        session.cropMode = true
        try await Task.sleep(for: .milliseconds(150))
        let fullSource = layout.fittedCanvas(size: CGSize(width: 720, height: 480))
        let cropBoundary = try XCTUnwrap(recorder.frames["Output Bounds"]?.first)
        XCTAssertEqual(cropBoundary.minX, fullSource.minX + fullSource.width * 8 / 72, accuracy: 0.001)
        XCTAssertEqual(cropBoundary.minY, fullSource.minY + fullSource.height * 6 / 48, accuracy: 0.001)
        XCTAssertEqual(cropBoundary.width, fullSource.width * 52 / 72, accuracy: 0.001)
        XCTAssertEqual(cropBoundary.height, fullSource.height * 34 / 48, accuracy: 0.001)
        XCTAssertEqual(document.edits.crop, CGRect(x: 8, y: 6, width: 52, height: 34),
            "Entering crop presentation must not change committed pixel geometry")
        session.cropMode = false
        document.undo()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(try XCTUnwrap(recorder.frames["Output Bounds"]?.first), cropped)
        document.redo()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(try XCTUnwrap(recorder.frames["Output Bounds"]?.first), styled,
            "Redo must restore the styled export bounds after crop inspection")
    }

    func testWorkspaceKeepsWholeOutputClearOfInspectorAndToolbarAtEveryAspectRatio() {
        for screen in [CGSize(width: 640, height: 480), CGSize(width: 800, height: 480),
                       CGSize(width: 1280, height: 800), CGSize(width: 1920, height: 1080)] {
            for topInset: CGFloat in [14, 40] {
                let layout = CaptureEditorLayout(screen: screen, topInset: topInset)
                let bounds = CGRect(origin: .zero, size: screen)
                XCTAssertTrue(bounds.contains(layout.workspace))
                XCTAssertTrue(bounds.contains(layout.inspector))
                XCTAssertTrue(bounds.contains(layout.toolbar))
                XCTAssertGreaterThanOrEqual(layout.workspace.minY, topInset)
                XCTAssertTrue(layout.workspace.intersection(layout.inspector).isEmpty)
                XCTAssertTrue(layout.workspace.intersection(layout.toolbar).isEmpty)
                XCTAssertTrue(layout.inspector.intersection(layout.toolbar).isEmpty)
                for size in [CGSize(width: 64, height: 48), CGSize(width: 3840, height: 2160),
                             CGSize(width: 300, height: 4000), CGSize(width: 4000, height: 300)] {
                    let output = layout.fittedCanvas(size: size)
                    XCTAssertTrue(layout.workspace.insetBy(dx: -0.001, dy: -0.001).contains(output),
                        "The entire export must be visible for screen=\(screen), output=\(size)")
                    XCTAssertGreaterThan(output.width, 0)
                    XCTAssertGreaterThan(output.height, 0)
                    XCTAssertLessThanOrEqual(output.width, size.width)
                    XCTAssertLessThanOrEqual(output.height, size.height)
                    XCTAssertEqual(output.width / output.height, size.width / size.height, accuracy: 0.0001,
                        "Fitting the editor must preserve the native output aspect ratio")
                    XCTAssertTrue(output.intersection(layout.inspector).isEmpty)
                    XCTAssertTrue(output.intersection(layout.toolbar).isEmpty)
                }
            }
        }
    }

    func testEveryOutputEdgeHasLightAndDarkContrastAcrossContentAndAppearance() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftShot-BoundaryContrast-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BackgroundLibrary(rootURL: root.appendingPathComponent("library"),
            bundleURL: root.appendingPathComponent("empty-backgrounds"))
        let screenSize = CGSize(width: 800, height: 600)
        let layout = CaptureEditorLayout(screen: screenSize, topInset: 14)
        let output = layout.fittedCanvas(size: CGSize(width: 720, height: 480))
        for content in 0..<4 {
            let image = try sourceImage(content: content)
            let screen = FrozenScreen(id: 2026, frame: CGRect(origin: .zero, size: screenSize),
                image: image, windows: [])
            let session = OverlaySession(mode: .region, style: CaptureStyle(), library: library,
                onDocument: { _ in }, onCopy: { _ in }, onSave: { _ in }, onOCR: { _ in }, onCancel: {})
            session.document = CaptureDocument(image: image)
            session.activeScreenID = screen.id
            session.imagePlacement = CGRect(x: 0, y: 0, width: 720, height: 480)
            for scheme in [ColorScheme.light, .dark] {
                for panel in [nil, OverlaySession.Popover.annotations] {
                    session.activePopover = panel
                    let renderer = SwiftUI.ImageRenderer(content: CaptureOverlayView(screen: screen, session: session)
                        .environment(\.colorScheme, scheme))
                    renderer.scale = 1
                    let preview = try XCTUnwrap(renderer.cgImage)
                    let pixels = try rgba(preview)
                    var edgeSamples = [[CGPoint]](repeating: [], count: 4)
                    for distance in 0..<6 {
                        let d = CGFloat(distance)
                        edgeSamples[0].append(CGPoint(x: output.midX, y: output.minY + d))
                        edgeSamples[1].append(CGPoint(x: output.midX, y: output.maxY - 1 - d))
                        edgeSamples[2].append(CGPoint(x: output.minX + d, y: output.midY))
                        edgeSamples[3].append(CGPoint(x: output.maxX - 1 - d, y: output.midY))
                    }
                    for (edge, samples) in edgeSamples.enumerated() {
                        let luminances = samples.map { point -> Int in
                            let offset = (Int(point.y) * preview.width + Int(point.x)) * 4
                            return (Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])) / 3
                        }
                        XCTAssertLessThan(try XCTUnwrap(luminances.min()), 90,
                            "Missing dark boundary on edge=\(edge), content=\(content), scheme=\(scheme)")
                        XCTAssertGreaterThan(try XCTUnwrap(luminances.max()), 210,
                            "Missing light boundary on edge=\(edge), content=\(content), scheme=\(scheme)")
                    }
                }
            }
        }
    }

    private func assertFrame(_ actual: CGRect, matches expected: CGRect,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.001, file: file, line: line)
    }

    private func sourceImage(content: Int) throws -> CGImage {
        var bytes = [UInt8]()
        for y in 0..<48 {
            for x in 0..<72 {
                switch content {
                case 0: bytes += [255, 255, 255, 255]
                case 1: bytes += [0, 0, 0, 255]
                case 2: bytes += [UInt8((x * 13) % 256), UInt8((y * 19) % 256), UInt8((x * 7 + y * 3) % 256), 255]
                default: bytes += [0, 0, 0, 0]
                }
            }
        }
        return try XCTUnwrap(CGImage(width: 72, height: 48, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 72 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
        return Array(UnsafeBufferPointer(start: data, count: image.width * image.height * 4))
    }

    private func decode(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
}

@MainActor
private final class BoundaryFrameRecorder {
    var frames: CaptureControlFrames = [:]
}
