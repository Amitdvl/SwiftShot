import CoreGraphics
import Foundation

/// Keeps independently owned image strips. Matching and flattening are actor-
/// isolated so neither pixel analysis nor output allocation blocks the UI.
actor ScrollStitcher {
    private struct Piece {
        let image: CGImage
        var height: Int
    }
    private let limits: ScrollCaptureLimits
    private var pieces: [Piece] = []
    private var previousPixels: ScrollCapturePixels?
    private var state = ScrollCaptureStatistics()
    private var incomingFrameBytes = 0
    private var outputColorSpace: CGColorSpace?

    init(limits: ScrollCaptureLimits = ScrollCaptureLimits()) { self.limits = limits }

    func append(_ frame: ScrollCaptureFrame) throws -> ScrollAppendReport {
        try Task.checkCancellation()
        let image = frame.image
        guard image.width > 0, image.height >= 48, image.width <= 16_384, image.height <= 16_384 else {
            return rejected(.dimensionsChanged)
        }
        let sourceBytes = image.bytesPerRow * image.height
        let pixelBytes = image.width * image.height * 4
        if let previousPixels {
            guard previousPixels.width == image.width, previousPixels.height == image.height else {
                return rejected(.dimensionsChanged)
            }
        }
        guard state.frameCount < limits.maximumFrames else { return rejected(.frameLimit) }
        guard image.width * image.height <= limits.maximumOutputPixels else { return rejected(.outputLimit) }
        // Normalization temporarily owns both a CGContext and immutable byte
        // copy. Count these alongside prior strips/pixels and a finishable canvas.
        let normalizationPeak = state.retainedBytes + sourceBytes + (previousPixels?.byteCount ?? 0) + pixelBytes * 2 +
            max(pixelBytes, state.outputWidth * state.outputHeight * 4)
        guard normalizationPeak <= limits.maximumMemoryBytes else { return rejected(.memoryLimit) }
        let pixels = try ScrollCapturePixels(image: image)
        guard let previous = previousPixels else {
            pieces = [Piece(image: image, height: image.height)]
            previousPixels = pixels
            incomingFrameBytes = sourceBytes
            outputColorSpace = image.colorSpace
            state = ScrollCaptureStatistics(frameCount: 1, outputWidth: image.width, outputHeight: image.height,
                retainedBytes: sourceBytes)
            return ScrollAppendReport(disposition: .firstFrame, addedRows: image.height)
        }
        let match = try ScrollOverlapMatcher.match(previous: previous, next: pixels)
        switch match {
        case .unchanged:
            return ScrollAppendReport(disposition: .unchanged)
        case .rejected(let issue):
            return rejected(issue)
        case .overlap(let offset, let header, let footer):
            let outputHeight = state.outputHeight + offset
            guard image.width * outputHeight <= limits.maximumOutputPixels else { return rejected(.outputLimit) }
            let stripHeight = offset + footer
            let stripBytes = image.width * stripHeight * 4
            let appendPeak = state.retainedBytes + sourceBytes + previous.byteCount + pixels.byteCount +
                stripBytes + image.width * outputHeight * 4
            // makeImage may copy the flattening context. Admit only states whose
            // retained strips + previous pixels + both output buffers fit.
            let finishPeak = state.retainedBytes + stripBytes + pixels.byteCount + image.width * outputHeight * 8
            guard max(appendPeak, finishPeak) <= limits.maximumMemoryBytes else { return rejected(.memoryLimit) }
            let startY = image.height - footer - offset
            guard startY >= header, let last = pieces.last, last.height > footer else {
                return rejected(.insufficientOverlap)
            }
            let strip = try Self.copyStrip(image, y: startY, height: stripHeight, colorSpace: outputColorSpace)
            try Task.checkCancellation()
            // Drop the previous fixed footer; keep newly exposed body and latest
            // footer. The original header remains exactly once.
            pieces[pieces.count - 1].height -= footer
            pieces.append(Piece(image: strip, height: stripHeight))
            previousPixels = pixels
            incomingFrameBytes = sourceBytes
            state.frameCount += 1
            state.outputHeight = outputHeight
            state.retainedBytes += stripBytes
            return ScrollAppendReport(disposition: .appended, addedRows: offset,
                stickyHeaderRows: header, stickyFooterRows: footer)
        }
    }

    func statistics() -> ScrollCaptureStatistics { state }

    func canAcquireAnotherFrame(stabilityPair: Bool = false) -> Bool {
        guard let previousPixels, state.frameCount < limits.maximumFrames else { return false }
        let nextOutputPixels = state.outputWidth * (state.outputHeight + previousPixels.height)
        // Reserve the worst permitted step and native acquisition's transient
        // buffers before the controller requests another screenshot.
        let candidateBuffers = stabilityPair ? 3 : 2
        let predicted = state.retainedBytes + previousPixels.byteCount * 3 +
            incomingFrameBytes * candidateBuffers + nextOutputPixels * 8
        return state.outputWidth * (state.outputHeight + 1) <= limits.maximumOutputPixels && predicted <= limits.maximumMemoryBytes
    }

    func framesAreStable(_ first: ScrollCaptureFrame, _ second: ScrollCaptureFrame) throws -> Bool {
        try Task.checkCancellation()
        guard first.image.width == second.image.width, first.image.height == second.image.height else { return false }
        let bytes = first.image.width * first.image.height * 4
        let peak = state.retainedBytes + (previousPixels?.byteCount ?? 0) +
            first.image.bytesPerRow * first.image.height + second.image.bytesPerRow * second.image.height + bytes * 3
        guard peak <= limits.maximumMemoryBytes else { throw ScrollCaptureIssue.memoryLimit }
        let a = try ScrollCapturePixels(image: first.image)
        let b = try ScrollCapturePixels(image: second.image)
        return try a.matchFraction(other: b, fromRow: 0, otherFromRow: 0, rowCount: a.height) == 1
    }

    func render() throws -> ScrollCaptureFrame {
        try Task.checkCancellation()
        guard !pieces.isEmpty else { throw ScrollCaptureIssue.noFrames }
        let outputBytes = state.outputWidth * state.outputHeight * 4
        guard state.retainedBytes + (previousPixels?.byteCount ?? 0) + outputBytes * 2 <= limits.maximumMemoryBytes else {
            throw ScrollCaptureIssue.memoryLimit
        }
        guard let context = CGContext(data: nil, width: state.outputWidth, height: state.outputHeight,
            bitsPerComponent: 8, bytesPerRow: state.outputWidth * 4,
            space: outputColorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScrollCaptureIssue.memoryLimit }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        var top = 0
        for piece in pieces {
            try Task.checkCancellation()
            guard let crop = piece.image.cropping(to: CGRect(x: 0, y: 0, width: state.outputWidth, height: piece.height)) else {
                throw ScrollCaptureIssue.dimensionsChanged
            }
            context.draw(crop, in: CGRect(x: 0, y: state.outputHeight - top - piece.height,
                width: state.outputWidth, height: piece.height))
            top += piece.height
        }
        guard top == state.outputHeight, let image = context.makeImage() else { throw ScrollCaptureIssue.memoryLimit }
        return ScrollCaptureFrame(image: image)
    }

    private func rejected(_ issue: ScrollCaptureIssue) -> ScrollAppendReport {
        ScrollAppendReport(disposition: .rejected, issue: issue)
    }

    private static func copyStrip(_ image: CGImage, y: Int, height: Int, colorSpace: CGColorSpace?) throws -> CGImage {
        guard let crop = image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height)),
              let context = CGContext(data: nil, width: image.width, height: height, bitsPerComponent: 8,
                  bytesPerRow: image.width * 4, space: colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScrollCaptureIssue.memoryLimit }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(crop, in: CGRect(x: 0, y: 0, width: image.width, height: height))
        guard let result = context.makeImage() else { throw ScrollCaptureIssue.memoryLimit }
        return result
    }
}
