import Foundation

/// Admission and clipboard ordering are independent from editor navigation.
/// One document cannot export twice concurrently; exports of different images
/// may overlap, with only the latest clipboard request allowed to publish.
@MainActor
final class CaptureExportCoordinator {
    struct Permit: Equatable, Sendable {
        let id: UUID
        let documentID: UUID
    }
    private var active: [UUID: UUID] = [:]
    private var clipboardOwner: UUID?
    var hasActiveExports: Bool { !active.isEmpty }

    func begin(documentID: UUID) -> Permit? {
        guard active[documentID] == nil else { return nil }
        let permit = Permit(id: UUID(), documentID: documentID)
        active[documentID] = permit.id
        return permit
    }

    func isExporting(_ documentID: UUID) -> Bool { active[documentID] != nil }

    func claimClipboard(_ permit: Permit) { clipboardOwner = permit.id }

    func canPublishClipboard(_ permit: Permit) -> Bool {
        clipboardOwner == permit.id && active[permit.documentID] == permit.id
    }

    func finish(_ permit: Permit) {
        if active[permit.documentID] == permit.id { active.removeValue(forKey: permit.documentID) }
    }
}
