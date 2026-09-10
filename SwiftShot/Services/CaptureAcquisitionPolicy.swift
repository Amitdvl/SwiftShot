import Foundation
import CoreGraphics

struct CaptureDisplayLayout: Equatable, Sendable {
    let id: UInt32
    let frame: CGRect
    var scale: CGFloat = 1
}

struct CapturePixelDimensions: Sendable {
    let width: Int
    let height: Int
    let reservedBytes: Int
}

enum CaptureAcquisitionPolicy {
    static func targets(mode: CaptureMode, pointer: CGPoint, displays: [CaptureDisplayLayout]) throws -> [CaptureDisplayLayout] {
        guard !displays.isEmpty else {
            throw CaptureError.failed("No display is available. Reconnect your display and try again.")
        }
        guard Set(displays.map(\.id)).count == displays.count,
              displays.allSatisfy({ $0.frame.width.isFinite && $0.frame.height.isFinite &&
                  $0.frame.minX.isFinite && $0.frame.minY.isFinite && $0.frame.width > 0 && $0.frame.height > 0 &&
                  $0.scale.isFinite && $0.scale > 0 }) else {
            throw CaptureError.failed("The display layout is unavailable. Try capturing again.")
        }
        if mode == .fullscreen {
            return [displays.first(where: { $0.frame.contains(pointer) }) ?? displays[0]]
        }
        return displays
    }

    static func layoutMatches(_ original: [CaptureDisplayLayout], _ current: [CaptureDisplayLayout]) -> Bool {
        guard original.count == current.count,
              Set(original.map(\.id)).count == original.count,
              Set(current.map(\.id)).count == current.count else { return false }
        return original.allSatisfy { item in current.contains(item) }
    }

    static func dimensions(points: CGSize, scale: CGFloat) throws -> CapturePixelDimensions {
        guard points.width.isFinite, points.height.isFinite, scale.isFinite,
              points.width > 0, points.height > 0, scale > 0,
              points.width * scale <= 64_000_000, points.height * scale <= 64_000_000 else {
            throw CaptureError.failed("Invalid capture dimensions")
        }
        let width = Int((points.width * scale).rounded())
        let height = Int((points.height * scale).rounded())
        guard width > 0, height > 0, width * height <= 64_000_000 else {
            throw CaptureError.failed("This capture is too large to acquire safely. Use a smaller display resolution or window.")
        }
        // SDR BGRA output, 256-byte row alignment, plus a second buffer's worth
        // of headroom for ScreenCaptureKit's handoff. Reserve before acquisition.
        let rowBytes = ((width * 4 + 255) / 256) * 256
        return CapturePixelDimensions(width: width, height: height, reservedBytes: rowBytes * height * 2)
    }
}

/// Display/application metadata only; the query surface deliberately has no
/// windows property. Native SCK objects remain main-actor confined.
@MainActor
final class CaptureDisplayMetadataCache<Display, Application> {
    typealias Snapshot = (displays: [Display], applications: [Application])
    typealias Resolved = (displays: [Display], excludedApplications: [Application])
    private let ownProcessID: Int32
    private let processID: (Application) -> Int32
    private var cached: (layout: [CaptureDisplayLayout], metadata: Resolved)?

    init(ownProcessID: Int32, processID: @escaping (Application) -> Int32) {
        self.ownProcessID = ownProcessID
        self.processID = processID
    }

    func metadata(for layout: [CaptureDisplayLayout], query: @MainActor (Bool) async throws -> Snapshot) async throws -> Resolved {
        try Task.checkCancellation()
        if let cached, CaptureAcquisitionPolicy.layoutMatches(cached.layout, layout) { return cached.metadata }
        cached = nil
        var snapshot = try await query(true)
        try Task.checkCancellation()
        var ownApplication = snapshot.applications.first { processID($0) == ownProcessID }
        if ownApplication == nil {
            // The last SwiftShot panel may have just left the screen. Refresh
            // once with offscreen content, consuming only app/display metadata.
            snapshot = try await query(false)
            try Task.checkCancellation()
            ownApplication = snapshot.applications.first { processID($0) == ownProcessID }
        }
        guard let ownApplication else {
            throw CaptureError.failed("SwiftShot could not safely exclude its own interface from this display capture. Reopen SwiftShot and try again, or use Window capture to select a specific window.")
        }
        let result: Resolved = (snapshot.displays, [ownApplication])
        cached = (layout, result)
        return result
    }

    func invalidate() { cached = nil }
}

@MainActor
final class CaptureMemoryBudget {
    let limit: Int
    private var reserved = 0
    init(limit: Int = 512 * 1024 * 1024) { self.limit = limit }
    func reserve(_ bytes: Int) throws {
        guard bytes > 0, bytes <= limit, reserved <= limit - bytes else {
            throw CaptureError.failed("The displays or pending captures exceed the safe capture memory limit. Finish the current capture or use fewer/lower-resolution displays.")
        }
        reserved += bytes
    }
    func release(_ bytes: Int) {
        precondition(bytes >= 0 && bytes <= reserved, "Unbalanced capture memory reservation")
        reserved -= bytes
    }
}

@MainActor
enum CaptureAcquisitionBatch {
    static func run<Input: Sendable, Output: Sendable>(_ inputs: [Input], maximumConcurrent: Int,
        operation: @escaping @MainActor @Sendable (Input) async throws -> Output) async throws -> [Output] {
        try Task.checkCancellation()
        guard maximumConcurrent > 0 else { throw CaptureError.failed("Invalid capture concurrency limit.") }
        guard !inputs.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            var next = 0
            var results: [(Int, Output)] = []
            func enqueue(_ index: Int) {
                let input = inputs[index]
                group.addTask { [input, operation] in
                    try Task.checkCancellation()
                    let value = try await operation(input)
                    try Task.checkCancellation()
                    return (index, value)
                }
            }
            for index in 0..<min(maximumConcurrent, inputs.count) {
                enqueue(index)
                next += 1
            }
            do {
                while let result = try await group.next() {
                    try Task.checkCancellation()
                    results.append(result)
                    if next < inputs.count {
                        enqueue(next)
                        next += 1
                    }
                }
            } catch {
                // Native screenshots may finish after Swift task cancellation;
                // structured concurrency keeps their reservations alive until then.
                group.cancelAll()
                throw error
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}
