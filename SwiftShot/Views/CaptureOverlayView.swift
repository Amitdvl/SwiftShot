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
    @State private var editingAnnotation: CaptureAnnotation?
    @State private var pointer: CGPoint?
    @State private var spaceOrigin: CGRect?
    @State private var spaceAnchor: CGPoint?
    @State private var selectionOffset: CGSize = .zero
    @State private var spaceStartingOffset: CGSize = .zero
    @State private var textAnchor: CGPoint?
    @State private var textValue = ""
    @State private var textFocusRequest = 0
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

    private var toolbarTopInset: CGFloat {
        let display = NSScreen.screens.first { $0.frame == screen.frame }
        return max(14, (display?.safeAreaInsets.top ?? 0) + 8)
    }

    private var toolbarCapacity: OverlayToolbarLayout {
        OverlayToolbarLayout(screen: screenSize, topInset: toolbarTopInset,
                             inspectorHeight: session.activePopover == nil ? 0 : .greatestFiniteMagnitude,
                             hasTextEntry: textAnchor != nil, hasStatus: !session.status.isEmpty)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !screen.isLive {
                Color.black
                Image(decorative: screen.image, scale: 1)
                .resizable().interpolation(.none)
                .frame(width: desktopImageFrame.width, height: desktopImageFrame.height)
                .position(x: desktopImageFrame.midX, y: desktopImageFrame.midY)
                .accessibilityHidden(true)
            }
            Color.black.opacity(document == nil ? (screen.isLive ? 0.08 : 0.35) : 0.56)
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
            if let annotation = draftAnnotation ?? session.selectedAnnotation, session.annotationTool == nil, document != nil {
                annotationChrome(annotation)
            }
            if let pointer, document == nil, !screen.isLive { magnifier(at: pointer) }
            if let document, let canvasFrame {
                toolbar(document: document, selection: canvasFrame)
            } else {
                instruction
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .coordinateSpace(name: "SwiftShotCaptureOverlay")
        .clipped()
        .preferredColorScheme(nil)
        .background { presentationObserver }
        .onChange(of: session.cropMode) { _, _ in selection = nil; gestureOrigin = nil }
        .onChange(of: document?.revision) { _, _ in selection = nil }
        .onChange(of: session.annotationTool) { _, tool in
            if tool != .text { textAnchor = nil; textValue = "" }
        }
    }

    @ViewBuilder private var presentationObserver: some View {
        if let document, let presented = session.actions.editorPresented {
            CapturePresentationObserver(receiptID: document.id, onPresented: presented,
                traceRunID: session.latencyTraceRunID, tracePresentation: .editor,
                traceSurface: session.latencyTraceSurfaces[screen.id])
                .frame(width: 1, height: 1).allowsHitTesting(false).accessibilityHidden(true)
        } else if document == nil, session.actions.selectorPresented != nil {
            CapturePresentationObserver(receiptID: session.presentationID,
                onPresented: { session.selectorPresented(on: screen.id) },
                traceRunID: session.latencyTraceRunID, tracePresentation: .selector,
                traceSurface: session.latencyTraceSurfaces[screen.id])
                .frame(width: 1, height: 1).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private var previewAnnotations: [CaptureAnnotation] {
        var annotations = document?.edits.annotations ?? []
        if let draftAnnotation {
            if let index = annotations.firstIndex(where: { $0.id == draftAnnotation.id }) { annotations[index] = draftAnnotation }
            else { annotations.append(draftAnnotation) }
        }
        return annotations
    }

    private func selectedImage(_ image: CGImage, crop: CGRect, screenshot: CGRect, canvas: CGRect) -> some View {
        let clippedSource = ZStack {
            // Keep the editor's card appearance identical to the exported
            // bitmap. Window captures contain translucent vibrancy and text
            // edge pixels; revealing the chosen decorative image beneath them
            // makes the preview (and formerly the export) look lower quality.
            if isStyled { Color.white }
            Image(decorative: image, scale: 1).resizable().interpolation(.none)
            AnnotationCanvasView(annotations: previewAnnotations.filter { $0.kind != .redact }, crop: crop)
        }
        .frame(width: screenshot.width, height: screenshot.height)
        .clipShape(RoundedRectangle(cornerRadius: isStyled ? CGFloat(session.effectiveStyle.cornerRadius) * screenshot.width / crop.width : 0))
        return ZStack(alignment: .topLeading) {
            if isStyled {
                ZStack {
                    // Export composites decorative alpha over white, never the
                    // frozen/dimmed desktop behind the editing canvas.
                    Color.white
                    if let thumbnail = session.library.thumbnail(for: session.effectiveStyle.backgroundID) {
                        Image(nsImage: thumbnail).resizable().scaledToFill()
                    } else { Rectangle().fill(Color.gray.opacity(0.6)) }
                }
                .frame(width: canvas.width, height: canvas.height).clipped()
                .position(x: canvas.midX, y: canvas.midY)
            }
            if isStyled && session.effectiveStyle.shadow > 0 {
                ZStack {
                    clippedSource
                    // Redact outside the rounded clip, then flatten this group
                    // BEFORE shadowing it. Hidden alpha must not cast a shadow.
                    AnnotationCanvasView(annotations: previewAnnotations.filter { $0.kind == .redact }, crop: crop)
                        .frame(width: screenshot.width, height: screenshot.height)
                }
                .frame(width: screenshot.width, height: screenshot.height)
                .compositingGroup()
                .shadow(color: .black.opacity(0.35), radius: CGFloat(session.effectiveStyle.shadow) * screenshot.width / crop.width,
                        y: CGFloat(session.effectiveStyle.shadow) * screenshot.width / crop.width / 3)
                .position(x: screenshot.midX, y: screenshot.midY)
            } else {
                // Raw/no-shadow preview keeps its original ungrouped path.
                clippedSource.position(x: screenshot.midX, y: screenshot.midY)
            }
            AnnotationCanvasView(annotations: previewAnnotations.filter { $0.kind == .redact }, crop: crop)
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
                    pointer = location
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
                case .ended: pointer = nil; hoveredWindow = nil; NSCursor.arrow.set()
                }
            }
            .accessibilityLabel(document == nil ? (screen.isLive ? "Live windows. Click to capture now." : "Frozen screen. Drag to select a region.") : "Screenshot canvas")
    }

    private func annotationChrome(_ annotation: CaptureAnnotation) -> some View {
        let rect = annotationPoints(editBounds(annotation))
        return ZStack {
            Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
            ForEach(Array(OverlayGeometry.handles(for: rect).enumerated()), id: \.offset) { _, point in
                Rectangle().fill(.white).frame(width: 7, height: 7).overlay(Rectangle().stroke(Color.accentColor))
                    .position(point)
            }
        }.allowsHitTesting(false)
    }

    private func magnifier(at point: CGPoint) -> some View {
        let pixel = CGPoint(x: (point.x - imageFrame.minX) * pixelSize.width / imageFrame.width,
            y: (point.y - imageFrame.minY) * pixelSize.height / imageFrame.height)
        let area = CGRect(x: min(max(0, floor(pixel.x) - 12), max(0, pixelSize.width - 25)),
            y: min(max(0, floor(pixel.y) - 12), max(0, pixelSize.height - 25)),
            width: min(25, pixelSize.width), height: min(25, pixelSize.height))
        let crosshair = CGPoint(x: (min(max(0, floor(pixel.x)), pixelSize.width - 1) - area.minX + 0.5) * 100 / area.width,
            y: (min(max(0, floor(pixel.y)), pixelSize.height - 1) - area.minY + 0.5) * 100 / area.height)
        return Group {
            if let detail = screen.image.cropping(to: area), area.width > 0, area.height > 0 {
                ZStack(alignment: .topLeading) {
                    Image(decorative: detail, scale: 1).resizable().interpolation(.none)
                    Rectangle().stroke(.black.opacity(0.8), lineWidth: 1).frame(width: 5, height: 5).position(crosshair)
                    Rectangle().stroke(.white, lineWidth: 1).frame(width: 7, height: 7).position(crosshair)
                }
                .frame(width: 100, height: 100).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white, lineWidth: 2))
                .shadow(radius: 8)
                .position(x: min(max(58, point.x + 80), screenSize.width - 58),
                    y: min(max(58, point.y + 80), screenSize.height - 58))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
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
            Text(screen.isLive && document == nil ? "Capture at click" : "\(Int(toPixels(rect).width)) × \(Int(toPixels(rect).height))")
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
                Text(session.status.isEmpty ? (screen.isLive ? "Live selector · Captured at click · Space for Region · Esc cancels" : "Screen frozen · Space switches mode or moves a drag · Shift constrains · Esc cancels") : session.status)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if screen.isLive {
                Button("Refresh Windows") { session.actions.switchMode(.window) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            Button { session.onCancel() } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                .buttonStyle(.plain).accessibilityLabel("Cancel Capture")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
        .position(x: screenSize.width / 2, y: max(50, screenSize.height - 62))
    }

    private func toolbar(document: CaptureDocument, selection: CGRect) -> some View {
        OverlayToolbarPlacement(screen: screenSize, topInset: toolbarTopInset,
            selection: selection, manualOrigin: toolbarOrigin) {
            toolbarContent(document: document)
                .frame(width: toolbarCapacity.size.width)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: session.activePopover)
    }

    private func toolbarContent(document: CaptureDocument) -> some View {
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
            if session.activePopover != nil {
                CappedInspectorLayout(maximumHeight: toolbarCapacity.inspectorHeight) {
                    ViewThatFits(in: .vertical) {
                        OverlayInspectorView(session: session, document: document)
                            .fixedSize(horizontal: false, vertical: true)
                        ScrollView {
                            OverlayInspectorView(session: session, document: document)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .scrollIndicators(.automatic)
                    }
                }
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
                .task(id: textFocusRequest) {
                    // The field must enter the responder hierarchy before requesting focus.
                    // A new placement also needs a false → true transition when the row already exists.
                    textFocused = false
                    await Task.yield()
                    guard !Task.isCancelled, textAnchor != nil else { return }
                    textFocused = true
                }
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
        .overlay {
            GeometryReader { geometry in
                // Only the dimensions strip receives this gesture. Measuring in
                // an overlay preserves the content's intrinsic layout while
                // supplying its complete current frame for drag-end clamping.
                toolbarDragHandle(frame: geometry.frame(in: .named("SwiftShotCaptureOverlay")))
                    .frame(height: 22)
                    .offset(y: 61 + 8)
            }
        }
    }

    private func toolbarDragHandle(frame: CGRect) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .accessibilityHidden(true)
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
                        toolbarOrigin = OverlayToolbarLayout.frame(screen: screenSize, topInset: toolbarTopInset,
                            size: frame.size, near: .zero, manualOrigin: destination).origin
                    }
                    toolbarDragOrigin = nil
                    NSCursor.openHand.set()
                })
    }

    private func dragChanged(_ value: DragGesture.Value) {
        guard session.document == nil || document != nil else { return }
        session.isDragging = true
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
                let start = sourcePoint(value.startLocation)
                var end = sourcePoint(value.location)
                if session.shiftHeld { end = constrainedEnd(start: start, end: end, arrow: kind == .arrow) }
                draftAnnotation = CaptureAnnotation(kind: kind, start: start, end: end)
            } else if session.annotationTool == nil, let screenshotFrame, screenshotFrame.contains(value.startLocation) {
                let start = sourcePoint(value.startLocation)
                if gestureOrigin == nil {
                    gestureOrigin = .zero
                    if let selected = session.selectedAnnotation {
                        dragHandle = OverlayGeometry.handles(for: annotationPoints(editBounds(selected)))
                            .firstIndex { hypot($0.x - value.startLocation.x, $0.y - value.startLocation.y) < 10 }
                        if dragHandle != nil { editingAnnotation = selected }
                    }
                    if editingAnnotation == nil {
                        editingAnnotation = document.edits.annotations.reversed().first { AnnotationGeometry.hitTest(start, annotation: $0,
                            tolerance: 6 * document.edits.crop.width / screenshotFrame.width) }
                    }
                    session.selectedAnnotationID = editingAnnotation?.id
                }
                if let original = editingAnnotation, hypot(value.translation.width, value.translation.height) >= 0.5 {
                    let end = sourcePoint(value.location)
                    if let dragHandle {
                        draftAnnotation = original.resized(to: OverlayGeometry.resized(editBounds(original),
                            handle: dragHandle, to: end, in: document.edits.crop))
                    } else {
                        let bounds = AnnotationGeometry.bounds(for: original)
                        let moved = OverlayGeometry.moved(bounds, by: CGSize(width: end.x - start.x, height: end.y - start.y), in: document.edits.crop)
                        draftAnnotation = original.translated(by: CGSize(width: moved.minX - bounds.minX, height: moved.minY - bounds.minY))
                    }
                }
            }
        } else if session.mode != .window {
            if session.spaceHeld, let selection {
                if spaceOrigin == nil { spaceOrigin = selection; spaceAnchor = value.location; spaceStartingOffset = selectionOffset }
                if let origin = spaceOrigin, let anchor = spaceAnchor {
                    let moved = OverlayGeometry.moved(origin, by: CGSize(width: value.location.x - anchor.x, height: value.location.y - anchor.y), in: imageFrame)
                    self.selection = moved
                    selectionOffset = CGSize(width: spaceStartingOffset.width + moved.minX - origin.minX,
                        height: spaceStartingOffset.height + moved.minY - origin.minY)
                }
            } else {
                let start = CGPoint(x: value.startLocation.x + selectionOffset.width, y: value.startLocation.y + selectionOffset.height)
                spaceOrigin = nil; spaceAnchor = nil
                let end = session.shiftHeld ? constrainedEnd(start: start, end: value.location, arrow: false) : value.location
                selection = OverlayGeometry.rectangle(from: start, to: end, bounds: imageFrame)
            }
        }
    }

    private func dragEnded(_ value: DragGesture.Value) {
        defer { gestureOrigin = nil; dragHandle = nil; draftAnnotation = nil; editingAnnotation = nil
            spaceOrigin = nil; spaceAnchor = nil; selectionOffset = .zero; spaceStartingOffset = .zero; session.isDragging = false }
        guard session.document == nil || document != nil else { return }
        if let document {
            if session.cropMode {
                let proposed = selection
                selection = nil
                if let proposed, proposed.width >= 2, proposed.height >= 2 {
                    let pixels = toPixels(proposed)
                    document.change { $0.crop = pixels }; session.changed()
                }
            } else if let original = editingAnnotation, let updated = draftAnnotation {
                document.updateAnnotation(id: original.id) { $0 = updated }; session.changed()
            } else if session.annotationTool == .numberedStep, let screenshotFrame, screenshotFrame.contains(value.location) {
                let point = sourcePoint(value.location)
                let previous = document.edits.annotations.filter { $0.kind == .numberedStep }.compactMap { Int($0.text) }.max() ?? 0
                guard previous < Int.max else {
                    session.status = "The largest step label is too large. Edit it before adding another step."
                    session.statusIsError = true
                    return
                }
                let next = max(0, previous) + 1
                let annotation = CaptureAnnotation(kind: .numberedStep, start: point, end: point, text: String(next))
                document.change { $0.annotations.append(annotation) }; session.changed()
            } else if let annotation = draftAnnotation, hypot(annotation.end.x - annotation.start.x, annotation.end.y - annotation.start.y) >= 2 {
                document.change { $0.annotations.append(annotation) }; session.changed()
            } else if session.annotationTool == .text, let screenshotFrame, screenshotFrame.contains(value.location) {
                textFocused = false
                textAnchor = sourcePoint(value.location)
                textValue = ""
                textFocusRequest += 1
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

    private func constrainedEnd(start: CGPoint, end: CGPoint, arrow: Bool) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        if arrow {
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
        }
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
    }

    private func annotationPoints(_ rect: CGRect) -> CGRect {
        guard let frame = screenshotFrame, let crop else { return .zero }
        return CGRect(x: frame.minX + (rect.minX - crop.minX) * frame.width / crop.width,
            y: frame.minY + (rect.minY - crop.minY) * frame.height / crop.height,
            width: rect.width * frame.width / crop.width, height: rect.height * frame.height / crop.height)
    }

    private func editBounds(_ annotation: CaptureAnnotation) -> CGRect {
        // Arrow handles represent endpoints, not the extra stroke/arrowhead bounds.
        annotation.kind == .arrow ? annotation.rect : AnnotationGeometry.bounds(for: annotation)
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

/// Measures the fitting candidate before proposing a capped viewport. The same
/// layout pass selects scrolling only for overflowing content, so no invisible
/// fixed-height tail or asynchronous measurement state intercepts canvas input.
private struct CappedInspectorLayout: Layout {
    let maximumHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let inspector = subviews.first else { return .zero }
        let natural = inspector.sizeThatFits(ProposedViewSize(width: 380, height: nil))
        return CGSize(width: 380, height: min(natural.height, maximumHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// Positions the actual toolbar content without a preference/State feedback pass.
/// The full-screen layout itself adds no hit shape or background over the canvas.
private struct OverlayToolbarPlacement: Layout {
    let screen: CGSize
    let topInset: CGFloat
    let selection: CGRect
    let manualOrigin: CGPoint?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { screen }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let toolbar = subviews.first else { return }
        let width = min(428, screen.width - 28)
        let content = toolbar.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let frame = OverlayToolbarLayout.frame(screen: screen, topInset: topInset,
            size: CGSize(width: width, height: content.height), near: selection, manualOrigin: manualOrigin)
        toolbar.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
            anchor: .topLeading, proposal: ProposedViewSize(width: frame.width, height: frame.height))
    }
}

/// Reserves fixed chrome and optional rows before capping the inspector's content.
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
        Self.frame(screen: screen, topInset: topInset, size: size, near: selection, manualOrigin: manualOrigin)
    }

    static func frame(screen: CGSize, topInset: CGFloat, size: CGSize,
                      near selection: CGRect, manualOrigin: CGPoint? = nil) -> CGRect {
        let available = CGSize(width: screen.width, height: screen.height - topInset)
        let automatic = OverlayGeometry.toolbarFrame(selection: selection.offsetBy(dx: 0, dy: -topInset), size: size, screen: available)
            .offsetBy(dx: 0, dy: topInset)
        let origin = manualOrigin ?? automatic.origin
        return CGRect(x: min(max(14, origin.x), screen.width - size.width - 14),
                      y: min(max(topInset, origin.y), screen.height - size.height - 14), width: size.width, height: size.height)
    }
}
