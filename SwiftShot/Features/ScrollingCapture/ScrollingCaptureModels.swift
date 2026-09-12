import CoreGraphics
import Foundation

/// One immutable, display-local viewport sample. Pixel rows are interpreted from top to bottom.
struct ScrollingCaptureFrame: @unchecked Sendable {
    let image: CGImage
    let pointPixelScale: CGFloat

    init(image: CGImage, pointPixelScale: CGFloat) {
        self.image = image
        self.pointPixelScale = pointPixelScale
    }
}

struct ScrollingStitchLimits: Equatable, Sendable {
    var maximumFramePixels: Int
    var maximumOutputPixels: Int
    var maximumRetainedBytes: Int
    var maximumAcceptedFrames: Int
    var minimumOverlapRows: Int

    init(maximumFramePixels: Int = 64_000_000,
         maximumOutputPixels: Int = 128_000_000,
         maximumRetainedBytes: Int = 512 * 1024 * 1024,
         maximumAcceptedFrames: Int = 1_000,
         minimumOverlapRows: Int = 2) {
        self.maximumFramePixels = maximumFramePixels
        self.maximumOutputPixels = maximumOutputPixels
        self.maximumRetainedBytes = maximumRetainedBytes
        self.maximumAcceptedFrames = maximumAcceptedFrames
        self.minimumOverlapRows = minimumOverlapRows
    }
}

enum ScrollingFrameRejection: Equatable, Sendable {
    case insufficientTexture
    case insufficientOverlap
    case ambiguousOverlap
    case reverseMotion
    case stickyRegionChanged
}

enum ScrollingIngestDisposition: Equatable, Sendable {
    case firstFrame
    case appended(rows: Int)
    case unchanged
    case rejected(ScrollingFrameRejection)
}

struct ScrollingStitchProgress: Equatable, Sendable {
    let acceptedFrames: Int
    let outputWidth: Int
    let outputHeight: Int
    let retainedBytes: Int
}

struct ScrollingIngestResult: Equatable, Sendable {
    let disposition: ScrollingIngestDisposition
    let progress: ScrollingStitchProgress
}

struct ScrollingStitchArtifact: @unchecked Sendable {
    let image: CGImage
    let acceptedFrames: Int
    let appendedRows: Int
}

enum ScrollingStitchError: Error, Equatable, Sendable {
    case invalidFrame
    case noFrames
    case cancelled
    case dimensionMismatch(expectedWidth: Int, expectedHeight: Int, actualWidth: Int, actualHeight: Int)
    case scaleMismatch(expected: CGFloat, actual: CGFloat)
    case framePixelLimitExceeded(limit: Int, actual: Int)
    case outputPixelLimitExceeded(limit: Int, actual: Int)
    case memoryLimitExceeded(limit: Int, required: Int)
    case acceptedFrameLimitExceeded(limit: Int)
}
