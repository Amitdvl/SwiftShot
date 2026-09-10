import Foundation

/// Receipt identity is scoped to a particular view/presentation, not a timeout.
struct CapturePresentationReceipt {
    private var current: UUID?
    private var completed = false
    mutating func request(_ id: UUID) {
        guard id != current else { return }
        current = id
        completed = false
    }
    mutating func complete(_ id: UUID, isVisible: Bool) -> Bool {
        guard isVisible, current == id, !completed else { return false }
        completed = true
        return true
    }
}
