import AppKit
import Observation
import SwiftUI
import OSLog

@MainActor @Observable
final class AppState {
    static let shared = AppState()
    enum Phase: String { case idle, freezing, editing, scrolling }
    private(set) var phase: Phase = .idle
    var isCapturing: Bool { phase == .freezing || phase == .scrolling }
    var appSettings: AppSettings
    var statusMessage: String?
    var shortcutErrors: [String: String] = [:]
    var recoveredRecords: [RecoveryRecord] = []
    var lastDocument: CaptureDocument?
    private(set) var recoveryProblem: String?
    let backgrounds: BackgroundLibrary

    private let defaults: UserDefaults
    private let settingsKey = "com.swiftshot.settings"
    private let recovery: RecoveryStore
    private let recoveryCoordinator: RecoveryCoordinator
    private let indexing: HistoryIndexingCoordinator
    private let floatingCaptures: any FloatingCapturePresenting
    private let scrolling: any ScrollCapturePresenting
    private let directoryPicker: any CaptureDirectoryPicking
    private let combiner = CaptureCombiner()
    private var historyWindow: HistoryWindowController?
    private let renderer: any CaptureRendering
    private let captureService: any ScreenCaptureProviding
    private let textRecognizer: any TextRecognizing
    private let exporter: any CaptureExporting
    private let clipboard: any CaptureClipboard
    private let presentsUI: Bool
    private let overlay: any CapturePresenting
    private let diagnostics: PerformanceDiagnostics?
    private let focusTracker = CaptureFocusTracker()
    private var preferencesWindow: NSWindow?
    private var persistenceTasks: [UUID: Task<Void, Never>] = [:]
    private var persistenceTokens: [UUID: UUID] = [:]
    private var recoveryObserver: Task<Void, Never>?
    private var recoveryGeneration = 0
    private var observedRecoveryGeneration = 0
    private var indexingObserver: Task<Void, Never>?
    private var indexingObservationGeneration = 0
    private var observedIndexingGeneration = 0
    // One metadata-only admission per lane. Weak identity avoids retaining old
    // originals and distinguishes reopened documents even when they share an ID.
    private struct AdmissionStamp {
        weak var document: CaptureDocument?
        let edits: CaptureEdits
        let revision: Int
        let savedURL: URL?
        let privateCapture: Bool

        init(document: CaptureDocument, snapshot: RecoverySnapshot) {
            self.document = document
            edits = snapshot.edits
            revision = snapshot.revision
            savedURL = snapshot.savedURL
            privateCapture = snapshot.privateCapture
        }

        func matches(_ document: CaptureDocument, _ snapshot: RecoverySnapshot) -> Bool {
            self.document === document && revision == snapshot.revision && edits == snapshot.edits &&
                savedURL == snapshot.savedURL && privateCapture == snapshot.privateCapture
        }
    }
    @ObservationIgnored private var recoveryAdmission: AdmissionStamp?
    @ObservationIgnored private var indexingAdmission: AdmissionStamp?
    @ObservationIgnored private var indexingAdmissionEpoch = 0
    private var isQuitting = false
    private let exportCoordinator = CaptureExportCoordinator()
    private let sessionCoordinator = CaptureSessionCoordinator()
    private var sessionID: UUID { sessionCoordinator.id }
    private var freezeTask: Task<[FrozenScreen], Error>? {
        get { sessionCoordinator.freezeTask }
        set { sessionCoordinator.freezeTask = newValue }
    }
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private(set) var lastRegion: CaptureRegionReference?
    private let logger = Logger(subsystem: "com.swiftshot.app", category: "Workflow")

    init(defaults: UserDefaults = .standard, recovery: RecoveryStore = RecoveryStore(),
         backgrounds: BackgroundLibrary = BackgroundLibrary(), exporter: any CaptureExporting = ExportService(),
         clipboard: any CaptureClipboard = ClipboardService.shared, presentsUI: Bool = true,
         captureService: any ScreenCaptureProviding = ScreenCaptureService.shared,
         renderer: any CaptureRendering = ImageRenderer(), textRecognizer: any TextRecognizing = OCRService.shared,
         overlay: any CapturePresenting = CaptureOverlayController(),
         scrolling: (any ScrollCapturePresenting)? = nil,
         directoryPicker: any CaptureDirectoryPicking = NativeCaptureDirectoryPicker(),
         diagnostics: PerformanceDiagnostics? = .shared,
         recoveryCoordinator: RecoveryCoordinator? = nil,
         indexingCoordinator: HistoryIndexingCoordinator? = nil,
         floatingCaptures: (any FloatingCapturePresenting)? = nil,
         historyWindow: HistoryWindowController? = nil) {
        self.defaults = defaults
        self.recovery = recovery
        self.recoveryCoordinator = recoveryCoordinator ?? RecoveryCoordinator(store: recovery)
        self.backgrounds = backgrounds
        self.exporter = exporter
        self.clipboard = clipboard
        self.presentsUI = presentsUI
        self.historyWindow = historyWindow
        self.captureService = captureService
        self.renderer = renderer
        self.textRecognizer = textRecognizer
        self.overlay = overlay
        self.diagnostics = diagnostics
        self.directoryPicker = directoryPicker
        self.floatingCaptures = floatingCaptures ?? FloatingCaptureController(renderer: renderer)
        self.scrolling = scrolling ?? ScrollCaptureController(acquire: { region in
            ScrollCaptureFrame(image: try await captureService.captureRegion(displayID: region.displayID, rect: region.rect))
        })
        let initialSettings: AppSettings
        if let data = defaults.data(forKey: "com.swiftshot.settings"), let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            initialSettings = settings
        } else { initialSettings = .default }
        appSettings = initialSettings
        lastRegion = initialSettings.lastRegion
        indexing = indexingCoordinator ?? HistoryIndexingCoordinator(store: recovery, recovery: self.recoveryCoordinator,
            recognizer: textRecognizer, enabled: initialSettings.historyIndexingEnabled)
    }

    func start() {
        // No dependency on menu content appearing: shortcuts work from cold launch.
        focusTracker.start()
        registerShortcuts()
        installLifecycleObservers()
        saveSettings()
        Task { await refreshRecovery() }
        if !defaults.bool(forKey: "hasSeenCaptureEditor") {
            showPreferences()
            defaults.set(true, forKey: "hasSeenCaptureEditor")
        }
    }

    func saveSettings() {
        let traceRun = diagnostics?.activeRunID
        CaptureLatencyTrace.shared.mark(.settingsSaveStarted, for: traceRun)
        defer { CaptureLatencyTrace.shared.mark(.settingsSaveFinished, for: traceRun) }
        do { defaults.set(try JSONEncoder().encode(appSettings), forKey: settingsKey) }
        catch { report("Couldn't save preferences: \(error.localizedDescription)") }
    }

    /// Reports this request's selector handoff, not an unrelated editor's current phase.
    /// Does not await later interactive selection, Copy, or OCR completion.
    @discardableResult
    func capture(mode: CaptureMode, quickCopy: Bool = false, privateCapture: Bool? = nil, scrollingCapture: Bool = false,
                 respectImmediatePreference: Bool = true) async -> Bool {
        guard phase != .freezing, phase != .scrolling, !isQuitting, !Task.isCancelled else { return false }
        let performanceRun = diagnostics?.activeRunID
        diagnostics?.mark(.captureRequested, for: performanceRun)
        CaptureLatencyTrace.shared.mark(.captureRequested, for: performanceRun)
        let returnApplication = focusTracker.destination()
        let copyImmediately = !scrollingCapture && mode != .ocr && (quickCopy || (respectImmediatePreference && appSettings.immediateCopy))
        let privateForSession = privateCapture ?? appSettings.privateCapture
        let workflow: CaptureWorkflow = scrollingCapture ? .scroll : copyImmediately ? .quickCopy : CaptureWorkflow(rawValue: mode.rawValue) ?? .region
        let style = appSettings.style(for: workflow)
        phase = .freezing
        let token = beginSession()
        // Freeze interaction before handing off the final immutable revision.
        overlay.dismiss()
        diagnostics?.setCaptureHidden(true)
        CaptureLatencyTrace.shared.mark(.scrollDrainStarted, for: performanceRun)
        await scrolling.cancelAndWait()
        CaptureLatencyTrace.shared.mark(.scrollDrainFinished, for: performanceRun)
        guard token == sessionID else { return false }
        // The coordinator owns the old immutable pixels before navigation. Disk
        // encoding/fsync and history maintenance run independently of capture.
        CaptureLatencyTrace.shared.mark(.recoveryHandoffStarted, for: performanceRun)
        if let current = lastDocument, !(await enqueueRecovery(current)) {
            if sessionID == token {
                reopen(current)
                showStatus("Recovery could not take ownership. Save this capture or retry recovery before navigating.", for: current, isError: true)
            }
            return false
        }
        CaptureLatencyTrace.shared.mark(.recoveryHandoffFinished, for: performanceRun)
        guard sessionID == token else { return false }
        overlay.dismiss()
        floatingCaptures.setCaptureHidden(true)
        // Persistent SwiftShot windows stay visible so display and region
        // captures can document the app itself. Capture-owned overlays and
        // floating results are hidden above; those transient surfaces should
        // never be part of the source pixels.
        NotificationService.dismiss()
        CaptureLatencyTrace.shared.mark(.captureWindowsHidden, for: performanceRun)
        statusMessage = "Freezing screen…"
        defer { if sessionID == token { freezeTask = nil } }
        do {
            let service = captureService
            let task = Task {
                try Task.checkCancellation()
                CaptureLatencyTrace.shared.mark(.freezeTaskStarted, for: performanceRun)
                if mode == .window { return try await service.freeze(mode: mode, selectorID: token) }
                return try await service.freeze(mode: mode)
            }
            freezeTask = task
            let screens = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            CaptureLatencyTrace.shared.mark(.freezeReturned, for: performanceRun)
            guard sessionID == token else { return false }
            phase = .editing
            statusMessage = nil
            overlay.configure(actions: CaptureActions(
                latencyTraceRunID: performanceRun,
                captureWindow: { [weak self] id, display in
                    guard let self, self.sessionID == token else { throw CancellationError() }
                    let window = try await self.captureService.captureWindow(id: id, onDisplayID: display, selectorID: token, traceRunID: performanceRun)
                    guard self.sessionID == token else { throw CancellationError() }
                    return window
                },
                switchMode: { [weak self] next in
                    guard !scrollingCapture else { return }
                    Task { await self?.capture(mode: next, quickCopy: copyImmediately, privateCapture: privateForSession, respectImmediatePreference: false) }
                },
                selectedRegion: { [weak self] screen, crop in
                    guard mode == .region else { return }
                    guard let self, let region = CaptureRegionReference(screen: screen, crop: crop, isPrivate: privateForSession) else { return }
                    if scrollingCapture { self.startScrolling(region: region, style: style) }
                    else {
                        self.lastRegion = region
                        self.appSettings.lastRegion = region.isPrivate ? nil : region
                        self.saveSettings()
                    }
                },
                pin: { [weak self] document in Task { await self?.pin(document) } },
                copySmaller: { [weak self] document in Task { await self?.copy(document, smaller: true) } },
                saveSmaller: { [weak self] document in Task { await self?.save(document, smaller: true) } },
                dragRenderer: renderer,
                dragEnded: { [weak self] in
                    guard let self, self.sessionID == token else { return }
                    self.closeEditor()
                },
                returnApplication: returnApplication,
                selectorPresented: performanceCallback(.selectorReady, run: performanceRun),
                selectionCommitted: performanceCallback(.selectionCommitted, run: performanceRun),
                editorPresented: performanceCallback(.editorReady, run: performanceRun)))
            CaptureLatencyTrace.shared.mark(.overlayPresentationStarted, for: performanceRun)
            overlay.present(screens: screens, mode: mode, style: style, library: backgrounds,
                onDocument: { [weak self] document in
                    guard let self, self.sessionID == token, !scrollingCapture else { return }
                    document.performanceRunID = performanceRun
                    self.diagnostics?.updatePixels(input: .init(width: Int(document.edits.crop.width), height: Int(document.edits.crop.height)), for: performanceRun)
                    if mode == .region, document.sourceRegion == nil { document.sourceRegion = self.lastRegion }
                    self.documentChanged(document, immediate: copyImmediately, privateCapture: privateForSession, workflow: workflow)
                },
                onCopy: { [weak self] document in Task { await self?.copy(document) } },
                onSave: { [weak self] document in Task { await self?.save(document) } },
                onOCR: { [weak self] document in Task { await self?.recognize(document) } },
                onCancel: { [weak self] in self?.closeEditor() },
                onDiscard: { [weak self] document in Task { await self?.discard(document) } })
            CaptureLatencyTrace.shared.mark(.overlayPresentationFinished, for: performanceRun)
            return true
        } catch {
            guard sessionID == token else { return false }
            phase = .idle
            floatingCaptures.setCaptureHidden(false)
            diagnostics?.setCaptureHidden(false)
            if error is CancellationError { statusMessage = nil; return false }
            var openSettings: (() -> Void)?
            if let failure = error as? CaptureError, case .permissionDenied = failure {
                openSettings = {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
            report(error.localizedDescription, retry: { [weak self] in
                Task { await self?.capture(mode: mode, quickCopy: copyImmediately, privateCapture: privateForSession, scrollingCapture: scrollingCapture, respectImmediatePreference: false) }
            }, openSettings: openSettings)
            return false
        }
    }

    private func documentChanged(_ document: CaptureDocument, immediate: Bool, privateCapture: Bool = false, workflow: CaptureWorkflow? = nil) {
        guard !isQuitting else { return }
        let isNew = lastDocument?.id != document.id
        if privateCapture { document.isPrivate = true }
        if !document.isPrivate {
            historyWindow?.model.invalidate(id: document.id, minimumRevision: document.revision)
        }
        if isNew && immediate { document.isQuickCopy = true }
        if let workflow { document.workflow = workflow }
        if let region = document.sourceRegion?.applyingCrop(document.edits.crop, relativeToCapturedRegion: document.sourceRegionIsLocal) {
            lastRegion = region
            appSettings.lastRegion = document.isPrivate ? nil : region
        }
        if isNew && presentsUI {
            CaptureLatencyTrace.shared.mark(.captureSoundStarted, for: document.performanceRunID)
            SoundPlayer.shared.playScreenshotSound()
            CaptureLatencyTrace.shared.mark(.captureSoundFinished, for: document.performanceRunID)
        }
        lastDocument = document
        appSettings.setStyle(document.edits.style, for: document.workflow)
        saveSettings()
        persistenceTasks[document.id]?.cancel()
        let persistenceToken = UUID()
        persistenceTokens[document.id] = persistenceToken
        persistenceTasks[document.id] = Task { [weak self] in
            defer {
                if self?.persistenceTokens[document.id] == persistenceToken {
                    self?.persistenceTasks.removeValue(forKey: document.id)
                    self?.persistenceTokens.removeValue(forKey: document.id)
                }
            }
            do { try await Task.sleep(for: .milliseconds(isNew ? 0 : 250)) } catch { return }
            await self?.enqueueRecovery(document)
        }
        if isNew && immediate { Task { await copy(document) } }
    }

    func closeEditor() {
        guard phase != .scrolling else { return }
        if let document = lastDocument { Task { await enqueueRecovery(document) } }
        overlay.dismiss()
        if !isQuitting { floatingCaptures.setCaptureHidden(false) }
        diagnostics?.setCaptureHidden(false)
        phase = .idle
        _ = beginSession()
        statusMessage = nil
    }

    func reopenLastCapture() async {
        guard !isQuitting, phase != .scrolling else { return }
        let performanceRun = diagnostics?.activeRunID
        diagnostics?.mark(.historyRequested, for: performanceRun)
        if let document = lastDocument {
            document.performanceRunID = performanceRun
            reopen(document)
            return
        }
        let token = beginSession()
        phase = .idle
        await refreshRecovery()
        guard sessionID == token else { return }
        guard let record = recoveredRecords.first else { return }
        await reopenRecovery(record.id)
    }

    func reopenRecovery(_ id: UUID) async {
        guard !isQuitting, phase != .scrolling else { return }
        let performanceRun = diagnostics?.activeRunID
        diagnostics?.mark(.historyRequested, for: performanceRun)
        let token = beginSession()
        overlay.dismiss()
        phase = overlay.activeDocument == nil ? .idle : .editing
        if let current = lastDocument, !(await preserve(current)) {
            if sessionID == token { reopen(current) }
            return
        }
        guard sessionID == token else { return }
        do {
            let loaded = try await recovery.load(id: id)
            guard sessionID == token else { return }
            let document = CaptureDocument(id: loaded.record.id, image: loaded.image, edits: loaded.record.edits, revision: loaded.record.revision)
            document.performanceRunID = performanceRun
            document.savedURL = loaded.record.savedPath.map { URL(fileURLWithPath: $0) }
            lastDocument = document
            reopen(document)
        } catch {
            guard sessionID == token else { return }
            report(error.localizedDescription)
        }
    }

    private func reopen(_ document: CaptureDocument) {
        guard !isQuitting, phase != .scrolling else { return }
        let token = beginSession()
        overlay.dismiss()
        NotificationService.dismiss()
        phase = .editing
        floatingCaptures.setCaptureHidden(true)
        diagnostics?.setCaptureHidden(true)
        diagnostics?.updatePixels(input: .init(width: Int(document.edits.crop.width), height: Int(document.edits.crop.height)), for: document.performanceRunID)
        overlay.configure(actions: CaptureActions(
            latencyTraceRunID: document.performanceRunID,
            pin: { [weak self] document in Task { await self?.pin(document) } },
            copySmaller: { [weak self] document in Task { await self?.copy(document, smaller: true) } },
            saveSmaller: { [weak self] document in Task { await self?.save(document, smaller: true) } },
            dragRenderer: renderer,
            dragEnded: { [weak self] in
                guard let self, self.sessionID == token else { return }
                self.closeEditor()
            },
            returnApplication: focusTracker.destination(),
            editorPresented: recoveredPresentationCallback(run: document.performanceRunID)))
        overlay.reopen(document: document, library: backgrounds,
            onCopy: { [weak self] document in Task { await self?.copy(document) } },
            onSave: { [weak self] document in Task { await self?.save(document) } },
            onCancel: { [weak self] in self?.closeEditor() },
            onDocument: { [weak self] document in self?.documentChanged(document, immediate: false) },
            onDiscard: { [weak self] document in Task { await self?.discard(document) } })
    }

    @discardableResult
    func copy(_ document: CaptureDocument, smaller: Bool = false, presentRecent: Bool = true) async -> Bool {
        guard !isQuitting, !document.isDiscarded, let permit = exportCoordinator.begin(documentID: document.id) else { return false }
        defer { exportCoordinator.finish(permit) }
        exportCoordinator.claimClipboard(permit)
        let sessionToken = sessionID
        let revision = document.revision
        let performanceRun = document.performanceRunID
        diagnostics?.mark(.copyRequested, for: performanceRun)
        let request = document.request(backgroundURL: backgrounds.url(for: document.edits.style.backgroundID),
            output: smaller ? .smallerShare(maxPixelDimension: appSettings.shareMaxDimension) : .native)
        await enqueueRecovery(document)
        guard !document.isDiscarded else { return false }
        showStatus("Preparing full-resolution image…", for: document)
        do {
            let started = ContinuousClock.now
            let result = try await renderer.render(request)
            guard exportCoordinator.canPublishClipboard(permit), !document.isDiscarded else { return false }
            guard clipboard.copyPNGData(result.png) else { throw CaptureError.failed("Couldn't write to the clipboard. Your capture is still available; try Copy again.") }
            diagnostics?.mark(.clipboardReady, for: performanceRun)
            diagnostics?.updatePixels(output: .init(width: result.image.width, height: result.image.height), for: performanceRun)
            logger.info("Copy render finished in \(String(describing: started.duration(to: .now)), privacy: .public)")
            showStatus("Copied · \(result.image.width) × \(result.image.height) px", for: document)
            if isCurrent(document, revision: revision, session: sessionToken) { closeEditor() }
            if phase == .idle && presentsUI {
                if presentRecent && appSettings.showRecentThumbnail { await showRecent(document, request: request, image: result.image) }
                else { NotificationService.showToast(title: "Copied", subtitle: "Reopen Last Capture to edit or save it.") }
            }
            return true
        } catch {
            // Failure paths may wait for durability; successful Copy must not.
            await preserve(document)
            report(error.localizedDescription, retry: { [weak self] in Task { await self?.copy(document, smaller: smaller, presentRecent: presentRecent) } })
            return false
        }
    }

    func save(_ document: CaptureDocument, smaller: Bool = false, presentRecent: Bool = true) async {
        guard !isQuitting, !document.isDiscarded, let permit = exportCoordinator.begin(documentID: document.id) else { return }
        defer { exportCoordinator.finish(permit) }
        let sessionToken = sessionID
        let revision = document.revision
        let performanceRun = document.performanceRunID
        diagnostics?.mark(.saveRequested, for: performanceRun)
        let request = document.request(backgroundURL: backgrounds.url(for: document.edits.style.backgroundID),
            output: smaller ? .smallerShare(maxPixelDimension: appSettings.shareMaxDimension) : .native)
        await enqueueRecovery(document)
        guard !document.isDiscarded else { return }
        let directory = appSettings.saveDirectory
        showStatus("Saving full-resolution image…", for: document)
        do {
            let result = try await renderer.render(request)
            guard !document.isDiscarded else { return }
            let exporter = self.exporter
            let url = try await Task.detached(priority: .userInitiated) { try exporter.savePNGData(result.png, to: directory) }.value
            guard !document.isDiscarded else { return }
            if revision == document.revision { document.savedURL = url }
            diagnostics?.updatePixels(output: .init(width: result.image.width, height: result.image.height), for: performanceRun)
            var maintenanceWarning: String?
            if await preserve(document) {
                do {
                    if appSettings.retentionDays > 0 || appSettings.retentionSavedCount != nil {
                        let removed = try await recoveryCoordinator.applyRetention(retentionPolicy,
                            protected: Set([lastDocument?.id].compactMap { $0 }))
                        historyWindow?.model.acknowledgeRemovedRecords(ids: removed)
                    }
                } catch { maintenanceWarning = "Recovery cleanup couldn't finish: \(error.localizedDescription)" }
            } else { maintenanceWarning = "Recovery couldn't be updated. Keep this capture open to preserve its editable original." }
            await refreshRecovery()
            if let maintenanceWarning {
                report("Saved to \(url.lastPathComponent). \(maintenanceWarning)")
                diagnostics?.mark(.saveComplete, for: performanceRun)
                return
            }
            if isCurrent(document, revision: revision, session: sessionToken) { closeEditor() }
            if presentsUI {
                if phase == .idle && appSettings.showRecentThumbnail {
                    if presentRecent {
                        await showRecent(document, request: request, image: result.image, completion: "Saved")
                    } else {
                        NotificationService.showToast(title: "Saved", subtitle: "Reopen Last Capture to edit or save it again.")
                    }
                } else {
                    NotificationService.showToast(title: "Screenshot saved", subtitle: "\(result.image.width) × \(result.image.height) px · \(url.deletingLastPathComponent().lastPathComponent)")
                }
            }
            statusMessage = "Saved to \(url.lastPathComponent)"
            diagnostics?.mark(.saveComplete, for: performanceRun)
        } catch {
            await preserve(document)
            report("Save failed: \(error.localizedDescription)",
                retry: { [weak self] in Task { await self?.save(document, smaller: smaller, presentRecent: presentRecent) } },
                chooseFolder: { [weak self] in self?.chooseSaveDirectory(retryDocument: document) })
        }
    }

    private func recognize(_ document: CaptureDocument) async {
        guard !isQuitting, !document.isDiscarded, let permit = exportCoordinator.begin(documentID: document.id) else { return }
        defer { exportCoordinator.finish(permit) }
        let sessionToken = sessionID
        let revision = document.revision
        let performanceRun = document.performanceRunID
        diagnostics?.mark(.ocrRequested, for: performanceRun)
        exportCoordinator.claimClipboard(permit)
        var edits = document.edits
        edits.style.backgroundID = ""
        await enqueueRecovery(document)
        do {
            let image = try await renderer.renderImage(RenderRequest(image: document.image, edits: edits, backgroundURL: nil,
                documentID: document.id, revision: revision))
            let text = try await textRecognizer.recognizeText(in: image)
            guard !document.isDiscarded, exportCoordinator.canPublishClipboard(permit) else { return }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                showStatus("No text found. Adjust the selection and try again.", for: document, isError: true)
                return
            }
            guard clipboard.copyText(text) else { throw CaptureError.failed("Couldn't copy the recognized text. Try again.") }
            diagnostics?.mark(.ocrComplete, for: performanceRun)
            if isCurrent(document, revision: revision, session: sessionToken) { closeEditor() }
            if presentsUI { NotificationService.showToast(title: "Text copied", subtitle: "\(text.count) characters ready to paste.") }
        } catch { report("Text recognition failed: \(error.localizedDescription)", retry: { [weak self] in Task { await self?.recognize(document) } }) }
    }

    @discardableResult
    func preserve(_ document: CaptureDocument) async -> Bool {
        guard !document.isDiscarded else { return false }
        do {
            try await recoveryCoordinator.preserve(recoverySnapshot(document))
            recoveryProblem = nil
            await refreshRecovery()
            return true
        } catch {
            recoveryProblem = error.localizedDescription
            report("Recovery couldn't be updated: \(error.localizedDescription). Keep this capture open until you save it.")
            return false
        }
    }

    func isPrivate(_ document: CaptureDocument) -> Bool { document.isPrivate }

    private func recoverySnapshot(_ document: CaptureDocument) -> RecoverySnapshot {
        RecoverySnapshot(id: document.id, image: document.image, edits: document.edits,
            revision: document.revision, savedURL: document.savedURL, privateCapture: isPrivate(document))
    }

    @discardableResult
    private func enqueueRecovery(_ document: CaptureDocument) async -> Bool {
        guard !document.isDiscarded else { return false }
        do {
            let snapshot = recoverySnapshot(document)
            // Capture the precise accepted values before suspension: the editor
            // can mutate this document while either coordinator is accepting it.
            let stamp = AdmissionStamp(document: document, snapshot: snapshot)
            let needsRecovery = recoveryAdmission?.matches(document, snapshot) != true
            if needsRecovery {
                try await recoveryCoordinator.enqueue(snapshot)
                recoveryAdmission = stamp
            }
            var admittedIndexing = false
            if snapshot.privateCapture {
                if needsRecovery {
                    invalidateIndexingAdmission()
                    await indexing.cancel(id: snapshot.id)
                }
            } else if appSettings.historyIndexingEnabled,
                      indexingAdmission?.matches(document, snapshot) != true {
                let epoch = indexingAdmissionEpoch
                admittedIndexing = await indexing.enqueue(snapshot)
                if admittedIndexing, epoch == indexingAdmissionEpoch {
                    indexingAdmission = stamp
                }
            }
            if needsRecovery {
                recoveryGeneration &+= 1
                observeRecovery()
            } else if admittedIndexing {
                // A retry can admit OCR without new durable metadata. Observe
                // that lane directly instead of restarting the recovery scan.
                indexingObservationGeneration &+= 1
                observeIndexing()
            }
            return true
        } catch {
            recoveryProblem = error.localizedDescription
            report("Recovery couldn't take ownership: \(error.localizedDescription)", retry: { [weak self] in
                Task { await self?.retryRecovery() }
            })
            return false
        }
    }

    private func invalidateIndexingAdmission() {
        indexingAdmissionEpoch &+= 1
        indexingAdmission = nil
    }

    private func observeRecovery() {
        guard recoveryObserver == nil, recoveryProblem == nil, !isQuitting else { return }
        recoveryObserver = Task { [weak self] in
            guard let self else { return }
            defer {
                self.recoveryObserver = nil
                self.historyWindow?.model.refreshObserver?(.recoveryObservationFinished)
                // A failed quit can resume admissions while a canceled observer
                // still owns an uninterruptible await. Keep its handle until here.
                if !self.isQuitting, self.recoveryGeneration != self.observedRecoveryGeneration {
                    self.observeRecovery()
                }
            }
            do {
                repeat {
                    let generation = self.recoveryGeneration
                    try await self.recoveryCoordinator.flush()
                    guard !Task.isCancelled, !self.isQuitting else { return }
                    // Snapshot before reading history: a job may commit while
                    // that read is suspended, leaving an empty queue afterward.
                    let indexingStatus = await self.indexing.status()
                    guard !Task.isCancelled, !self.isQuitting else { return }
                    await self.refreshRecovery()
                    guard !Task.isCancelled, !self.isQuitting else { return }
                    // OCR must not hold up later durability notifications. Its
                    // separate, coalesced observer owns the optional flush.
                    if indexingStatus.pendingCount > 0 || indexingStatus.lastFailure != nil {
                        self.indexingObservationGeneration &+= 1
                        self.observeIndexing()
                    }
                    self.observedRecoveryGeneration = generation
                    // An admission during an await increments this generation
                    // and is included before the observer gives up ownership.
                    if self.recoveryGeneration == generation { break }
                } while !Task.isCancelled
            } catch {
                guard !Task.isCancelled, !self.isQuitting else { return }
                self.recoveryProblem = error.localizedDescription
                self.report("Recovery is waiting: \(error.localizedDescription). Your pending captures remain in memory.",
                    retry: { [weak self] in Task { await self?.retryRecovery() } })
            }
        }
    }

    private func observeIndexing() {
        guard indexingObserver == nil, !isQuitting,
              indexingObservationGeneration != observedIndexingGeneration else { return }
        indexingObserver = Task { [weak self] in
            guard let self else { return }
            defer {
                self.indexingObserver = nil
                self.observeIndexing()
            }
            repeat {
                let generation = self.indexingObservationGeneration
                var warning: String?
                do { try await self.indexing.flush() }
                catch {
                    self.invalidateIndexingAdmission()
                    warning = "Local text indexing couldn't finish: \(error.localizedDescription)"
                }
                // A fast job may already have ended before flush saw its task.
                // Its terminal failure remains authoritative until success/reset.
                let status = await self.indexing.status()
                if let failure = status.lastFailure {
                    self.invalidateIndexingAdmission()
                    warning = "Local text indexing couldn't finish: \(failure)"
                }
                guard !Task.isCancelled, !self.isQuitting else { return }
                await self.refreshRecovery()
                guard !Task.isCancelled, !self.isQuitting else { return }
                if let warning { self.historyWindow?.model.errorMessage = warning }
                self.observedIndexingGeneration = generation
                if self.indexingObservationGeneration == generation { break }
            } while !Task.isCancelled
        }
    }

    func retryRecovery() async {
        do {
            try await recoveryCoordinator.retry()
            // A failed admission is not in the coordinator's queue. Re-admit
            // the currently owned capture after freeing any pending capacity.
            if let document = lastDocument, !document.isDiscarded {
                try await recoveryCoordinator.preserve(recoverySnapshot(document))
            }
            recoveryProblem = nil
            await refreshRecovery()
            observeRecovery()
        } catch { recoveryProblem = error.localizedDescription; report("Recovery retry failed: \(error.localizedDescription)") }
    }

    func prepareToQuit() async -> Bool {
        guard !isQuitting else { return false }
        guard phase != .scrolling else {
            report("Finish or explicitly cancel the scrolling capture before quitting, so its pending frames are not lost.")
            return false
        }
        isQuitting = true
        invalidateIndexingAdmission()
        // Cancel only the read-only observers, without forgetting their handles.
        // Their defers release ownership after native/actor waits actually end.
        recoveryObserver?.cancel()
        indexingObserver?.cancel()
        let openDocument = overlay.activeDocument
        overlay.dismiss()
        _ = beginSession()
        phase = .idle
        await scrolling.cancelAndWait()
        while exportCoordinator.hasActiveExports { try? await Task.sleep(for: .milliseconds(25)) }
        for task in persistenceTasks.values { task.cancel() }
        persistenceTasks.removeAll(); persistenceTokens.removeAll()
        do {
            try await indexing.stop()
            if let document = lastDocument { try await recoveryCoordinator.enqueue(recoverySnapshot(document)) }
            try await recoveryCoordinator.shutdown()
            floatingCaptures.closeAll()
            await renderer.clearCache()
            return true
        } catch {
            isQuitting = false
            invalidateIndexingAdmission()
            try? await indexing.setEnabled(appSettings.historyIndexingEnabled)
            if let openDocument { reopen(openDocument) }
            recoveryProblem = error.localizedDescription
            observeIndexing()
            report("SwiftShot kept running to protect pending captures: \(error.localizedDescription)")
            return false
        }
    }

    func refreshRecovery() async {
        do {
            let records = try await recovery.records()
            guard !Task.isCancelled, !isQuitting else { return }
            recoveredRecords = records
            if let model = historyWindow?.model {
                model.acknowledgeDurableRecords(recoveredRecords)
                await model.reload(refreshStorage: true)
            }
        }
        catch {
            guard !Task.isCancelled, !isQuitting else { return }
            statusMessage = "Couldn't read recovery: \(error.localizedDescription)"
        }
    }

    func discard(_ document: CaptureDocument) async {
        guard !isQuitting else { return }
        guard !exportCoordinator.isExporting(document.id) else {
            showStatus("Wait for the current copy or save to finish before discarding.", for: document, isError: true)
            return
        }
        document.isDiscarded = true
        persistenceTasks.removeValue(forKey: document.id)?.cancel()
        do {
            invalidateIndexingAdmission()
            await indexing.cancel(id: document.id)
            try await recoveryCoordinator.discard(id: document.id)
            historyWindow?.model.acknowledgeRemovedRecords(ids: [document.id])
            if overlay.activeDocument === document { overlay.dismiss(); phase = .idle; _ = beginSession() }
            if lastDocument === document {
                lastDocument = nil
                if phase == .freezing { _ = beginSession(); phase = .idle }
            }
            await refreshRecovery()
        } catch {
            document.isDiscarded = false
            report("Couldn't discard this capture: \(error.localizedDescription)")
        }
    }

    private func isCurrent(_ document: CaptureDocument, revision: Int, session: UUID) -> Bool {
        sessionID == session && overlay.activeDocument === document && document.revision == revision
    }

    /// Navigation invalidates both pending presentation and the work acquiring it.
    /// User-requested exports have their own lifetime and are intentionally retained.
    private func beginSession() -> UUID {
        captureService.invalidateWindowMetadata()
        return sessionCoordinator.begin()
    }

    @discardableResult
    func captureLastRegion(quickCopy: Bool = false, respectImmediatePreference: Bool = true) async -> Bool {
        guard !isQuitting, phase != .freezing, phase != .scrolling else { return false }
        guard let region = lastRegion, region.isValid else { report("Select a region once before recapturing it."); return false }
        guard let displayFrame = captureService.currentDisplayFrame(id: region.displayID), displayFrame == region.displayFrame else {
            report("The last region's display layout changed. Select a new region."); return false
        }
        let privateForSession = region.isPrivate || appSettings.privateCapture
        let immediate = quickCopy || (respectImmediatePreference && appSettings.immediateCopy)
        let workflow: CaptureWorkflow = immediate ? .quickCopy : .region
        let style = appSettings.style(for: workflow)
        let performanceRun = diagnostics?.activeRunID
        diagnostics?.mark(.captureRequested, for: performanceRun)
        let token = beginSession()
        phase = .freezing
        overlay.dismiss()
        diagnostics?.setCaptureHidden(true)
        await scrolling.cancelAndWait()
        if let document = lastDocument, !(await enqueueRecovery(document)) {
            if sessionID == token { reopen(document) }
            return false
        }
        guard token == sessionID else { return false }
        overlay.dismiss()
        floatingCaptures.setCaptureHidden(true)
        // Keep visible Settings/History windows in the source frame. The
        // capture overlay, floating results, and notifications are transient
        // capture chrome and are hidden before acquisition.
        NotificationService.dismiss()
        do {
            let task = Task { try await captureService.captureRegion(displayID: region.displayID, rect: region.rect) }
            sessionCoordinator.regionTask = task
            defer { if token == sessionID { sessionCoordinator.regionTask = nil } }
            let image = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard token == sessionID else { return false }
            guard region.matches(frame: displayFrame, image: image) else {
                throw CaptureError.failed("The last region's resolution changed. Select a new region.")
            }
            let document = CaptureDocument(image: image, style: style)
            document.sourceRegion = region.applyingPrivacy(privateForSession)
            document.sourceRegionIsLocal = true
            document.performanceRunID = performanceRun
            document.isQuickCopy = immediate
            documentChanged(document, immediate: false, privateCapture: privateForSession, workflow: workflow)
            phase = .idle
            floatingCaptures.setCaptureHidden(false)
            diagnostics?.setCaptureHidden(false)
            if immediate { return await copy(document) }
            reopen(document)
            return true
        } catch {
            guard token == sessionID else { return false }
            phase = .idle
            floatingCaptures.setCaptureHidden(false)
            diagnostics?.setCaptureHidden(false)
            report(error.localizedDescription)
            return false
        }
    }

    func setHistoryIndexing(_ enabled: Bool) async {
        invalidateIndexingAdmission()
        appSettings.historyIndexingEnabled = enabled
        saveSettings()
        do {
            try await indexing.setEnabled(enabled, clearExistingIndex: !enabled)
            await refreshRecovery()
        }
        catch { report("Couldn't update local text indexing: \(error.localizedDescription)") }
    }

    private func installLifecycleObservers() {
        guard lifecycleObservers.isEmpty else { return }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            lifecycleObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.systemCaptureEnvironmentChanged() }
            })
        }
        lifecycleObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.systemCaptureEnvironmentChanged() } })
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in Task { await self?.handleMemoryPressure() } }
        source.resume()
        memoryPressureSource = source
    }

    func systemCaptureEnvironmentChanged() {
        captureService.invalidateDisplayCache()
        if phase == .freezing || phase == .editing { closeEditor() }
    }

    func handleMemoryPressure() async {
        captureService.invalidateDisplayCache()
        floatingCaptures.handleMemoryPressure()
        await renderer.clearCache()
        do { try await recoveryCoordinator.handleMemoryPressure() }
        catch { recoveryProblem = error.localizedDescription; report("Pending captures remain protected in memory: \(error.localizedDescription)") }
    }

    private var retentionPolicy: RecoveryRetentionPolicy {
        RecoveryRetentionPolicy(maximumSavedCount: appSettings.retentionSavedCount,
            maximumSavedAgeDays: appSettings.retentionDays > 0 ? appSettings.retentionDays : nil)
    }

    func showHistory() {
        guard !isQuitting else { return }
        diagnostics?.mark(.historyRequested, for: diagnostics?.activeRunID)
        if historyWindow == nil {
            historyWindow = HistoryWindowController(store: recovery, retention: retentionPolicy,
                onOpen: { [weak self] id in Task { await self?.reopenRecovery(id) } },
                onPin: { [weak self] id in Task { await self?.pinRecovery(id) } },
                onDelete: { [weak self] id in
                    guard let self else { return }
                    guard !self.exportCoordinator.isExporting(id) else { throw CaptureError.failed("Wait for this capture's export to finish before deleting it.") }
                    self.invalidateIndexingAdmission()
                    await self.indexing.cancel(id: id)
                    if let document = self.lastDocument, document.id == id {
                        await self.discard(document)
                        guard document.isDiscarded else { throw CaptureError.failed(self.statusMessage ?? "The capture could not be deleted.") }
                    } else {
                        try await self.recoveryCoordinator.discard(id: id)
                        self.historyWindow?.model.acknowledgeRemovedRecords(ids: [id])
                    }
                    await self.refreshRecovery()
                },
                onCombine: { [weak self] ids, axis in try await self?.combineHistory(ids, axis: axis) },
                onRetentionChange: { [weak self] policy in
                    try await self?.applyHistoryRetention(policy)
                })
        }
        if let document = lastDocument, !document.isPrivate {
            historyWindow?.model.invalidate(id: document.id, minimumRevision: document.revision)
        }
        historyWindow?.show()
    }

    func applyHistoryRetention(_ policy: RecoveryRetentionPolicy) async throws {
        guard !exportCoordinator.hasActiveExports else { throw CaptureError.failed("Wait for active exports before changing retention.") }
        let removed = try await recoveryCoordinator.applyRetention(policy, protected: Set([lastDocument?.id].compactMap { $0 }))
        historyWindow?.model.acknowledgeRemovedRecords(ids: removed)
        appSettings.retentionDays = policy.maximumSavedAgeDays ?? 0
        appSettings.retentionSavedCount = policy.maximumSavedCount
        saveSettings(); await refreshRecovery()
    }

    func combineHistory(_ ids: [UUID], axis: HistoryCombineAxis) async throws {
        guard !isQuitting, phase != .scrolling, phase != .freezing else { throw CaptureError.failed("Finish the current capture before combining history.") }
        let privateForSession = appSettings.privateCapture
        let style = appSettings.style(for: .combine)
        let token = beginSession()
        overlay.dismiss()
        phase = .freezing
        defer { if token == sessionID && phase == .freezing { phase = .idle } }
        if let document = lastDocument, !(await enqueueRecovery(document)) {
            if sessionID == token { reopen(document) }
            throw CaptureError.failed("Recovery could not take ownership of the current capture.")
        }
        guard token == sessionID, !isQuitting else { throw CancellationError() }
        try Task.checkCancellation()
        let store = recovery, combiner = combiner, backgrounds = backgrounds
        let task = Task { @MainActor in
            var sources: [CaptureCombineSource] = []
            for id in ids { try Task.checkCancellation(); sources.append(try await store.combineSource(id: id)) }
            _ = try combiner.preflight(sources: sources, axis: axis)
            let renderer = ImageRenderer(cacheByteLimit: 0, cacheEntryLimit: 0)
            var images: [CGImage] = []
            for id in ids {
                try Task.checkCancellation()
                let loaded = try await store.load(id: id)
                let request = RenderRequest(image: loaded.image, edits: loaded.record.edits,
                    backgroundURL: backgrounds.url(for: loaded.record.edits.style.backgroundID), documentID: id, revision: loaded.record.revision)
                images.append(try await renderer.renderImage(request))
            }
            return try await combiner.combine(images: images, axis: axis)
        }
        sessionCoordinator.regionTask = task
        defer { if token == sessionID { sessionCoordinator.regionTask = nil } }
        let image = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard token == sessionID else { throw CancellationError() }
        let document = CaptureDocument(image: image, style: style)
        documentChanged(document, immediate: false, privateCapture: privateForSession, workflow: .combine)
        historyWindow?.window?.orderOut(nil)
        reopen(document)
    }

    private func pinRecovery(_ id: UUID) async {
        do {
            let loaded = try await recovery.load(id: id)
            let document = CaptureDocument(id: id, image: loaded.image, edits: loaded.record.edits, revision: loaded.record.revision)
            await pin(document)
        } catch { report(error.localizedDescription) }
    }

    func pin(_ document: CaptureDocument) async {
        guard !isQuitting, !document.isDiscarded else { return }
        let token = sessionID, revision = document.revision
        do {
            try await floatingCaptures.pin(document: document, backgroundURL: backgrounds.url(for: document.edits.style.backgroundID),
                onCopy: { [weak self] snapshot in Task { await self?.copy(snapshot, presentRecent: false) } }, onEdit: { [weak self] snapshot in Task { await self?.editFloatingSnapshot(snapshot) } },
                onSave: { [weak self] snapshot in Task { await self?.save(snapshot, presentRecent: false) } })
            if isCurrent(document, revision: revision, session: token) { closeEditor() }
        } catch { report("Couldn't pin the capture: \(error.localizedDescription)") }
    }

    private func editFloatingSnapshot(_ document: CaptureDocument) async {
        guard !isQuitting, phase != .scrolling else { return }
        let token = beginSession()
        overlay.dismiss()
        if let current = lastDocument, !(await enqueueRecovery(current)) {
            if token == sessionID { reopen(current) }
            return
        }
        guard !isQuitting, token == sessionID else { return }
        documentChanged(document, immediate: false, privateCapture: document.isPrivate, workflow: document.workflow)
        reopen(document)
    }

    private func showRecent(_ document: CaptureDocument, request: RenderRequest, image: CGImage, completion: String = "Copied") async {
        let snapshot = CaptureDocument(id: document.id, image: request.image, edits: request.edits, revision: request.revision)
        snapshot.isPrivate = document.isPrivate
        snapshot.workflow = document.workflow
        do {
            try await floatingCaptures.showRecent(document: snapshot, backgroundURL: request.backgroundURL, renderedImage: image, title: completion,
                onCopy: { [weak self] snapshot in Task { await self?.copy(snapshot, presentRecent: false) } }, onEdit: { [weak self] snapshot in Task { await self?.editFloatingSnapshot(snapshot) } },
                onSave: { [weak self] snapshot in Task { await self?.save(snapshot, presentRecent: false) } },
                onPin: { [weak self] snapshot in Task { await self?.pin(snapshot) } })
        } catch {
            if !(error is CancellationError) {
                statusMessage = "\(completion) successfully; recent thumbnail unavailable: \(error.localizedDescription)"
                NotificationService.showToast(title: completion, subtitle: "The recent thumbnail could not open. Reopen Last Capture to edit it.")
            }
        }
    }

    private func startScrolling(region: CaptureRegionReference, style: CaptureStyle) {
        let token = beginSession()
        overlay.dismiss()
        phase = .scrolling
        scrolling.start(region: ScrollCaptureRegion(displayID: region.displayID, displayFrame: region.displayFrame, rect: region.rect),
            onResult: { [weak self] result in
                guard let self, self.sessionID == token else { return }
                self.phase = .idle
                let document = CaptureDocument(image: result.image, style: style)
                self.documentChanged(document, immediate: false, privateCapture: region.isPrivate, workflow: .scroll)
                self.reopen(document)
                if !result.isComplete { self.showStatus("Partial scrolling capture: " + result.warnings.joined(separator: " "), for: document, isError: true) }
            }, onCancel: { [weak self] in
                guard let self, self.sessionID == token else { return }
                self.phase = .idle
                self.floatingCaptures.setCaptureHidden(false)
                self.statusMessage = nil
            })
    }

    func performIntent(_ action: CaptureIntentAction) async throws {
        try Task.checkCancellation()
        guard !isQuitting, !isCapturing else { throw CaptureError.failed("Finish the current capture before starting this action.") }
        switch action {
        case .start(let mode, let quickCopy, let privateCapture):
            guard await capture(mode: mode, quickCopy: quickCopy, privateCapture: privateCapture || appSettings.privateCapture,
                respectImmediatePreference: false) else {
                throw CaptureError.failed(statusMessage ?? "Capture could not start.")
            }
        case .lastRegion(let quickCopy):
            guard await captureLastRegion(quickCopy: quickCopy, respectImmediatePreference: false) else {
                throw CaptureError.failed(statusMessage ?? "The last region could not be captured.")
            }
        case .history: showHistory()
        }
    }

    func chooseSaveDirectory(retryDocument: CaptureDocument? = nil) {
        guard !isQuitting else { return }
        guard phase != .scrolling else {
            report("Finish or explicitly cancel the scrolling capture before choosing a save folder, so its pending frames are not lost.")
            return
        }
        _ = beginSession()
        let current = overlay.activeDocument
        overlay.dismiss()
        phase = .idle
        if let url = directoryPicker.chooseDirectory() {
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
            if shortcut.mode == "quickCopy" {
                let registered = manager.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
                    Task { await self?.capture(mode: .region, quickCopy: true) }
                }
                if !registered { shortcutErrors[shortcut.mode] = "\(shortcut.displayString) is in use by another app." }
                continue
            }
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

    private func performanceCallback(_ stage: WorkflowPerformance.Stage, run: UUID?) -> (() -> Void)? {
        guard let diagnostics, let run, diagnostics.isEnabled else { return nil }
        return { [weak diagnostics] in diagnostics?.mark(stage, for: run) }
    }

    private func recoveredPresentationCallback(run: UUID?) -> (() -> Void)? {
        guard let diagnostics, let run, diagnostics.isEnabled else { return nil }
        return { [weak diagnostics] in
            diagnostics?.mark(.editorReady, for: run)
            diagnostics?.mark(.historyReady, for: run)
        }
    }

    private func report(_ message: String, retry: (() -> Void)? = nil, chooseFolder: (() -> Void)? = nil, openSettings: (() -> Void)? = nil) {
        statusMessage = message
        overlay.showStatus(message, isError: true)
        if presentsUI { NotificationService.showError(message, retry: retry, chooseFolder: chooseFolder, openSettings: openSettings) }
    }
}
