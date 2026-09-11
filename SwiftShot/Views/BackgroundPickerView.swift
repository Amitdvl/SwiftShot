import SwiftUI
import UniformTypeIdentifiers

/// Shared by preferences and the capture toolbar's background popover.
struct BackgroundPickerView: View {
    let library: BackgroundLibrary
    @Binding var selection: String
    var showsHeader = true
    @State private var importPanel: NSOpenPanel?
    @State private var windowReference = BackgroundPickerWindowReference()
    @State private var isDropTargeted = false
    @State private var importError: String?
    private let columns = [GridItem(.adaptive(minimum: 76, maximum: 110), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsHeader {
                pickerHeader
            } else {
                HStack {
                    Spacer(minLength: 0)
                    importButton
                }
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    tile(id: "", name: "None") {
                        ZStack {
                            Capsule().fill(.quaternary.opacity(0.5))
                            Image(systemName: "nosign").font(.title2).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(library.assets) { asset in
                        tile(id: asset.id, name: asset.name) {
                            if let image = library.thumbnail(for: asset.id) {
                                Image(nsImage: image).resizable().scaledToFill()
                            } else {
                                Rectangle().fill(.quaternary)
                                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                            }
                        }
                        .contextMenu {
                            Button(asset.isBundled ? "Hide Background" : "Remove Background", role: .destructive) {
                                remove(asset.id)
                            }
                        }
                    }
                }
                .padding(3)
            }
            .frame(minHeight: 100, idealHeight: 185, maxHeight: 220)
            .scrollIndicators(.hidden)
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5])) }
                        .allowsHitTesting(false)
                }
            }
            HStack(spacing: 12) {
                Button { remove(selection) } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(selection.isEmpty || library.isImporting)
                .help("Remove the selected background; bundled images can be restored")
                Button { perform { try library.undoRemoval() } } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!library.canUndoRemoval || library.isImporting)
                Spacer(minLength: 0)
                Menu {
                    Button("Restore Bundled Backgrounds") { perform { try library.restoreBundled() } }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Background Library Options")
            }
            Text("Drop images here to add them. Your originals stay untouched.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = importError ?? library.errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(message).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { importError = nil; library.errorMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss Background Error")
                }
                .font(.caption)
            }
        }
        .frame(minWidth: 280)
        .background { BackgroundPickerWindowReader(reference: windowReference).frame(width: 0, height: 0) }
        .onDisappear { importPanel?.cancel(nil) }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty, !library.isImporting else { return false }
            importImages(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .onChange(of: library.assets.map(\.id)) { _, ids in
            if !selection.isEmpty && !ids.contains(selection) { selection = "" }
        }
    }

    private var pickerHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Backgrounds").font(.headline)
                Text("Select a backdrop or add your own image.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            importButton
        }
    }

    private var importButton: some View {
        HStack(spacing: 8) {
            if library.isImporting { ProgressView().controlSize(.small) }
            Button { beginImport() } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Add background images")
            .disabled(library.isImporting)
            .accessibilityLabel("Add Backgrounds")
        }
    }

    private func tile<Content: View>(id: String, name: String, @ViewBuilder content: () -> Content) -> some View {
        Button { selection = id } label: {
            VStack(spacing: 5) {
                content()
                    .frame(height: 52)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(Capsule())
                    .overlay(alignment: .topTrailing) {
                        if selection == id {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette).foregroundStyle(.white, Color.accentColor)
                                .padding(4)
                        }
                    }
                    .overlay { Capsule().strokeBorder(selection == id ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selection == id ? 2 : 1) }
                Text(name)
                    .font(.caption)
                    .fontWeight(selection == id ? .semibold : .regular)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selection == id ? .isSelected : [])
    }

    /// Explicit attachment is essential when the capture panel sits above normal windows.
    private func beginImport() {
        guard importPanel == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Add Backgrounds"
        panel.prompt = "Add Backgrounds"
        panel.message = "Choose images to copy into your SwiftShot background library."
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        importPanel = panel
        if let window = windowReference.window {
            let previousResponder = window.firstResponder
            panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.modalPanel.rawValue, window.level.rawValue + 1))
            panel.beginSheetModal(for: window) { [weak window] response in
                let urls = response == .OK ? panel.urls : []
                importPanel = nil
                if let window, window.isVisible {
                    window.makeKey()
                    window.makeFirstResponder(previousResponder)
                }
                if !urls.isEmpty { importImages(urls) }
            }
            panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.modalPanel.rawValue, window.level.rawValue + 1))
        } else {
            panel.begin { response in
                let urls = response == .OK ? panel.urls : []
                importPanel = nil
                if !urls.isEmpty { importImages(urls) }
            }
        }
    }

    private func importImages(_ urls: [URL]) {
        importError = nil
        Task {
            do { try await library.importFiles(urls) }
            catch { importError = error.localizedDescription }
        }
    }

    private func remove(_ id: String) {
        perform {
            try library.remove(id: id)
            if selection == id { selection = "" }
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation(); importError = nil }
        catch { importError = error.localizedDescription }
    }
}

/// A weak reference avoids retaining the containing NSWindow through its hosted view.
@MainActor private final class BackgroundPickerWindowReference {
    weak var window: NSWindow?
}

private struct BackgroundPickerWindowReader: NSViewRepresentable {
    let reference: BackgroundPickerWindowReference
    func makeNSView(context: Context) -> AnchorView { AnchorView(reference: reference) }
    func updateNSView(_ nsView: AnchorView, context: Context) { }

    final class AnchorView: NSView {
        let reference: BackgroundPickerWindowReference
        init(reference: BackgroundPickerWindowReference) {
            self.reference = reference
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func viewDidMoveToWindow() { reference.window = window }
    }
}
