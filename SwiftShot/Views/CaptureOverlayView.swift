import SwiftUI
import AppKit

struct CaptureOverlayView: View {
    let screen: FrozenScreen
    let session: OverlaySession
    @State private var selection: CGRect?
    @State private var hoveredWindow: FrozenWindow?
    @State private var gestureOrigin: CGRect?
    @State private var dragHandle: Int?
    @State private var draftAnnotation: CaptureAnnotation?
    @State private var textAnchor: CGPoint?
    @State private var textValue = ""
    @State private var toolbarOrigin: CGPoint?
    @State private var toolbarDragOrigin: CGPoint?
    @FocusState private var textFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var screenSize: CGSize { screen.frame.size }
    private var sourceImage: CGImage { document?.image ?? screen.image }
    private var pixelSize: CGSize { CGSize(width: sourceImage.width, height: sourceImage.height) }
    private var desktopImageFrame: CGRect {
        OverlayGeometry.imageFrame(imageSize: CGSize(width: screen.image.width, height: screen.image.height), screenSize: screenSize)
    }
    private var imageFrame: CGRect { document != nil ? (session.imagePlacement ?? desktopImageFrame) : desktopImageFrame }
    private var document: CaptureDocument? { session.activeScreenID == screen.id ? session.document : nil }
    private var crop: CGRect? { selection.map(toPixels) ?? document?.edits.crop }
    private var sourceFrame: CGRect? { crop.map(toPoints) ?? hoveredWindow?.frame }
    private var isStyled: Bool { document != nil && !session.effectiveStyle.backgroundID.isEmpty && !session.cropMode }

    private var canvasFrame: CGRect? {
        guard let sourceFrame else { return nil }
        guard isStyled else { return sourceFrame }
        let padding = CGFloat(session.effectiveStyle.padding.rounded()) * imageFrame.width / pixelSize.width
        let proposed = sourceFrame.insetBy(dx: -padding, dy: -padding)
        let scale = min(1, (screenSize.width - 48) / proposed.width, (screenSize.height - 110) / proposed.height)
        let width = proposed.width * scale, height = proposed.height * scale
        return CGRect(x: min(max(24, proposed.midX - width / 2), screenSize.width - width - 24),
                      y: min(max(24, proposed.midY - height / 2), screenSize.height - height - 24), width: width, height: height)
    }

    private var screenshotFrame: CGRect? {
        guard let canvasFrame, let crop else { return sourceFrame }
        guard isStyled else { return canvasFrame }
        let padding = CGFloat(session.effectiveStyle.padding.rounded())
        let scale = canvasFrame.width / (crop.width + 2 * padding)
        return canvasFrame.insetBy(dx: padding * scale, dy: padding * scale)
    }

    private var preferredInspectorHeight: CGFloat {
        switch session.activePopover {
        case .backgrounds: 440
        case .annotations: 174
        case .more: session.mode == .ocr ? 218 : 190
        case nil: 0
        }
    }

    private var toolbarTopInset: CGFloat {
        let display = NSScreen.screens.first { $0.frame == screen.frame }
        return max(14, (display?.safeAreaInsets.top ?? 0) + 8)
    }

    private var toolbarLayout: OverlayToolbarLayout {
        OverlayToolbarLayout(screen: screenSize, topInset: toolbarTopInset,
                             inspectorHeight: preferredInspectorHeight,
                             hasTextEntry: textAnchor != nil, hasStatus: !session.status.isEmpty)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            Image(decorative: screen.image, scale: 1)
                .resizable().interpolation(.none)
                .frame(width: desktopImageFrame.width, height: desktopImageFrame.height)
                .position(x: desktopImageFrame.midX, y: desktopImageFrame.midY)
                .accessibilityHidden(true)
            Color.black.opacity(document == nil ? 0.35 : 0.56)
            if let crop, let screenshotFrame, let canvasFrame, let captured = sourceImage.cropping(to: crop) {
                selectedImage(captured, crop: crop, screenshot: screenshotFrame, canvas: canvasFrame)
            } else if let hoveredWindow, let snapshot = hoveredWindow.snapshot {
                Image(decorative: snapshot, scale: 1).resizable().interpolation(.none)
                    .frame(width: hoveredWindow.frame.width, height: hoveredWindow.frame.height)
                    .position(x: hoveredWindow.frame.midX, y: hoveredWindow.frame.midY)
            }
            gestureSurface
            if let sourceFrame, document == nil || session.cropMode {
                selectionChrome(sourceFrame)
            }
            if let document, let canvasFrame {
                toolbar(document: document, selection: canvasFrame)
            } else {
                instruction
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .clipped()
        .preferredColorScheme(nil)
        .onChange(of: session.cropMode) { _, _ in selection = nil; gestureOrigin = nil }
        .onChange(of: document?.revision) { _, _ in selection = nil }
        .onChange(of: session.annotationTool) { _, tool in
            if tool != .text { textAnchor = nil; textValue = "" }
        }
    }

    private func selectedImage(_ image: CGImage, crop: CGRect, screenshot: CGRect, canvas: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            if isStyled {
                Group {
                    if let thumbnail = session.library.thumbnail(for: session.effectiveStyle.backgroundID) {
                        Image(nsImage: thumbnail).resizable().scaledToFill()
                    } else { Rectangle().fill(Color.gray.opacity(0.6)) }
                }
                .frame(width: canvas.width, height: canvas.height).clipped()
                .position(x: canvas.midX, y: canvas.midY)
            }
            ZStack {
                Image(decorative: image, scale: 1).resizable().interpolation(.none)
                AnnotationCanvasView(annotations: ((document?.edits.annotations ?? []) + [draftAnnotation].compactMap { $0 }).filter { $0.kind != .redact }, crop: crop)
            }
            .frame(width: screenshot.width, height: screenshot.height)
            .clipShape(RoundedRectangle(cornerRadius: isStyled ? CGFloat(session.effectiveStyle.cornerRadius) * screenshot.width / crop.width : 0))
            .shadow(color: .black.opacity(isStyled ? 0.35 : 0), radius: isStyled ? CGFloat(session.effectiveStyle.shadow) * screenshot.width / crop.width : 0,
                    y: isStyled ? CGFloat(session.effectiveStyle.shadow) * screenshot.width / crop.width / 3 : 0)
            .position(x: screenshot.midX, y: screenshot.midY)
            AnnotationCanvasView(annotations: ((document?.edits.annotations ?? []) + [draftAnnotation].compactMap { $0 }).filter { $0.kind == .redact }, crop: crop)
                .frame(width: screenshot.width, height: screenshot.height)
                .position(x: screenshot.midX, y: screenshot.midY)
        }
        .allowsHitTesting(false)
    }

    private var gestureSurface: some View {
        Color.clear.contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in dragChanged(value) }
                .onEnded { value in dragEnded(value) })
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    if document == nil, session.document == nil {
                        NSCursor.crosshair.set()
                        if session.mode == .window { hoveredWindow = screen.windows.first(where: { $0.frame.contains(location) }) }
                    } else if session.annotationTool == .text { NSCursor.iBeam.set() }
                    else if session.annotationTool != nil { NSCursor.crosshair.set() }
                    else if session.cropMode, let sourceFrame {
                        if let handle = OverlayGeometry.handles(for: sourceFrame).firstIndex(where: { hypot($0.x - location.x, $0.y - location.y) < 12 }) {
                            (handle == 1 || handle == 5 ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set()
                        } else if sourceFrame.contains(location) { NSCursor.openHand.set() }
                        else { NSCursor.crosshair.set() }
                    } else { NSCursor.arrow.set() }
                case .ended: hoveredWindow = nil; NSCursor.arrow.set()
                }
            }
            .accessibilityLabel(document == nil ? "Frozen screen. Drag to select a region." : "Screenshot canvas")
    }

    private func selectionChrome(_ rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().strokeBorder(.white, lineWidth: 1)
                .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
            if document != nil {
                ForEach(Array(OverlayGeometry.handles(for: rect).enumerated()), id: \.offset) { _, point in
                    RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 7, height: 7)
                        .shadow(color: .black.opacity(0.4), radius: 1)
                        .position(point)
                }
            }
            Text("\(Int(toPixels(rect).width)) × \(Int(toPixels(rect).height))")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white).padding(.horizontal, 9).padding(.vertical, 5)
                .background(.black.opacity(0.7), in: Capsule())
                .position(x: min(max(70, rect.midX), screenSize.width - 70), y: max(16, rect.minY - 18))
        }
        .allowsHitTesting(false)
    }

    private var instruction: some View {
        HStack(spacing: 12) {
            Image(systemName: session.mode == .window ? "macwindow" : "viewfinder").font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.document == nil ? (session.mode == .window ? "Choose a window" : "Drag to capture")
                     : "Editing on another display").font(.system(size: 13, weight: .semibold))
                Text(session.status.isEmpty ? "Screen frozen · Selection stays on this display · Esc to cancel" : session.status)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button { session.onCancel() } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                .buttonStyle(.plain).accessibilityLabel("Cancel Capture")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
        .position(x: screenSize.width / 2, y: max(50, screenSize.height - 62))
    }

    private func toolbar(document: CaptureDocument, selection: CGRect) -> some View {
        let layout = toolbarLayout
        let frame = layout.frame(near: selection, manualOrigin: toolbarOrigin)
        let padding = session.effectiveStyle.backgroundID.isEmpty ? 0 : Int(session.effectiveStyle.padding.rounded())
        return VStack(spacing: 8) {
            CaptureToolbarView(session: session, document: document).frame(height: 61)
            HStack(spacing: 7) {
                Image(systemName: "line.3.horizontal").font(.system(size: 10))
                Text("\(Int(document.edits.crop.width) + padding * 2) × \(Int(document.edits.crop.height) + padding * 2) px · PNG")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity).frame(height: 22)
            .background(.regularMaterial, in: Capsule())
            .contentShape(Rectangle())
            .help("Drag to move the toolbar")
            .accessibilityLabel("Output dimensions. Drag to move the toolbar.")
            .onHover { if $0 { NSCursor.openHand.set() } else { NSCursor.arrow.set() } }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { value in
                    if toolbarDragOrigin == nil { toolbarDragOrigin = frame.origin }
                    if let origin = toolbarDragOrigin {
                        toolbarOrigin = CGPoint(x: origin.x + value.translation.width, y: origin.y + value.translation.height)
                    }
                    NSCursor.closedHand.set()
                }
                .onEnded { value in
                    if let origin = toolbarDragOrigin {
                        let destination = CGPoint(x: origin.x + value.translation.width, y: origin.y + value.translation.height)
                        toolbarOrigin = layout.frame(near: selection, manualOrigin: destination).origin
                    }
                    toolbarDragOrigin = nil
                    NSCursor.openHand.set()
                })
            if session.activePopover != nil {
                ScrollView { OverlayInspectorView(session: session, document: document) }
                    .scrollIndicators(.automatic)
                    .frame(height: layout.inspectorHeight)
                    .transition(.opacity)
            }
            if textAnchor != nil {
                HStack {
                    TextField("Enter text", text: $textValue).textFieldStyle(.roundedBorder)
                        .focused($textFocused).onSubmit(addText)
                        .onExitCommand { textAnchor = nil; textValue = ""; textFocused = false }
                    Button("Add", action: addText).disabled(textValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button { textAnchor = nil; textValue = "" } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cancel Text")
                }
                .padding(.horizontal, 12).frame(height: 48)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .onAppear { textFocused = true }
            }
            if !session.status.isEmpty {
                HStack(spacing: 7) {
                    if !session.statusIsError && session.status.hasSuffix("…") {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: session.statusIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    }
                    Text(session.status).lineLimit(2)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(session.statusIsError ? Color.orange : Color.primary)
                .padding(.horizontal, 12).frame(height: 48)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .help(session.status)
                .accessibilityLabel(session.status)
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .top)
        .position(x: frame.midX, y: frame.midY)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: session.activePopover)
    }

    private func dragChanged(_ value: DragGesture.Value) {
        guard session.document == nil || document != nil else { return }
        if let document {
            if session.cropMode {
                if gestureOrigin == nil {
                    let rect = toPoints(document.edits.crop)
                    gestureOrigin = rect
                    dragHandle = OverlayGeometry.handles(for: rect).firstIndex { hypot($0.x - value.startLocation.x, $0.y - value.startLocation.y) < 12 }
                }
                guard let origin = gestureOrigin else { return }
                if let dragHandle {
                    selection = OverlayGeometry.resized(origin, handle: dragHandle, to: value.location, in: imageFrame)
                } else if origin.contains(value.startLocation) {
                    selection = OverlayGeometry.moved(origin, by: value.translation, in: imageFrame)
                } else {
                    selection = OverlayGeometry.rectangle(from: value.startLocation, to: value.location, bounds: imageFrame)
                }
            } else if let kind = session.annotationTool, kind != .text, let screenshotFrame, screenshotFrame.contains(value.startLocation) {
                draftAnnotation = CaptureAnnotation(kind: kind, start: sourcePoint(value.startLocation), end: sourcePoint(value.location))
            }
        } else if session.mode != .window {
            selection = OverlayGeometry.rectangle(from: value.startLocation, to: value.location, bounds: imageFrame)
        }
    }

    private func dragEnded(_ value: DragGesture.Value) {
        defer { gestureOrigin = nil; dragHandle = nil; draftAnnotation = nil }
        guard session.document == nil || document != nil else { return }
        if let document {
            if session.cropMode {
                let proposed = selection
                selection = nil
                if let proposed, proposed.width >= 2, proposed.height >= 2 {
                    let pixels = toPixels(proposed)
                    document.change { $0.crop = pixels }; session.changed()
                }
            } else if let annotation = draftAnnotation, hypot(annotation.end.x - annotation.start.x, annotation.end.y - annotation.start.y) >= 2 {
                document.change { $0.annotations.append(annotation) }; session.changed()
            } else if session.annotationTool == .text, let screenshotFrame, screenshotFrame.contains(value.location) {
                textAnchor = sourcePoint(value.location)
                textValue = ""
                textFocused = true
            }
        } else {
            if session.mode == .window {
                if let window = screen.windows.first(where: { $0.frame.contains(value.location) }) {
                    session.select(window: window, on: screen)
                    hoveredWindow = nil
                }
                return
            }
            guard let selected = selection, selected.width >= 2, selected.height >= 2 else { selection = nil; return }
            selection = nil
            session.select(screen: screen, crop: toPixels(selected))
        }
    }

    private func sourcePoint(_ point: CGPoint) -> CGPoint {
        guard let frame = screenshotFrame, let crop else { return .zero }
        let p = OverlayGeometry.clamped(point, to: frame)
        return CGPoint(x: crop.minX + (p.x - frame.minX) * crop.width / frame.width,
                       y: crop.minY + (p.y - frame.minY) * crop.height / frame.height)
    }

    private func addText() {
        guard let document, let anchor = textAnchor else { return }
        let value = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let annotation = CaptureAnnotation(kind: .text, start: anchor, end: anchor, text: String(value.prefix(2000)))
        document.change { $0.annotations.append(annotation) }; session.changed()
        textAnchor = nil; textValue = ""; textFocused = false
    }

    private func toPixels(_ rect: CGRect) -> CGRect { OverlayGeometry.pixels(from: rect, imageFrame: imageFrame, pixelSize: pixelSize) }
    private func toPoints(_ rect: CGRect) -> CGRect { OverlayGeometry.points(from: rect, imageFrame: imageFrame, pixelSize: pixelSize) }
}

/// Every child has a known height, so the toolbar is bounded even on its first layout pass.
struct OverlayToolbarLayout {
    let screen: CGSize
    let topInset: CGFloat
    let size: CGSize
    let inspectorHeight: CGFloat

    init(screen: CGSize, topInset: CGFloat, inspectorHeight preferred: CGFloat, hasTextEntry: Bool, hasStatus: Bool) {
        self.screen = screen
        self.topInset = topInset
        // Toolbar + dimensions strip, then eight points between optional rows.
        let fixedHeight: CGFloat = 61 + 8 + 22 + (hasTextEntry ? 56 : 0) + (hasStatus ? 56 : 0)
        let inspectorGap: CGFloat = preferred > 0 ? 8 : 0
        inspectorHeight = min(preferred, max(0, screen.height - topInset - 14 - fixedHeight - inspectorGap))
        size = CGSize(width: min(428, screen.width - 28), height: fixedHeight + inspectorGap + inspectorHeight)
    }

    func frame(near selection: CGRect, manualOrigin: CGPoint? = nil) -> CGRect {
        let available = CGSize(width: screen.width, height: screen.height - topInset)
        let automatic = OverlayGeometry.toolbarFrame(selection: selection.offsetBy(dx: 0, dy: -topInset), size: size, screen: available)
            .offsetBy(dx: 0, dy: topInset)
        let origin = manualOrigin ?? automatic.origin
        return CGRect(x: min(max(14, origin.x), screen.width - size.width - 14),
                      y: min(max(topInset, origin.y), screen.height - size.height - 14), width: size.width, height: size.height)
    }
}
