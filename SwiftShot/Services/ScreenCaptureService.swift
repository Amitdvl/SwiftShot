import AppKit
import Foundation

// MARK: - Screen Capture Service

/// Uses macOS `screencapture` CLI for reliable screenshot capture.
@MainActor
final class ScreenCaptureService: Sendable {
    static let shared = ScreenCaptureService()

    private init() {}

    /// Interactive region capture — user selects area
    func captureRegion() async throws -> URL {
        let path = temporaryPath(prefix: "region")
        try await runScreenCapture(args: ["-i", "-x", path])
        guard FileManager.default.fileExists(atPath: path) else {
            throw CaptureError.cancelled
        }
        return URL(fileURLWithPath: path)
    }

    /// Fullscreen capture of main display
    func captureFullscreen() async throws -> URL {
        let path = temporaryPath(prefix: "fullscreen")
        try await runScreenCapture(args: ["-x", path])
        guard FileManager.default.fileExists(atPath: path) else {
            throw CaptureError.failed("Fullscreen capture failed")
        }
        return URL(fileURLWithPath: path)
    }

    /// Window capture — user clicks a window
    func captureWindow() async throws -> URL {
        let path = temporaryPath(prefix: "window")
        try await runScreenCapture(args: ["-i", "-w", "-x", path])
        guard FileManager.default.fileExists(atPath: path) else {
            throw CaptureError.cancelled
        }
        return URL(fileURLWithPath: path)
    }

    /// Region capture for OCR — captures then returns the image path
    func captureForOCR() async throws -> URL {
        let path = temporaryPath(prefix: "ocr")
        try await runScreenCapture(args: ["-i", "-x", path])
        guard FileManager.default.fileExists(atPath: path) else {
            throw CaptureError.cancelled
        }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Private

    private func temporaryPath(prefix: String) -> String {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let tempDir = FileManager.default.temporaryDirectory.path
        return "\(tempDir)/\(prefix)_\(timestamp).png"
    }

    private func runScreenCapture(args: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = args

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CaptureError.failed("screencapture exited with status \(proc.terminationStatus)"))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - Capture Errors

enum CaptureError: LocalizedError {
    case cancelled
    case failed(String)
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .cancelled: "Capture was cancelled"
        case .failed(let msg): msg
        case .permissionDenied: "Screen Recording permission is required"
        }
    }
}
