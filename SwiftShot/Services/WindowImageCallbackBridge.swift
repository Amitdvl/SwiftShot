import CoreGraphics
import Foundation

/// Window-only SDK callback boundary; invocation stays on the capture service's
/// actor, while the completion may arrive on an arbitrary SDK thread.
enum WindowImageCallbackBridge {
    @MainActor
    static func capture(traceRunID: UUID?, trace: CaptureLatencyTrace = .shared,
                        request: (@escaping @Sendable (CGImage?, (any Error)?) -> Void) -> Void) async throws -> CGImage {
        // Transport the original Error as a value: throwing-continuation
        // transport can rebox NSError and lose the SDK error's object identity.
        let result: Result<CGImage, any Error> = await withCheckedContinuation { continuation in
            request { image, error in
                // Record SDK delivery on its callback thread, before resuming
                // the awaiting actor. A late callback retains its original run.
                trace.mark(.windowImageCallbackReceived, for: traceRunID)
                if let error {
                    continuation.resume(returning: .failure(error))
                } else if let image {
                    continuation.resume(returning: .success(image))
                } else {
                    continuation.resume(returning: .failure(CaptureError.failed("The window capture returned no image.")))
                }
            }
        }
        return try result.get()
    }
}
