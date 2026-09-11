import CoreGraphics
import Foundation

/// Sparse edge samples propose offsets; full-resolution overlap pixels authorize
/// a stitch. Normalization also makes BGRA/RGBA and display profiles comparable.
struct ScrollCapturePixels: Sendable {
    let width: Int
    let height: Int
    let bytes: [UInt8]
    var byteCount: Int { bytes.count }

    static let pixelTolerance = 8

    init(image: CGImage) throws {
        width = image.width
        height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScrollCaptureIssue.memoryLimit }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { throw ScrollCaptureIssue.memoryLimit }
        bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }

    func matchFraction(other: ScrollCapturePixels, fromRow: Int, otherFromRow: Int, rowCount: Int) throws -> Double {
        try Task.checkCancellation()
        guard rowCount > 0 else { return 0 }
        let count = rowCount * width
        var matches = 0
        let leftStart = fromRow * width * 4
        let rightStart = otherFromRow * width * 4
        for pixel in 0..<count {
            if pixel % (width * 16) == 0 { try Task.checkCancellation() }
            let a = leftStart + pixel * 4
            let b = rightStart + pixel * 4
            if Self.close(bytes, a, other.bytes, b) { matches += 1 }
        }
        return Double(matches) / Double(count)
    }

    static func close(_ a: [UInt8], _ ai: Int, _ b: [UInt8], _ bi: Int) -> Bool {
        abs(Int(a[ai]) - Int(b[bi])) <= pixelTolerance && abs(Int(a[ai + 1]) - Int(b[bi + 1])) <= pixelTolerance &&
            abs(Int(a[ai + 2]) - Int(b[bi + 2])) <= pixelTolerance && abs(Int(a[ai + 3]) - Int(b[bi + 3])) <= pixelTolerance
    }
}

enum ScrollOverlapMatcher {
    private static let acceptanceFraction = 0.995
    enum Match {
        case unchanged
        case overlap(offset: Int, header: Int, footer: Int)
        case rejected(ScrollCaptureIssue)
    }

    static func match(previous: ScrollCapturePixels, next: ScrollCapturePixels) throws -> Match {
        let height = previous.height
        guard previous.width == next.width, height == next.height else { return .rejected(.dimensionsChanged) }
        if try previous.matchFraction(other: next, fromRow: 0, otherFromRow: 0, rowCount: height) >= acceptanceFraction { return .unchanged }
        var header = 0
        var footer = 0
        let stickyLimit = height / 3
        while header < stickyLimit {
            guard try previous.matchFraction(other: next, fromRow: header, otherFromRow: header, rowCount: 1) >= acceptanceFraction else { break }
            header += 1
        }
        while footer < stickyLimit {
            guard try previous.matchFraction(other: next, fromRow: height - footer - 1,
                otherFromRow: height - footer - 1, rowCount: 1) >= acceptanceFraction else { break }
            footer += 1
        }
        let minimumOverlap = max(32, height / 5)
        let maximumOffset = height - header - footer - minimumOverlap
        guard maximumOffset >= 1 else { return .rejected(.insufficientOverlap) }
        var candidates: [(offset: Int, quality: Double)] = []
        var sawEvidence = false
        for offset in 1...maximumOffset {
            if offset % 32 == 0 { try Task.checkCancellation() }
            let quality = edgeQuality(previous: previous, next: next, offset: offset, header: header, footer: footer)
            if quality >= 0 { sawEvidence = true }
            if quality >= 0.65 { candidates.append((offset, quality)) }
        }
        guard sawEvidence else { return .rejected(.ambiguousContent) }
        guard let best = candidates.max(by: { $0.quality < $1.quality }) else { return .rejected(.insufficientOverlap) }
        func validated(_ offset: Int) throws -> Bool {
            let overlap = height - footer - header - offset
            return try previous.matchFraction(other: next, fromRow: header + offset, otherFromRow: header,
                rowCount: overlap) >= acceptanceFraction
        }
        guard best.quality >= 0.985, try validated(best.offset) else { return .rejected(.dynamicContent) }
        for candidate in candidates where candidate.offset != best.offset && candidate.quality >= best.quality - 0.005 {
            if try validated(candidate.offset) { return .rejected(.ambiguousContent) }
        }
        return .overlap(offset: best.offset, header: header, footer: footer)
    }

    private static func edgeQuality(previous: ScrollCapturePixels, next: ScrollCapturePixels,
                                    offset: Int, header: Int, footer: Int) -> Double {
        let overlap = previous.height - footer - header - offset
        let rows = min(24, overlap)
        let columns = min(96, previous.width)
        var evidence = 0
        var matches = 0
        for sampleY in 0..<rows {
            let y = header + (sampleY * max(0, overlap - 2)) / max(1, rows - 1)
            for sampleX in 0..<columns {
                let x = (sampleX * (previous.width - 1)) / max(1, columns - 1)
                let a = ((y + offset) * previous.width + x) * 4
                let b = (y * previous.width + x) * 4
                let neighbour = x + 1 < previous.width ? a + 4 : a - (x > 0 ? 4 : 0)
                let below = a + previous.width * 4
                let horizontalEdge = abs(Int(previous.bytes[a]) - Int(previous.bytes[neighbour])) +
                    abs(Int(previous.bytes[a + 1]) - Int(previous.bytes[neighbour + 1])) +
                    abs(Int(previous.bytes[a + 2]) - Int(previous.bytes[neighbour + 2]))
                let verticalEdge = abs(Int(previous.bytes[a]) - Int(previous.bytes[below])) +
                    abs(Int(previous.bytes[a + 1]) - Int(previous.bytes[below + 1])) +
                    abs(Int(previous.bytes[a + 2]) - Int(previous.bytes[below + 2]))
                guard max(horizontalEdge, verticalEdge) >= 24 else { continue }
                evidence += 1
                if ScrollCapturePixels.close(previous.bytes, a, next.bytes, b) { matches += 1 }
            }
        }
        guard evidence >= max(24, rows * columns / 200) else { return -1 }
        return Double(matches) / Double(evidence)
    }
}
