import Foundation

enum ScrollingCaptureSessionState: Equatable, Sendable {
    case idle
    case starting
    case capturing(ScrollingStitchProgress, ScrollingIngestDisposition?)
    case finishing
    case finished
    case cancelled
    case failed(String)
}

enum ScrollingCaptureSessionError: Error, Equatable, Sendable {
    case invalidState
    case sourceFailed(String)
    case stitchFailed(ScrollingStitchError)
}

enum ScrollingCaptureOutcome: @unchecked Sendable, Equatable {
    case captured(ScrollingStitchArtifact)
    case cancelled

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.cancelled, .cancelled): return true
        case let (.captured(a), .captured(b)):
            return a.acceptedFrames == b.acceptedFrames && a.appendedRows == b.appendedRows &&
                a.image.width == b.image.width && a.image.height == b.image.height
        default: return false
        }
    }
}

/// Owns one passive capture from native stream start through a single terminal outcome.
@MainActor
final class ScrollingCaptureSession {
    private let source: any ScrollingFrameSource
    private let engine: ScrollingStitchEngine
    private var consumeTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var sourceIsRunning = false
    private var terminalError: ScrollingCaptureSessionError?
    private var latestProgress = ScrollingStitchProgress(acceptedFrames: 0, outputWidth: 0,
                                                         outputHeight: 0, retainedBytes: 0)
    private var onStateChange: ((ScrollingCaptureSessionState) -> Void)?
    private(set) var state: ScrollingCaptureSessionState = .idle {
        didSet { onStateChange?(state) }
    }

    init(source: any ScrollingFrameSource,
         engine: ScrollingStitchEngine = ScrollingStitchEngine()) {
        self.source = source
        self.engine = engine
    }

    func start(for region: CaptureRegionReference,
               onStateChange: ((ScrollingCaptureSessionState) -> Void)? = nil) async throws {
        guard state == .idle else { throw ScrollingCaptureSessionError.invalidState }
        self.onStateChange = onStateChange
        state = .starting
        do {
            let frames = try await source.start(for: region)
            sourceIsRunning = true
            state = .capturing(.init(acceptedFrames: 0, outputWidth: 0,
                                     outputHeight: 0, retainedBytes: 0), nil)
            consumeTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await frame in frames {
                        try Task.checkCancellation()
                        guard case .capturing = self.state else { continue }
                        let result = try await self.engine.ingest(frame)
                        guard case .capturing = self.state else { continue }
                        self.latestProgress = result.progress
                        self.state = .capturing(result.progress, result.disposition)
                    }
                    if case .capturing = self.state {
                        self.fail(.sourceFailed("Capture stream ended unexpectedly."))
                    }
                } catch is CancellationError {
                    // Cancellation is owned by cancel(); stale callbacks stay silent.
                } catch let error as ScrollingStitchError {
                    self.fail(.stitchFailed(error))
                } catch {
                    self.fail(.sourceFailed(error.localizedDescription))
                }
            }
        } catch {
            let failure = ScrollingCaptureSessionError.sourceFailed(error.localizedDescription)
            terminalError = failure
            state = .failed(error.localizedDescription)
            throw failure
        }
    }

    func finish() async throws -> ScrollingCaptureOutcome {
        let canFinish: Bool
        switch state {
        case .capturing: canFinish = true
        case .failed where latestProgress.acceptedFrames > 0: canFinish = true
        default: canFinish = false
        }
        guard canFinish else {
            if let terminalError { await stopSourceOnce(); throw terminalError }
            throw ScrollingCaptureSessionError.invalidState
        }
        state = .finishing
        await stopSourceOnce()
        await consumeTask?.value
        consumeTask = nil
        terminalError = nil
        do {
            let artifact = try await engine.render()
            state = .finished
            return .captured(artifact)
        } catch let error as ScrollingStitchError {
            let failure = ScrollingCaptureSessionError.stitchFailed(error)
            terminalError = failure
            state = .failed(String(describing: error))
            throw failure
        } catch {
            let failure = ScrollingCaptureSessionError.sourceFailed(error.localizedDescription)
            terminalError = failure
            state = .failed(error.localizedDescription)
            throw failure
        }
    }

    func cancel() async -> ScrollingCaptureOutcome {
        guard state != .finished else { return .cancelled }
        if state != .cancelled {
            state = .cancelled
            consumeTask?.cancel()
        }
        await stopSourceOnce()
        await consumeTask?.value
        consumeTask = nil
        await engine.cancel()
        return .cancelled
    }

    private func stopSourceOnce() async {
        if let stopTask {
            await stopTask.value
            return
        }
        guard sourceIsRunning else { return }
        sourceIsRunning = false
        let source = self.source
        let task = Task { await source.stop() }
        stopTask = task
        await task.value
    }

    private func fail(_ error: ScrollingCaptureSessionError) {
        guard case .capturing = state else { return }
        terminalError = error
        state = .failed(error.message)
    }
}

private extension ScrollingCaptureSessionError {
    var message: String {
        switch self {
        case .invalidState: return "The scrolling capture is no longer active."
        case let .sourceFailed(message): return message
        case let .stitchFailed(error): return String(describing: error)
        }
    }
}
