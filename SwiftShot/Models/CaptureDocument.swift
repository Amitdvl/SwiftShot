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
    enum Kind: String, Codable, CaseIterable, Sendable {
        case arrow, rectangle, text, redact, highlighter, numberedStep, spotlight
    }
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

    func translated(by delta: CGSize) -> Self {
        guard delta.width.isFinite, delta.height.isFinite else { return self }
        var copy = self
        copy.start = CGPoint(x: start.x + delta.width, y: start.y + delta.height)
        copy.end = CGPoint(x: end.x + delta.width, y: end.y + delta.height)
        return copy
    }

    /// Rectangular/arrow handles preserve the original drag direction. Text and
    /// step handles resize the font uniformly, keeping their native pixel model.
    func resized(to proposedBounds: CGRect) -> Self {
        let target = proposedBounds.standardized
        guard [target.minX, target.minY, target.width, target.height].allSatisfy(\.isFinite),
              target.width >= 1, target.height >= 1 else { return self }
        var copy = self
        if kind == .text || kind == .numberedStep {
            let previous = AnnotationGeometry.bounds(for: self)
            let scale = min(target.width / max(1, previous.width), target.height / max(1, previous.height))
            copy.fontSize = min(4096, max(1, fontSize * scale))
            copy.start = kind == .text ? target.origin : CGPoint(x: target.midX, y: target.midY)
            copy.end = copy.start
        } else {
            copy.start = CGPoint(x: start.x <= end.x ? target.minX : target.maxX,
                                 y: start.y <= end.y ? target.minY : target.maxY)
            copy.end = CGPoint(x: start.x <= end.x ? target.maxX : target.minX,
                               y: start.y <= end.y ? target.maxY : target.minY)
        }
        return copy
    }
}

struct CaptureEdits: Codable, Equatable, Sendable {
    var crop: CGRect
    var annotations: [CaptureAnnotation] = []
    var style = CaptureStyle()
}

/// CGImage is immutable; ownership crosses rendering tasks without mutation.
enum RenderOutput: Equatable, Sendable {
    case native
    case smallerShare(maxPixelDimension: Int)
}

struct RenderRequest: @unchecked Sendable {
    let image: CGImage
    let edits: CaptureEdits
    let backgroundURL: URL?
    var documentID: UUID? = nil
    var revision: Int = 0
    var backgroundVersion: Int = 0
    var output: RenderOutput = .native
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
    var ownerPID: Int32? = nil
}

struct FrozenScreen: @unchecked Sendable, Identifiable {
    let id: UInt32
    /// Global AppKit screen frame, bottom-left origin.
    let frame: CGRect
    let image: CGImage
    let windows: [FrozenWindow]
    /// Live window selection has no frozen desktop pixels behind its overlay.
    var isLive: Bool = false

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
    // Session classification is attached to the owned document, never a growing
    // process-wide ID registry or a mutable global preference.
    var isPrivate = false
    var isQuickCopy = false
    var workflow: CaptureWorkflow = .region
    var sourceRegion: CaptureRegionReference?
    var sourceRegionIsLocal = false
    @ObservationIgnored var performanceRunID: UUID?
    var isDiscarded = false

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

    func updateAnnotation(id: UUID, _ update: (inout CaptureAnnotation) -> Void) {
        change { edits in
            guard let index = edits.annotations.firstIndex(where: { $0.id == id }) else { return }
            update(&edits.annotations[index])
        }
    }

    func removeAnnotation(id: UUID) {
        change { $0.annotations.removeAll { $0.id == id } }
    }

    func request(backgroundURL: URL?, output: RenderOutput = .native, backgroundVersion: Int = 0) -> RenderRequest {
        RenderRequest(image: image, edits: edits, backgroundURL: backgroundURL,
                      documentID: id, revision: revision, backgroundVersion: backgroundVersion, output: output)
    }
}
