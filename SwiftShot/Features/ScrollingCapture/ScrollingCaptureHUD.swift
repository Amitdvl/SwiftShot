import AppKit
import Observation
import QuartzCore
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
            ScrollingCaptureHUDPresentation(headline: "Keep scrolling",
                                            detail: "The spotlight tracks your capture",
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
    func show(relativeTo selectedFrame: CGRect, on displayFrame: CGRect, in visibleFrame: CGRect,
              onFinish: @escaping @MainActor () -> Void,
              onCancel: @escaping @MainActor () -> Void)
    func update(_ state: ScrollingCaptureHUDState)
    func update(_ extent: ScrollingCaptureExtent)
    func dismiss()
}

@MainActor @Observable
final class ScrollingCaptureHUDModel {
    var state: ScrollingCaptureHUDState
    var extent: ScrollingCaptureExtent?
    var actionDelivered = false

    init(state: ScrollingCaptureHUDState = .preparing) {
        self.state = state
    }
}

@MainActor
final class ScrollingCaptureHUDController: ScrollingCaptureHUDPresenting {
    private(set) var panel: ScrollingCaptureHUDPanel?
    private(set) var spotlightPanel: ScrollingCaptureSpotlightPanel?
    private(set) var spotlightView: ScrollingCaptureSpotlightView?
    private(set) var model: ScrollingCaptureHUDModel?
    private var onFinish: (@MainActor () -> Void)?
    private var onCancel: (@MainActor () -> Void)?

    var isVisible: Bool { panel?.isVisible == true }

    func show(relativeTo selectedFrame: CGRect, on displayFrame: CGRect, in visibleFrame: CGRect,
              onFinish: @escaping @MainActor () -> Void,
              onCancel: @escaping @MainActor () -> Void) {
        dismiss()

        let model = ScrollingCaptureHUDModel()
        let localSelection = ScrollingCaptureSpotlightGeometry.localSelection(
            selected: selectedFrame, overlay: displayFrame)
        let spotlightView = ScrollingCaptureSpotlightView(
            frame: CGRect(origin: .zero, size: displayFrame.size),
            spotlightFrame: localSelection)
        spotlightView.autoresizingMask = [.width, .height]
        let spotlightPanel = ScrollingCaptureSpotlightPanel(
            contentRect: displayFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        configure(panel: spotlightPanel)
        spotlightPanel.title = "Scrolling Capture Spotlight"
        spotlightPanel.ignoresMouseEvents = true
        spotlightPanel.contentView = spotlightView

        let panel = ScrollingCaptureHUDPanel(
            contentRect: ScrollingCaptureHUDPlacement.frame(selected: selectedFrame, visible: visibleFrame),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        configure(panel: panel)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.title = "Scrolling Capture"
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
        self.spotlightPanel = spotlightPanel
        self.spotlightView = spotlightView
        self.onFinish = onFinish
        self.onCancel = onCancel
        spotlightPanel.alphaValue = 0
        spotlightPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            spotlightPanel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()
    }

    func update(_ state: ScrollingCaptureHUDState) {
        guard let model, !model.actionDelivered else { return }
        model.state = state
        spotlightView?.update(state)
    }

    func update(_ extent: ScrollingCaptureExtent) {
        guard let model, !model.actionDelivered else { return }
        model.extent = extent
        spotlightView?.update(extent)
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel?.close()
        spotlightPanel?.orderOut(nil)
        spotlightPanel?.close()
        panel = nil
        spotlightPanel = nil
        spotlightView = nil
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

    private func configure(panel: NSPanel) {
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
    }
}

final class ScrollingCaptureHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ScrollingCaptureSpotlightPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum ScrollingCaptureSpotlightGeometry {
    static func localSelection(selected: CGRect, overlay: CGRect) -> CGRect {
        let local = selected.offsetBy(dx: -overlay.minX, dy: -overlay.minY)
        let bounds = CGRect(origin: .zero, size: overlay.size)
        let clipped = local.intersection(bounds)
        return clipped.isNull ? .zero : clipped
    }
}

final class ScrollingCaptureSpotlightView: NSView {
    private(set) var extent: ScrollingCaptureExtent?
    private var state: ScrollingCaptureHUDState = .preparing
    private let spotlightFrame: CGRect

    init(frame frameRect: NSRect, spotlightFrame: CGRect) {
        self.spotlightFrame = spotlightFrame
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(_ extent: ScrollingCaptureExtent) {
        self.extent = extent
        needsDisplay = true
    }

    func update(_ state: ScrollingCaptureHUDState) {
        self.state = state
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !spotlightFrame.isEmpty else { return }
        drawDimmingMask()
        drawSpotlightEdge()
        if let extent { drawProgress(extent) }
    }

    private func drawDimmingMask() {
        let hole = spotlightFrame.intersection(bounds)
        guard !hole.isNull else { return }
        NSColor.black.withAlphaComponent(0.34).setFill()
        [
            CGRect(x: bounds.minX, y: hole.maxY, width: bounds.width,
                   height: max(0, bounds.maxY - hole.maxY)),
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
                   height: max(0, hole.minY - bounds.minY)),
            CGRect(x: bounds.minX, y: hole.minY, width: max(0, hole.minX - bounds.minX),
                   height: hole.height),
            CGRect(x: hole.maxX, y: hole.minY, width: max(0, bounds.maxX - hole.maxX),
                   height: hole.height)
        ].filter { !$0.isEmpty }.forEach { NSBezierPath(rect: $0).fill() }
    }

    private func drawSpotlightEdge() {
        let color = isPaused ? NSColor.systemOrange : NSColor.controlAccentColor
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = .zero
        shadow.set()
        color.withAlphaComponent(0.95).setStroke()
        let path = NSBezierPath(roundedRect: spotlightFrame.insetBy(dx: 1, dy: 1),
                                xRadius: 11, yRadius: 11)
        path.lineWidth = 2
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawProgress(_ extent: ScrollingCaptureExtent) {
        let color = isPaused ? NSColor.systemOrange : NSColor.controlAccentColor
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let label = extent.extentLabel as NSString
        let textSize = label.size(withAttributes: attributes)
        let badgeSize = CGSize(width: textSize.width + 18, height: 26)
        let x = min(max(spotlightFrame.minX + 10, spotlightFrame.maxX - badgeSize.width - 12),
                    bounds.maxX - badgeSize.width - 6)
        let y = max(bounds.minY + 6, spotlightFrame.minY + 10)
        let badge = CGRect(origin: CGPoint(x: x, y: y), size: badgeSize)
        color.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 13, yRadius: 13).fill()
        label.draw(at: CGPoint(x: badge.minX + 9,
                               y: badge.midY - textSize.height / 2), withAttributes: attributes)

        let tickCount = min(8, max(1, extent.acceptedFrames))
        let railX = spotlightFrame.maxX - 10
        let railBottom = badge.maxY + 10
        let available = max(0, spotlightFrame.maxY - railBottom - 14)
        guard available >= 5 else { return }
        color.withAlphaComponent(0.28).setStroke()
        let rail = NSBezierPath()
        rail.move(to: CGPoint(x: railX, y: railBottom))
        rail.line(to: CGPoint(x: railX, y: railBottom + available))
        rail.lineWidth = 1
        rail.stroke()
        color.withAlphaComponent(0.95).setStroke()
        for index in 0..<tickCount {
            let y = railBottom + min(available, CGFloat(index) * 11)
            let tick = NSBezierPath()
            tick.move(to: CGPoint(x: railX - 5, y: y))
            tick.line(to: CGPoint(x: railX + 1, y: y))
            tick.lineWidth = 2
            tick.stroke()
        }
    }

    private var isPaused: Bool {
        switch state {
        case .recoverableSeam, .terminal: true
        default: false
        }
    }
}

enum ScrollingCaptureHUDPlacement {
    static let size = CGSize(width: 332, height: 60)

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
                Text(model.extent?.extentLabel ?? presentation.detail)
                    .font(.system(size: 10, weight: model.extent == nil ? .regular : .medium,
                                  design: model.extent == nil ? .default : .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            .frame(width: 156, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Capture status")
            .accessibilityValue("\(presentation.headline). \(model.extent?.extentLabel ?? presentation.detail)")

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
            .frame(minWidth: 40, minHeight: 40)
            .buttonStyle(CaptureButtonStyle(compact: true))
            .keyboardShortcut(.cancelAction)
            .disabled(model.actionDelivered)
            .help("Cancel and discard")
            .accessibilityLabel("Cancel Scrolling Capture")
        }
        .padding(.horizontal, 10)
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
            Image(systemName: isPaused ? "exclamationmark.triangle.fill" : "arrow.down")
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
