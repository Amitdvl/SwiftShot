import XCTest
@testable import SwiftShot

@MainActor
final class OverlayInteractionTests: XCTestCase {
    func testActiveRedactionGestureCannotExportUntilItsEditIsCommitted() throws {
        var copies: [CaptureEdits] = []
        var saves: [CaptureEdits] = []
        let session = makeSession(onCopy: { copies.append($0.edits) }, onSave: { saves.append($0.edits) })
        let image = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let document = CaptureDocument(image: image)
        session.document = document
        session.annotationTool = .redact
        // Canvas owns the visible draft; the document must not be exported until
        // dragEnded installs that draft as a real edit.
        session.isDragging = true
        XCTAssertTrue(session.handleKey(code: 8, characters: "c", modifiers: .command, isTextEditing: false, isKeyUp: false))
        XCTAssertTrue(session.handleKey(code: 1, characters: "s", modifiers: .command, isTextEditing: false, isKeyUp: false))
        XCTAssertTrue(copies.isEmpty, "Copy must not export the unredacted document beneath a visible draft")
        XCTAssertTrue(saves.isEmpty, "Save must not export the unredacted document beneath a visible draft")

        let redaction = CaptureAnnotation(kind: .redact, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 40, y: 40))
        document.change { $0.annotations.append(redaction) }
        session.isDragging = false
        XCTAssertTrue(session.handleKey(code: 8, characters: "c", modifiers: .command, isTextEditing: false, isKeyUp: false))
        XCTAssertTrue(session.handleKey(code: 1, characters: "s", modifiers: .command, isTextEditing: false, isKeyUp: false))
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(saves.count, 1)
        XCTAssertEqual(copies.last?.annotations, [redaction])
        XCTAssertEqual(saves.last?.annotations, [redaction])
    }

    func testCropModeNudgeCannotMovePreviouslySelectedRedaction() throws {
        let session = makeSession()
        let image = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let redaction = CaptureAnnotation(kind: .redact, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 40, y: 40))
        let document = CaptureDocument(image: image, edits: CaptureEdits(
            crop: CGRect(x: 10, y: 10, width: 60, height: 60), annotations: [redaction]))
        session.document = document
        session.selectedAnnotationID = redaction.id
        session.cropMode = true

        XCTAssertTrue(session.handleKey(code: 124, characters: nil, modifiers: .shift, isTextEditing: false, isKeyUp: false))

        XCTAssertEqual(document.edits.crop, CGRect(x: 20, y: 10, width: 60, height: 60))
        XCTAssertEqual(document.edits.annotations, [redaction], "Crop nudging must not uncover redacted pixels")
        document.undo()
        XCTAssertEqual(document.edits.crop, CGRect(x: 10, y: 10, width: 60, height: 60))
        XCTAssertEqual(document.edits.annotations, [redaction])
    }

    func testTextResponderRetainsAllNativeKeys() {
        let session = makeSession()
        for key: UInt16 in [0, 8, 49, 51, 53, 123] {
            XCTAssertFalse(session.handleKey(code: key, characters: "a", modifiers: [], isTextEditing: true, isKeyUp: false))
        }
        XCTAssertNil(session.annotationTool)
    }

    func testToolKeysAndSpaceSwitchModeWithoutDocument() {
        let session = makeSession()
        var chosen: CaptureMode?
        session.actions.switchMode = { chosen = $0 }
        XCTAssertTrue(session.handleKey(code: 49, characters: " ", modifiers: [], isTextEditing: false, isKeyUp: false))
        XCTAssertEqual(chosen, .window)
        XCTAssertTrue(session.handleKey(code: 0, characters: "a", modifiers: [], isTextEditing: false, isKeyUp: false))
        XCTAssertEqual(session.annotationTool, .arrow)
    }

    func testPrecisionNudgeAndDeleteAreUndoable() throws {
        let session = makeSession()
        let image = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let document = CaptureDocument(image: image)
        let annotation = CaptureAnnotation(kind: .rectangle, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 40, y: 40))
        document.change { $0.annotations.append(annotation) }
        session.document = document
        session.selectedAnnotationID = annotation.id
        XCTAssertTrue(session.handleKey(code: 124, characters: nil, modifiers: .shift, isTextEditing: false, isKeyUp: false))
        XCTAssertEqual(document.edits.annotations[0].start.x, 30)
        XCTAssertTrue(session.handleKey(code: 51, characters: nil, modifiers: [], isTextEditing: false, isKeyUp: false))
        XCTAssertTrue(document.edits.annotations.isEmpty)
        document.undo()
        XCTAssertEqual(document.edits.annotations[0].start.x, 30)
    }

    func testOversizedAnnotationMovementPreservesViewportOverlapWithoutJumping() {
        let moved = OverlayGeometry.moved(CGRect(x: -50, y: -30, width: 300, height: 200),
            by: CGSize(width: 1, height: 1), in: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(moved.origin, CGPoint(x: -49, y: -29))
    }

    private func makeSession(onCopy: @escaping (CaptureDocument) -> Void = { _ in },
                             onSave: @escaping (CaptureDocument) -> Void = { _ in }) -> OverlaySession {
        OverlaySession(mode: .region, style: CaptureStyle(), library: BackgroundLibrary(), onDocument: { _ in },
            onCopy: onCopy, onSave: onSave, onOCR: { _ in }, onCancel: {})
    }
}
