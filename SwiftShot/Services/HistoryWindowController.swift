import AppKit
import Observation
import SwiftUI

enum HistoryCombineAxis: String, Equatable, Sendable { case vertical, horizontal }

/// Window-scoped browser state. All external capture mutations are explicit callbacks.
@MainActor @Observable
final class CaptureHistoryModel {
    enum RefreshEvent { case reloadStarted, recoveryObservationFinished }
    @ObservationIgnored var refreshObserver: (@MainActor (RefreshEvent) -> Void)?
    let store: RecoveryStore
    let thumbnails: HistoryThumbnailLoader
    var query = ""
    var selection: Set<UUID> = []
    private(set) var entries: [RecoveryHistoryEntry] = []
    private(set) var storage: RecoveryStorageUsage?
    private(set) var reconciliation = RecoveryReconciliationReport()
    private(set) var retention: RecoveryRetentionPolicy
    private(set) var isLoading = false
    private(set) var isMutating = false
    var errorMessage: String?
    private var reloadToken = UUID()
    private let maximumPendingRevisions: Int
    private var minimumRevisions: [UUID: Int] = [:]
    private var freshnessLimitReached = false
    private let freshnessLimitMessage = "History is paused to avoid displaying outdated edits. Save pending captures, then restart SwiftShot."
    private let onOpen: @MainActor (UUID) -> Void
    private let onPin: @MainActor (UUID) -> Void
    private let onDelete: @MainActor (UUID) async throws -> Void
    private let onCombine: @MainActor ([UUID], HistoryCombineAxis) async throws -> Void
    private let onRetentionChange: @MainActor (RecoveryRetentionPolicy) async throws -> Void

    init(store: RecoveryStore, retention: RecoveryRetentionPolicy = RecoveryRetentionPolicy(),
         maximumPendingRevisions: Int = 64,
         onOpen: @escaping @MainActor (UUID) -> Void,
         onPin: @escaping @MainActor (UUID) -> Void,
         onDelete: @escaping @MainActor (UUID) async throws -> Void,
         onCombine: @escaping @MainActor ([UUID], HistoryCombineAxis) async throws -> Void,
         onRetentionChange: @escaping @MainActor (RecoveryRetentionPolicy) async throws -> Void) {
        self.store = store
        thumbnails = HistoryThumbnailLoader(store: store)
        self.retention = retention
        self.maximumPendingRevisions = max(0, min(maximumPendingRevisions, 512))
        self.onOpen = onOpen
        self.onPin = onPin
        self.onDelete = onDelete
        self.onCombine = onCombine
        self.onRetentionChange = onRetentionChange
    }

    var selectedEntries: [RecoveryHistoryEntry] { entries.filter { selection.contains($0.id) } }

    /// Main-actor invalidation happens before the edit's debounced disk write.
    /// Removing the entry also removes its old detail text and thumbnail views.
    func invalidate(id: UUID, minimumRevision: Int) {
        guard minimumRevision > 0 else { return }
        reloadToken = UUID()
        isLoading = false
        guard !freshnessLimitReached else { return }
        if minimumRevisions[id] == nil, minimumRevisions.count >= maximumPendingRevisions {
            // Do not evict a barrier: its older on-disk pixels may still exist.
            // Normal admission is bounded to 32 captures; this is a fail-closed
            // backstop for unusually many undurable revisions in one window.
            freshnessLimitReached = true
            entries.removeAll()
            selection.removeAll()
            errorMessage = freshnessLimitMessage
            return
        }
        minimumRevisions[id] = max(minimumRevisions[id] ?? 0, minimumRevision)
        entries.removeAll { $0.id == id && $0.record.revision < minimumRevision }
        selection.formIntersection(Set(entries.map(\.id)))
    }

    /// Only a known durable revision releases its barrier. Invalidate older
    /// in-flight reads first, since they may already hold pre-edit value copies.
    func acknowledgeDurableRecords(_ records: [RecoveryRecord]) {
        var acknowledged = false
        for record in records {
            if let minimum = minimumRevisions[record.id], record.revision >= minimum {
                minimumRevisions.removeValue(forKey: record.id)
                acknowledged = true
            }
        }
        if acknowledged { reloadToken = UUID(); isLoading = false }
    }

    /// A successful explicit removal is authoritative even if its latest edit
    /// never reached disk. Failed deletion must leave the revision barrier intact.
    func acknowledgeRemovedRecords(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let removed = Set(ids)
        reloadToken = UUID()
        isLoading = false
        for id in removed { minimumRevisions.removeValue(forKey: id) }
        entries.removeAll { removed.contains($0.id) }
        selection.subtract(removed)
    }

    var canCombine: Bool { selectedEntries.count >= 2 && selectedEntries.allSatisfy(\.isRecoverable) }
    var retentionLabel: String {
        if let count = retention.maximumSavedCount { return "Newest \(count) saved" }
        if let days = retention.maximumSavedAgeDays { return "Saved · \(days) days" }
        return "Keep all captures"
    }

    func reload(refreshStorage: Bool = false) async {
        guard !freshnessLimitReached else {
            errorMessage = freshnessLimitMessage
            return
        }
        let token = UUID()
        reloadToken = token
        isLoading = true
        refreshObserver?(.reloadStarted)
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { if reloadToken == token { isLoading = false } }
        do {
            let records: [RecoveryRecord]
            if query.isEmpty {
                records = Array(try await store.records().prefix(200))
            } else {
                records = try await store.searchOCR(query, limit: 200)
            }
            let report = try await store.reconciliationReport()
            // Rows do not display per-capture byte totals. Read their cached
            // metadata only; the footer still requests accurate storage usage.
            let result = records.map { record in
                RecoveryHistoryEntry(record: record, storageBytes: 0,
                    isRecoverable: !report.issues.contains { $0.id == record.id })
            }
            let usage: RecoveryStorageUsage?
            if refreshStorage || storage == nil { usage = try await store.storageUsage() }
            else { usage = storage }
            guard reloadToken == token, !Task.isCancelled else { return }
            entries = result.filter { $0.record.revision >= (minimumRevisions[$0.id] ?? 0) }
            storage = usage
            reconciliation = report
            selection.formIntersection(Set(entries.map(\.id)))
            errorMessage = nil
        } catch {
            guard reloadToken == token, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func open(id: UUID) {
        guard entries.contains(where: { $0.id == id && $0.isRecoverable }) else { return }
        onOpen(id)
    }

    func pinToScreen(id: UUID) {
        guard entries.contains(where: { $0.id == id && $0.isRecoverable }) else { return }
        onPin(id)
    }

    func toggleKeep(id: UUID) async {
        guard !isMutating, let entry = entries.first(where: { $0.id == id }) else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            try await store.setPinned(id: id, isPinned: !entry.record.isPinned)
            await reload(refreshStorage: true)
        } catch { errorMessage = error.localizedDescription }
    }

    /// Called only from the confirmation dialog, never selection or window lifecycle.
    func deleteSelected() async {
        await delete(ids: selectedEntries.map(\.id))
    }

    func delete(ids: [UUID]) async {
        guard !isMutating else { return }
        guard !ids.isEmpty else { return }
        isMutating = true
        defer { isMutating = false }
        var failure: String?
        for id in ids {
            do {
                try await onDelete(id)
                acknowledgeRemovedRecords(ids: [id])
            }
            catch { failure = error.localizedDescription; break }
        }
        await reload(refreshStorage: true)
        if let failure { errorMessage = failure }
    }

    func applyRetention(_ policy: RecoveryRetentionPolicy) async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            try await onRetentionChange(policy)
            retention = policy
            await reload(refreshStorage: true)
        } catch { errorMessage = error.localizedDescription }
    }

    func combineSelected(axis: HistoryCombineAxis) async {
        guard canCombine, !isMutating else { return }
        let ids = selectedEntries.map(\.id) // Explicit visible top-to-bottom ordering.
        isMutating = true
        defer { isMutating = false }
        do { try await onCombine(ids, axis) }
        catch { errorMessage = error.localizedDescription }
    }
}

/// Keep row tasks cheap while one full-resolution original is decoded/rendered at a time.
/// Queued tasks own only identifiers; cancellation is checked before taking pixel ownership.
actor HistoryThumbnailLoader {
    private let store: RecoveryStore
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(store: RecoveryStore) { self.store = store }

    func load(id: UUID, maximumPixelSize: Int) async throws -> CGImage {
        try Task.checkCancellation()
        if busy { await withCheckedContinuation { waiters.append($0) } }
        else { busy = true }
        defer {
            if waiters.isEmpty { busy = false }
            else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        return try await store.thumbnail(id: id, maximumPixelSize: maximumPixelSize)
    }
}

/// Lazy singleton utility window; construction alone neither activates nor presents UI.
@MainActor
final class HistoryWindowController: NSWindowController {
    let model: CaptureHistoryModel

    init(store: RecoveryStore, retention: RecoveryRetentionPolicy = RecoveryRetentionPolicy(),
         onOpen: @escaping @MainActor (UUID) -> Void,
         onPin: @escaping @MainActor (UUID) -> Void,
         onDelete: @escaping @MainActor (UUID) async throws -> Void,
         onCombine: @escaping @MainActor ([UUID], HistoryCombineAxis) async throws -> Void,
         onRetentionChange: @escaping @MainActor (RecoveryRetentionPolicy) async throws -> Void) {
        model = CaptureHistoryModel(store: store, retention: retention, onOpen: onOpen, onPin: onPin,
            onDelete: onDelete, onCombine: onCombine, onRetentionChange: onRetentionChange)
        super.init(window: nil)
    }

    required init?(coder: NSCoder) { return nil }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "SwiftShot History"
            window.contentMinSize = NSSize(width: 680, height: 440)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: CaptureHistoryView(model: model))
            window.setFrameAutosaveName("SwiftShotHistory")
            window.center()
            self.window = window
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
    }

    func refresh() { Task { await model.reload(refreshStorage: true) } }
}
