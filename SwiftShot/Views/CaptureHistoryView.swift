import AppKit
import SwiftUI

struct CaptureHistoryView: View {
    @Bindable var model: CaptureHistoryModel
    @State private var pendingDeletion: [UUID] = []
    @State private var pendingRetention: RecoveryRetentionPolicy?

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            NavigationSplitView {
                List(selection: $model.selection) {
                    ForEach(model.entries) { entry in
                        HistoryCaptureRow(entry: entry, thumbnails: model.thumbnails)
                            .tag(entry.id)
                            .contextMenu { captureActions(entry) }
                    }
                }
                // Use List's native primary action. A row-level tap recognizer
                // consumes content clicks before AppKit can update selection.
                // The row owns its contextual actions so a multi-selection still
                // opens the actual right-clicked capture, not an arbitrary ID.
                .contextMenu(forSelectionType: UUID.self) { _ in EmptyView() } primaryAction: { ids in
                    if ids.count == 1, let id = ids.first { model.open(id: id) }
                }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 245, ideal: 310, max: 400)
                .onDeleteCommand { pendingDeletion = model.selectedEntries.map(\.id) }
                .overlay {
                    if model.entries.isEmpty, !model.isLoading {
                        ContentUnavailableView(model.query.isEmpty ? "No Recent Captures" : "No Text Matches",
                            systemImage: model.query.isEmpty ? "photo.stack" : "text.magnifyingglass",
                            description: Text(model.query.isEmpty ? "Private captures are never stored here." : "Search uses local OCR of edited captures only."))
                    }
                }
            } detail: {
                detail
            }
            Divider()
            footer
        }
        .task(id: model.query) {
            do { try await Task.sleep(for: .milliseconds(model.query.isEmpty ? 0 : 180)) }
            catch { return }
            await model.reload()
        }
        .confirmationDialog("Delete \(pendingDeletion.count) editable original\(pendingDeletion.count == 1 ? "" : "s")?",
            isPresented: Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } }), titleVisibility: .visible) {
            Button("Delete Originals", role: .destructive) {
                let ids = pendingDeletion
                pendingDeletion = []
                Task { await model.delete(ids: ids) }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = [] }
        } message: {
            Text("This permanently deletes their editable pixels and OCR search text from SwiftShot. Saved exports are unaffected.")
        }
        .confirmationDialog("Apply History Retention?",
            isPresented: Binding(get: { pendingRetention != nil }, set: { if !$0 { pendingRetention = nil } }), titleVisibility: .visible) {
            Button("Apply Retention", role: pendingRetention == RecoveryRetentionPolicy() ? nil : .destructive) {
                if let policy = pendingRetention {
                    pendingRetention = nil
                    Task { await model.applyRetention(policy) }
                }
            }
            Button("Cancel", role: .cancel) { pendingRetention = nil }
        } message: {
            Text("Saved captures outside the selected policy may be deleted. Unsaved, kept, and currently open captures are retained. Saved exports are unaffected.")
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search recognized text", text: $model.query)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search local capture text")
            if model.isLoading { ProgressView().controlSize(.small) }
            Button { Task { await model.reload(refreshStorage: true) } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh history")
                .accessibilityLabel("Refresh history")
            Menu {
                Button("Keep All Saved Captures") { pendingRetention = RecoveryRetentionPolicy() }
                Button("Keep Newest 100 Saved Captures") { pendingRetention = RecoveryRetentionPolicy(maximumSavedCount: 100) }
                Button("Keep Saved Captures for 7 Days") { pendingRetention = RecoveryRetentionPolicy(maximumSavedAgeDays: 7) }
                Button("Keep Saved Captures for 30 Days") { pendingRetention = RecoveryRetentionPolicy(maximumSavedAgeDays: 30) }
            } label: { Label(model.retentionLabel, systemImage: "clock.arrow.circlepath") }
            .fixedSize()
            .disabled(model.isMutating)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder
    private var detail: some View {
        if model.selectedEntries.count == 1, let entry = model.selectedEntries.first {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HistoryThumbnail(thumbnails: model.thumbnails, record: entry.record, maximumPixelSize: 720)
                        .frame(maxWidth: .infinity, minHeight: 180, idealHeight: 300, maxHeight: 340)
                    HStack {
                        Text(HistoryCaptureRow.title(entry.record)).font(.headline).textSelection(.enabled)
                        Spacer()
                        Text(entry.record.updatedAt, style: .date).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Open Editor", systemImage: "pencil.tip.crop.circle") { model.open(id: entry.id) }
                            .buttonStyle(.borderedProminent).disabled(!entry.isRecoverable)
                        Button("Pin to Screen", systemImage: "pin") { model.pinToScreen(id: entry.id) }
                            .disabled(!entry.isRecoverable)
                    }
                    HStack {
                        Button(entry.record.isPinned ? "Stop Keeping in History" : "Keep in History",
                               systemImage: entry.record.isPinned ? "bookmark.fill" : "bookmark") {
                            Task { await model.toggleKeep(id: entry.id) }
                        }
                        Spacer()
                        Button("Delete…", systemImage: "trash", role: .destructive) { pendingDeletion = [entry.id] }
                    }.disabled(model.isMutating)
                    if !entry.isRecoverable {
                        Label("The original is damaged or unavailable. Its files have been retained for manual recovery.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if entry.record.reconciled == true {
                        Label("Recovered original. Its previous crop and annotations could not be restored; damaged metadata was preserved separately.", systemImage: "arrow.counterclockwise")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let text = entry.record.ocrText, !text.isEmpty {
                        Divider()
                        Text("Recognized Text").font(.subheadline.weight(.medium))
                        Text(text).font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(20)
            }
        } else if model.selectedEntries.count > 1 {
            VStack(spacing: 18) {
                Image(systemName: "photo.stack").font(.system(size: 42)).foregroundStyle(.secondary)
                Text("\(model.selectedEntries.count) Captures Selected").font(.title2.weight(.semibold))
                Text("Combine in the list’s top-to-bottom order.\nCommand-click to add or remove captures.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                HStack {
                    Button("Combine Vertically", systemImage: "rectangle.split.1x2") { Task { await model.combineSelected(axis: .vertical) } }
                    Button("Side by Side", systemImage: "rectangle.split.2x1") { Task { await model.combineSelected(axis: .horizontal) } }
                }.disabled(!model.canCombine || model.isMutating)
                Button("Delete Selected…", systemImage: "trash", role: .destructive) { pendingDeletion = model.selectedEntries.map(\.id) }
                    .disabled(model.isMutating)
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Choose a Capture", systemImage: "photo.on.rectangle",
                description: Text("Open, pin, or combine your recent screenshots."))
        }
    }

    @ViewBuilder
    private func captureActions(_ entry: RecoveryHistoryEntry) -> some View {
        Button("Open Editor") { model.open(id: entry.id) }.disabled(!entry.isRecoverable)
        Button("Pin to Screen") { model.pinToScreen(id: entry.id) }.disabled(!entry.isRecoverable)
        Button(entry.record.isPinned ? "Stop Keeping in History" : "Keep in History") { Task { await model.toggleKeep(id: entry.id) } }
        Divider()
        Button("Delete…", role: .destructive) { pendingDeletion = [entry.id] }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                if let storage = model.storage {
                    Text("\(storage.captureCount) captures · \(ByteCountFormatter.string(fromByteCount: storage.totalBytes, countStyle: .file)) · \(storage.pinnedCount) kept")
                }
                Spacer()
                if model.entries.count == 200 { Text("Showing newest 200") }
            }.foregroundStyle(.secondary)
            Text("Editable originals retain cropped and redacted pixels. Private captures are never stored here.")
                .foregroundStyle(.secondary)
            if !model.reconciliation.issues.isEmpty {
                Text("\(model.reconciliation.issues.count) recovery item(s) need attention; their files were retained.")
                    .foregroundStyle(.orange)
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
        }.font(.caption).padding(.horizontal, 16).padding(.vertical, 9)
    }
}

private struct HistoryCaptureRow: View {
    let entry: RecoveryHistoryEntry
    let thumbnails: HistoryThumbnailLoader

    var body: some View {
        HStack(spacing: 10) {
            HistoryThumbnail(thumbnails: thumbnails, record: entry.record, maximumPixelSize: 96)
                .frame(width: 60, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.title(entry.record)).lineLimit(1)
                Text("\(entry.record.isPinned ? "Kept" : entry.record.savedPath == nil ? "Unsaved" : "Saved") · \(Int(entry.record.edits.crop.width)) × \(Int(entry.record.edits.crop.height))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(.vertical, 3)
    }

    static func title(_ record: RecoveryRecord) -> String {
        if let path = record.savedPath { return URL(fileURLWithPath: path).lastPathComponent }
        return record.createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct HistoryThumbnail: View {
    let thumbnails: HistoryThumbnailLoader
    let record: RecoveryRecord
    let maximumPixelSize: Int
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.4))
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else if failed {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .accessibilityLabel(failed ? "Thumbnail unavailable" : "Edited capture thumbnail")
        .task(id: "\(record.id)-\(record.revision)-\(maximumPixelSize)") {
            image = nil
            failed = false
            do {
                let thumbnail = try await thumbnails.load(id: record.id, maximumPixelSize: maximumPixelSize)
                guard !Task.isCancelled else { return }
                image = thumbnail
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }
}
