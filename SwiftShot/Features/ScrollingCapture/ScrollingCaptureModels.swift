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

/// The verified cumulative extent shown by the passive capture spotlight.
/// It contains measurement only; accepted pixels stay inside the stitch engine
/// until the user finishes.
struct ScrollingCaptureExtent: Sendable, Equatable {
    let acceptedFrames: Int
    let outputWidth: Int
    let outputHeight: Int
    let viewportHeight: Int

    var screenCount: Double {
        guard viewportHeight > 0 else { return 0 }
        return Double(outputHeight) / Double(viewportHeight)
    }

    var extentLabel: String {
        let count = (screenCount * 10).rounded() / 10
        let noun = abs(count - 1) < 0.05 ? "screen" : "screens"
        return String(format: "%.1f %@ · %@ px", locale: Locale(identifier: "en_US_POSIX"),
                      count, noun, Self.grouped(outputHeight))
    }

    var dimensionsLabel: String {
        "\(Self.grouped(outputWidth)) × \(Self.grouped(outputHeight)) px"
    }

    private static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSize = 3
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: max(0, value))) ?? String(max(0, value))
    }
}

struct ScrollingIngestResult: Equatable, Sendable {
    let disposition: ScrollingIngestDisposition
    let progress: ScrollingStitchProgress
    let extent: ScrollingCaptureExtent?
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
