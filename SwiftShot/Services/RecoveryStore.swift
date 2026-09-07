import AppKit
import ImageIO
import UniformTypeIdentifiers

struct RecoveryRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var edits: CaptureEdits
    var revision: Int
    var savedPath: String?
}

struct RecoveredCapture: @unchecked Sendable {
    let record: RecoveryRecord
    let image: CGImage
}

/// One durable folder per capture. Editing and failed exports never remove originals.
actor RecoveryStore {
    let root: URL
    private var originalIDs: Set<UUID> = []
    private var discardedIDs: Set<UUID> = []

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftShot/Recovery", isDirectory: true)
    }

    func persist(id: UUID, image: CGImage, edits: CaptureEdits, revision: Int, savedURL: URL?) throws {
        guard !discardedIDs.contains(id) else { return }
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        let metadata = folder.appendingPathComponent("capture.json")
        let old = (try? Data(contentsOf: metadata)).flatMap { try? JSONDecoder().decode(RecoveryRecord.self, from: $0) }
        guard revision >= (old?.revision ?? -1) else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("original.png")
        if !originalIDs.contains(id), !FileManager.default.fileExists(atPath: original.path) {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                throw CaptureError.failed("Couldn't preserve this capture. Keep the editor open and try saving it.")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw CaptureError.failed("Couldn't encode the recovery image.") }
            try (data as Data).write(to: original, options: .atomic)
        }
        originalIDs.insert(id)
        let record = RecoveryRecord(id: id, createdAt: old?.createdAt ?? Date(), updatedAt: Date(), edits: edits, revision: revision, savedPath: savedURL?.path)
        try JSONEncoder().encode(record).write(to: metadata, options: .atomic)
    }

    func records() throws -> [RecoveryRecord] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .compactMap { folder in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("capture.json")) else { return nil }
                return try? JSONDecoder().decode(RecoveryRecord.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func load(id: UUID) throws -> RecoveredCapture {
        let folder = root.appendingPathComponent(id.uuidString)
        let record = try JSONDecoder().decode(RecoveryRecord.self, from: Data(contentsOf: folder.appendingPathComponent("capture.json")))
        guard let source = CGImageSourceCreateWithURL(folder.appendingPathComponent("original.png") as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CaptureError.failed("The recovery image couldn't be opened. Your saved exports are unaffected.")
        }
        return RecoveredCapture(record: record, image: image)
    }

    /// Only resolved captures are pruned; every unsaved capture remains recoverable.
    func pruneSaved(except latest: UUID, protected: Set<UUID> = []) throws {
        for record in try records() where record.id != latest && record.savedPath != nil && !protected.contains(record.id) {
            try discard(id: record.id)
        }
    }

    func discard(id: UUID) throws {
        let folder = root.appendingPathComponent(id.uuidString)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        discardedIDs.insert(id)
        originalIDs.remove(id)
    }
}
