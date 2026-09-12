import AppKit
import Observation
import SwiftUI

struct ScrollingCaptureHUDPresentation: Equatable, Sendable {
    let headline: String
    let detail: String
    let showsProgress: Bool
    let finishEnabled: Bool
}

enum ScrollingCaptureHUDState: Equatable, Sendable {
    case preparing
    case ready(sectionCount: Int)
    case adding(sectionCount: Int)
    case recoverableSeam(sectionCount: Int)
    case terminal(reason: String, sectionCount: Int)
    case finishing(sectionCount: Int)

    var presentation: ScrollingCaptureHUDPresentation {
        switch self {
        case .preparing:
            ScrollingCaptureHUDPresentation(headline: "Preparing…", detail: "Starting capture",
                                            showsProgress: true, finishEnabled: false)
        case .ready(let sectionCount):
            ScrollingCaptureHUDPresentation(headline: "Scroll the page", detail: sectionLabel(sectionCount),
                                            showsProgress: false, finishEnabled: true)
        case .adding:
            ScrollingCaptureHUDPresentation(headline: "Scroll the page", detail: "Adding section…",
                                            showsProgress: true, finishEnabled: true)
        case .recoverableSeam:
            ScrollingCaptureHUDPresentation(headline: "Scroll a little slower",
                                            detail: "The last view didn’t overlap enough.",
                                            showsProgress: false, finishEnabled: true)
        case .terminal(let reason, let sectionCount):
            ScrollingCaptureHUDPresentation(headline: "Capture paused", detail: reason,
                                            showsProgress: false, finishEnabled: sectionCount > 0)
        case .finishing(let sectionCount):
            ScrollingCaptureHUDPresentation(headline: "Finishing…", detail: sectionLabel(sectionCount),
                                            showsProgress: true, finishEnabled: false)
        }
    }

    var sectionCount: Int {
        switch self {
        case .preparing: 0
        case .ready(let count), .adding(let count), .recoverableSeam(let count),
             .terminal(_, let count), .finishing(let count): max(0, count)
        }
    }

    private func sectionLabel(_ count: Int) -> String {
        let safeCount = max(0, count)
        return safeCount == 1 ? "1 section captured" : "\(safeCount) sections captured"
    }
}

@MainActor
protocol ScrollingCaptureHUDPresenting: AnyObject {
    var isVisible: Bool { get }
    func show(relativeTo selectedFrame: CGRect, in visibleFrame: CGRect,
              onFinish: @escaping @MainActor () -> Void,
              onCancel: @escaping @MainActor () -> Void)
    func update(_ state: ScrollingCaptureHUDState)
    func dismiss()
}

@MainActor @Observable
final class ScrollingCaptureHUDModel {
    var state: ScrollingCaptureHUDState
    var actionDelivered = false

    init(state: ScrollingCaptureHUDState = .preparing) {
        self.state = state
    }
}

@MainActor
final class ScrollingCaptureHUDController: ScrollingCaptureHUDPresenting {
    private(set) var panel: ScrollingCaptureHUDPanel?
    private(set) var model: ScrollingCaptureHUDModel?
    private var onFinish: (@MainActor () -> Void)?
    private var onCancel: (@MainActor () -> Void)?

    var isVisible: Bool { panel?.isVisible == true }

    func show(relativeTo selectedFrame: CGRect, in visibleFrame: CGRect,
              onFinish: @escaping @MainActor () -> Void,
              onCancel: @escaping @MainActor () -> Void) {
        dismiss()

        let model = ScrollingCaptureHUDModel()
        let panel = ScrollingCaptureHUDPanel(
            contentRect: ScrollingCaptureHUDPlacement.frame(selected: selectedFrame, visible: visibleFrame),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Scrolling Capture"
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.setAccessibilityLabel("Scrolling Capture")

        let hosting = NSHostingView(rootView: ScrollingCaptureHUDView(
            model: model,
            onFinish: { [weak self] in self?.performFinish() },
            onCancel: { [weak self] in self?.performCancel() }
        ))
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: ScrollingCaptureHUDPlacement.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        self.model = model
        self.panel = panel
        self.onFinish = onFinish
        self.onCancel = onCancel
        panel.orderFrontRegardless()
    }

    func update(_ state: ScrollingCaptureHUDState) {
        guard let model, !model.actionDelivered else { return }
        model.state = state
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        model = nil
        onFinish = nil
        onCancel = nil
    }

    func performFinish() {
        guard let model, model.state.presentation.finishEnabled, !model.actionDelivered else { return }
        model.actionDelivered = true
        model.state = .finishing(sectionCount: model.state.sectionCount)
        onFinish?()
    }

    func performCancel() {
        guard let model, !model.actionDelivered else { return }
        model.actionDelivered = true
        onCancel?()
    }
}

final class ScrollingCaptureHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum ScrollingCaptureHUDPlacement {
    static let size = CGSize(width: 304, height: 58)

    static func frame(selected: CGRect, visible: CGRect) -> CGRect {
        let safe = visible.insetBy(dx: 8, dy: 8)
        let gap: CGFloat = 12
        let alignedX = min(max(selected.midX - size.width / 2, safe.minX), safe.maxX - size.width)
        let alignedY = min(max(selected.midY - size.height / 2, safe.minY), safe.maxY - size.height)
        let candidates = [
            CGRect(origin: CGPoint(x: alignedX, y: selected.minY - size.height - gap), size: size),
            CGRect(origin: CGPoint(x: alignedX, y: selected.maxY + gap), size: size),
            CGRect(origin: CGPoint(x: selected.maxX + gap, y: alignedY), size: size),
            CGRect(origin: CGPoint(x: selected.minX - size.width - gap, y: alignedY), size: size)
        ]
        if let frame = candidates.first(where: { safe.contains($0) && !$0.intersects(selected) }) {
            return frame
        }

        let corners = [
            CGPoint(x: safe.minX, y: safe.minY),
            CGPoint(x: safe.maxX - size.width, y: safe.minY),
            CGPoint(x: safe.minX, y: safe.maxY - size.height),
            CGPoint(x: safe.maxX - size.width, y: safe.maxY - size.height)
        ]
        let target = CGPoint(x: selected.midX, y: selected.midY)
        let origin = corners.max { lhs, rhs in
            hypot(lhs.x + size.width / 2 - target.x, lhs.y + size.height / 2 - target.y) <
            hypot(rhs.x + size.width / 2 - target.x, rhs.y + size.height / 2 - target.y)
        } ?? safe.origin
        return CGRect(origin: origin, size: size)
    }
}

private struct ScrollingCaptureHUDView: View {
    @Bindable var model: ScrollingCaptureHUDModel
    let onFinish: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    private var presentation: ScrollingCaptureHUDPresentation { model.state.presentation }

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(presentation.headline)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(presentation.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(presentation.detail)
            }
            .frame(width: 126, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Capture status")
            .accessibilityValue("\(presentation.headline). \(presentation.detail)")

            Spacer(minLength: 0)

            Button("Finish", action: onFinish)
                .buttonStyle(CaptureButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!presentation.finishEnabled || model.actionDelivered)
                .help("Finish and open in editor")
                .accessibilityLabel("Finish Scrolling Capture")

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(CaptureButtonStyle(compact: true))
            .keyboardShortcut(.cancelAction)
            .disabled(model.actionDelivered)
            .help("Cancel and discard")
            .accessibilityLabel("Cancel Scrolling Capture")
        }
        .padding(.horizontal, 12)
        .frame(width: ScrollingCaptureHUDPlacement.size.width,
               height: ScrollingCaptureHUDPlacement.size.height)
        .captureChrome(capsule: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Scrolling Capture")
    }

    @ViewBuilder
    private var statusIcon: some View {
        if presentation.showsProgress {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Checking captured content")
        } else {
            Image(systemName: isPaused ? "exclamationmark.triangle.fill" : "rectangle.portrait.and.arrow.down")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isPaused ? Color.orange : Color.secondary)
                .accessibilityHidden(true)
        }
    }

    private var isPaused: Bool {
        switch model.state {
        case .recoverableSeam, .terminal: true
        default: false
        }
    }
}
