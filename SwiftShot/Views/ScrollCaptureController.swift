import AppKit
import SwiftUI

/// Owns only the scrolling utility panel. The lead session hides its selection
/// overlay before start and receives one flattened result for the normal editor.
@MainActor
final class ScrollCaptureController: NSObject, NSWindowDelegate {
    private let acquire: ScrollCaptureCoordinator.Acquisition
    private let makeDriver: @MainActor () -> any ScrollCaptureDriving
    private let limits: ScrollCaptureLimits
    private var panel: NSPanel?
    private var model: ScrollCapturePanelModel?
    private var coordinator: ScrollCaptureCoordinator?
    private var work: Task<Void, Never>?
    private var drainingWork: Task<Void, Never>?
    private var drainID = UUID()
    private var sessionID: UUID?
    private var onResult: ((ScrollCaptureResult) -> Void)?
    private var onCancel: (() -> Void)?
    private var displayObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    var isActive: Bool { sessionID != nil }
    var hasCapturedFrames: Bool { (model?.frameCount ?? 0) > 0 }

    init(limits: ScrollCaptureLimits = ScrollCaptureLimits(),
         acquire: @escaping ScrollCaptureCoordinator.Acquisition = { region in
             ScrollCaptureFrame(image: try await ScreenCaptureService.shared.captureRegion(displayID: region.displayID, rect: region.rect))
         }, makeDriver: @escaping @MainActor () -> any ScrollCaptureDriving = { NativeScrollCaptureDriver() }) {
        self.limits = limits
        self.acquire = acquire
        self.makeDriver = makeDriver
        super.init()
    }

    func start(region: ScrollCaptureRegion, onResult: @escaping (ScrollCaptureResult) -> Void,
               onCancel: @escaping () -> Void = {}) {
        let priorWork = work ?? drainingWork
        terminate(notifyCancellation: false)
        let id = UUID()
        sessionID = id
        self.onResult = onResult
        self.onCancel = onCancel
        let model = ScrollCapturePanelModel()
        self.model = model
        let coordinator = ScrollCaptureCoordinator(region: region, limits: limits, acquire: { [weak self] region in
            guard let self, self.sessionID == id else { throw CancellationError() }
            // Window sharingType exclusions are not reliable across macOS versions.
            // Remove our own panel, allow compositor presentation, then capture.
            self.panel?.orderOut(nil)
            defer {
                if self.sessionID == id { self.panel?.orderFrontRegardless() }
            }
            try await Task.sleep(for: .milliseconds(60))
            guard self.sessionID == id else { throw CancellationError() }
            return try await self.acquire(region)
        }, driver: makeDriver())
        self.coordinator = coordinator
        showPanel(region: region, model: model)
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionID == id else { return }
                    self.stop(reason: "The display layout changed. This partial result needs review; start a new scrolling capture for more frames.", terminal: true)
                }
            }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionID == id else { return }
                    self.stop(reason: "Capture stopped for sleep. This partial result needs review; start a new scrolling capture for more frames.", terminal: true)
                }
            }
        work = Task { [weak self] in
            // A cancelled native operation retains its ownership until it finishes
            // restoring the old target, before the next session acquires pixels
            // or begins a native input operation. Its waiting panel is visible.
            await priorWork?.value
            guard let self, self.sessionID == id else { return }
            do {
                let report = try await coordinator.start()
                await self.update(report, coordinator: coordinator, id: id)
                guard self.sessionID == id else { return }
                // Screenshot X-style capture is automatic after the region is
                // committed. Manual Add Frame remains available when a target
                // does not expose a safe native scrolling surface.
                if report.disposition == .firstFrame, !model.acquisitionDisabled, !model.automaticDisabled {
                    await self.runAutomatic(id: id, coordinator: coordinator, model: model)
                }
            } catch { self.show(error, id: id) }
            self.finishedWork(id: id)
        }
    }

    func cancel() {
        terminate(notifyCancellation: true)
    }

    private func terminate(notifyCancellation: Bool) {
        let callback = notifyCancellation && sessionID != nil ? onCancel : nil
        sessionID = nil
        coordinator?.invalidate()
        work?.cancel()
        if let work {
            drainingWork = work
            drainID = UUID()
        }
        work = nil
        closePanel()
        coordinator = nil
        model = nil
        onResult = nil
        onCancel = nil
        callback?()
    }

    /// New capture sessions and app shutdown await this before taking ownership
    /// of focus/pointer state. A previous synchronous cancel still retains its drain.
    func cancelAndWait() async {
        let priorWork = work ?? drainingWork
        terminate(notifyCancellation: false)
        let expectedDrain = drainID
        await priorWork?.value
        if drainID == expectedDrain { drainingWork = nil }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel()
        return false
    }

    private func addFrame() {
        guard let coordinator, let id = sessionID, let model, !model.busy, !model.acquisitionDisabled else { return }
        model.busy = true
        model.status = "Capturing and checking overlap…"
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let report = model.frameCount == 0 ? try await coordinator.start() : try await coordinator.addManualFrame()
                await self.update(report, coordinator: coordinator, id: id)
            } catch { self.show(error, id: id) }
            self.finishedWork(id: id)
        }
    }

    private func startAutomatic() {
        guard let coordinator, let id = sessionID, let model, !model.busy, model.frameCount > 0,
              !model.acquisitionDisabled, !model.automaticDisabled else { return }
        model.busy = true
        work = Task { [weak self] in
            guard let self else { return }
            await self.runAutomatic(id: id, coordinator: coordinator, model: model)
            self.finishedWork(id: id)
        }
    }

    private func runAutomatic(id: UUID, coordinator: ScrollCaptureCoordinator, model: ScrollCapturePanelModel) async {
        guard sessionID == id else { return }
        model.busy = true
        model.automatic = true
        model.status = "Auto-scrolling and stitching… Keep the target unchanged; Stop Auto preserves the partial result."
        do {
            try await coordinator.runAutomatic { [weak self] report, statistics in
                guard let self, self.sessionID == id else { return }
                self.apply(report, statistics: statistics)
            }
        } catch {
            guard sessionID == id else { return }
            if error is CancellationError {
                model.status = "Stopped. Review the partial capture before finishing."
            } else if coordinator.warnings.isEmpty {
                // Accessibility/native scrolling is optional. Keep the first
                // frame usable when manual capture can still finish the job.
                model.status = "Auto-scrolling is unavailable for this target. Scroll manually, then Add Frame."
            } else {
                show(error, id: id)
            }
        }
        guard sessionID == id else { return }
        model.warnings = coordinator.warnings
        model.automatic = false
        model.busy = false
    }

    private func stop(reason: String = "Auto stopped. Review the partial result before finishing.", terminal: Bool = false) {
        guard let coordinator, let model else { return }
        if terminal {
            coordinator.preventFurtherAcquisition(reason: reason)
            model.acquisitionDisabled = true
        }
        coordinator.addWarning(reason)
        model.warnings = coordinator.warnings
        model.status = reason
        work?.cancel()
    }

    private func finish() {
        guard let coordinator, let id = sessionID, let model, !model.busy, model.frameCount > 0 else { return }
        model.busy = true
        model.status = "Flattening verified frames…"
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await coordinator.finish()
                guard self.sessionID == id else { return }
                let callback = self.onResult
                self.sessionID = nil
                self.closePanel()
                self.coordinator = nil
                self.model = nil
                self.onResult = nil
                self.onCancel = nil
                self.work = nil
                callback?(result)
            } catch {
                self.show(error, id: id)
                self.finishedWork(id: id)
            }
        }
    }

    private func update(_ report: ScrollAppendReport, coordinator: ScrollCaptureCoordinator, id: UUID) async {
        let statistics = await coordinator.statistics()
        guard sessionID == id else { return }
        apply(report, statistics: statistics)
        model?.warnings = coordinator.warnings
    }

    private func apply(_ report: ScrollAppendReport, statistics: ScrollCaptureStatistics) {
        guard let model else { return }
        model.frameCount = statistics.frameCount
        model.width = statistics.outputWidth
        model.height = statistics.outputHeight
        switch report.disposition {
        case .firstFrame: model.status = "Preparing automatic scrolling…"
        case .appended:
            model.status = "Added \(report.addedRows) verified rows."
        case .unchanged: model.status = "End of content detected. Review the result or Finish."
        case .rejected: model.status = report.issue?.localizedDescription ?? "The uncertain frame was not added."
        }
    }

    private func show(_ error: Error, id: UUID) {
        guard sessionID == id else { return }
        if error is CancellationError {
            model?.status = "Stopped. Review the partial capture before finishing."
        } else {
            coordinator?.addWarning(error.localizedDescription)
            model?.status = error.localizedDescription
            model?.warnings = coordinator?.warnings ?? []
        }
    }

    private func finishedWork(id: UUID) {
        guard sessionID == id else { return }
        model?.busy = false
        model?.automatic = false
        work = nil
    }

    private func showPanel(region: ScrollCaptureRegion, model: ScrollCapturePanelModel) {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 384, height: 300),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        // Capture repeatedly hides this panel. Ordering animations can leave
        // window-server transactions pending during target revalidation.
        panel.animationBehavior = .none
        panel.title = "Scrolling Capture"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ScrollCapturePanelView(model: model,
            addFrame: { [weak self] in self?.addFrame() }, startAutomatic: { [weak self] in self?.startAutomatic() },
            stop: { [weak self] in self?.stop() }, finish: { [weak self] in self?.finish() }, cancel: { [weak self] in self?.cancel() }))
        let selected = CGRect(x: region.displayFrame.minX + region.rect.minX,
            y: region.displayFrame.maxY - region.rect.maxY, width: region.rect.width, height: region.rect.height)
        let visible = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == region.displayID
        })?.visibleFrame ?? region.displayFrame
        if let placement = ScrollCapturePanelPlacement.frame(selected: selected, visible: visible, panelSize: panel.frame.size) {
            panel.setFrameOrigin(placement.origin)
        } else {
            model.automaticDisabled = true
            panel.setFrameOrigin(CGPoint(x: visible.minX, y: max(visible.minY, visible.maxY - panel.frame.height)))
        }
        self.panel = panel
        panel.orderFrontRegardless()
    }

    private func closePanel() {
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        displayObserver = nil
        sleepObserver = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}
