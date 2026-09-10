import Foundation

struct RecoveryRetentionPolicy: Codable, Equatable, Sendable {
    var maximumSavedCount: Int?
    var maximumSavedAgeDays: Int?

    /// Nil limits mean keep forever. Policies are applied only on explicit invocation.
    init(maximumSavedCount: Int? = nil, maximumSavedAgeDays: Int? = nil) {
        self.maximumSavedCount = maximumSavedCount
        self.maximumSavedAgeDays = maximumSavedAgeDays
    }
}

struct RecoveryHistoryEntry: Identifiable, Sendable {
    let record: RecoveryRecord
    let storageBytes: Int64
    let isRecoverable: Bool
    var id: UUID { record.id }
}

struct RecoveryStorageUsage: Sendable {
    let totalBytes: Int64
    let captureCount: Int
    let pinnedCount: Int
    let unresolvedCount: Int
}

struct RecoveryReconciliationIssue: Identifiable, Sendable {
    let id: UUID
    let message: String
}

struct RecoveryReconciliationReport: Sendable {
    var repairedIDs: [UUID] = []
    var issues: [RecoveryReconciliationIssue] = []
}
