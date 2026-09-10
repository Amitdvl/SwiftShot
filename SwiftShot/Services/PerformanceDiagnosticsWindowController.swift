import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Owns only the explicitly requested utility panel and JSON save panel. No
/// screenshot APIs, window enumeration, activation, polling, or restoration.
@MainActor
final class PerformanceDiagnosticsWindowController {
    private weak var diagnostics: PerformanceDiagnostics?
    private var panel: DiagnosticsPanel?
    private var savePanel: NSSavePanel?
    private var wantsVisible = false
    private var captureHidden = false
    private var avoiding: CGRect?

    init(diagnostics: PerformanceDiagnostics) { self.diagnostics = diagnostics }

    func show(avoiding frame: CGRect?, captureHidden: Bool) -> Bool {
        wantsVisible = true
        avoiding = frame
        self.captureHidden = captureHidden
        return presentIfSafe()
    }
    func hide() { wantsVisible = false; hidePanelContent() }
    func setCaptureHidden(_ hidden: Bool) -> Bool {
        captureHidden = hidden
        if hidden {
            // A capture hotkey may arrive while the explicit metadata exporter
            // is still choosing its destination. Do not photograph that panel.
            savePanel?.cancel(nil)
            savePanel?.orderOut(nil)
            hidePanelContent()
            return false
        }
        return presentIfSafe()
    }

    private func presentIfSafe() -> Bool {
        guard wantsVisible, !captureHidden, let diagnostics,
              let frame = DiagnosticsWindowPlacement.frame(visibleFrames: NSScreen.screens.map(\.visibleFrame), avoiding: avoiding) else {
            hidePanelContent()
            return false
        }
        let window: DiagnosticsPanel
        if let panel { window = panel }
        else {
            window = Self.makeDiagnosticsPanel()
            window.contentView = nil
            window.onClose = { [weak self] in
                guard let self else { return }
                self.wantsVisible = false
                self.panel?.contentView = nil
                self.panel = nil
                self.diagnostics?.diagnosticsWindowDidClose()
            }
            panel = window
        }
        if window.contentView == nil {
            window.contentView = NSHostingView(rootView: PerformanceDiagnosticsView(diagnostics: diagnostics))
        }
        // This is the outer window frame, including title bar, so placement
        // never accidentally expands back into a target rectangle.
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        return true
    }

    private func hidePanelContent() {
        panel?.orderOut(nil)
        // Ordering out alone leaves the Form observing every capture stage.
        // Keep panel/recorder identity, but recreate UI only when safe and wanted.
        panel?.contentView = nil
    }

    func export(data: Data, completion: @escaping (Result<Bool, Error>) -> Void) {
        guard savePanel == nil else { completion(.success(false)); return }
        let chooser = Self.makeSavePanel()
        savePanel = chooser
        chooser.begin { [weak self] response in
            defer { self?.savePanel = nil }
            guard response == .OK, let destination = chooser.url else { completion(.success(false)); return }
            do { try data.write(to: destination, options: .atomic); completion(.success(true)) }
            catch { completion(.failure(error)) }
        }
    }

    /// Configure owned native panels before either presentation or capture hiding.
    /// Construction alone must not order a window onto the screen.
    static func makeDiagnosticsPanel() -> DiagnosticsPanel {
        let window = DiagnosticsPanel(contentRect: .zero, styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        window.title = "Performance Diagnostics"
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        // orderOut must not leave an animated utility panel in a capture frame.
        // This removes AppKit animation, not the need for capture-filter exclusion.
        window.animationBehavior = .none
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.contentMinSize = NSSize(width: 300, height: 340)
        return window
    }

    static func makeSavePanel() -> NSSavePanel {
        let chooser = NSSavePanel()
        chooser.title = "Export Performance Diagnostics"
        chooser.nameFieldStringValue = "SwiftShot-performance.json"
        chooser.allowedContentTypes = [.json]
        chooser.canCreateDirectories = false
        chooser.animationBehavior = .none
        chooser.message = "Metadata only: timings, conditions, counts and process CPU/memory. No screenshots, OCR text or capture paths."
        return chooser
    }
}

final class DiagnosticsPanel: NSPanel {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func close() {
        let callback = onClose
        onClose = nil
        super.close()
        callback?()
    }
}
