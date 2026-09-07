import AppKit
import ImageIO
import Observation

struct BackgroundAsset: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let isBundled: Bool
    let url: URL
}

/// Owns background copies, the hidden bundled set, and one persistent removal undo.
@MainActor @Observable
final class BackgroundLibrary {
    private(set) var assets: [BackgroundAsset] = []
    private(set) var isImporting = false
    var errorMessage: String?
    var canUndoRemoval: Bool { manifest.removed != nil }

    private struct Record: Codable, Sendable {
        var id: String
        var name: String
        var filename: String
    }
    private struct Removal: Codable {
        var bundledID: String?
        var record: Record?
    }
    private struct Manifest: Codable {
        var records: [Record] = []
        var hidden: Set<String> = []
        var removed: Removal?
    }
    enum LibraryError: LocalizedError {
        case invalidImage(String), oversized(String), busy, unavailable, missing
        var errorDescription: String? {
            switch self {
            case .invalidImage(let name): return "\(name) isn’t a readable image. Choose a PNG, JPEG, HEIC, TIFF, or WebP image."
            case .oversized(let name): return "\(name) is too large. Backgrounds must be under 50 MB, 100 megapixels, and 32,768 pixels per side."
            case .busy: return "Please wait for the current import to finish."
            case .unavailable: return "The background library couldn’t be opened. Check its folder permissions and reopen SwiftShot."
            case .missing: return "This background is no longer available."
            }
        }
    }
    private let rootURL: URL
    private let bundled: [BackgroundAsset]
    private var manifest = Manifest()
    private var storageAvailable = true
    private var thumbnails: [String: NSImage] = [:]
    @ObservationIgnored private var pendingThumbnails: Set<String> = []
    @ObservationIgnored private var failedThumbnails: Set<String> = []
    @ObservationIgnored private var thumbnailOrder: [String] = []
    private var metadataURL: URL { rootURL.appendingPathComponent("library.json") }
    private var trashURL: URL { rootURL.appendingPathComponent("Removed", isDirectory: true) }

    /// bundleURL is the Backgrounds directory, injectable for tests.
    init(rootURL: URL? = nil, bundleURL: URL? = nil) {
        self.rootURL = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftShot/Backgrounds", isDirectory: true)
        let folder = bundleURL ?? Bundle.main.url(forResource: "Backgrounds", withExtension: nil)
        bundled = (folder.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? [])
            .filter { ["png", "jpg", "jpeg", "heic", "tif", "tiff", "webp"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                let stem = url.deletingPathExtension().lastPathComponent
                return BackgroundAsset(id: "bundled:\(stem)", name: stem.replacingOccurrences(of: "-", with: " ").capitalized,
                                       isBundled: true, url: url)
            }
        do {
            try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: metadataURL.path) {
                manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: metadataURL))
                let records = manifest.records + [manifest.removed?.record].compactMap { $0 }
                guard records.allSatisfy({ $0.filename == URL(fileURLWithPath: $0.filename).lastPathComponent && !$0.filename.hasPrefix(".") }) else {
                    throw LibraryError.unavailable
                }
            }
        } catch {
            storageAvailable = false
            errorMessage = "Couldn’t load the background library: \(error.localizedDescription)"
        }
        rebuildAssets()
    }

    func url(for id: String) -> URL? { assets.first { $0.id == id }?.url }

    /// Decoding and downsampling run outside the UI actor; observation updates once ready.
    func thumbnail(for id: String) -> NSImage? {
        if let cached = thumbnails[id] {
            thumbnailOrder.removeAll { $0 == id }
            thumbnailOrder.append(id)
            return cached
        }
        guard !pendingThumbnails.contains(id), !failedThumbnails.contains(id), let url = url(for: id) else { return nil }
        pendingThumbnails.insert(id)
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Self.makeThumbnail(url: url) }.value
            guard let self else { return }
            self.pendingThumbnails.remove(id)
            if let result, self.url(for: id) == url {
                self.thumbnails[id] = NSImage(cgImage: result.image, size: NSSize(width: result.image.width, height: result.image.height))
                self.thumbnailOrder.append(id)
                if self.thumbnailOrder.count > 128 {
                    let evicted = self.thumbnailOrder.removeFirst()
                    self.thumbnails.removeValue(forKey: evicted)
                }
            } else { self.failedThumbnails.insert(id) }
        }
        return nil
    }

    /// Imports a batch atomically. Source files are read only; all names on disk are UUIDs.
    func importFiles(_ urls: [URL]) async throws {
        guard storageAvailable else { throw LibraryError.unavailable }
        guard !isImporting else { throw LibraryError.busy }
        guard !urls.isEmpty else { return }
        isImporting = true
        defer { isImporting = false }
        let destination = rootURL
        let records = try await Task.detached(priority: .userInitiated) {
            var imported: [Record] = []
            do {
                for source in urls {
                    try Task.checkCancellation()
                    let scoped = source.startAccessingSecurityScopedResource()
                    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                    try Self.validate(source)
                    let id = UUID().uuidString
                    let filename = id + "." + source.pathExtension.lowercased()
                    let record = Record(id: id, name: source.deletingPathExtension().lastPathComponent, filename: filename)
                    let copied = destination.appendingPathComponent(filename)
                    try FileManager.default.copyItem(at: source, to: copied)
                    imported.append(record)
                    // Validate the managed copy too, in case the source changed during the copy.
                    try Self.validate(copied)
                }
                return imported
            } catch {
                for record in imported { try? FileManager.default.removeItem(at: destination.appendingPathComponent(record.filename)) }
                throw error
            }
        }.value
        do {
            try Task.checkCancellation()
            var next = manifest
            next.records.append(contentsOf: records)
            try persist(next)
            manifest = next
            errorMessage = nil
            rebuildAssets()
        } catch {
            for record in records { try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(record.filename)) }
            throw error
        }
    }

    func remove(id: String) throws {
        guard storageAvailable else { throw LibraryError.unavailable }
        guard let asset = assets.first(where: { $0.id == id }) else { throw LibraryError.missing }
        var next = manifest
        let oldRemoved = manifest.removed
        var moved: Record?
        if asset.isBundled {
            next.hidden.insert(id)
            next.removed = Removal(bundledID: id)
        } else if let record = next.records.first(where: { $0.id == id }) {
            try FileManager.default.moveItem(at: asset.url, to: trashURL.appendingPathComponent(record.filename))
            moved = record
            next.records.removeAll { $0.id == id }
            next.removed = Removal(record: record)
        }
        do { try persist(next) }
        catch {
            if let moved { try? FileManager.default.moveItem(at: trashURL.appendingPathComponent(moved.filename), to: rootURL.appendingPathComponent(moved.filename)) }
            throw error
        }
        manifest = next
        if let stale = oldRemoved?.record { try? FileManager.default.removeItem(at: trashURL.appendingPathComponent(stale.filename)) }
        thumbnails.removeValue(forKey: id)
        thumbnailOrder.removeAll { $0 == id }
        rebuildAssets()
    }

    func undoRemoval() throws {
        guard storageAvailable else { throw LibraryError.unavailable }
        guard let removed = manifest.removed else { return }
        var next = manifest
        if let id = removed.bundledID { next.hidden.remove(id) }
        if let record = removed.record {
            try FileManager.default.moveItem(at: trashURL.appendingPathComponent(record.filename), to: rootURL.appendingPathComponent(record.filename))
            next.records.append(record)
        }
        next.removed = nil
        do { try persist(next) }
        catch {
            if let record = removed.record { try? FileManager.default.moveItem(at: rootURL.appendingPathComponent(record.filename), to: trashURL.appendingPathComponent(record.filename)) }
            throw error
        }
        manifest = next
        rebuildAssets()
    }

    /// Undoing an image edit may refer to a background removed from the library.
    func restoreForEdit(id: String) throws {
        guard !id.isEmpty, url(for: id) == nil else { return }
        if manifest.removed?.record?.id == id || manifest.removed?.bundledID == id {
            try undoRemoval()
        } else if bundled.contains(where: { $0.id == id }) {
            var next = manifest
            next.hidden.remove(id)
            try persist(next)
            manifest = next
            rebuildAssets()
        } else { throw LibraryError.missing }
    }

    func restoreBundled() throws {
        guard storageAvailable else { throw LibraryError.unavailable }
        var next = manifest
        next.hidden.removeAll()
        if next.removed?.bundledID != nil { next.removed = nil }
        try persist(next)
        manifest = next
        rebuildAssets()
    }

    private func persist(_ value: Manifest) throws {
        try JSONEncoder().encode(value).write(to: metadataURL, options: .atomic)
    }

    private func rebuildAssets() {
        assets = bundled.filter { !manifest.hidden.contains($0.id) } + manifest.records.map {
            BackgroundAsset(id: $0.id, name: $0.name, isBundled: false, url: rootURL.appendingPathComponent($0.filename))
        }
    }

    nonisolated private static func validate(_ url: URL) throws {
        let name = url.lastPathComponent
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw LibraryError.invalidImage(name) }
        guard (values.fileSize ?? Int.max) <= 50 * 1_024 * 1_024 else { throw LibraryError.oversized(name) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = info[kCGImagePropertyPixelHeight] as? NSNumber,
              width.int64Value > 0, height.int64Value > 0 else { throw LibraryError.invalidImage(name) }
        guard width.int64Value <= 32_768, height.int64Value <= 32_768,
              width.int64Value * height.int64Value <= 100_000_000 else { throw LibraryError.oversized(name) }
        guard makeThumbnail(url: url) != nil else { throw LibraryError.invalidImage(name) }
    }

    private struct Thumbnail: @unchecked Sendable { let image: CGImage }
    nonisolated private static func makeThumbnail(url: URL) -> Thumbnail? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 240,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return Thumbnail(image: image)
    }
}
