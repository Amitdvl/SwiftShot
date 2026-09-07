import Foundation

protocol CaptureExporting: Sendable {
    func savePNGData(_ data: Data, to directory: String) throws -> URL
}

struct ExportService: CaptureExporting {
    static let shared = ExportService()

    func savePNGData(_ data: Data, to directory: String) throws -> URL {
        guard !data.isEmpty else { throw CaptureError.failed("The screenshot is empty. Try capturing it again.") }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let date = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let filename = "SwiftShot-\(date)-\(UUID().uuidString.prefix(8)).png"
        let url = folder.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }
}
