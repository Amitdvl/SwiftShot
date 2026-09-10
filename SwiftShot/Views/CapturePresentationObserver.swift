import AppKit
import QuartzCore
import SwiftUI

/// Opt-in software presentation receipt. This runs only for an armed diagnostic
/// run. It proves layout/display submission, not physical pixels at the monitor.
struct CapturePresentationObserver: NSViewRepresentable {
    let receiptID: UUID
    let onPresented: () -> Void
    var traceRunID: UUID? = nil
    var tracePresentation: CaptureLatencyTrace.Presentation? = nil
    var traceSurface: Int? = nil
    func makeNSView(context: Context) -> CapturePresentationView { CapturePresentationView() }
    func updateNSView(_ view: CapturePresentationView, context: Context) {
        view.request(receiptID, traceRunID: traceRunID, tracePresentation: tracePresentation,
                     traceSurface: traceSurface, completion: onPresented)
    }
}

@MainActor
final class CapturePresentationView: NSView {
    private var receipt = CapturePresentationReceipt()
    private var currentID: UUID?
    private var queuedID: UUID?
    private var completion: (() -> Void)?
    private var traceRunID: UUID?
    private var tracePresentation: CaptureLatencyTrace.Presentation?
    private var traceSurface: Int?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedulePresentation() }

    func request(_ id: UUID, traceRunID: UUID? = nil,
                 tracePresentation: CaptureLatencyTrace.Presentation? = nil,
                 traceSurface: Int? = nil, completion: @escaping () -> Void) {
        receipt.request(id)
        currentID = id
        self.completion = completion
        self.traceRunID = traceRunID
        self.tracePresentation = tracePresentation
        self.traceSurface = traceSurface
        schedulePresentation()
    }

    private func schedulePresentation() {
        guard let id = currentID, window != nil, queuedID != id else { return }
        queuedID = id
        // Carry the armed run across both asynchronous boundaries. Never resolve
        // a newer active run in an older presentation's completion callback.
        let traceRunID = traceRunID, tracePresentation = tracePresentation, traceSurface = traceSurface
        let trace = CaptureLatencyTrace.shared
        trace.mark(.receiptEnqueued, for: traceRunID, presentation: tracePresentation, surface: traceSurface)
        // Never synchronously force layout from SwiftUI's update/layout stack.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentID == id, let window = self.window, window.isVisible else { return }
            trace.mark(.receiptDequeued, for: traceRunID, presentation: tracePresentation, surface: traceSurface)
            trace.mark(.layoutStarted, for: traceRunID, presentation: tracePresentation, surface: traceSurface)
            window.contentView?.layoutSubtreeIfNeeded()
            trace.mark(.layoutFinished, for: traceRunID, presentation: tracePresentation, surface: traceSurface)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { [weak self] in
                trace.mark(.transactionCompleted, for: traceRunID, presentation: tracePresentation, surface: traceSurface)
                Task { @MainActor in
                    guard let self, self.currentID == id,
                          self.receipt.complete(id, isVisible: self.window?.isVisible == true) else { return }
                    trace.mark(.receiptDelivered, for: traceRunID, presentation: tracePresentation, surface: traceSurface)
                    self.completion?()
                }
            }
            trace.mark(.displayStarted, for: traceRunID, presentation: tracePresentation, surface: traceSurface)
            window.displayIfNeeded()
            trace.mark(.displayFinished, for: traceRunID, presentation: tracePresentation, surface: traceSurface)
            CATransaction.commit()
            trace.mark(.transactionCommitted, for: traceRunID, presentation: tracePresentation, surface: traceSurface)
            CATransaction.flush()
            trace.mark(.transactionFlushed, for: traceRunID, presentation: tracePresentation, surface: traceSurface)
        }
    }
}
