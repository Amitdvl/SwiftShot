import CoreGraphics
import CoreText
import Foundation

/// One CoreText layout is used by the canvas, selection bounds and flattened
/// exports. Coordinates and font sizes are original-image pixels, not points.
struct AnnotationTextLayout {
    let lines: [CTLine]
    let ascent: CGFloat
    let lineHeight: CGFloat
    let size: CGSize

    init(text: String, fontSize: CGFloat, color: AnnotationColor) {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        ]
        lines = text.components(separatedBy: .newlines).map {
            CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes))
        }
        ascent = CTFontGetAscent(font)
        lineHeight = max(fontSize * 1.2, ascent + CTFontGetDescent(font) + CTFontGetLeading(font))
        size = CGSize(width: max(1, lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }.max() ?? 0),
                      height: max(1, CGFloat(lines.count - 1) * lineHeight + ascent + CTFontGetDescent(font)))
    }

    /// The caller's coordinate system is top-left/y-down.
    func draw(in context: CGContext, at origin: CGPoint) {
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        for (index, line) in lines.enumerated() {
            context.textPosition = CGPoint(x: 0, y: -ascent - CGFloat(index) * lineHeight)
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }
}

enum AnnotationGeometry {
    static func stepRadius(for annotation: CaptureAnnotation) -> CGFloat {
        max(annotation.fontSize * 0.8, annotation.lineWidth * 2)
    }

    static func bounds(for annotation: CaptureAnnotation) -> CGRect {
        switch annotation.kind {
        case .text:
            return CGRect(origin: annotation.start, size: AnnotationTextLayout(text: annotation.text,
                fontSize: annotation.fontSize, color: annotation.color).size)
        case .numberedStep:
            let radius = stepRadius(for: annotation)
            return CGRect(x: annotation.start.x - radius, y: annotation.start.y - radius,
                          width: radius * 2, height: radius * 2)
        case .arrow:
            return arrowPath(for: annotation).boundingBoxOfPath.insetBy(dx: -annotation.lineWidth / 2, dy: -annotation.lineWidth / 2)
        default:
            return annotation.rect
        }
    }

    static func arrowPath(for annotation: CaptureAnnotation) -> CGPath {
        let start = annotation.start, end = annotation.end
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(12, annotation.lineWidth * 3)
        let path = CGMutablePath()
        path.move(to: start)
        path.addLine(to: end)
        path.move(to: CGPoint(x: end.x - length * cos(angle - .pi / 6), y: end.y - length * sin(angle - .pi / 6)))
        path.addLine(to: end)
        path.addLine(to: CGPoint(x: end.x - length * cos(angle + .pi / 6), y: end.y - length * sin(angle + .pi / 6)))
        return path
    }

    static func hitTest(_ point: CGPoint, annotation: CaptureAnnotation, tolerance: CGFloat = 6) -> Bool {
        let tolerance = max(0, tolerance)
        switch annotation.kind {
        case .arrow:
            return arrowPath(for: annotation).copy(strokingWithWidth: annotation.lineWidth + tolerance * 2,
                lineCap: .round, lineJoin: .round, miterLimit: 10).contains(point)
        case .rectangle:
            let outer = annotation.rect.insetBy(dx: -tolerance - annotation.lineWidth / 2, dy: -tolerance - annotation.lineWidth / 2)
            let inner = annotation.rect.insetBy(dx: tolerance + annotation.lineWidth / 2, dy: tolerance + annotation.lineWidth / 2)
            return outer.contains(point) && (inner.isEmpty || !inner.contains(point))
        case .numberedStep:
            return hypot(point.x - annotation.start.x, point.y - annotation.start.y) <= stepRadius(for: annotation) + tolerance
        default:
            return bounds(for: annotation).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }
}

/// Shared by preview (Canvas.withCGContext) and export. Destination uses a
/// bottom-left CGContext; all annotations remain original-image top-left pixels.
enum AnnotationDrawing {
    static func draw(annotations: [CaptureAnnotation], in context: CGContext, crop: CGRect, destination: CGRect,
                     includeRedactions: Bool = true) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: destination)
        context.translateBy(x: destination.minX, y: destination.maxY)
        context.scaleBy(x: destination.width / crop.width, y: -destination.height / crop.height)
        context.translateBy(x: -crop.minX, y: -crop.minY)

        let spotlights = annotations.filter { $0.kind == .spotlight }
        if !spotlights.isEmpty {
            context.saveGState()
            // Successive outside-hole clips dim outside the UNION of spotlight
            // rectangles, including overlapping ones (a single even-odd path would XOR).
            for annotation in spotlights {
                context.beginPath()
                context.addRect(crop)
                let covered = annotation.rect.intersection(crop)
                if !covered.isNull && !covered.isEmpty { context.addRect(covered) }
                context.clip(using: .evenOdd)
            }
            context.setFillColor(CGColor(gray: 0, alpha: 0.55))
            context.fill(crop)
            context.restoreGState()
        }
        for annotation in annotations where annotation.kind != .redact && annotation.kind != .spotlight {
            draw(annotation, in: context)
        }
        if includeRedactions {
            context.setShouldAntialias(false)
            context.setBlendMode(.copy)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            for annotation in annotations where annotation.kind == .redact {
                let covered = annotation.rect.integral.intersection(crop)
                if !covered.isNull && !covered.isEmpty { context.fill(covered) }
            }
        }
    }

    private static func draw(_ annotation: CaptureAnnotation, in context: CGContext) {
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
            context.stroke(annotation.rect)
        case .arrow:
            context.addPath(AnnotationGeometry.arrowPath(for: annotation))
            context.strokePath()
        case .text:
            AnnotationTextLayout(text: annotation.text, fontSize: annotation.fontSize, color: annotation.color)
                .draw(in: context, at: annotation.start)
        case .highlighter:
            context.setFillColor(CGColor(red: annotation.color.red, green: annotation.color.green,
                                        blue: annotation.color.blue, alpha: min(0.35, annotation.color.alpha)))
            context.fill(annotation.rect)
        case .numberedStep:
            context.fillEllipse(in: AnnotationGeometry.bounds(for: annotation))
            let label = Int(annotation.text).map { String(max(1, $0)) } ?? "1"
            let white = AnnotationColor(red: 1, green: 1, blue: 1)
            let initial = AnnotationTextLayout(text: label, fontSize: annotation.fontSize, color: white)
            let fit = min(1, AnnotationGeometry.stepRadius(for: annotation) * 1.6 / initial.size.width)
            let layout = AnnotationTextLayout(text: label, fontSize: annotation.fontSize * fit, color: white)
            layout.draw(in: context, at: CGPoint(x: annotation.start.x - layout.size.width / 2,
                                                y: annotation.start.y - layout.size.height / 2))
        case .redact, .spotlight: break
        }
    }
}
