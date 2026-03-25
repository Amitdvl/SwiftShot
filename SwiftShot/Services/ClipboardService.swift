import AppKit
import Foundation

// MARK: - Clipboard Service

final class ClipboardService: Sendable {
    static let shared = ClipboardService()

    private init() {}

    /// Copy an image file to the clipboard
    func copyImage(from url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    /// Copy an NSImage to the clipboard
    func copyImage(_ image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    /// Copy text to the clipboard
    func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Copy a PNG data blob to clipboard
    func copyPNGData(_ data: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
    }
}
