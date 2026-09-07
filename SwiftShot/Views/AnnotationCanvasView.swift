import SwiftUI

/// A lightweight preview. Exports render the same source-pixel annotations off the UI actor.
struct AnnotationCanvasView: View {
    let annotations: [CaptureAnnotation]
    let crop: CGRect

    var body: some View {
        Canvas { context, size in
            let sx = size.width / crop.width, sy = size.height / crop.height
            func point(_ value: CGPoint) -> CGPoint {
                CGPoint(x: (value.x - crop.minX) * sx, y: (value.y - crop.minY) * sy)
            }
            for annotation in annotations.filter({ $0.kind != .redact }) + annotations.filter({ $0.kind == .redact }) {
                let start = point(annotation.start), end = point(annotation.end)
                let color = Color(red: annotation.color.red, green: annotation.color.green,
                                  blue: annotation.color.blue, opacity: annotation.color.alpha)
                let width = annotation.lineWidth * sx
                let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                  width: abs(end.x - start.x), height: abs(end.y - start.y))
                switch annotation.kind {
                case .redact:
                    let covered = annotation.rect.integral.intersection(crop)
                    if !covered.isNull {
                        let origin = point(covered.origin)
                        let pixels = CGRect(x: origin.x, y: origin.y, width: covered.width * sx, height: covered.height * sy)
                        context.fill(Path(pixels), with: .color(.black), style: FillStyle(antialiased: false))
                    }
                case .rectangle:
                    context.stroke(Path(rect), with: .color(color), style: StrokeStyle(lineWidth: width, lineJoin: .round))
                case .arrow:
                    let angle = atan2(end.y - start.y, end.x - start.x)
                    let length = max(12 * sx, width * 3)
                    var path = Path()
                    path.move(to: start); path.addLine(to: end)
                    path.move(to: CGPoint(x: end.x - length * cos(angle - CGFloat.pi / 6), y: end.y - length * sin(angle - CGFloat.pi / 6)))
                    path.addLine(to: end)
                    path.addLine(to: CGPoint(x: end.x - length * cos(angle + CGFloat.pi / 6), y: end.y - length * sin(angle + CGFloat.pi / 6)))
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                case .text:
                    context.draw(Text(annotation.text).font(.custom("Helvetica", size: annotation.fontSize * sy)).foregroundColor(color), at: start, anchor: .topLeading)
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
