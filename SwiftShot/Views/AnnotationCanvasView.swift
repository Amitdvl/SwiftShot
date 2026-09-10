import SwiftUI

/// Uses the same Core Graphics/CoreText geometry as export, including redaction order.
struct AnnotationCanvasView: View {
    let annotations: [CaptureAnnotation]
    let crop: CGRect

    var body: some View {
        Canvas { context, size in
            guard crop.width > 0, crop.height > 0 else { return }
            context.withCGContext { cg in
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: size.width / crop.width, y: -size.height / crop.height)
                AnnotationDrawing.draw(annotations: annotations, in: cg, crop: crop,
                                       destination: CGRect(origin: .zero, size: crop.size))
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
