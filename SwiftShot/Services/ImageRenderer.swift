import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Preview/export share native-pixel geometry; smaller-share explicitly downsamples.
actor ImageRenderer: CaptureRendering {
    struct WorkingSetBudget: Sendable {
        let byteLimit: Int
        init(byteLimit: Int = 512 * 1024 * 1024) { self.byteLimit = max(0, byteLimit) }

        func admitSource(bytesPerRow: Int, height: Int) throws -> Int {
            guard bytesPerRow > 0, height > 0 else { throw RenderError.imageTooLarge }
            let bytes = bytesPerRow.multipliedReportingOverflow(by: height)
            guard !bytes.overflow, bytes.partialValue <= byteLimit else { throw RenderError.imageTooLarge }
            return bytes.partialValue
        }

        // Conservative per-operation admission, not a process-RSS or ImageIO
        // allocator guarantee. Keep the existing 512 MiB ceiling / 64 MiB reserve.
        func admitPNG(sourceBytes: Int, outputBytes: Int, sharesSource: Bool) throws {
            guard sourceBytes > 0, outputBytes > 0 else { throw RenderError.imageTooLarge }
            // Original source, any distinct flattened bitmap, PNG bytes, encoder
            // workspace, and a reserve for compression/metadata overhead.
            try admit([sourceBytes, sharesSource ? 0 : outputBytes, outputBytes, outputBytes, 64 * 1024 * 1024])
        }

        func admitBitmap(sourceBytes: Int, outputBytes: Int) throws {
            guard sourceBytes > 0, outputBytes > 0 else { throw RenderError.imageTooLarge }
            // Existing compositing policy: source + native/smaller-share buffers
            // + bounded decorative decode, checked without overflowing sums.
            try admit([sourceBytes, outputBytes, outputBytes, 64 * 1024 * 1024])
        }

        private func admit(_ components: [Int]) throws {
            var remaining = byteLimit
            for bytes in components {
                guard bytes >= 0, bytes <= remaining else { throw RenderError.imageTooLarge }
                remaining -= bytes
            }
        }
    }

    struct CacheStatistics: Sendable {
        var renders = 0
        var encodes = 0
        var bitmapHits = 0
        var pngHits = 0
        var retainedBytes = 0
        var entries = 0
    }

    private struct BackgroundSignature: Equatable {
        let url: URL?
        let size: Int?
        let modified: Date?
        init(_ url: URL?) {
            let resolved = url?.resolvingSymlinksInPath().standardizedFileURL
            self.url = resolved
            // URL resource values may be cached on the URL instance. Read fresh
            // filesystem attributes so a replaced custom background invalidates.
            let values = resolved.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path) }
            size = (values?[.size] as? NSNumber)?.intValue
            modified = values?[.modificationDate] as? Date
        }
    }

    private struct CacheEntry {
        let request: RenderRequest
        let background: BackgroundSignature
        let image: CGImage
        var png: Data?
        var cost: Int {
            // Cropped CGImages can retain the entire source provider. Charge the
            // source too, conservatively, even when output shares its backing.
            let textBytes = request.edits.annotations.reduce(0) { $0 + $1.text.utf8.count * 2 }
            let modelBytes = MemoryLayout<CaptureAnnotation>.stride * request.edits.annotations.count * 2
            let pathBytes = ((request.backgroundURL?.path.utf8.count ?? 0) + request.edits.style.backgroundID.utf8.count) * 2
            return request.image.bytesPerRow * request.image.height + image.bytesPerRow * image.height +
                (png?.count ?? 0) + textBytes + modelBytes + pathBytes + 512
        }
        func matches(_ candidate: RenderRequest, background: BackgroundSignature) -> Bool {
            request.image === candidate.image && request.documentID == candidate.documentID &&
                request.revision == candidate.revision && request.edits == candidate.edits &&
                request.backgroundVersion == candidate.backgroundVersion && request.output == candidate.output &&
                self.background == background
        }
    }

    private let cacheByteLimit: Int
    private let cacheEntryLimit: Int
    private let workingSetBudget: WorkingSetBudget
    private var cache: [CacheEntry] = [] // Most recently used first; bounded tiny array.
    private(set) var cacheStatistics = CacheStatistics()

    init(cacheByteLimit: Int = 128 * 1024 * 1024, cacheEntryLimit: Int = 3,
         workingSetByteLimit: Int = 512 * 1024 * 1024) {
        self.cacheByteLimit = max(0, cacheByteLimit)
        self.cacheEntryLimit = max(0, min(16, cacheEntryLimit))
        self.workingSetBudget = WorkingSetBudget(byteLimit: workingSetByteLimit)
    }

    /// Called on memory pressure, privacy transitions and session shutdown.
    func clearCache() async {
        cache.removeAll(keepingCapacity: false)
        updateCacheStatistics()
    }

    private func updateCacheStatistics() {
        cacheStatistics.retainedBytes = cache.reduce(0) { $0 + $1.cost }
        cacheStatistics.entries = cache.count
    }

    private func trimCache() {
        while !cache.isEmpty && (cache.count > cacheEntryLimit || cache.reduce(0, { $0 + $1.cost }) > cacheByteLimit) {
            cache.removeLast()
        }
        updateCacheStatistics()
    }

    enum RenderError: LocalizedError {
        case invalidGeometry, imageTooLarge, missingBackground, invalidBackground, allocationFailed, encodingFailed

        var errorDescription: String? {
            switch self {
            case .invalidGeometry: "The image edits contain invalid geometry."
            case .imageTooLarge: "This image is too large to render safely."
            case .missingBackground: "The selected background is unavailable. Choose another background."
            case .invalidBackground: "The selected background could not be decoded."
            case .allocationFailed: "There is not enough memory to render this capture."
            case .encodingFailed: "The capture could not be encoded as PNG."
            }
        }
    }

    func render(_ request: RenderRequest) throws -> RenderedCapture {
        try Task.checkCancellation()
        let background = BackgroundSignature(request.backgroundURL)
        if let index = cache.firstIndex(where: { $0.matches(request, background: background) }), let png = cache[index].png {
            let entry = cache.remove(at: index)
            cache.insert(entry, at: 0)
            cacheStatistics.pngHits += 1
            return RenderedCapture(image: entry.image, png: png)
        }
        let image = try cachedRenderImage(request)
        try Task.checkCancellation()
        let sourceBytes = try workingSetBudget.admitSource(bytesPerRow: request.image.bytesPerRow, height: request.image.height)
        let outputBytes = try workingSetBudget.admitSource(bytesPerRow: image.bytesPerRow, height: image.height)
        try workingSetBudget.admitPNG(sourceBytes: sourceBytes, outputBytes: outputBytes, sharesSource: image === request.image)
        let png = try Self.encodePNG(image)
        try Task.checkCancellation()
        cacheStatistics.encodes += 1
        if let index = cache.firstIndex(where: { $0.matches(request, background: background) }) {
            cache[index].png = png
            trimCache()
        }
        return RenderedCapture(image: image, png: png)
    }

    /// OCR consumes this bitmap directly. It never pays the PNG encoder cost.
    func renderImage(_ request: RenderRequest) async throws -> CGImage {
        try cachedRenderImage(request)
    }

    private func cachedRenderImage(_ request: RenderRequest) throws -> CGImage {
        try Task.checkCancellation()
        _ = try workingSetBudget.admitSource(bytesPerRow: request.image.bytesPerRow, height: request.image.height)
        let background = BackgroundSignature(request.backgroundURL)
        if let index = cache.firstIndex(where: { $0.matches(request, background: background) }) {
            let entry = cache.remove(at: index)
            cache.insert(entry, at: 0)
            cacheStatistics.bitmapHits += 1
            return entry.image
        }
        let image = try Self.renderBitmap(request, budget: workingSetBudget)
        try Task.checkCancellation()
        cacheStatistics.renders += 1
        cache.insert(CacheEntry(request: request, background: background, image: image, png: nil), at: 0)
        trimCache()
        return image
    }

    private static func renderBitmap(_ request: RenderRequest, budget: WorkingSetBudget) throws -> CGImage {
        try autoreleasepool {
            let edits = request.edits
            let crop = edits.crop
            let bounds = CGRect(x: 0, y: 0, width: request.image.width, height: request.image.height)
            guard Self.finite(crop), !crop.isEmpty, crop == crop.integral,
                  bounds.contains(crop), edits.annotations.count <= 10_000 else {
                throw RenderError.invalidGeometry
            }
            let framed = !edits.style.backgroundID.isEmpty
            let style = edits.style
            guard style.backgroundID.utf8.count <= 1024,
                  [style.padding, style.cornerRadius, style.shadow].allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 16_384 }) else {
                throw RenderError.invalidGeometry
            }
            let padding = framed ? Int(style.padding.rounded()) : 0
            let width = Int(crop.width) + padding * 2
            let height = Int(crop.height) + padding * 2
            // Bound each axis and total allocation before decoding or allocating bitmap memory.
            guard width <= 32_768, height <= 32_768, width * height <= 64_000_000 else {
                throw RenderError.imageTooLarge
            }
            if case .smallerShare(let limit) = request.output, !(1...32_768).contains(limit) {
                throw RenderError.invalidGeometry
            }
            var totalTextBytes = 0
            var totalTextLines = 0
            let newlineCharacters = CharacterSet.newlines
            for annotation in edits.annotations {
                totalTextBytes += annotation.text.utf8.count
                // Count line separators without allocating thousands of strings.
                totalTextLines += 1 + annotation.text.unicodeScalars.reduce(0) { $0 + (newlineCharacters.contains($1) ? 1 : 0) }
                guard [annotation.start.x, annotation.start.y, annotation.end.x, annotation.end.y,
                       annotation.lineWidth, annotation.fontSize].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
                      annotation.lineWidth > 0, annotation.fontSize > 0, annotation.fontSize <= 4096,
                      annotation.text.utf8.count <= 100_000,
                      totalTextBytes <= 1_048_576, totalTextLines <= 16_384,
                      [annotation.color.red, annotation.color.green, annotation.color.blue, annotation.color.alpha]
                        .allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                    throw RenderError.invalidGeometry
                }
            }
            try Task.checkCancellation()
            let source: CGImage
            if crop == bounds {
                source = request.image
            } else if let cropped = request.image.cropping(to: crop) {
                source = cropped
            } else {
                throw RenderError.allocationFailed
            }
            if !framed && edits.annotations.isEmpty {
                return try resizedIfNeeded(source, output: request.output, budget: budget)
            }
            let context = try makeContext(width: width, height: height, source: request.image, budget: budget)
            let canvas = CGRect(x: 0, y: 0, width: width, height: height)
            let destination = CGRect(x: padding, y: padding, width: source.width, height: source.height)
            if framed {
                guard let url = request.backgroundURL else { throw RenderError.missingBackground }
                guard let backgroundSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    throw RenderError.invalidBackground
                }
                // Decode a bounded background: it is decorative and the sole resampled layer.
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                               kCGImageSourceCreateThumbnailWithTransform: true,
                                               kCGImageSourceThumbnailMaxPixelSize: min(4096, max(width, height))]
                guard let background = CGImageSourceCreateThumbnailAtIndex(backgroundSource, 0, options as CFDictionary) else {
                    throw RenderError.invalidBackground
                }
                let scale = max(CGFloat(width) / CGFloat(background.width), CGFloat(height) / CGFloat(background.height))
                let backgroundRect = CGRect(x: (CGFloat(width) - CGFloat(background.width) * scale) / 2,
                                            y: (CGFloat(height) - CGFloat(background.height) * scale) / 2,
                                            width: CGFloat(background.width) * scale, height: CGFloat(background.height) * scale)
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(canvas)
                context.interpolationQuality = .high
                context.draw(background, in: backgroundRect)
            }
            let radius = framed ? min(CGFloat(style.cornerRadius), min(destination.width, destination.height) / 2) : 0
            let outline = CGPath(roundedRect: destination, cornerWidth: radius, cornerHeight: radius, transform: nil)
            let castsShadow = framed && style.shadow > 0
            let redactionAnnotations = edits.annotations.filter { $0.kind == .redact }
            context.saveGState()
            if castsShadow {
                context.setShadow(offset: CGSize(width: 0, height: -style.shadow / 3), blur: style.shadow,
                                  color: CGColor(gray: 0, alpha: 0.35))
                // Shadow the actual clipped source + annotations, just like the
                // preview. A filled silhouette would become an opaque black
                // matte behind translucent source pixels.
                context.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            context.saveGState()
            context.addPath(outline)
            context.clip()
            // ScreenCaptureKit window images retain fractional alpha around
            // vibrancy, type and rounded edges. If the decorative background
            // shows through those pixels, the exact same capture looks
            // different (and its text fringes pick up the background colour)
            // as soon as padding is enabled. Treat the screenshot itself as
            // the white-backed card that a raw PNG is normally presented on;
            // only the padding is decorative.
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(destination)
            context.interpolationQuality = .none
            context.draw(source, in: destination)
            // Original-image top-left coordinates become canvas bottom-left coordinates.
            AnnotationDrawing.draw(annotations: edits.annotations, in: context, crop: crop, destination: destination, includeRedactions: false)
            context.restoreGState()
            if castsShadow {
                // Sanitize the shadow's alpha input, not just the final image.
                // Apply AFTER restoring the rounded clip: clipping the mask a
                // second time could retain hidden source alpha at curved edges.
                AnnotationDrawing.draw(annotations: redactionAnnotations, in: context,
                    crop: crop, destination: destination)
                context.endTransparencyLayer()
            }
            context.restoreGState()
            // Redaction is always opaque, pixel-aligned and applied after every other layer.
            // Do not apply the antialiased corner mask a second time: partial coverage
            // could leave source pixels visible under the redaction at rounded edges.
            context.saveGState()
            context.setShouldAntialias(false)
            for annotation in redactionAnnotations {
                let rect = annotation.rect.integral.intersection(crop)
                guard !rect.isNull, !rect.isEmpty else { continue }
                context.setBlendMode(.copy)
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fill(CGRect(x: destination.minX + rect.minX - crop.minX,
                                    y: destination.maxY - (rect.maxY - crop.minY),
                                    width: rect.width, height: rect.height))
            }
            context.restoreGState()
            guard let image = context.makeImage() else { throw RenderError.allocationFailed }
            let redactions = redactionAnnotations.compactMap { annotation -> CGRect? in
                let covered = annotation.rect.integral.intersection(crop)
                guard !covered.isNull, !covered.isEmpty else { return nil }
                return CGRect(x: CGFloat(padding) + covered.minX - crop.minX,
                              y: CGFloat(padding) + covered.minY - crop.minY,
                              width: covered.width, height: covered.height)
            }
            return try resizedIfNeeded(image, output: request.output, redactions: redactions, budget: budget)
        }
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        try autoreleasepool {
            let data = NSMutableData()
            guard let encoder = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                throw RenderError.encodingFailed
            }
            // Deliberately supply only the flattened CGImage, never source image
            // properties, editor records, thumbnails or an embedded original.
            CGImageDestinationAddImage(encoder, image, nil)
            guard CGImageDestinationFinalize(encoder) else { throw RenderError.encodingFailed }
            return data as Data
        }
    }

    private static func makeContext(width: Int, height: Int, source: CGImage, budget: WorkingSetBudget) throws -> CGContext {
        let sourceBytes = try budget.admitSource(bytesPerRow: source.bytesPerRow, height: source.height)
        let componentBits = source.bitsPerComponent > 8 ? 16 : 8
        // Bound source + two output buffers (native and smaller-share) + bounded
        // decorative decode. Float/EDR inputs are explicitly flattened to a
        // tagged integer RGB image; this does not claim EDR display equivalence.
        let rowBytes = width.multipliedReportingOverflow(by: componentBits == 16 ? 8 : 4)
        guard !rowBytes.overflow else { throw RenderError.imageTooLarge }
        let outputBytes = try budget.admitSource(bytesPerRow: rowBytes.partialValue, height: height)
        try budget.admitBitmap(sourceBytes: sourceBytes, outputBytes: outputBytes)
        let space = source.colorSpace?.model == .rgb ? source.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: componentBits,
            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RenderError.allocationFailed
        }
        return context
    }

    private static func resizedIfNeeded(_ image: CGImage, output: RenderOutput, redactions: [CGRect] = [], budget: WorkingSetBudget) throws -> CGImage {
        guard case .smallerShare(let limit) = output, max(image.width, image.height) > limit else { return image }
        try Task.checkCancellation()
        let scale = CGFloat(limit) / CGFloat(max(image.width, image.height))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let context = try makeContext(width: width, height: height, source: image, budget: budget)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Resampling mixes edge pixels. Reapply redactions on the final integer
        // output grid so no boundary becomes translucent or partly unredacted.
        context.setShouldAntialias(false)
        context.setBlendMode(.copy)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        let sx = CGFloat(width) / CGFloat(image.width), sy = CGFloat(height) / CGFloat(image.height)
        for covered in redactions {
            let left = floor(covered.minX * sx), right = ceil(covered.maxX * sx)
            let top = floor(covered.minY * sy), bottom = ceil(covered.maxY * sy)
            context.fill(CGRect(x: left, y: CGFloat(height) - bottom, width: right - left, height: bottom - top))
        }
        guard let result = context.makeImage() else { throw RenderError.allocationFailed }
        return result
    }

    private static func finite(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].allSatisfy(\.isFinite)
    }

}
