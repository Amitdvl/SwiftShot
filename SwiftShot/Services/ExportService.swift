import AppKit
import Foundation

// MARK: - Export Service

final class ExportService: Sendable {
    static let shared = ExportService()

    private init() {}

    /// Save raw PNG data to disk
    func savePNGData(_ data: Data, to directory: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let filename = "bettershot_\(timestamp).png"
        let path = (directory as NSString).appendingPathComponent(filename)
        let url = URL(fileURLWithPath: path)

        try data.write(to: url)
        return url
    }

    /// Copy a file to save directory with a new timestamped name
    func copyToSaveDirectory(from source: URL, directory: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let filename = "bettershot_\(timestamp).png"
        let destPath = (directory as NSString).appendingPathComponent(filename)
        let destURL = URL(fileURLWithPath: destPath)

        try fm.copyItem(at: source, to: destURL)
        return destURL
    }
}
