import CoreGraphics
import Foundation

/// An immutable image plus value edits: owns the capture independently of editor lifetime.
struct RecoverySnapshot: @unchecked Sendable {
    let id: UUID
    let image: CGImage
    let edits: CaptureEdits
    let revision: Int
    let savedURL: URL?
    var privateCapture = false

    var estimatedBytes: Int { image.bytesPerRow * image.height }
}

struct RecoveryCoordinatorStatus: Sendable {
    let pendingCount: Int
    let pendingBytes: Int
    let failedIDs: [UUID]
    let lastFailure: String?
    let isShuttingDown: Bool
}

/// Takes ownership immediately; the actor's pending queue retains failed originals until retry.
/// Disk work does not block the main actor or ordinary Copy/Save interaction.
actor RecoveryCoordinator {
    enum Failure: LocalizedError {
        case shuttingDown, capacityExceeded, lifetimeLimitReached

        var errorDescription: String? {
            switch self {
            case .shuttingDown: "Recovery is shutting down. Keep this capture open until SwiftShot finishes quitting."
            case .capacityExceeded: "Recovery has too many unsaved pixels waiting for disk. Keep this capture open and retry saving before another capture."
            case .lifetimeLimitReached: "This session has reached its private/discarded capture tracking limit. Finish saving your open captures, then restart SwiftShot."
            }
        }
    }

    private struct Pending {
        let token = UUID()
        let snapshot: RecoverySnapshot
    }

    private struct DurableStamp {
        let revision: Int
        let edits: CaptureEdits
        let savedURL: URL?

        func matches(_ snapshot: RecoverySnapshot) -> Bool {
            revision == snapshot.revision && edits == snapshot.edits && savedURL == snapshot.savedURL
        }
    }

    private let store: RecoveryStore
    private let maximumPendingBytes: Int
    private let maximumPendingCaptures: Int
    private var pending: [UUID: Pending] = [:]
    private var durable: [UUID: DurableStamp] = [:]
    private var durableOrder: [UUID] = []
    private var privateIDs: Set<UUID> = []
    private var discardedIDs: Set<UUID> = []
    private var failures: [UUID: String] = [:]
    private var worker: Task<Void, Error>?
    private var isShuttingDown = false
    // Never evict tombstones while late producers may still submit old IDs. Bound their
    // lifetime explicitly instead; a fully flushed process restart is the safe reset.
    private let maximumLifetimeTombstones = 65_536

    init(store: RecoveryStore, maximumPendingBytes: Int = 512 * 1_024 * 1_024, maximumPendingCaptures: Int = 32) {
        self.store = store
        self.maximumPendingBytes = max(0, maximumPendingBytes)
        self.maximumPendingCaptures = max(0, maximumPendingCaptures)
    }

    /// Returns once this actor owns the snapshot, not once its PNG is on disk.
    func enqueue(_ snapshot: RecoverySnapshot) throws {
        guard !isShuttingDown else { throw Failure.shuttingDown }
        if snapshot.privateCapture {
            guard privateIDs.contains(snapshot.id) || privateIDs.count + discardedIDs.count < maximumLifetimeTombstones else {
                throw Failure.lifetimeLimitReached
            }
            privateIDs.insert(snapshot.id)
        }
        guard !privateIDs.contains(snapshot.id), !discardedIDs.contains(snapshot.id) else { return }
        if let old = pending[snapshot.id]?.snapshot {
            guard snapshot.revision >= old.revision else { return }
            if old.revision == snapshot.revision && old.edits == snapshot.edits && old.savedURL == snapshot.savedURL { return }
        }
        if let stamp = durable[snapshot.id] {
            guard snapshot.revision >= stamp.revision else { return }
            if stamp.matches(snapshot) { return }
        }
        let bytes = pending.values.reduce(0) { $0 + $1.snapshot.estimatedBytes }
            - (pending[snapshot.id]?.snapshot.estimatedBytes ?? 0) + snapshot.estimatedBytes
        let count = pending.count + (pending[snapshot.id] == nil ? 1 : 0)
        guard bytes <= maximumPendingBytes, count <= maximumPendingCaptures else { throw Failure.capacityExceeded }
        pending[snapshot.id] = Pending(snapshot: snapshot)
        // A failure requires explicit retry/flush; do not spin or repeatedly write a broken disk.
        if failures.isEmpty { startWorkerIfNeeded() }
    }

    /// Navigation compatibility: transfer ownership and wait until every admitted revision is durable.
    func preserve(_ snapshot: RecoverySnapshot) async throws {
        try enqueue(snapshot)
        try await flush()
    }

    /// A barrier, including snapshots admitted while its current disk write was running.
    /// Errors propagate while snapshots remain strongly retained; subsequent calls retry.
    func flush() async throws {
        while !pending.isEmpty {
            startWorkerIfNeeded()
            if let worker { try await worker.value }
        }
    }

    func retry() async throws { try await flush() }

    /// Reject new admission, then await durable ownership handoff. Failed shutdown is retryable.
    func shutdown() async throws {
        isShuttingDown = true
        do { try await flush() }
        catch {
            // The app must cancel termination on failure and remain fully usable.
            isShuttingDown = false
            throw error
        }
    }

    /// Never drops undurable pixels under pressure. Flushes them and releases reconstructible caches.
    func handleMemoryPressure() async throws {
        await store.releaseTransientCaches()
        durable.removeAll()
        durableOrder.removeAll()
        try await flush()
    }

    /// Pending/failed revisions may be newer than their saved on-disk metadata.
    /// Protect their originals without requiring a broken disk to flush first.
    /// Admissions during the store await are covered by its retention revision floor.
    @discardableResult
    func applyRetention(_ policy: RecoveryRetentionPolicy, protected: Set<UUID> = [], now: Date = Date()) async throws -> [UUID] {
        guard !isShuttingDown else { throw Failure.shuttingDown }
        let protectedIDs = protected.union(pending.keys)
        return try await store.applyRetention(policy, protected: protectedIDs, now: now)
    }

    /// Explicit user discard only. Store tombstones prevent an already-running write resurrection.
    func discard(id: UUID) async throws {
        guard discardedIDs.contains(id) || privateIDs.count + discardedIDs.count < maximumLifetimeTombstones else {
            throw Failure.lifetimeLimitReached
        }
        try await store.discard(id: id)
        discardedIDs.insert(id)
        pending.removeValue(forKey: id)
        durable.removeValue(forKey: id)
        durableOrder.removeAll { $0 == id }
        failures.removeValue(forKey: id)
    }

    func status() -> RecoveryCoordinatorStatus {
        RecoveryCoordinatorStatus(pendingCount: pending.count,
            pendingBytes: pending.values.reduce(0) { $0 + $1.snapshot.estimatedBytes },
            failedIDs: Array(failures.keys), lastFailure: failures.values.first,
            isShuttingDown: isShuttingDown)
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !pending.isEmpty else { return }
        worker = Task(priority: .utility) { try await self.drain() }
    }

    private func drain() async throws {
        defer { worker = nil }
        while let item = pending.values.min(by: { $0.snapshot.revision < $1.snapshot.revision }) {
            let snapshot = item.snapshot
            do {
                try await store.persist(id: snapshot.id, image: snapshot.image, edits: snapshot.edits,
                    revision: snapshot.revision, savedURL: snapshot.savedURL, privateCapture: snapshot.privateCapture)
                failures.removeValue(forKey: snapshot.id)
                if !discardedIDs.contains(snapshot.id) {
                    durable[snapshot.id] = DurableStamp(revision: snapshot.revision, edits: snapshot.edits, savedURL: snapshot.savedURL)
                    durableOrder.removeAll { $0 == snapshot.id }
                    durableOrder.append(snapshot.id)
                    // Durable metadata may be forgotten: the store remains the authoritative no-op gate.
                    while durableOrder.count > 128 { durable.removeValue(forKey: durableOrder.removeFirst()) }
                }
                if pending[snapshot.id]?.token == item.token { pending.removeValue(forKey: snapshot.id) }
            } catch {
                // An explicit discard may complete while the store write is awaiting.
                // Its intentionally dropped snapshot must not leave a phantom failure.
                if !discardedIDs.contains(snapshot.id), pending[snapshot.id] != nil {
                    failures[snapshot.id] = error.localizedDescription
                    throw error
                }
            }
        }
    }
}
