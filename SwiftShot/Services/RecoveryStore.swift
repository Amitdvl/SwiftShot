import AppKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

struct RecoveryRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var edits: CaptureEdits
    var revision: Int
    var savedPath: String?
    // Optional storage fields preserve decoding of pre-history recovery records.
    var pinned: Bool? = nil
    var ocrText: String? = nil
    var ocrRevision: Int? = nil
    var reconciled: Bool? = nil
    var isPinned: Bool { pinned == true }
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
    private var privateIDs: Set<UUID> = []
    // Retention resolves a saved revision, not every future edit of its ID.
    // Keep the floor for late producers; explicit discard/private always win.
    private var retentionRevisionFloors: [UUID: Int] = [:]
    private var index: [UUID: RecoveryRecord] = [:]
    private var indexLoaded = false
    private var lastReconciliation = RecoveryReconciliationReport()
    private var thumbnailCache: [String: CGImage] = [:]
    private var thumbnailOrder: [String] = []
    private let thumbnailRenderer = ImageRenderer(cacheByteLimit: 0, cacheEntryLimit: 0)
    // Late writes can survive a caller's cancellation. Tombstones are not evicted;
    // admission is bounded until a fully flushed app restart safely resets the session.
    private let maximumLifetimeTombstones = 65_536

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftShot/Recovery", isDirectory: true)
    }

    func persist(id: UUID, image: CGImage, edits: CaptureEdits, revision: Int, savedURL: URL?, privateCapture: Bool = false) throws {
        if privateCapture { try markPrivate(id: id) }
        guard !discardedIDs.contains(id), !privateIDs.contains(id) else { return }
        if let floor = retentionRevisionFloors[id], revision <= floor { return }
        try ensureIndex()
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        let metadata = folder.appendingPathComponent("capture.json")
        let old = index[id]
        guard revision >= (old?.revision ?? -1) else { return }
        if let old, originalIDs.contains(id), old.revision == revision, old.edits == edits,
           old.savedPath == savedURL?.path { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("original.png")
        if !originalIDs.contains(id) {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                throw CaptureError.failed("Couldn't preserve this capture. Keep the editor open and try saving it.")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw CaptureError.failed("Couldn't encode the recovery image.") }
            try durableWrite(data as Data, to: original)
        }
        originalIDs.insert(id)
        var record = RecoveryRecord(id: id, createdAt: old?.createdAt ?? Date(), updatedAt: Date(), edits: edits, revision: revision, savedPath: savedURL?.path)
        record.pinned = old?.pinned
        record.reconciled = old?.reconciled
        if old?.revision == revision, old?.edits == edits {
            record.ocrText = old?.ocrText
            record.ocrRevision = old?.ocrRevision
        }
        try durableWrite(JSONEncoder().encode(record), to: metadata)
        index[id] = record
        evictThumbnails(id: id)
    }

    func records() throws -> [RecoveryRecord] {
        try ensureIndex()
        return index.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func load(id: UUID) throws -> RecoveredCapture {
        try ensureIndex()
        let folder = root.appendingPathComponent(id.uuidString)
        guard let record = index[id] else { throw CaptureError.failed("This recovery record is unavailable.") }
        guard let source = CGImageSourceCreateWithURL(folder.appendingPathComponent("original.png") as CFURL, nil),
              validDimensions(source) != nil,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CaptureError.failed("The recovery image couldn't be opened. Your saved exports are unaffected.")
        }
        return RecoveredCapture(record: record, image: image)
    }

    /// Only resolved captures are pruned; every unsaved capture remains recoverable.
    func pruneSaved(except latest: UUID, protected: Set<UUID> = []) throws {
        for record in try records() where record.id != latest && record.savedPath != nil && !record.isPinned && !protected.contains(record.id) {
            try removeSavedForRetention(record)
        }
    }

    func discard(id: UUID) throws {
        guard canTrackLifetimeID(id) else {
            throw CaptureError.failed("History tracking has reached its session limit. Save open captures and restart SwiftShot before deleting more captures.")
        }
        let folder = root.appendingPathComponent(id.uuidString)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        discardedIDs.insert(id)
        privateIDs.remove(id)
        retentionRevisionFloors.removeValue(forKey: id)
        originalIDs.remove(id)
        index.removeValue(forKey: id)
        evictThumbnails(id: id)
    }

    /// Explicit rescan, normally once at launch. Never deletes damaged evidence.
    @discardableResult
    func reconcile() throws -> RecoveryReconciliationReport {
        guard FileManager.default.fileExists(atPath: root.path) else {
            index = [:]
            indexLoaded = true
            lastReconciliation = RecoveryReconciliationReport()
            return lastReconciliation
        }
        let folders = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        var next: [UUID: RecoveryRecord] = [:]
        var report = RecoveryReconciliationReport()
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent), !discardedIDs.contains(id), !privateIDs.contains(id) else { continue }
            let properties = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard properties.isDirectory == true, properties.isSymbolicLink != true else {
                report.issues.append(RecoveryReconciliationIssue(id: id, message: "Recovery folder is not a regular directory."))
                continue
            }
            let metadata = folder.appendingPathComponent("capture.json")
            let original = folder.appendingPathComponent("original.png")
            let metadataExists = FileManager.default.fileExists(atPath: metadata.path)
            if (try? metadata.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true ||
               (try? original.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                report.issues.append(RecoveryReconciliationIssue(id: id, message: "Recovery files are symbolic links. Files were not followed or changed."))
                continue
            }
            let metadataSize = (try? metadata.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let data = metadataSize <= 8 * 1_024 * 1_024 ? (try? Data(contentsOf: metadata)) : nil
            let decoded = data.flatMap { try? JSONDecoder().decode(RecoveryRecord.self, from: $0) }
            let source = CGImageSourceCreateWithURL(original as CFURL, nil)
            let dimensions = source.flatMap { validDimensions($0) }
            // A valid header alone does not prove an interrupted PNG is recoverable.
            let imageIsReadable = dimensions != nil && source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, [kCGImageSourceShouldCache: false] as CFDictionary) } != nil
            if let decoded, decoded.id == id {
                next[id] = decoded
                if imageIsReadable { originalIDs.insert(id) }
                else { report.issues.append(RecoveryReconciliationIssue(id: id, message: "Original image is missing or damaged. Files were retained for manual recovery.")) }
                continue
            }
            guard imageIsReadable, let dimensions else {
                report.issues.append(RecoveryReconciliationIssue(id: id, message: "Metadata and/or original image cannot be read. Files were retained for manual recovery."))
                continue
            }
            // Preserve corrupt edit metadata before reconstructing a raw original record.
            if metadataExists {
                let backup = folder.appendingPathComponent("capture.corrupt.\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: metadata, to: backup)
                let file = try FileHandle(forWritingTo: backup)
                defer { try? file.close() }
                try file.synchronize()
            }
            let values = try original.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            var recovered = RecoveryRecord(id: id, createdAt: values.creationDate ?? Date(),
                updatedAt: values.contentModificationDate ?? Date(),
                edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: dimensions.width, height: dimensions.height)),
                revision: 0, savedPath: nil)
            recovered.reconciled = true
            try durableWrite(JSONEncoder().encode(recovered), to: metadata)
            next[id] = recovered
            originalIDs.insert(id)
            report.repairedIDs.append(id)
        }
        index = next
        indexLoaded = true
        lastReconciliation = report
        releaseTransientCaches()
        return report
    }

    func reconciliationReport() throws -> RecoveryReconciliationReport {
        try ensureIndex()
        return lastReconciliation
    }

    func recentRecords(limit: Int = 20) throws -> [RecoveryHistoryEntry] {
        try records().prefix(max(0, min(limit, 500))).map { record in
            let folder = root.appendingPathComponent(record.id.uuidString)
            return RecoveryHistoryEntry(record: record, storageBytes: try directoryBytes(folder),
                isRecoverable: !lastReconciliation.issues.contains { $0.id == record.id })
        }
    }

    func storageUsage() throws -> RecoveryStorageUsage {
        try ensureIndex()
        return RecoveryStorageUsage(totalBytes: try directoryBytes(root), captureCount: index.count,
            pinnedCount: index.values.filter(\.isPinned).count,
            unresolvedCount: index.values.filter { $0.savedPath == nil }.count)
    }

    func setPinned(id: UUID, isPinned: Bool) throws {
        try ensureIndex()
        guard var record = index[id] else { throw CaptureError.failed("This history capture is unavailable.") }
        guard record.isPinned != isPinned else { return }
        record.pinned = isPinned
        try updateMetadata(record)
    }

    /// Retention is explicit, saved-only, and never removes pinned/open/unresolved originals.
    @discardableResult
    func applyRetention(_ policy: RecoveryRetentionPolicy, protected: Set<UUID> = [], now: Date = Date()) throws -> [UUID] {
        let candidates = try records().filter { $0.savedPath != nil && !$0.isPinned && !protected.contains($0.id) }
        var removed: [UUID] = []
        for (position, record) in candidates.enumerated() {
            let exceedsCount = policy.maximumSavedCount.map { position >= max(0, $0) } ?? false
            let expired = policy.maximumSavedAgeDays.map { now.timeIntervalSince(record.updatedAt) > Double(max(0, $0)) * 86_400 } ?? false
            if exceedsCount || expired {
                try removeSavedForRetention(record)
                removed.append(record.id)
            }
        }
        return removed
    }

    /// Caller supplies OCR from the rendered, cropped/redacted revision, never the original.
    func indexOCR(id: UUID, text: String, revision: Int, privateCapture: Bool) throws {
        // Actor messages are not FIFO. A clear-index request may overtake a canceled
        // OCR writer, so cancellation must also be enforced at the storage boundary.
        try Task.checkCancellation()
        if privateCapture { try markPrivate(id: id); return }
        guard !privateIDs.contains(id), !discardedIDs.contains(id) else { return }
        try ensureIndex()
        guard var record = index[id], record.revision == revision else { return }
        record.ocrText = String(text.prefix(100_000))
        record.ocrRevision = revision
        try updateMetadata(record)
    }

    func searchOCR(_ query: String, limit: Int = 50) throws -> [RecoveryRecord] {
        let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return try records().filter { record in
            guard !privateIDs.contains(record.id), record.ocrRevision == record.revision, let text = record.ocrText else { return false }
            let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return words.allSatisfy { folded.contains($0) }
        }.prefix(max(0, min(limit, 500))).map { $0 }
    }

    /// Clears only derived searchable text. Editable originals, edits and pins remain intact.
    func clearOCR(id: UUID) throws {
        try ensureIndex()
        guard var record = index[id], record.ocrText != nil || record.ocrRevision != nil else { return }
        record.ocrText = nil
        record.ocrRevision = nil
        try updateMetadata(record)
    }

    func clearOCRIndex() throws {
        for id in try records().map(\.id) { try clearOCR(id: id) }
    }

    /// Metadata-only combining admission. Does not reconcile/scan/decode image pixels.
    /// Width/height predict edited native output; retainedSourceBytes charges the original
    /// provider as well, since raw crops may keep it alive behind a smaller CGImage.
    func combineSource(id: UUID) throws -> CaptureCombineSource {
        guard !privateIDs.contains(id), !discardedIDs.contains(id) else {
            throw CaptureError.failed("This capture is not available in history.")
        }
        let folder = root.appendingPathComponent(id.uuidString)
        let metadataURL = folder.appendingPathComponent("capture.json")
        let originalURL = folder.appendingPathComponent("original.png")
        for url in [folder, metadataURL, originalURL] {
            guard (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                throw CaptureError.failed("Symbolic links cannot be combined from recovery storage.")
            }
        }
        let record: RecoveryRecord
        if let cached = index[id] { record = cached }
        else {
            let size = try metadataURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 8 * 1_024 * 1_024 else { throw CaptureError.failed("This capture's edit metadata is too large.") }
            record = try JSONDecoder().decode(RecoveryRecord.self, from: Data(contentsOf: metadataURL))
        }
        guard record.id == id,
              let source = CGImageSourceCreateWithURL(originalURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let dimensions = validDimensions(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw CaptureError.failed("The original capture's metadata cannot be read.")
        }
        let crop = record.edits.crop
        let style = record.edits.style
        guard [crop.minX, crop.minY, crop.width, crop.height].allSatisfy(\.isFinite),
              crop == crop.integral, crop.width >= 1, crop.height >= 1,
              CGRect(x: 0, y: 0, width: dimensions.width, height: dimensions.height).contains(crop),
              [style.padding, style.cornerRadius, style.shadow].allSatisfy({ $0.isFinite && (0...16_384).contains($0) }) else {
            throw CaptureError.failed("The capture's crop or styling geometry is invalid.")
        }
        let padding = style.backgroundID.isEmpty ? 0 : Int(style.padding.rounded())
        let width = Int(crop.width) + padding * 2
        let height = Int(crop.height) + padding * 2
        guard width <= 32_768, height <= 32_768, width * height <= 64_000_000 else {
            throw CaptureError.failed("This capture's edited output is too large to combine safely.")
        }
        let depth = properties[kCGImagePropertyDepth] as? Int ?? 8
        let floating = (properties[kCGImagePropertyIsFloat] as? Bool ?? false) || depth > 16
        let bits = floating ? 32 : depth > 8 ? 16 : 8
        let bytesPerPixel = bits / 8 * 4
        // Conservative scanline alignment for ImageIO's native decoded backing.
        let originalRow = ((dimensions.width * bytesPerPixel + 255) / 256) * 256
        let editedRow = ((width * bytesPerPixel + 255) / 256) * 256
        return CaptureCombineSource(width: width, height: height, bytesPerRow: editedRow,
            bitsPerComponent: bits, isFloatingPoint: floating,
            retainedSourceBytes: originalRow * dimensions.height)
    }

    /// Lazy edited thumbnails; original/cropped/redacted-away pixels are never shown.
    func thumbnail(id: UUID, maximumPixelSize: Int = 256) async throws -> CGImage {
        try ensureIndex()
        guard let record = index[id] else { throw CaptureError.failed("This history capture is unavailable.") }
        let maximum = max(1, min(maximumPixelSize, 1024))
        let key = "\(id)-\(record.revision)-\(maximum)"
        if let cached = thumbnailCache[key] { return cached }
        let loaded = try load(id: id)
        var edits = loaded.record.edits
        edits.style.backgroundID = ""
        let rendered = try await thumbnailRenderer.renderImage(RenderRequest(image: loaded.image, edits: edits, backgroundURL: nil))
        let ratio = min(1, CGFloat(maximum) / CGFloat(max(rendered.width, rendered.height)))
        let width = max(1, Int(CGFloat(rendered.width) * ratio))
        let height = max(1, Int(CGFloat(rendered.height) * ratio))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureError.failed("Couldn't allocate a history thumbnail.") }
        context.interpolationQuality = .high
        context.draw(rendered, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw CaptureError.failed("Couldn't create a history thumbnail.") }
        guard index[id]?.revision == loaded.record.revision, index[id]?.edits == loaded.record.edits else {
            throw CaptureError.failed("This history capture changed while its thumbnail was being prepared. Retry the thumbnail.")
        }
        do {
            thumbnailCache[key] = image
            thumbnailOrder.removeAll { $0 == key }
            thumbnailOrder.append(key)
            while thumbnailOrder.count > 12 || thumbnailCache.values.reduce(0, { $0 + $1.bytesPerRow * $1.height }) > 24 * 1_024 * 1_024 {
                thumbnailCache.removeValue(forKey: thumbnailOrder.removeFirst())
            }
        }
        return image
    }

    func releaseTransientCaches() {
        thumbnailCache.removeAll()
        thumbnailOrder.removeAll()
    }

    private func ensureIndex() throws { if !indexLoaded { try reconcile() } }

    private func canTrackLifetimeID(_ id: UUID) -> Bool {
        discardedIDs.contains(id) || privateIDs.contains(id) || retentionRevisionFloors[id] != nil ||
            privateIDs.count + discardedIDs.count + retentionRevisionFloors.count < maximumLifetimeTombstones
    }

    /// A same-revision nil savedURL is a late pre-save snapshot, not a new edit.
    /// New edits increment revision and may recreate recovery from their owned
    /// immutable original if they were admitted concurrently with this removal.
    private func removeSavedForRetention(_ record: RecoveryRecord) throws {
        guard canTrackLifetimeID(record.id) else {
            throw CaptureError.failed("History tracking has reached its session limit. Save open captures and restart SwiftShot before removing more saved captures.")
        }
        let folder = root.appendingPathComponent(record.id.uuidString)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        if !discardedIDs.contains(record.id), !privateIDs.contains(record.id) {
            retentionRevisionFloors[record.id] = max(retentionRevisionFloors[record.id] ?? record.revision, record.revision)
        }
        originalIDs.remove(record.id)
        index.removeValue(forKey: record.id)
        evictThumbnails(id: record.id)
    }

    private func markPrivate(id: UUID) throws {
        guard !discardedIDs.contains(id) else { return }
        guard canTrackLifetimeID(id) else {
            throw CaptureError.failed("Private capture tracking has reached its session limit. Save open captures and restart SwiftShot before continuing.")
        }
        privateIDs.insert(id)
        retentionRevisionFloors.removeValue(forKey: id)
    }

    private func updateMetadata(_ record: RecoveryRecord) throws {
        try durableWrite(JSONEncoder().encode(record), to: root.appendingPathComponent(record.id.uuidString).appendingPathComponent("capture.json"))
        index[record.id] = record
    }

    private func evictThumbnails(id: UUID) {
        let keys = thumbnailOrder.filter { $0.hasPrefix(id.uuidString) }
        for key in keys { thumbnailCache.removeValue(forKey: key) }
        thumbnailOrder.removeAll { keys.contains($0) }
    }

    private func durableWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
        // Synchronize the atomic rename's directory entry as well as the file's contents.
        for directory in Set([url.deletingLastPathComponent(), root]) {
            let descriptor = open(directory.path, O_RDONLY)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let result = fsync(descriptor)
            let failure = errno
            close(descriptor)
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
        }
    }

    private func validDimensions(_ source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 32_768, height <= 32_768,
              width * height <= 64_000_000 else { return nil }
        return (width, height)
    }

    private func directoryBytes(_ directory: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys.union([.isDirectoryKey])))
        var bytes: Int64 = 0
        for file in files {
            let values = try file.resourceValues(forKeys: keys.union([.isDirectoryKey]))
            guard values.isSymbolicLink != true else { continue }
            if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
            else if values.isDirectory == true { bytes += try directoryBytes(file) }
        }
        return bytes
    }
}
