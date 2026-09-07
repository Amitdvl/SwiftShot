import AppKit
import Observation
import SwiftUI
import OSLog

@MainActor @Observable
final class AppState {
    static let shared = AppState()
    enum Phase: String { case idle, freezing, editing }
    private(set) var phase: Phase = .idle
    var isCapturing: Bool { phase == .freezing }
    var appSettings: AppSettings
    var statusMessage: String?
    var shortcutErrors: [String: String] = [:]
    var recoveredRecords: [RecoveryRecord] = []
    var lastDocument: CaptureDocument?
    let backgrounds: BackgroundLibrary

    private let defaults: UserDefaults
    private let settingsKey = "com.swiftshot.settings"
    private let recovery: RecoveryStore
    private let renderer: any CaptureRendering
    private let captureService: any ScreenCaptureProviding
    private let textRecognizer: any TextRecognizing
    private let exporter: any CaptureExporting
    private let clipboard: any CaptureClipboard
    private let presentsUI: Bool
    private let overlay: any CapturePresenting
    private var preferencesWindow: NSWindow?
    private var persistenceTasks: [UUID: Task<Void, Never>] = [:]
    private var exporting: Set<UUID> = []
    private var discarded: Set<UUID> = []
    private var clipboardRequestID = UUID()
    private var sessionID = UUID()
    private var freezeTask: Task<[FrozenScreen], Error>?
    private let logger = Logger(subsystem: "com.swiftshot.app", category: "Workflow")

    init(defaults: UserDefaults = .standard, recovery: RecoveryStore = RecoveryStore(),
         backgrounds: BackgroundLibrary = BackgroundLibrary(), exporter: any CaptureExporting = ExportService(),
         clipboard: any CaptureClipboard = ClipboardService.shared, presentsUI: Bool = true,
         captureService: any ScreenCaptureProviding = ScreenCaptureService.shared,
         renderer: any CaptureRendering = ImageRenderer(), textRecognizer: any TextRecognizing = OCRService.shared,
         overlay: any CapturePresenting = CaptureOverlayController()) {
        self.defaults = defaults
        self.recovery = recovery
        self.backgrounds = backgrounds
        self.exporter = exporter
        self.clipboard = clipboard
        self.presentsUI = presentsUI
        self.captureService = captureService
        self.renderer = renderer
        self.textRecognizer = textRecognizer
        self.overlay = overlay
        if let data = defaults.data(forKey: settingsKey), let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            appSettings = settings
        } else { appSettings = .default }
    }

    func start() {
        // No dependency on menu content appearing: shortcuts work from cold launch.
        registerShortcuts()
        saveSettings()
        Task { await refreshRecovery() }
        if !defaults.bool(forKey: "hasSeenCaptureEditor") {
            showPreferences()
            defaults.set(true, forKey: "hasSeenCaptureEditor")
        }
    }

    func saveSettings() {
        do { defaults.set(try JSONEncoder().encode(appSettings), forKey: settingsKey) }
        catch { report("Couldn't save preferences: \(error.localizedDescription)") }
    }

    func capture(mode: CaptureMode) async {
        guard phase != .freezing else { return }
        phase = .freezing
        let token = beginSession()
        if let current = lastDocument, !(await preserve(current)) {
            if sessionID == token { phase = overlay.activeDocument == nil ? .idle : .editing }
            return
        }
        guard sessionID == token else { return }
        overlay.dismiss()
        NotificationService.dismiss()
        preferencesWindow?.orderOut(nil)
        statusMessage = "Freezing screen…"
        defer { if sessionID == token { freezeTask = nil } }
        do {
            let service = captureService
            let task = Task {
                try Task.checkCancellation()
                return try await service.freeze(mode: mode)
            }
            freezeTask = task
            let screens = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard sessionID == token else { return }
            phase = .editing
            statusMessage = nil
            overlay.present(screens: screens, mode: mode, style: appSettings.style, library: backgrounds,
                onDocument: { [weak self] document in self?.documentChanged(document, immediate: mode != .ocr) },
                onCopy: { [weak self] document in Task { await self?.copy(document) } },
                onSave: { [weak self] document in Task { await self?.save(document) } },
                onOCR: { [weak self] document in Task { await self?.recognize(document) } },
                onCancel: { [weak self] in self?.closeEditor() },
                onDiscard: { [weak self] document in Task { await self?.discard(document) } })
        } catch {
            guard sessionID == token else { return }
            phase = .idle
            if error is CancellationError { statusMessage = nil; return }
            report(error.localizedDescription, retry: { [weak self] in Task { await self?.capture(mode: mode) } })
        }
    }

    private func documentChanged(_ document: CaptureDocument, immediate: Bool) {
        let isNew = lastDocument?.id != document.id
        if isNew && presentsUI { SoundPlayer.shared.playScreenshotSound() }
        lastDocument = document
        appSettings.style = document.edits.style
        saveSettings()
        persistenceTasks[document.id]?.cancel()
        persistenceTasks[document.id] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(isNew ? 0 : 250)) } catch { return }
            await self?.preserve(document)
        }
        if isNew && immediate && appSettings.immediateCopy { Task { await copy(document, closeAfter: true) } }
    }

    func closeEditor() {
        if let document = lastDocument { Task { await preserve(document) } }
        overlay.dismiss()
        phase = .idle
        _ = beginSession()
        statusMessage = nil
    }

    func reopenLastCapture() async {
        if let document = lastDocument { reopen(document); return }
        let token = beginSession()
        phase = .idle
        await refreshRecovery()
        guard sessionID == token else { return }
        guard let record = recoveredRecords.first else { return }
        await reopenRecovery(record.id)
    }

    func reopenRecovery(_ id: UUID) async {
        let token = beginSession()
        phase = overlay.activeDocument == nil ? .idle : .editing
        if let current = lastDocument, !(await preserve(current)) { return }
        guard sessionID == token else { return }
        do {
            let loaded = try await recovery.load(id: id)
            guard sessionID == token else { return }
            let document = CaptureDocument(id: loaded.record.id, image: loaded.image, edits: loaded.record.edits, revision: loaded.record.revision)
            document.savedURL = loaded.record.savedPath.map { URL(fileURLWithPath: $0) }
            lastDocument = document
            reopen(document)
        } catch {
            guard sessionID == token else { return }
            report(error.localizedDescription)
        }
    }

    private func reopen(_ document: CaptureDocument) {
        _ = beginSession()
        overlay.dismiss()
        NotificationService.dismiss()
        phase = .editing
        overlay.reopen(document: document, library: backgrounds,
            onCopy: { [weak self] document in Task { await self?.copy(document) } },
            onSave: { [weak self] document in Task { await self?.save(document) } },
            onCancel: { [weak self] in self?.closeEditor() },
            onDocument: { [weak self] document in self?.documentChanged(document, immediate: false) },
            onDiscard: { [weak self] document in Task { await self?.discard(document) } })
    }

    func copy(_ document: CaptureDocument, closeAfter: Bool = false) async {
        guard exporting.insert(document.id).inserted else { return }
        defer { exporting.remove(document.id) }
        let clipboardToken = UUID()
        clipboardRequestID = clipboardToken
        let sessionToken = sessionID
        await preserve(document)
        guard !discarded.contains(document.id) else { return }
        let revision = document.revision
        let request = document.request(backgroundURL: backgrounds.url(for: document.edits.style.backgroundID))
        showStatus("Preparing full-resolution image…", for: document)
        do {
            let started = ContinuousClock.now
            let result = try await renderer.render(request)
            guard clipboardRequestID == clipboardToken, !discarded.contains(document.id) else { return }
            guard clipboard.copyPNGData(result.png) else { throw CaptureError.failed("Couldn't write to the clipboard. Your capture is still available; try Copy again.") }
            logger.info("Copy render finished in \(String(describing: started.duration(to: .now)), privacy: .public)")
            showStatus("Copied · \(result.image.width) × \(result.image.height) px", for: document)
            if closeAfter && isCurrent(document, revision: revision, session: sessionToken) { closeEditor() }
            if phase == .idle && presentsUI { NotificationService.showToast(title: "Copied", subtitle: "Reopen Last Capture to edit or save it.") }
        } catch {
            report(error.localizedDescription, retry: { [weak self] in Task { await self?.copy(document, closeAfter: closeAfter) } })
        }
    }

    func save(_ document: CaptureDocument) async {
        guard exporting.insert(document.id).inserted else { return }
        defer { exporting.remove(document.id) }
        let sessionToken = sessionID
        await preserve(document)
        guard !discarded.contains(document.id) else { return }
        let revision = document.revision
        let request = document.request(backgroundURL: backgrounds.url(for: document.edits.style.backgroundID))
        let directory = appSettings.saveDirectory
        showStatus("Saving full-resolution image…", for: document)
        do {
            let result = try await renderer.render(request)
            guard !discarded.contains(document.id) else { return }
            let exporter = self.exporter
            let url = try await Task.detached(priority: .userInitiated) { try exporter.savePNGData(result.png, to: directory) }.value
            guard !discarded.contains(document.id) else { return }
            if revision == document.revision { document.savedURL = url }
            var maintenanceWarning: String?
            if await preserve(document) {
                do {
                    try await recovery.pruneSaved(except: document.id, protected: Set([lastDocument?.id].compactMap { $0 }))
                } catch { maintenanceWarning = "Recovery cleanup couldn't finish: \(error.localizedDescription)" }
            } else { maintenanceWarning = "Recovery couldn't be updated. Keep this capture open to preserve its editable original." }
            await refreshRecovery()
            if let maintenanceWarning {
                report("Saved to \(url.lastPathComponent). \(maintenanceWarning)")
                return
            }
            if isCurrent(document, revision: revision, session: sessionToken) { closeEditor() }
            if presentsUI { NotificationService.showToast(title: "Screenshot saved", subtitle: "\(result.image.width) × \(result.image.height) px · \(url.deletingLastPathComponent().lastPathComponent)") }
            statusMessage = "Saved to \(url.lastPathComponent)"
        } catch {
            report("Save failed: \(error.localizedDescription)",
                retry: { [weak self] in Task { await self?.save(document) } },
                chooseFolder: { [weak self] in self?.chooseSaveDirectory(retryDocument: document) })
        }
    }

    private func recognize(_ document: CaptureDocument) async {
        guard exporting.insert(document.id).inserted else { return }
        defer { exporting.remove(document.id) }
        let sessionToken = sessionID
        let revision = document.revision
        let clipboardToken = UUID()
        clipboardRequestID = clipboardToken
        await preserve(document)
        do {
            var edits = document.edits
            edits.style.backgroundID = ""
            let rendered = try await renderer.render(RenderRequest(image: document.image, edits: edits, backgroundURL: nil))
            let text = try await textRecognizer.recognizeText(in: rendered.image)
            guard !discarded.contains(document.id), clipboardRequestID == clipboardToken else { return }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                showStatus("No text found. Adjust the selection and try again.", for: document, isError: true)
                return
            }
            guard clipboard.copyText(text) else { throw CaptureError.failed("Couldn't copy the recognized text. Try again.") }
            if isCurrent(document, revision: revision, session: sessionToken) { closeEditor() }
            if presentsUI { NotificationService.showToast(title: "Text copied", subtitle: "\(text.count) characters ready to paste.") }
        } catch { report("Text recognition failed: \(error.localizedDescription)", retry: { [weak self] in Task { await self?.recognize(document) } }) }
    }

    @discardableResult
    func preserve(_ document: CaptureDocument) async -> Bool {
        guard !discarded.contains(document.id) else { return false }
        let id = document.id, image = document.image, edits = document.edits, revision = document.revision, savedURL = document.savedURL
        do {
            try await recovery.persist(id: id, image: image, edits: edits, revision: revision, savedURL: savedURL)
            await refreshRecovery()
            return true
        } catch {
            report("Recovery couldn't be updated: \(error.localizedDescription). Keep this capture open until you save it.")
            return false
        }
    }

    func refreshRecovery() async {
        do { recoveredRecords = try await recovery.records() }
        catch { statusMessage = "Couldn't read recovery: \(error.localizedDescription)" }
    }

    func discard(_ document: CaptureDocument) async {
        guard !exporting.contains(document.id) else {
            showStatus("Wait for the current copy or save to finish before discarding.", for: document, isError: true)
            return
        }
        discarded.insert(document.id)
        persistenceTasks.removeValue(forKey: document.id)?.cancel()
        do {
            try await recovery.discard(id: document.id)
            if overlay.activeDocument === document { overlay.dismiss(); phase = .idle; _ = beginSession() }
            if lastDocument === document {
                lastDocument = nil
                if phase == .freezing { _ = beginSession(); phase = .idle }
            }
            await refreshRecovery()
        } catch {
            discarded.remove(document.id)
            report("Couldn't discard this capture: \(error.localizedDescription)")
        }
    }

    private func isCurrent(_ document: CaptureDocument, revision: Int, session: UUID) -> Bool {
        sessionID == session && overlay.activeDocument === document && document.revision == revision
    }

    /// Navigation invalidates both pending presentation and the work acquiring it.
    /// User-requested exports have their own lifetime and are intentionally retained.
    private func beginSession() -> UUID {
        freezeTask?.cancel()
        freezeTask = nil
        sessionID = UUID()
        return sessionID
    }

    func chooseSaveDirectory(retryDocument: CaptureDocument? = nil) {
        _ = beginSession()
        let current = overlay.activeDocument
        overlay.dismiss()
        phase = .idle
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose where SwiftShot saves screenshots"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            appSettings.saveDirectory = url.path
            saveSettings()
            if let retryDocument { Task { await save(retryDocument) }; return }
        }
        if let current { reopen(current) }
    }

    func showPreferences() {
        if phase == .freezing { _ = beginSession(); phase = .idle }
        if let preferencesWindow {
            NSApp.activate(ignoringOtherApps: true)
            preferencesWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "SwiftShot Settings"
        window.contentView = NSHostingView(rootView: PreferencesView().environment(self))
        window.isReleasedWhenClosed = false
        window.center()
        preferencesWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func registerShortcuts() {
        let manager = GlobalShortcutManager.shared
        manager.unregisterAll()
        shortcutErrors = [:]
        for shortcut in appSettings.shortcuts where shortcut.enabled {
            guard let mode = CaptureMode(rawValue: shortcut.mode) else { continue }
            let registered = manager.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
                Task { await self?.capture(mode: mode) }
            }
            if !registered { shortcutErrors[shortcut.mode] = "\(shortcut.displayString) is in use by another app. Disable that shortcut there, then retry." }
        }
    }

    private func showStatus(_ message: String, for document: CaptureDocument, isError: Bool = false) {
        statusMessage = message
        if overlay.activeDocument?.id == document.id { overlay.showStatus(message, isError: isError) }
    }

    private func report(_ message: String, retry: (() -> Void)? = nil, chooseFolder: (() -> Void)? = nil) {
        statusMessage = message
        overlay.showStatus(message, isError: true)
        if presentsUI { NotificationService.showError(message, retry: retry, chooseFolder: chooseFolder) }
    }
}
