import Foundation
import CoreGraphics

/// Acquisition tasks are session-owned; exporting a selected image is not.
@MainActor
final class CaptureSessionCoordinator {
    private(set) var id = UUID()
    var freezeTask: Task<[FrozenScreen], Error>?
    var regionTask: Task<CGImage, Error>?

    @discardableResult
    func begin() -> UUID {
        freezeTask?.cancel()
        regionTask?.cancel()
        freezeTask = nil
        regionTask = nil
        id = UUID()
        return id
    }

    func isCurrent(_ token: UUID) -> Bool { token == id }
}
