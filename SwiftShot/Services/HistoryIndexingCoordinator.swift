import CoreGraphics
import Foundation

struct HistoryIndexingStatus: Sendable {
    let isEnabled: Bool
    let pendingCount: Int
    let retainedBytes: Int
    let skippedCount: Int
    let lastFailure: String?
}

/// Optional, local-only OCR. One serial job limits Vision and bitmap allocation pressure.
/// Enqueue transfers bounded ownership immediately and never waits for recognition.
actor HistoryIndexingCoordinator {
    private struct Job {
        let token = UUID()
        let snapshot: RecoverySnapshot
    }

    private let store: RecoveryStore
    private let recovery: RecoveryCoordinator?
    private let renderer: any CaptureRendering
    private let recognizer: any TextRecognizing
    private let maximumJobs: Int
    private let maximumBytes: Int
    private var jobs: [UUID: Job] = [:]
    private var order: [UUID] = []
    private var active: Job?
    private var worker: Task<Void, Error>?
    private var enabled: Bool
    private var generation = UUID()
    private var skippedCount = 0
    private var lastFailure: String?

    init(store: RecoveryStore, recovery: RecoveryCoordinator? = nil,
         renderer: any CaptureRendering = ImageRenderer(cacheByteLimit: 0, cacheEntryLimit: 0),
         recognizer: any TextRecognizing = OCRService.shared, enabled: Bool = true,
         maximumJobs: Int = 4, maximumBytes: Int = 192 * 1_024 * 1_024) {
        self.store = store
        self.recovery = recovery
        self.renderer = renderer
        self.recognizer = recognizer
        self.enabled = enabled
        self.maximumJobs = max(0, maximumJobs)
        self.maximumBytes = max(0, maximumBytes)
    }

    /// False means private, disabled, superseded, or explicitly bounded-out optional indexing.
    @discardableResult
    func enqueue(_ snapshot: RecoverySnapshot) -> Bool {
        if snapshot.privateCapture { cancel(id: snapshot.id); return false }
        guard enabled else { return false }
        if let existing = jobs[snapshot.id] {
            if existing.snapshot.revision > snapshot.revision { return false }
            if existing.snapshot.revision == snapshot.revision, existing.snapshot.edits == snapshot.edits { return true }
        }
        var next = jobs
        next[snapshot.id] = Job(snapshot: snapshot)
        guard next.count <= maximumJobs, estimatedBytes(next) <= maximumBytes else {
            skippedCount += 1
            return false
        }
        jobs = next
        if !order.contains(snapshot.id) { order.append(snapshot.id) }
        startWorkerIfNeeded()
        return true
    }

    func cancel(id: UUID) {
        jobs.removeValue(forKey: id)
        order.removeAll { $0 == id }
        if active?.snapshot.id == id { worker?.cancel() }
    }

    /// Invalidates in-flight results before clearing text, so late Vision output cannot resurrect it.
    func setEnabled(_ enabled: Bool, clearExistingIndex: Bool = false) async throws {
        guard enabled != self.enabled || clearExistingIndex else { return }
        generation = UUID()
        self.enabled = enabled
        worker?.cancel()
        jobs.removeAll()
        order.removeAll()
        lastFailure = nil
        if clearExistingIndex { try await store.clearOCRIndex() }
        await renderer.clearCache()
    }

    func stop(clearIndex: Bool = false) async throws {
        try await setEnabled(false, clearExistingIndex: clearIndex)
    }

    /// Includes a canceled active recognizer while it finishes its non-interruptible native call.
    func flush() async throws {
        while let task = worker { try await task.value }
    }

    func status() -> HistoryIndexingStatus {
        HistoryIndexingStatus(isEnabled: enabled, pendingCount: jobs.count,
            retainedBytes: estimatedBytes(jobs), skippedCount: skippedCount, lastFailure: lastFailure)
    }

    private func estimatedBytes(_ values: [UUID: Job]) -> Int {
        var bytes = values.values.reduce(0) { $0 + $1.snapshot.estimatedBytes }
        if let active, values[active.snapshot.id]?.token != active.token {
            bytes += active.snapshot.estimatedBytes
        }
        return bytes
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, enabled, !jobs.isEmpty else { return }
        worker = Task(priority: .utility) { try await self.drain() }
    }

    private func isCurrent(_ job: Job, generation token: UUID) -> Bool {
        enabled && generation == token && jobs[job.snapshot.id]?.token == job.token && !Task.isCancelled
    }

    private func finish(_ job: Job) {
        if jobs[job.snapshot.id]?.token == job.token { jobs.removeValue(forKey: job.snapshot.id) }
        active = nil
    }

    private func drain() async throws {
        defer {
            active = nil
            worker = nil
            startWorkerIfNeeded()
        }
        var firstError: Error?
        while enabled, !Task.isCancelled, !order.isEmpty {
            let id = order.removeFirst()
            guard let job = jobs[id] else { continue }
            active = job
            let token = generation
            do {
                let snapshot = job.snapshot
                // A capture may be enqueued for indexing before its first recovery write finishes.
                if let recovery { try await recovery.preserve(snapshot) }
                guard isCurrent(job, generation: token) else { finish(job); continue }
                if let record = try await store.records().first(where: { $0.id == snapshot.id }),
                   record.revision == snapshot.revision, record.edits == snapshot.edits,
                   record.ocrRevision == snapshot.revision {
                    finish(job)
                    continue
                }
                var edits = snapshot.edits
                edits.style.backgroundID = "" // Decorative backgrounds are not searchable content.
                let image = try await renderer.renderImage(RenderRequest(image: snapshot.image, edits: edits,
                    backgroundURL: nil, documentID: snapshot.id, revision: snapshot.revision))
                guard isCurrent(job, generation: token) else { finish(job); continue }
                let text = try await recognizer.recognizeText(in: image)
                guard isCurrent(job, generation: token) else { finish(job); continue }
                try await store.indexOCR(id: snapshot.id, text: text, revision: snapshot.revision, privateCapture: false)
                lastFailure = nil
            } catch {
                if isCurrent(job, generation: token), !(error is CancellationError) {
                    firstError = firstError ?? error
                    lastFailure = error.localizedDescription
                }
            }
            finish(job)
        }
        if let firstError { throw firstError }
    }
}
