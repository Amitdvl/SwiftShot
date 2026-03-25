import SwiftUI
import Foundation

// MARK: - App State

@MainActor
@Observable
final class AppState {
    var isCapturing = false
    var lastCapturePath: String?
    var statusMessage: String?

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

        guard await captureService.hasPermission() else {
            HUDController.showPermissionDenied()
            isCapturing = false
            return
        }

        do {

            switch mode {
            case .region:
                let url = try await captureService.captureRegion()
                SoundPlayer.shared.playScreenshotSound()
                saveCapture(url: url)

            case .fullscreen:
                let url = try await captureService.captureFullscreen()
                SoundPlayer.shared.playScreenshotSound()
                saveCapture(url: url)

            case .window:
                let url = try await captureService.captureWindow()
                SoundPlayer.shared.playScreenshotSound()
                saveCapture(url: url)

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

    // MARK: - Save Capture

    private func saveCapture(url: URL) {
        do {
            let saved: URL

            if appSettings.backgroundEnabled,
               let screenshot = NSImage(contentsOf: url),
               let composited = BackgroundCompositor.composite(screenshot: screenshot, backgroundName: appSettings.backgroundName) {
                saved = try ExportService.shared.savePNGData(
                    composited,
                    to: appSettings.saveDirectory
                )
                if appSettings.copyToClipboard {
                    ClipboardService.shared.copyPNGData(composited)
                }
            } else {
                saved = try ExportService.shared.copyToSaveDirectory(
                    from: url,
                    directory: appSettings.saveDirectory
                )
                if appSettings.copyToClipboard {
                    ClipboardService.shared.copyImage(from: url)
                }
            }

            lastCapturePath = saved.path
            statusMessage = "Saved to \(saved.lastPathComponent)"
            NotificationService.notifyScreenshotSaved(filename: saved.lastPathComponent)

            try? FileManager.default.removeItem(at: url)
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
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
