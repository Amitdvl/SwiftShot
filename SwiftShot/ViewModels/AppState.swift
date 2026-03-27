import SwiftUI
import Foundation

// MARK: - Pending Capture

struct PendingCapture: Sendable {
    let data: Data
    let saveDirectory: String
}

// MARK: - App State

@MainActor
@Observable
final class AppState {
    var isCapturing = false
    var lastCapturePath: String?
    var statusMessage: String?
    var pendingCapture: PendingCapture?

    // Settings
    var appSettings: AppSettings

    private let settingsKey = "com.swiftshot.settings"

    init() {
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.appSettings = settings
        } else {
            self.appSettings = .default
        }
    }

    // MARK: - Persistence

    func saveSettings() {
        if let data = try? JSONEncoder().encode(appSettings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    // MARK: - Capture Actions

    func capture(mode: CaptureMode) async {
        guard !isCapturing else { return }
        isCapturing = true
        statusMessage = nil

        let captureService = ScreenCaptureService.shared

        do {
            switch mode {
            case .region:
                let url = try await captureService.captureRegion()
                SoundPlayer.shared.playScreenshotSound()
                preparePendingCapture(url: url)

            case .fullscreen:
                let url = try await captureService.captureFullscreen()
                SoundPlayer.shared.playScreenshotSound()
                preparePendingCapture(url: url)

            case .window:
                let url = try await captureService.captureWindow()
                SoundPlayer.shared.playScreenshotSound()
                preparePendingCapture(url: url)

            case .ocr:
                let url = try await captureService.captureForOCR()
                SoundPlayer.shared.playScreenshotSound()
                await handleOCRResult(url: url)
            }
        } catch CaptureError.cancelled {
            // User cancelled — nothing to do
        } catch {
            statusMessage = error.localizedDescription
        }

        isCapturing = false
    }

    // MARK: - Pending Capture

    private func preparePendingCapture(url: URL) {
        let data: Data
        if appSettings.backgroundEnabled,
           let screenshot = NSImage(contentsOf: url),
           let composited = BackgroundCompositor.composite(screenshot: screenshot, backgroundName: appSettings.backgroundName) {
            data = composited
        } else {
            guard let raw = try? Data(contentsOf: url) else { return }
            data = raw
        }
        try? FileManager.default.removeItem(at: url)

        pendingCapture = PendingCapture(data: data, saveDirectory: appSettings.saveDirectory)

        NotificationService.showCaptureActions(
            onCopy: { [weak self] in self?.performCopy() },
            onSave: { [weak self] in self?.performSave() }
        )
    }

    func performCopy() {
        guard let pending = pendingCapture else { return }
        ClipboardService.shared.copyPNGData(pending.data)
        pendingCapture = nil
    }

    func performSave() {
        guard let pending = pendingCapture else { return }
        do {
            let saved = try ExportService.shared.savePNGData(pending.data, to: pending.saveDirectory)
            lastCapturePath = saved.path
            statusMessage = "Saved to \(saved.lastPathComponent)"
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
        pendingCapture = nil
    }

    // MARK: - OCR

    private func handleOCRResult(url: URL) async {
        do {
            let text = try await OCRService.shared.recognizeText(from: url)
            if text.isEmpty {
                statusMessage = "No text found"
            } else {
                ClipboardService.shared.copyText(text)
                statusMessage = "Copied: \(String(text.prefix(50)))..."
            }
            try? FileManager.default.removeItem(atPath: url.path)
        } catch {
            statusMessage = "OCR failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Shortcut Registration

    func registerShortcuts() {
        let manager = GlobalShortcutManager.shared
        manager.unregisterAll()

        for shortcut in appSettings.shortcuts where shortcut.enabled {
            let captureMode: CaptureMode? = CaptureMode(rawValue: shortcut.mode)
            guard let mode = captureMode else { continue }

            manager.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
                Task { @MainActor in
                    await self?.capture(mode: mode)
                }
            }
        }
    }
}
