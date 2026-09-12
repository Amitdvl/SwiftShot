import CoreGraphics
import Foundation

struct ScrollCaptureRegion: Sendable {
    let displayID: UInt32
    /// Global AppKit display frame, bottom-left origin.
    let displayFrame: CGRect
    /// Selected display-local points, top-left origin.
    let rect: CGRect
}

struct ScrollCaptureLimits: Sendable {
    // The output and memory caps remain the real safety bounds. A 40-frame cap
    // truncates long documents before either of those limits is meaningful.
    var maximumFrames = 120
    var maximumOutputPixels = 64_000_000
    var maximumMemoryBytes = 384 * 1024 * 1024
}

struct ScrollCaptureFrame: @unchecked Sendable {
    let image: CGImage
}

struct ScrollCaptureResult: @unchecked Sendable {
    let image: CGImage
    /// The requested manual extent stitched without warnings. This does not
    /// assert that the entire page was captured or its bottom was established.
    let isComplete: Bool
    let warnings: [String]
}

enum ScrollCaptureIssue: String, Error, Sendable, LocalizedError {
    case insufficientOverlap, ambiguousContent, dynamicContent, dimensionsChanged, memoryLimit, frameLimit, outputLimit, noFrames

    var errorDescription: String? {
        switch self {
        case .insufficientOverlap: "The frames do not overlap enough. The uncertain frame was not added."
        case .ambiguousContent: "Repeated or blank content makes the overlap ambiguous. The uncertain frame was not added."
        case .dynamicContent: "Content changed while capturing. Stop animations or live updates and try again; the uncertain frame was not added."
        case .dimensionsChanged: "The capture dimensions changed. The uncertain frame was not added."
        case .memoryLimit: "The scrolling capture reached its safe memory limit. The result is incomplete."
        case .frameLimit: "The scrolling capture reached its frame limit. The result is incomplete."
        case .outputLimit: "The scrolling capture reached its output size limit. The result is incomplete."
        case .noFrames: "No scrolling capture frames are available."
        }
    }
}

struct ScrollAppendReport: Sendable {
    enum Disposition: Sendable, Equatable { case firstFrame, appended, unchanged, rejected }
    let disposition: Disposition
    var addedRows = 0
    var stickyHeaderRows = 0
    var stickyFooterRows = 0
    /// The first unchanged frame after verified movement is a lightweight end
    /// check, not a finished result. The coordinator follows it with one small
    /// scroll request before it declares the document complete.
    var isEndCheck = false
    var issue: ScrollCaptureIssue?
}

struct ScrollCaptureStatistics: Sendable {
    var frameCount = 0
    var outputWidth = 0
    var outputHeight = 0
    var retainedBytes = 0
}
