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
                session.commitStyle(); session.cropMode.toggle(); session.annotationTool = nil; session.activePopover = nil
            }
            tool("More", icon: "ellipsis", selected: session.activePopover == .more) { toggle(.more) }
        }
        .padding(7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))
        .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.22), radius: 22, y: 8)
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
                styleSlider("Padding", value: \.padding, range: 0...240)
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
                Text(annotationHint).font(.caption).foregroundStyle(.secondary)
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
                Text("\(outputWidth) × \(outputHeight) pixels · Lossless PNG").font(.callout.monospacedDigit())
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
    }

    private var outputWidth: Int { Int(document.edits.crop.width) + padding * 2 }
    private var outputHeight: Int { Int(document.edits.crop.height) + padding * 2 }
    private var padding: Int { document.edits.style.backgroundID.isEmpty ? 0 : Int(document.edits.style.padding.rounded()) }
    private var annotationHint: String {
        switch session.annotationTool {
        case .text: "Click the screenshot to place text."
        case .redact: "Drag to permanently cover sensitive content with solid black."
        case .arrow, .rectangle: "Drag on the screenshot to draw."
        case nil: "Choose a tool, then draw directly on your screenshot."
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
