import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pixel geometry is shared by preview and export. Only backgrounds are rescaled.
actor ImageRenderer: CaptureRendering {
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
            guard [style.padding, style.cornerRadius, style.shadow].allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 16_384 }) else {
                throw RenderError.invalidGeometry
            }
            let padding = framed ? Int(style.padding.rounded()) : 0
            let width = Int(crop.width) + padding * 2
            let height = Int(crop.height) + padding * 2
            // Bound each axis and total allocation before decoding or allocating bitmap memory.
            guard width <= 32_768, height <= 32_768, width * height <= 64_000_000 else {
                throw RenderError.imageTooLarge
            }
            for annotation in edits.annotations {
                guard [annotation.start.x, annotation.start.y, annotation.end.x, annotation.end.y,
                       annotation.lineWidth, annotation.fontSize].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
                      annotation.lineWidth > 0, annotation.fontSize > 0, annotation.fontSize <= 4096,
                      annotation.text.utf8.count <= 100_000,
                      [annotation.color.red, annotation.color.green, annotation.color.blue, annotation.color.alpha]
                        .allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                    throw RenderError.invalidGeometry
                }
            }
            guard let source = request.image.cropping(to: crop),
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw RenderError.allocationFailed
            }
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
                                               kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
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
            if framed && style.shadow > 0 {
                context.saveGState()
                context.setShadow(offset: CGSize(width: 0, height: -style.shadow / 3), blur: style.shadow,
                                  color: CGColor(gray: 0, alpha: 0.35))
                context.addPath(outline)
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fillPath()
                context.restoreGState()
            }
            context.saveGState()
            context.addPath(outline)
            context.clip()
            context.interpolationQuality = .none
            context.draw(source, in: destination)
            // Original-image top-left coordinates become canvas bottom-left coordinates.
            for annotation in edits.annotations where annotation.kind != .redact {
                Self.draw(annotation, in: context, crop: crop, destination: destination)
            }
            context.restoreGState()
            // Redaction is always opaque, pixel-aligned and applied after every other layer.
            // Do not apply the antialiased corner mask a second time: partial coverage
            // could leave source pixels visible under the redaction at rounded edges.
            context.saveGState()
            context.setShouldAntialias(false)
            for annotation in edits.annotations where annotation.kind == .redact {
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
            let data = NSMutableData()
            guard let encoder = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                throw RenderError.encodingFailed
            }
            CGImageDestinationAddImage(encoder, image, nil)
            guard CGImageDestinationFinalize(encoder) else { throw RenderError.encodingFailed }
            return RenderedCapture(image: image, png: data as Data)
        }
    }

    private static func finite(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].allSatisfy(\.isFinite)
    }

    private static func draw(_ annotation: CaptureAnnotation, in context: CGContext, crop: CGRect, destination: CGRect) {
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: destination.minX + p.x - crop.minX, y: destination.maxY - (p.y - crop.minY))
        }
        let start = point(annotation.start)
        let end = point(annotation.end)
        let color = CGColor(red: annotation.color.red, green: annotation.color.green,
                            blue: annotation.color.blue, alpha: annotation.color.alpha)
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(annotation.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch annotation.kind {
        case .rectangle:
            context.stroke(CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                  width: abs(end.x - start.x), height: abs(end.y - start.y)))
        case .arrow:
            let angle = atan2(end.y - start.y, end.x - start.x)
            let length = max(12, annotation.lineWidth * 3)
            context.move(to: start)
            context.addLine(to: end)
            context.move(to: CGPoint(x: end.x - length * cos(angle - .pi / 6), y: end.y - length * sin(angle - .pi / 6)))
            context.addLine(to: end)
            context.addLine(to: CGPoint(x: end.x - length * cos(angle + .pi / 6), y: end.y - length * sin(angle + .pi / 6)))
            context.strokePath()
        case .text:
            let font = CTFontCreateWithName("Helvetica" as CFString, annotation.fontSize, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
            ]
            for (index, text) in annotation.text.components(separatedBy: .newlines).enumerated() {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
                context.textMatrix = .identity
                context.textPosition = CGPoint(x: start.x, y: start.y - CTFontGetAscent(font) - CGFloat(index) * annotation.fontSize * 1.2)
                CTLineDraw(line, context)
            }
        case .redact: break
        }
    }
}
