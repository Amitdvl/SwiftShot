import CoreGraphics
import Foundation

/// Metadata-only admission lets callers reject a combination before loading originals.
struct CaptureCombineSource: Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bitsPerComponent: Int
    let isFloatingPoint: Bool
    /// A cropped CGImage can retain a larger provider. Callers that retain its original
    /// should pass that full footprint during preflight rather than only crop pixels.
    let retainedSourceBytes: Int?

    init(width: Int, height: Int, bytesPerRow: Int, bitsPerComponent: Int = 8,
         isFloatingPoint: Bool = false, retainedSourceBytes: Int? = nil) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.bitsPerComponent = bitsPerComponent
        self.isFloatingPoint = isFloatingPoint
        self.retainedSourceBytes = retainedSourceBytes
    }

    init(image: CGImage) {
        self.init(width: image.width, height: image.height, bytesPerRow: image.bytesPerRow,
                  bitsPerComponent: image.bitsPerComponent, isFloatingPoint: image.bitmapInfo.contains(.floatComponents))
    }
}

struct CaptureCombinePlan: Sendable {
    let width: Int
    let height: Int
    let bitsPerComponent: Int
    let bytesPerPixel: Int
    let bytesPerRow: Int
    let admittedSourceBytes: Int
    let outputBytes: Int
    let normalizationBytes: Int
    let estimatedPeakBytes: Int
}

/// Native-pixel, in-order combination. No encoder or scaling path is involved.
actor CaptureCombiner {
    enum Failure: LocalizedError {
        case invalidSources, arithmeticOverflow, outputTooLarge, memoryLimit, allocationFailed

        var errorDescription: String? {
            switch self {
            case .invalidSources: "Choose between 1 and 32 valid captures to combine."
            case .arithmeticOverflow: "The selected capture dimensions exceed safe arithmetic limits."
            case .outputTooLarge: "The combined capture exceeds the 64-megapixel output limit."
            case .memoryLimit: "This combination exceeds the safe 512 MiB image-buffer budget. Combine fewer or smaller captures."
            case .allocationFailed: "There is not enough available memory to combine these captures."
            }
        }
    }

    private let maximumOutputPixels: Int
    private let maximumWorkingBytes: Int

    /// Custom limits may tighten admission for pressure/tests, never raise the hard caps.
    init(maximumOutputPixels: Int = 64_000_000, maximumWorkingBytes: Int = 512 * 1_024 * 1_024) {
        self.maximumOutputPixels = max(0, min(64_000_000, maximumOutputPixels))
        self.maximumWorkingBytes = max(0, min(512 * 1_024 * 1_024, maximumWorkingBytes))
    }

    nonisolated func preflight(sources: [CaptureCombineSource], axis: HistoryCombineAxis) throws -> CaptureCombinePlan {
        guard !sources.isEmpty, sources.count <= 32,
              sources.allSatisfy({ $0.width > 0 && $0.height > 0 && $0.bytesPerRow > 0 && (1...32).contains($0.bitsPerComponent) }) else {
            throw Failure.invalidSources
        }
        let floating = sources.contains(where: \.isFloatingPoint)
        let componentBits = floating ? 32 : sources.contains(where: { $0.bitsPerComponent > 8 }) ? 16 : 8
        let bytesPerPixel = componentBits / 8 * 4
        var width = 0, height = 0, sourceBytes = 0, normalizationBytes = 0
        for source in sources {
            if axis == .vertical {
                width = max(width, source.width)
                height = try Self.add(height, source.height)
            } else {
                width = try Self.add(width, source.width)
                height = max(height, source.height)
            }
            let nominal = try Self.multiply(source.bytesPerRow, source.height)
            let retained = max(nominal, source.retainedSourceBytes ?? 0)
            sourceBytes = try Self.add(sourceBytes, retained)
            let normalized = try Self.multiply(try Self.multiply(source.width, bytesPerPixel), source.height)
            normalizationBytes = max(normalizationBytes, normalized)
        }
        let pixels = try Self.multiply(width, height)
        guard pixels <= maximumOutputPixels else { throw Failure.outputTooLarge }
        let bytesPerRow = try Self.multiply(width, bytesPerPixel)
        let outputBytes = try Self.multiply(bytesPerRow, height)
        // Reserve a second output backing for makeImage and a second largest source
        // normalization buffer for CoreGraphics conversion. Only one source is active.
        let peak = try Self.add(sourceBytes, try Self.add(Self.multiply(outputBytes, 2), Self.multiply(normalizationBytes, 2)))
        guard peak <= maximumWorkingBytes else { throw Failure.memoryLimit }
        return CaptureCombinePlan(width: width, height: height, bitsPerComponent: componentBits,
            bytesPerPixel: bytesPerPixel, bytesPerRow: bytesPerRow, admittedSourceBytes: sourceBytes,
            outputBytes: outputBytes, normalizationBytes: normalizationBytes, estimatedPeakBytes: peak)
    }

    func combine(images: [CGImage], axis: HistoryCombineAxis) async throws -> CGImage {
        try Task.checkCancellation()
        let plan = try preflight(sources: images.map(CaptureCombineSource.init(image:)), axis: axis)
        let space = Self.outputColorSpace(images)
        let floating = images.contains { $0.bitmapInfo.contains(.floatComponents) }
        var bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        if floating { bitmap.formUnion([.floatComponents, .byteOrder32Little]) }
        else if plan.bitsPerComponent == 16 { bitmap.formUnion(.byteOrder16Little) }
        return try autoreleasepool {
            guard let output = CGContext(data: nil, width: plan.width, height: plan.height,
                bitsPerComponent: plan.bitsPerComponent, bytesPerRow: plan.bytesPerRow,
                space: space, bitmapInfo: bitmap.rawValue), let destination = output.data else { throw Failure.allocationFailed }
            destination.initializeMemory(as: UInt8.self, repeating: 0, count: plan.outputBytes)
            var offsetX = 0, offsetY = 0
            for image in images {
                try Task.checkCancellation()
                try autoreleasepool {
                    let rowBytes = try Self.multiply(image.width, plan.bytesPerPixel)
                    guard let normalized = CGContext(data: nil, width: image.width, height: image.height,
                        bitsPerComponent: plan.bitsPerComponent, bytesPerRow: rowBytes,
                        space: space, bitmapInfo: bitmap.rawValue), let source = normalized.data else { throw Failure.allocationFailed }
                    normalized.interpolationQuality = .none
                    normalized.setShouldAntialias(false)
                    normalized.setBlendMode(.copy)
                    normalized.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                    // Bitmap rows are copied verbatim, so first source/top row remains
                    // first regardless of Quartz's drawing coordinate orientation.
                    for row in 0..<image.height {
                        if row.isMultiple(of: 64) { try Task.checkCancellation() }
                        let targetOffset = (offsetY + row) * plan.bytesPerRow + offsetX * plan.bytesPerPixel
                        destination.advanced(by: targetOffset).copyMemory(from: source.advanced(by: row * rowBytes), byteCount: rowBytes)
                    }
                }
                if axis == .vertical { offsetY += image.height }
                else { offsetX += image.width }
            }
            try Task.checkCancellation()
            guard let image = output.makeImage() else { throw Failure.allocationFailed }
            return image
        }
    }

    private nonisolated static func outputColorSpace(_ images: [CGImage]) -> CGColorSpace {
        if let first = images.first?.colorSpace, first.model == .rgb,
           images.allSatisfy({ image in image.colorSpace.map { $0.model == .rgb && CFEqual(first, $0) } ?? false }) {
            return first
        }
        // Mixing HDR/float sources must not silently clip them into an 8-bit SDR gamut.
        let name = images.contains { $0.bitmapInfo.contains(.floatComponents) } ? CGColorSpace.extendedLinearSRGB : CGColorSpace.sRGB
        return CGColorSpace(name: name)!
    }

    private nonisolated static func add(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, result >= 0 else { throw Failure.arithmeticOverflow }
        return result
    }

    private nonisolated static func multiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow, result >= 0 else { throw Failure.arithmeticOverflow }
        return result
    }
}
