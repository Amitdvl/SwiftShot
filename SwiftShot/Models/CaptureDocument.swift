import AppKit
import Observation

/// All edit geometry uses original-image pixels, with a top-left origin.
struct CaptureStyle: Codable, Equatable, Sendable {
    var backgroundID: String = ""
    var padding: Double = 64
    var cornerRadius: Double = 12
    var shadow: Double = 18
}

struct AnnotationColor: Codable, Equatable, Sendable {
    var red: Double = 1
    var green: Double = 0.27
    var blue: Double = 0.24
    var alpha: Double = 1
}

struct CaptureAnnotation: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case arrow, rectangle, text, redact }
    var id = UUID()
    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var text: String = ""
    var color = AnnotationColor()
    var lineWidth: Double = 6
    var fontSize: Double = 32

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}

struct CaptureEdits: Codable, Equatable, Sendable {
    var crop: CGRect
    var annotations: [CaptureAnnotation] = []
    var style = CaptureStyle()
}

/// CGImage is immutable; ownership crosses rendering tasks without mutation.
struct RenderRequest: @unchecked Sendable {
    let image: CGImage
    let edits: CaptureEdits
    let backgroundURL: URL?
}

struct RenderedCapture: @unchecked Sendable {
    let image: CGImage
    let png: Data
}

struct FrozenWindow: @unchecked Sendable {
    let id: UInt32
    let title: String
    /// Local display points, top-left origin; already clipped to this display.
    let frame: CGRect
    /// Window-specific pixels captured before the overlay; excludes occluding apps.
    var snapshot: CGImage? = nil
}

struct FrozenScreen: @unchecked Sendable, Identifiable {
    let id: UInt32
    /// Global AppKit screen frame, bottom-left origin.
    let frame: CGRect
    let image: CGImage
    let windows: [FrozenWindow]

    var scaleX: CGFloat { CGFloat(image.width) / frame.width }
    var scaleY: CGFloat { CGFloat(image.height) / frame.height }
}

@MainActor @Observable
final class CaptureDocument: Identifiable {
    let id: UUID
    let image: CGImage
    private(set) var edits: CaptureEdits
    private var undoStack: [CaptureEdits] = []
    private var redoStack: [CaptureEdits] = []
    var savedURL: URL?
    var revision = 0

    init(id: UUID = UUID(), image: CGImage, edits: CaptureEdits? = nil, style: CaptureStyle = CaptureStyle(), revision: Int = 0) {
        self.id = id
        self.image = image
        self.edits = edits ?? CaptureEdits(crop: CGRect(x: 0, y: 0, width: image.width, height: image.height), style: style)
        self.revision = revision
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func change(_ update: (inout CaptureEdits) -> Void) {
        var next = edits
        update(&next)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        next.crop = next.crop.integral.intersection(bounds)
        guard !next.crop.isNull, next.crop.width >= 2, next.crop.height >= 2, next != edits else { return }
        undoStack.append(edits)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        edits = next
        savedURL = nil
        revision += 1
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(edits)
        edits = previous
        savedURL = nil
        revision += 1
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(edits)
        edits = next
        savedURL = nil
        revision += 1
    }

    func request(backgroundURL: URL?) -> RenderRequest {
        RenderRequest(image: image, edits: edits, backgroundURL: backgroundURL)
    }
}
