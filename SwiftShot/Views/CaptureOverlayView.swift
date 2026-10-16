import SwiftUI
import AppKit

struct CaptureOverlayView: View {
    let screen: FrozenScreen
    let session: OverlaySession
    /// Opt-in layout evidence for process-local native-event tests.
    let controlFrameObserver: ((CaptureControlFrames) -> Void)?
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
    @Environment(\.colorScheme) private var colorScheme

    init(screen: FrozenScreen, session: OverlaySession,
         controlFrameObserver: ((CaptureControlFrames) -> Void)? = nil) {
        self.screen = screen
        self.session = session
        self.controlFrameObserver = controlFrameObserver
    }

    private var screenSize: CGSize { screen.frame.size }
    private var sourceImage: CGImage { document?.image ?? screen.image }
    private var pixelSize: CGSize { CGSize(width: sourceImage.width, height: sourceImage.height) }
    private var desktopImageFrame: CGRect {
        OverlayGeometry.imageFrame(imageSize: CGSize(width: screen.image.width, height: screen.image.height), screenSize: screenSize)
    }
    private var imageFrame: CGRect {
        let native = session.imagePlacement ?? desktopImageFrame
        guard document != nil, session.cropMode else { return document != nil ? native : desktopImageFrame }
        return editorLayout.fittedCanvas(size: native.size)
    }
    private var document: CaptureDocument? { session.activeScreenID == screen.id ? session.document : nil }
    private var crop: CGRect? { selection.map(toPixels) ?? document?.edits.crop }
    private var sourceFrame: CGRect? { crop.map(toPoints) ?? hoveredWindow?.frame }
    private var isStyled: Bool { document != nil && !session.effectiveStyle.backgroundID.isEmpty && !session.cropMode }

    private var canvasFrame: CGRect? {
        guard let sourceFrame else { return nil }
        guard document != nil, !session.cropMode else { return sourceFrame }
        let padding = isStyled ? CGFloat(session.effectiveStyle.padding.rounded()) * imageFrame.width / pixelSize.width : 0
        return editorLayout.fittedCanvas(size: sourceFrame.insetBy(dx: -padding, dy: -padding).size)
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

    private var toolbarAnchor: CGPoint {
        editorLayout.toolbarFrame(manualOrigin: toolbarOrigin).origin
    }

    private var editorLayout: CaptureEditorLayout { CaptureEditorLayout(screen: screenSize, topInset: toolbarTopInset) }
    private var inspectorFrame: CGRect { editorLayout.inspector }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if document != nil {
                Color(white: colorScheme == .dark ? 0.12 : 0.92)
                if session.cropMode {
                    Image(decorative: sourceImage, scale: 1).resizable().interpolation(.none)
                        .frame(width: imageFrame.width, height: imageFrame.height)
                        .position(x: imageFrame.midX, y: imageFrame.midY)
                        .opacity(0.3).accessibilityHidden(true)
                }
            } else if !screen.isLive {
                Color.black
                Image(decorative: screen.image, scale: 1)
                .resizable().interpolation(.none)
                .frame(width: desktopImageFrame.width, height: desktopImageFrame.height)
                .position(x: desktopImageFrame.midX, y: desktopImageFrame.midY)
                .accessibilityHidden(true)
            }
            if document == nil { Color.black.opacity(screen.isLive ? 0.08 : 0.35) }
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
            if document != nil, let canvasFrame {
                outputBoundary(canvasFrame)
            }
            if let annotation = draftAnnotation ?? session.selectedAnnotation, session.annotationTool == nil, document != nil {
                annotationChrome(annotation)
            }
            if let pointer, document == nil, !screen.isLive { magnifier(at: pointer) }
            if let document, canvasFrame != nil {
                toolbar(document: document)
            } else {
                instruction
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .coordinateSpace(name: "SwiftShotCaptureOverlay")
        .clipped()
        .preferredColorScheme(nil)
        .background { presentationObserver }
        .onPreferenceChange(CaptureControlFramePreferenceKey.self) { frames in
            controlFrameObserver?(frames)
        }
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
        let sourceLayer = ZStack {
            Image(decorative: image, scale: 1).resizable().interpolation(.none)
            AnnotationCanvasView(annotations: previewAnnotations.filter { $0.kind != .redact }, crop: crop)
        }
        .frame(width: screenshot.width, height: screenshot.height)
        .clipShape(RoundedRectangle(cornerRadius: isStyled ? CGFloat(session.effectiveStyle.cornerRadius) * screenshot.width / crop.width : 0))
        let cardLayer = ZStack {
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
            if !isStyled {
                CaptureTransparencyGrid()
                    .frame(width: canvas.width, height: canvas.height)
                    .position(x: canvas.midX, y: canvas.midY)
            }
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
                    sourceLayer
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
                // The opaque card is intentionally above the source-alpha
                // shadow. It stabilizes translucent text without turning the
                // entire rounded card into a shadow silhouette.
                cardLayer.position(x: screenshot.midX, y: screenshot.midY)
            } else {
                // Raw/no-shadow preview keeps its original ungrouped path.
                if isStyled {
                    cardLayer.position(x: screenshot.midX, y: screenshot.midY)
                } else {
                    sourceLayer.position(x: screenshot.midX, y: screenshot.midY)
                }
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
            .accessibilityLabel(document == nil ? (session.selectionPurpose == .scrolling ?
                "Frozen screen. Drag to select the scrolling area." :
                (screen.isLive ? "Live windows. Click to capture now." : "Frozen screen. Drag to select a region.")) : "Screenshot canvas")
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
            Rectangle().strokeBorder(.black.opacity(0.9), lineWidth: 3)
                .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
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

    /// These strokes are editor chrome only, outside the bitmap/export pipeline.
    /// Both light and dark edges remain visible regardless of the image content.
    private func outputBoundary(_ rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().strokeBorder(.black.opacity(0.9), lineWidth: 3)
                .overlay { Rectangle().strokeBorder(.white, lineWidth: 1) }
                .frame(width: rect.width, height: rect.height)
                .captureControlFrame("Output Bounds", enabled: controlFrameObserver != nil)
                .position(x: rect.midX, y: rect.midY)
            Text(session.cropMode ? "Crop · Drag edges to resize" : "Output · PNG")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: editorLayout.workspace.width, alignment: .leading)
                .position(x: editorLayout.workspace.midX, y: toolbarTopInset + 10)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(session.cropMode ? "Crop boundary" : "PNG output boundary")
    }

    private var instruction: some View {
        HStack(spacing: 12) {
            Image(systemName: session.mode == .window ? "macwindow" : "viewfinder").font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.document == nil ? session.selectionTitle
                     : "Editing on another display").font(.system(size: 13, weight: .semibold))
                Text(session.status.isEmpty ? (session.selectionPurpose == .scrolling ? session.selectionGuidance :
                    (screen.isLive ? "Live selector · Captured at click · Space for Region · Esc cancels" : session.selectionGuidance)) : session.status)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if screen.isLive && session.selectionPurpose == .standard {
                Button("Refresh Windows") { session.actions.switchMode(.window) }
                    .buttonStyle(CaptureButtonStyle()).controlSize(.small)
            }
            Button { session.onCancel() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)) }
                .buttonStyle(CaptureButtonStyle(compact: true)).accessibilityLabel("Cancel Capture")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .captureChrome(capsule: true)
        .position(x: screenSize.width / 2, y: max(50, screenSize.height - 62))
    }

    private func toolbar(document: CaptureDocument) -> some View {
        ZStack(alignment: .topLeading) {
            let frame = editorLayout.toolbarFrame(manualOrigin: toolbarOrigin)
            toolbarPrimary(document: document)
                .frame(width: frame.width)
                .captureControlFrame("Editor Toolbar", enabled: controlFrameObserver != nil)
                .position(x: frame.midX, y: frame.midY)
            if session.activePopover != nil || textAnchor != nil || !session.status.isEmpty {
                inspector(document: document)
                    .transition(.opacity)
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .onAppear { if toolbarOrigin == nil { toolbarOrigin = toolbarAnchor } }
    }

    private func inspector(document: CaptureDocument) -> some View {
        let frame = inspectorFrame
        let textRowHeight: CGFloat = textAnchor != nil ? 56 : 0
        let statusRowHeight: CGFloat = !session.status.isEmpty ? 56 : 0
        let supportingRowsHeight = textRowHeight + statusRowHeight
        let rowGap: CGFloat = supportingRowsHeight > 0 ? 8 : 0
        // Keep the viewport's size explicit. SwiftUI otherwise proposes an
        // unconstrained height to a ScrollView, which can leave a stale
        // document clip after a text/status row is inserted or removed.
        let viewportHeight = max(120, frame.height - supportingRowsHeight - rowGap)
        let panelHeight = min(frame.height, viewportHeight + supportingRowsHeight + rowGap)
        return VStack(spacing: 8) {
            if session.activePopover != nil {
                ScrollView {
                    OverlayInspectorView(session: session, document: document, width: frame.width,
                        reportsControlFrames: controlFrameObserver != nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: frame.width, height: viewportHeight, alignment: .topLeading)
                .scrollIndicators(.automatic)
            }
            supportingDetails(document: document)
        }
        .frame(width: frame.width, height: panelHeight, alignment: .topLeading)
        .captureControlFrame("Editor Inspector", enabled: controlFrameObserver != nil)
        .position(x: frame.midX, y: frame.midY)
        .captureGlassGroup()
    }

    private func toolbarPrimary(document: CaptureDocument) -> some View {
        let padding = session.effectiveStyle.backgroundID.isEmpty ? 0 : Int(session.effectiveStyle.padding.rounded())
        return VStack(spacing: 8) {
            CaptureToolbarView(session: session, document: document,
                reportsControlFrames: controlFrameObserver != nil).frame(height: 50)
            HStack(spacing: 7) {
                Image(systemName: "line.3.horizontal").font(.system(size: 10))
                Text("\(Int(document.edits.crop.width) + padding * 2) × \(Int(document.edits.crop.height) + padding * 2) px · PNG")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity).frame(height: 22)
            .captureChrome(capsule: true)
            .contentShape(Rectangle())
            .help("Drag horizontally to move the toolbar below the image")
            .accessibilityLabel("Output dimensions. Drag horizontally to move the toolbar.")
        }
        .overlay {
            GeometryReader { geometry in
                toolbarDragHandle(frame: geometry.frame(in: .named("SwiftShotCaptureOverlay")))
                    .frame(height: 22)
                    .offset(y: 58)
            }
        }
    }

    private func supportingDetails(document: CaptureDocument) -> some View {
        Group {
            if textAnchor != nil {
                HStack {
                    TextField("Enter text", text: $textValue).textFieldStyle(.roundedBorder)
                        .focused($textFocused).onSubmit(addText)
                        .onExitCommand { textAnchor = nil; textValue = ""; textFocused = false }
                    Button("Add", action: addText).disabled(textValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button { textAnchor = nil; textValue = "" } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cancel Text")
                        .captureControlFrame("Cancel Text", enabled: controlFrameObserver != nil)
                }
                .padding(.horizontal, 12).frame(height: 48)
                .captureChrome(capsule: true)
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
                .captureChrome(capsule: true)
                .help(session.status)
                .accessibilityLabel(session.status)
            }
        }
        .buttonStyle(CaptureButtonStyle())
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
                        toolbarOrigin = editorLayout.toolbarFrame(manualOrigin: destination).origin
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

/// A stable workspace is reserved even with the toolbox closed. Presentation
/// state must never obscure or reframe the image, including a full-display crop.
struct CaptureEditorLayout {
    let workspace: CGRect
    let inspector: CGRect
    let toolbar: CGRect
    private let screen: CGSize

    init(screen: CGSize, topInset: CGFloat) {
        self.screen = screen
        let inspectorWidth = min(360, max(300, screen.width * 0.27))
        let toolbarWidth = min(428, screen.width - 28)
        toolbar = CGRect(x: (screen.width - toolbarWidth) / 2,
                         y: screen.height - 94, width: toolbarWidth, height: 80)
        let top = topInset + 38
        inspector = CGRect(x: screen.width - inspectorWidth - 14, y: topInset + 32,
            width: inspectorWidth, height: min(380, max(120, toolbar.minY - topInset - 46)))
        workspace = CGRect(x: 24, y: top, width: max(1, inspector.minX - 48),
                           height: max(1, toolbar.minY - top - 24))
    }

    func fittedCanvas(size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(1, workspace.width / size.width, workspace.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: workspace.midX - fitted.width / 2, y: workspace.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    func toolbarFrame(manualOrigin: CGPoint?) -> CGRect {
        guard let manualOrigin else { return toolbar }
        return CGRect(x: min(max(14, manualOrigin.x), screen.width - toolbar.width - 14),
                      y: toolbar.minY, width: toolbar.width, height: toolbar.height)
    }
}

/// Transparency has a visible meaning in the editor instead of revealing the
/// dimmed desktop. This view is never passed to ImageRenderer or export services.
private struct CaptureTransparencyGrid: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.88)))
            let cell: CGFloat = 8
            for row in 0..<Int(ceil(size.height / cell)) {
                for column in 0..<Int(ceil(size.width / cell)) where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell,
                        width: cell, height: cell)), with: .color(Color(white: 0.74)))
                }
            }
        }
        .clipped().accessibilityHidden(true)
    }
}

typealias CaptureControlFrames = [String: [CGRect]]

private struct CaptureControlFramePreferenceKey: PreferenceKey {
    static let defaultValue: CaptureControlFrames = [:]

    static func reduce(value: inout CaptureControlFrames, nextValue: () -> CaptureControlFrames) {
        for (label, frames) in nextValue() {
            value[label, default: []].append(contentsOf: frames)
        }
    }
}

extension View {
    @ViewBuilder
    func captureControlFrame(_ label: String, enabled: Bool) -> some View {
        if enabled {
            background {
                GeometryReader { geometry in
                    Color.clear
                        .preference(key: CaptureControlFramePreferenceKey.self,
                            value: [label: [geometry.frame(in: .named("SwiftShotCaptureOverlay"))]])
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        } else {
            self
        }
    }
}
