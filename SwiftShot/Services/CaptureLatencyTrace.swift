import Foundation

/// Explicitly armed, bounded, metadata-only pilot trace. Never records content.
final class CaptureLatencyTrace: @unchecked Sendable {
    static let shared = CaptureLatencyTrace()

    enum Stage: String, Codable, Sendable {
        case shortcutReceived, shortcutDispatched
        case captureRequested, scrollDrainStarted, scrollDrainFinished
        case recoveryHandoffStarted, recoveryHandoffFinished, captureWindowsHidden
        case freezeTaskStarted, permissionCheckStarted, permissionCheckFinished, freezeReturned
        case overlayPresentationStarted, overlayPresentationFinished
        case panelCreationStarted, panelCreationFinished, hostingAttachmentStarted, hostingAttachmentFinished
        case panelOrderStarted, panelOrderFinished, activationStarted, activationFinished
        case receiptEnqueued, receiptDequeued, layoutStarted, layoutFinished
        case displayStarted, displayFinished, transactionCommitted, transactionFlushed
        case transactionCompleted, receiptDelivered
        case selectionCommitted, selectionCallbacksFinished
        case windowCaptureStarted, windowMetadataStarted, windowMetadataResolved
        case windowImageRequestStarted, windowImageCallbackReceived, windowImageRequestReturned, windowResultPrepared
        case settingsSaveStarted, settingsSaveFinished, captureSoundStarted, captureSoundFinished
    }
    enum Presentation: String, Codable, Sendable { case selector, editor }
    struct Event: Codable, Sendable {
        var stage: Stage
        var offsetMilliseconds: Double
        var presentation: Presentation?
        var surface: Int?
    }
    struct Run: Codable, Sendable {
        var id: UUID
        var events: [Event]
        var droppedEvents: Int
        var isComplete: Bool
    }
    struct Report: Codable, Sendable {
        var schemaVersion = 1
        var runs: [Run]
        var droppedRuns: Int
        var activeRunID: UUID?
    }

    private let lock = NSLock()
    private let runCapacity: Int
    private let eventCapacity: Int
    private let now: @Sendable () -> UInt64
    private var runs: [Run] = []
    private var current: UUID?
    private var started: UInt64 = 0
    private var droppedRuns = 0

    init(runCapacity: Int = 32, eventCapacity: Int = 256,
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.runCapacity = max(1, min(32, runCapacity))
        self.eventCapacity = max(1, min(256, eventCapacity))
        self.now = now
    }

    var activeRunID: UUID? { lock.withLock { current } }

    @discardableResult func beginRun(_ id: UUID) -> Bool {
        lock.withLock {
            guard !runs.contains(where: { $0.id == id }) else { return false }
            if current != nil, !runs.isEmpty { runs[runs.count - 1].isComplete = true }
            if runs.count == runCapacity {
                runs.removeFirst()
                if droppedRuns < Int.max { droppedRuns += 1 }
            }
            current = id
            started = now()
            runs.append(Run(id: id, events: [], droppedEvents: 0, isComplete: false))
            return true
        }
    }

    @discardableResult func endRun(_ id: UUID?) -> Bool {
        guard let id else { return false }
        return lock.withLock {
            guard id == current, !runs.isEmpty else { return false }
            runs[runs.count - 1].isComplete = true
            current = nil
            return true
        }
    }

    @discardableResult func mark(_ stage: Stage, for id: UUID?,
                                presentation: Presentation? = nil, surface: Int? = nil) -> Bool {
        guard let id, surface.map({ (0..<16).contains($0) }) ?? true else { return false }
        return lock.withLock {
            guard id == current, !runs.isEmpty else { return false }
            let index = runs.count - 1
            guard runs[index].events.count < eventCapacity else {
                if runs[index].droppedEvents < Int.max { runs[index].droppedEvents += 1 }
                return false
            }
            let timestamp = now()
            guard timestamp >= started else { return false }
            runs[index].events.append(Event(stage: stage,
                offsetMilliseconds: Double(timestamp - started) / 1_000_000,
                presentation: presentation, surface: surface))
            return true
        }
    }

    func reset() {
        lock.withLock {
            runs.removeAll(keepingCapacity: false)
            current = nil
            started = 0
            droppedRuns = 0
        }
    }

    func snapshot() -> Report {
        lock.withLock { Report(runs: runs, droppedRuns: droppedRuns, activeRunID: current) }
    }
}
