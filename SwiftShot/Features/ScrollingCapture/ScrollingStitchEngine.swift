import CoreGraphics
import Foundation
import OSLog

/// Stateful pixel stitcher. Native capture objects and UI state never enter this actor.
actor ScrollingStitchEngine {
    private let logger = Logger(subsystem: "com.swiftshot.app", category: "ScrollingStitch")
    private struct PixelFrame: Sendable {
        let width: Int
        let height: Int
        let scale: CGFloat
        let rgba: [UInt8]
        let signatureColumns: Int
        let rowSignatures: [UInt8]

        var retainedBytes: Int { rgba.count + rowSignatures.count }
    }

    private struct StickyInsets: Equatable, Sendable {
        let top: Int
        let bottom: Int
        static let none = StickyInsets(top: 0, bottom: 0)
    }

    private struct Seam: Sendable {
        let shift: Int
        let score: Double
    }

    private enum Match {
        case unchanged
        case append(Seam)
        case rejected(ScrollingFrameRejection)
    }

    private let limits: ScrollingStitchLimits
    private var reference: PixelFrame?
    private var stickyInsets: StickyInsets?
    private var stickyTop = [UInt8]()
    private var body = [UInt8]()
    private var stickyBottom = [UInt8]()
    private var acceptedFrames = 0
    private var appendedRows = 0
    private var cancelled = false

    init(limits: ScrollingStitchLimits = ScrollingStitchLimits()) {
        self.limits = limits
    }

    func ingest(_ input: ScrollingCaptureFrame) throws -> ScrollingIngestResult {
        try checkCancellation()
        let width = input.image.width
        let height = input.image.height
        guard width > 0, height > 0, input.pointPixelScale.isFinite, input.pointPixelScale > 0,
              let framePixels = multiplied(width, height) else {
            throw ScrollingStitchError.invalidFrame
        }
        guard framePixels <= limits.maximumFramePixels else {
            throw ScrollingStitchError.framePixelLimitExceeded(limit: limits.maximumFramePixels, actual: framePixels)
        }
        let incoming = try Self.normalized(input, width: width, height: height)
        try checkCancellation()

        guard let previous = reference else {
            guard limits.maximumAcceptedFrames >= 1 else {
                throw ScrollingStitchError.acceptedFrameLimitExceeded(limit: limits.maximumAcceptedFrames)
            }
            try preflight(outputWidth: width, outputHeight: height,
                          referenceBytes: incoming.retainedBytes)
            body = incoming.rgba
            reference = incoming
            acceptedFrames = 1
            return result(.firstFrame)
        }

        guard previous.width == width, previous.height == height else {
            throw ScrollingStitchError.dimensionMismatch(expectedWidth: previous.width,
                expectedHeight: previous.height, actualWidth: width, actualHeight: height)
        }
        guard abs(previous.scale - incoming.scale) <= 0.0001 else {
            throw ScrollingStitchError.scaleMismatch(expected: previous.scale, actual: incoming.scale)
        }

        let proposedInsets = stickyInsets ?? Self.detectStickyInsets(previous, incoming)
        if stickyInsets != nil && !Self.stickyRowsMatch(previous, incoming, insets: proposedInsets) {
            return result(.rejected(.stickyRegionChanged))
        }
        let match = try Self.match(previous, incoming, insets: proposedInsets,
                                   minimumOverlapRows: limits.minimumOverlapRows)
        try checkCancellation()

        switch match {
        case .unchanged:
            return result(.unchanged)
        case let .rejected(reason):
            logger.debug("Rejected frame: \(String(describing: reason), privacy: .public)")
            return result(.rejected(reason))
        case let .append(seam):
            guard acceptedFrames < limits.maximumAcceptedFrames else {
                throw ScrollingStitchError.acceptedFrameLimitExceeded(limit: limits.maximumAcceptedFrames)
            }
            let nextHeight = currentOutputHeight + seam.shift
            try preflight(outputWidth: width, outputHeight: nextHeight,
                          referenceBytes: incoming.retainedBytes)

            if stickyInsets == nil {
                applyInitialStickyInsets(proposedInsets, frame: previous)
                stickyInsets = proposedInsets
            }
            let newBodyRange = Self.rowByteRange(
                (incoming.height - proposedInsets.bottom - seam.shift)..<(incoming.height - proposedInsets.bottom),
                width: incoming.width)
            body.append(contentsOf: incoming.rgba[newBodyRange])
            reference = incoming
            acceptedFrames += 1
            appendedRows += seam.shift
            logger.debug("Appended \(seam.shift, privacy: .public) rows; accepted=\(self.acceptedFrames, privacy: .public)")
            return result(.appended(rows: seam.shift))
        }
    }

    func render() throws -> ScrollingStitchArtifact {
        try checkCancellation()
        guard let reference else { throw ScrollingStitchError.noFrames }
        let outputByteCount = stickyTop.count + body.count + stickyBottom.count
        try preflight(outputWidth: reference.width, outputHeight: currentOutputHeight,
                      referenceBytes: reference.retainedBytes)
        guard let rgba = NSMutableData(capacity: outputByteCount) else {
            throw ScrollingStitchError.memoryLimitExceeded(limit: limits.maximumRetainedBytes,
                                                           required: outputByteCount)
        }
        for component in [stickyTop, body, stickyBottom] where !component.isEmpty {
            component.withUnsafeBytes { bytes in
                if let baseAddress = bytes.baseAddress {
                    rgba.append(baseAddress, length: bytes.count)
                }
            }
        }
        guard rgba.length == outputByteCount else { throw ScrollingStitchError.invalidFrame }
        try checkCancellation()
        guard let provider = CGDataProvider(data: rgba as CFData),
              let image = CGImage(width: reference.width, height: currentOutputHeight,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: reference.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                    .union(.byteOrder32Big), provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent) else {
            throw ScrollingStitchError.invalidFrame
        }
        let artifact = ScrollingStitchArtifact(image: image, acceptedFrames: acceptedFrames,
                                               appendedRows: appendedRows)
        self.reference = nil
        stickyTop.removeAll(keepingCapacity: false)
        body.removeAll(keepingCapacity: false)
        stickyBottom.removeAll(keepingCapacity: false)
        return artifact
    }

    func cancel() {
        cancelled = true
        reference = nil
        stickyTop.removeAll(keepingCapacity: false)
        body.removeAll(keepingCapacity: false)
        stickyBottom.removeAll(keepingCapacity: false)
    }

    private var currentOutputHeight: Int {
        guard let reference, reference.width > 0 else { return 0 }
        return (stickyTop.count + body.count + stickyBottom.count) / (reference.width * 4)
    }

    private func result(_ disposition: ScrollingIngestDisposition) -> ScrollingIngestResult {
        ScrollingIngestResult(disposition: disposition, progress: ScrollingStitchProgress(
            acceptedFrames: acceptedFrames,
            outputWidth: reference?.width ?? 0,
            outputHeight: currentOutputHeight,
            retainedBytes: retainedBytes))
    }

    private var retainedBytes: Int {
        stickyTop.count + body.count + stickyBottom.count + (reference?.retainedBytes ?? 0)
    }

    private func preflight(outputWidth: Int, outputHeight: Int, referenceBytes: Int) throws {
        guard let outputPixels = multiplied(outputWidth, outputHeight) else {
            throw ScrollingStitchError.invalidFrame
        }
        guard outputPixels <= limits.maximumOutputPixels else {
            throw ScrollingStitchError.outputPixelLimitExceeded(limit: limits.maximumOutputPixels,
                                                                actual: outputPixels)
        }
        guard let outputBytes = multiplied(outputPixels, 4),
              let outputAndRenderBytes = multiplied(outputBytes, 2),
              referenceBytes <= Int.max - outputAndRenderBytes else {
            throw ScrollingStitchError.memoryLimitExceeded(limit: limits.maximumRetainedBytes,
                                                           required: Int.max)
        }
        // Accepted pixels remain owned while CoreGraphics receives one final,
        // contiguous data buffer. Reserve both copies before mutating state.
        let required = outputAndRenderBytes + referenceBytes
        guard required <= limits.maximumRetainedBytes else {
            throw ScrollingStitchError.memoryLimitExceeded(limit: limits.maximumRetainedBytes,
                                                           required: required)
        }
    }

    private func applyInitialStickyInsets(_ insets: StickyInsets, frame: PixelFrame) {
        guard insets != .none else { return }
        stickyTop = Array(frame.rgba[Self.rowByteRange(0..<insets.top, width: frame.width)])
        body = Array(frame.rgba[Self.rowByteRange(insets.top..<(frame.height - insets.bottom),
                                                  width: frame.width)])
        stickyBottom = Array(frame.rgba[Self.rowByteRange((frame.height - insets.bottom)..<frame.height,
                                                          width: frame.width)])
    }

    private func checkCancellation() throws {
        guard !cancelled, !Task.isCancelled else { throw ScrollingStitchError.cancelled }
    }

    private func multiplied(_ lhs: Int, _ rhs: Int) -> Int? {
        let value = lhs.multipliedReportingOverflow(by: rhs)
        return value.overflow ? nil : value.partialValue
    }

    private static func normalized(_ input: ScrollingCaptureFrame, width: Int, height: Int) throws -> PixelFrame {
        guard let byteCount = safeProduct(width, height, 4) else { throw ScrollingStitchError.invalidFrame }
        var rgba = [UInt8](repeating: 0, count: byteCount)
        guard let context = CGContext(data: &rgba, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                .union(.byteOrder32Big).rawValue) else {
            throw ScrollingStitchError.invalidFrame
        }
        context.interpolationQuality = .none
        context.draw(input.image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let signatureColumns = min(64, width)
        var rowSignatures = [UInt8](repeating: 0, count: height * signatureColumns)
        for y in 0..<height {
            for column in 0..<signatureColumns {
                let lower = column * width / signatureColumns
                let upper = max(lower + 1, (column + 1) * width / signatureColumns)
                var luminance = 0
                for x in lower..<upper {
                    let offset = (y * width + x) * 4
                    luminance += (Int(rgba[offset]) * 3 + Int(rgba[offset + 1]) * 6
                                  + Int(rgba[offset + 2])) / 10
                }
                rowSignatures[y * signatureColumns + column] =
                    UInt8(clamping: luminance / (upper - lower))
            }
        }
        return PixelFrame(width: width, height: height, scale: input.pointPixelScale, rgba: rgba,
                          signatureColumns: signatureColumns, rowSignatures: rowSignatures)
    }

    private static func detectStickyInsets(_ previous: PixelFrame, _ current: PixelFrame) -> StickyInsets {
        let maximum = max(0, min(previous.height / 4, previous.height - 2))
        guard maximum > 0 else { return .none }
        var top = 0
        while top < maximum && rowDifference(previous, top, current, top) <= 4 { top += 1 }
        var bottom = 0
        while bottom < maximum, top + bottom < previous.height - 2,
              rowDifference(previous, previous.height - 1 - bottom,
                            current, current.height - 1 - bottom) <= 4 { bottom += 1 }
        return StickyInsets(top: top, bottom: bottom)
    }

    private static func stickyRowsMatch(_ previous: PixelFrame, _ current: PixelFrame,
                                        insets: StickyInsets) -> Bool {
        for row in 0..<insets.top where rowDifference(previous, row, current, row) > 8 { return false }
        for offset in 0..<insets.bottom where rowDifference(previous, previous.height - 1 - offset,
            current, current.height - 1 - offset) > 8 { return false }
        return true
    }

    private static func match(_ previous: PixelFrame, _ current: PixelFrame,
                              insets: StickyInsets, minimumOverlapRows: Int) throws -> Match {
        let bodyHeight = previous.height - insets.top - insets.bottom
        guard bodyHeight >= 2 else { return .rejected(.insufficientOverlap) }
        guard hasTexture(previous, rows: insets.top..<(previous.height - insets.bottom)),
              hasTexture(current, rows: insets.top..<(current.height - insets.bottom)) else {
            return .rejected(.insufficientTexture)
        }
        // A sliver of matching chrome is not enough evidence for a seam. Keep at
        // least one eighth of the viewport so fast scrolling pauses safely.
        let confidenceFloor = max(2, bodyHeight / 8)
        let minimumOverlap = max(1, min(max(minimumOverlapRows, confidenceFloor), bodyHeight - 1))
        var candidates = [Seam]()
        for shift in 0...(bodyHeight - minimumOverlap) {
            if shift.isMultiple(of: 64), Task.isCancelled { throw ScrollingStitchError.cancelled }
            let overlap = bodyHeight - shift
            let score = difference(previous, previousStart: insets.top + shift,
                                   current, currentStart: insets.top, rows: overlap)
            if score <= 8 { candidates.append(Seam(shift: shift, score: score)) }
        }
        candidates.sort { $0.score == $1.score ? $0.shift < $1.shift : $0.score < $1.score }
        candidates = candidates.prefix(24).map {
            Seam(shift: $0.shift, score: difference(previous,
                previousStart: insets.top + $0.shift, current,
                currentStart: insets.top, rows: bodyHeight - $0.shift, exhaustive: true))
        }.filter { $0.score <= 8 }
        candidates.sort { $0.score == $1.score ? $0.shift < $1.shift : $0.score < $1.score }
        if let best = candidates.first {
            // A duplicate frame is always safe to ignore. Repeated visual
            // structure only becomes ambiguous once it proposes movement.
            if best.shift == 0 { return .unchanged }
            if candidates.dropFirst().contains(where: {
                $0.score <= max(best.score + 0.0001, best.score * 1.10)
            }) {
                return .rejected(.ambiguousOverlap)
            }
            return .append(best)
        }

        var reverseCandidates = [Seam]()
        for shift in 1...(bodyHeight - minimumOverlap) {
            let overlap = bodyHeight - shift
            let score = difference(previous, previousStart: insets.top,
                                   current, currentStart: insets.top + shift, rows: overlap)
            if score <= 8 { reverseCandidates.append(Seam(shift: shift, score: score)) }
        }
        reverseCandidates.sort { $0.score == $1.score ? $0.shift < $1.shift : $0.score < $1.score }
        reverseCandidates = reverseCandidates.prefix(24).map {
            Seam(shift: $0.shift, score: difference(previous,
                previousStart: insets.top, current,
                currentStart: insets.top + $0.shift, rows: bodyHeight - $0.shift,
                exhaustive: true))
        }.filter { $0.score <= 8 }
        reverseCandidates.sort { $0.score == $1.score ? $0.shift < $1.shift : $0.score < $1.score }
        if let best = reverseCandidates.first,
           !reverseCandidates.dropFirst().contains(where: {
               $0.score <= max(best.score + 0.0001, best.score * 1.10)
           }) {
            return .rejected(.reverseMotion)
        }
        return .rejected(.insufficientOverlap)
    }

    private static func hasTexture(_ frame: PixelFrame, rows: Range<Int>) -> Bool {
        let rowStep = max(1, rows.count / 32)
        let columnStep = max(1, frame.width / 32)
        var minimum = 255
        var maximum = 0
        var y = rows.lowerBound
        while y < rows.upperBound {
            var x = 0
            while x < frame.width {
                let offset = (y * frame.width + x) * 4
                let luminance = (Int(frame.rgba[offset]) * 3 + Int(frame.rgba[offset + 1]) * 6
                                 + Int(frame.rgba[offset + 2])) / 10
                minimum = min(minimum, luminance)
                maximum = max(maximum, luminance)
                x += columnStep
            }
            y += rowStep
        }
        return maximum - minimum >= 10
    }

    private static func difference(_ previous: PixelFrame, previousStart: Int,
                                   _ current: PixelFrame, currentStart: Int, rows: Int,
                                   exhaustive: Bool = false) -> Double {
        let rowStep = exhaustive ? 1 : max(1, rows / 192)
        let columns = min(previous.signatureColumns, current.signatureColumns)
        var total = 0
        var samples = 0
        var row = 0
        while row < rows {
            let a = (previousStart + row) * previous.signatureColumns
            let b = (currentStart + row) * current.signatureColumns
            for column in 0..<columns {
                total += abs(Int(previous.rowSignatures[a + column]) -
                             Int(current.rowSignatures[b + column]))
            }
            samples += columns
            row += rowStep
        }
        return samples == 0 ? .infinity : Double(total) / Double(samples)
    }

    private static func rowDifference(_ previous: PixelFrame, _ previousRow: Int,
                                      _ current: PixelFrame, _ currentRow: Int) -> Double {
        difference(previous, previousStart: previousRow, current, currentStart: currentRow, rows: 1)
    }

    private static func rowByteRange(_ rows: Range<Int>, width: Int) -> Range<Int> {
        (rows.lowerBound * width * 4)..<(rows.upperBound * width * 4)
    }

    private static func safeProduct(_ values: Int...) -> Int? {
        values.reduce(Optional(1)) { result, value in
            guard let result else { return nil }
            let product = result.multipliedReportingOverflow(by: value)
            return product.overflow ? nil : product.partialValue
        }
    }
}
