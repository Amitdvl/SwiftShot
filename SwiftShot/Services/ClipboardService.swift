import AppKit

@MainActor
protocol CaptureClipboard {
    func copyPNGData(_ data: Data) -> Bool
    func copyText(_ text: String) -> Bool
}

@MainActor
final class ClipboardService: CaptureClipboard {
    static let shared = ClipboardService()
    private let pasteboard: NSPasteboard
    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    func copyPNGData(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setData(data, forType: .png)
    }

    func copyText(_ text: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
