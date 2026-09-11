import SwiftUI
import AppKit

struct CaptureToolbarView: View {
    let session: OverlaySession
    let document: CaptureDocument

    var body: some View {
        HStack(spacing: 3) {
            tool("Copy", icon: "document.on.document", shortcut: "⌘C", prominent: true) { session.commitStyle(); session.onCopy(document) }
            tool("Save", icon: "square.and.arrow.down", shortcut: "⌘S") { session.commitStyle(); session.onSave(document) }
            Divider().frame(height: 28).padding(.horizontal, 4)
            tool("Background", icon: "photo.on.rectangle", selected: session.activePopover == .backgrounds) { toggle(.backgrounds) }
            tool("Annotate", icon: "pencil.tip.crop.circle", selected: session.annotationTool != nil || session.activePopover == .annotations) { toggle(.annotations) }
            tool("Crop", icon: "crop", selected: session.cropMode) {
                session.commitStyle(); session.cropMode.toggle(); session.annotationTool = nil
                session.selectedAnnotationID = nil; session.activePopover = nil
            }
            tool("More", icon: "ellipsis", selected: session.activePopover == .more) { toggle(.more) }
        }
        .padding(7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))
        .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.22), radius: 22, y: 8)
        .disabled(session.isDragging)
    }

    private func toggle(_ value: OverlaySession.Popover) {
        session.commitStyle()
        session.activePopover = session.activePopover == value ? nil : value
        session.cropMode = false
    }

    private func tool(_ title: String, icon: String, shortcut: String? = nil,
                      prominent: Bool = false, selected: Bool = false, action: @escaping () -> Void) -> some View {
        CaptureToolButton(title: title, icon: icon, shortcut: shortcut, prominent: prominent, selected: selected, action: action)
    }
}

private struct CaptureToolButton: View {
    let title: String
    let icon: String
    let shortcut: String?
    let prominent: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium)).frame(height: 20)
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .frame(width: title == "Background" ? 77 : 58, height: 47)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(prominent ? Color.accentColor.opacity(hovered ? 0.85 : 1) : (selected || hovered ? Color.primary.opacity(selected ? 0.12 : 0.07) : Color.clear), in: RoundedRectangle(cornerRadius: 11))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .help(shortcut.map { "\(title) (\($0))" } ?? title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { value in hovered = value; if value { NSCursor.arrow.set() } }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
}

struct OverlayInspectorView: View {
    let session: OverlaySession
    let document: CaptureDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch session.activePopover {
            case .backgrounds:
                BackgroundPickerView(library: session.library, selection: Binding(
                    get: { session.effectiveStyle.backgroundID },
                    set: { value in session.previewStyle = nil; document.change { $0.style.backgroundID = value }; session.changed() }
                ))
                Divider()
                styleSlider("Padding", value: \.padding, range: 0...Double(CaptureStyle.maxEffectivePadding))
                styleSlider("Corners", value: \.cornerRadius, range: 0...64)
                styleSlider("Shadow", value: \.shadow, range: 0...64)
            case .annotations:
                Text("Annotate").font(.headline)
                HStack(spacing: 8) {
                    annotation("Arrow", icon: "arrow.up.right", kind: .arrow)
                    annotation("Rectangle", icon: "rectangle", kind: .rectangle)
                    annotation("Text", icon: "textformat", kind: .text)
                    annotation("Redact", icon: "rectangle.fill", kind: .redact)
                }
                HStack(spacing: 8) {
                    annotation("Highlight", icon: "highlighter", kind: .highlighter)
                    annotation("Steps", icon: "1.circle", kind: .numberedStep)
                    annotation("Spotlight", icon: "light.beacon.max", kind: .spotlight)
                    Button("Select") { session.annotationTool = nil }
                        .frame(maxWidth: .infinity)
                }
                Text(annotationHint).font(.caption).foregroundStyle(.secondary)
                if let selected = session.selectedAnnotation {
                    Divider()
                    if selected.kind == .text || selected.kind == .numberedStep {
                        TextField("Text", text: Binding(get: { session.selectedAnnotation?.text ?? "" }, set: { text in
                            document.updateAnnotation(id: selected.id) { $0.text = String(text.prefix(2000)) }; session.changed()
                        })).textFieldStyle(.roundedBorder)
                    }
                    ColorPicker("Color", selection: Binding(get: {
                        let c = session.selectedAnnotation?.color ?? selected.color
                        return Color(red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
                    }, set: { color in
                        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                        document.updateAnnotation(id: selected.id) { $0.color = AnnotationColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent) }
                        session.changed()
                    }), supportsOpacity: selected.kind != .redact)
                    HStack {
                        Text(selected.kind == .text || selected.kind == .numberedStep ? "Text Size" : "Stroke")
                        Slider(value: Binding(get: {
                            guard let value = session.selectedAnnotation else { return 6 }
                            return value.kind == .text || value.kind == .numberedStep ? value.fontSize : value.lineWidth
                        }, set: { size in
                            document.updateAnnotation(id: selected.id) {
                                if $0.kind == .text || $0.kind == .numberedStep { $0.fontSize = size.rounded() }
                                else { $0.lineWidth = size.rounded() }
                            }; session.changed()
                        }), in: 1...(selected.kind == .text || selected.kind == .numberedStep ? 160 : 32))
                        Button("Delete", role: .destructive) { document.removeAnnotation(id: selected.id); session.selectedAnnotationID = nil; session.changed() }
                    }.font(.caption)
                }
                HStack {
                    Button("Undo", systemImage: "arrow.uturn.backward") { document.undo(); session.changed() }.disabled(!document.canUndo)
                    Button("Redo", systemImage: "arrow.uturn.forward") { document.redo(); session.changed() }.disabled(!document.canRedo)
                    Spacer()
                    Button("Done") { session.annotationTool = nil; session.activePopover = nil }
                }.font(.caption)
            case .more:
                if session.mode == .ocr {
                    Button("Recognize Text Again", systemImage: "text.viewfinder") { session.onOCR(document) }
                    Divider()
                }
                HStack {
                    Button("Undo", systemImage: "arrow.uturn.backward") { document.undo(); session.changed() }.disabled(!document.canUndo)
                    Button("Redo", systemImage: "arrow.uturn.forward") { document.redo(); session.changed() }.disabled(!document.canRedo)
                }
                Divider()
                HStack {
                    Button("Copy Smaller") { session.commitStyle(); session.actions.copySmaller(document) }
                    Button("Save Smaller") { session.commitStyle(); session.actions.saveSmaller(document) }
                }
                Button("Pin Image", systemImage: "pin") { session.commitStyle(); session.actions.pin(document) }
                if let renderer = session.actions.dragRenderer {
                    CaptureDragHandle(request: document.request(backgroundURL: session.library.url(for: document.edits.style.backgroundID)),
                        renderer: renderer, onDragBegan: session.actions.dragBegan, onDragEnded: session.actions.dragEnded,
                        onDragCanceled: session.actions.dragCanceled,
                        onError: { error in session.status = error.localizedDescription; session.statusIsError = true })
                        .frame(width: 170, height: 30)
                }
                Text("\(outputWidth) × \(outputHeight) pixels · Lossless PNG").font(.callout.monospacedDigit())
                Text("Editable recovery keeps the original pixels behind crops and redactions. Exported PNGs contain only the flattened visible image.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("⌘C Copy   ⌘S Save   ⌘Z Undo   ⇧⌘Z Redo").font(.caption).foregroundStyle(.secondary)
                Button("Close Editor", systemImage: "xmark") { session.commitStyle(); session.onCancel() }
                Button("Discard Screenshot", systemImage: "trash", role: .destructive) { session.onDiscard(document) }
            case nil: EmptyView()
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))
        .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 5)
        .disabled(session.isDragging)
    }

    private var outputWidth: Int { Int(document.edits.crop.width) + padding * 2 }
    private var outputHeight: Int { Int(document.edits.crop.height) + padding * 2 }
    private var padding: Int { document.edits.style.backgroundID.isEmpty ? 0 : Int(document.edits.style.padding.rounded()) }
    private var annotationHint: String {
        switch session.annotationTool {
        case .text: "Click the screenshot to place text."
        case .redact: "Exports cover pixels with solid black. Editable recovery still retains the original; use Private Capture to keep it off disk."
        case .arrow, .rectangle: "Drag on the screenshot to draw."
        case .highlighter: "Drag to highlight an area without hiding its text."
        case .numberedStep: "Click to add the next numbered step."
        case .spotlight: "Drag to keep an area bright and dim the rest."
        case nil: "Click to select · Drag to move · Handles resize · Arrows nudge (Shift: 10 px)"
        }
    }

    private func annotation(_ title: String, icon: String, kind: CaptureAnnotation.Kind) -> some View {
        Button {
            session.annotationTool = kind
            session.cropMode = false
        } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 18))
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(session.annotationTool == kind ? Color.accentColor.opacity(0.17) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(session.annotationTool == kind ? .isSelected : [])
    }

    private func styleSlider(_ title: String, value: WritableKeyPath<CaptureStyle, Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 58, alignment: .leading)
            Slider(value: Binding(get: { session.effectiveStyle[keyPath: value] }, set: { newValue in
                var style = session.effectiveStyle
                style[keyPath: value] = newValue.rounded()
                session.previewStyle = style
            }), in: range, onEditingChanged: { editing in
                if !editing { session.commitStyle() }
            })
            Text("\(Int(session.effectiveStyle[keyPath: value]))").monospacedDigit().frame(width: 28, alignment: .trailing)
        }
        .font(.caption)
        .disabled(document.edits.style.backgroundID.isEmpty)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}
