import AppKit
import ApplicationServices
import OSLog

private let scrollTargetLogger = Logger(subsystem: "com.swiftshot.app", category: "ScrollTarget")

enum NativeScrollCapturePurpose: Hashable {
    case initialPointerMove
    case validation
    case forwardScroll
    case pageRestoration
    case pointerRestoration
    case focusRestoration
}

/// One purpose-specific authorization. The synchronous consumer owns the final
/// context and identity checks and must not suspend before its associated effect.
@MainActor
final class NativeScrollCaptureReceipt {
    enum Rejection: Equatable { case invalidAuthority, contextChanged }
    let targetID: UUID
    let point: CGPoint
    let ownerPID: pid_t
    let purpose: NativeScrollCapturePurpose
    private let deadline: ContinuousClock.Instant
    private let now: @MainActor () -> ContinuousClock.Instant
    private let isCurrent: @MainActor () -> Bool
    private var consumed = false
    private(set) var rejection: Rejection?

    init(targetID: UUID = UUID(), point: CGPoint, ownerPID: pid_t, purpose: NativeScrollCapturePurpose,
         deadline: ContinuousClock.Instant, now: @escaping @MainActor () -> ContinuousClock.Instant,
         isCurrent: @escaping @MainActor () -> Bool) {
        self.targetID = targetID
        self.point = point
        self.ownerPID = ownerPID
        self.purpose = purpose
        self.deadline = deadline
        self.now = now
        self.isCurrent = isCurrent
    }

    func consume(while contextIsCurrent: @MainActor () -> Bool = { true }) -> Bool {
        guard !consumed else { rejectAuthority(); return false }
        // Claim before invoking any callback, including failed preconditions and
        // reentrant callbacks. Neither rejection nor a later recovery permits reuse.
        consumed = true
        guard checkMetadata() else { return false }
        let initialContext = contextIsCurrent()
        guard checkMetadata() else { return false }
        guard initialContext else { rejectContext(); return false }
        // Preserve an observed identity failure even if that callback also
        // cancels the owning task. Cancellation cannot repair invalid evidence.
        guard isCurrent() else { rejectAuthority(); return false }
        guard checkMetadata() else { return false }
        let finalContext = contextIsCurrent()
        guard checkMetadata() else { return false }
        guard finalContext else { rejectContext(); return false }
        return true
    }

    /// Scalar/deadline admission only; this grants no effect authority and never
    /// runs AX. It lets an awaited bad receipt be observed before cancellation.
    func validateMetadata() -> Bool {
        guard !consumed else { rejectAuthority(); return false }
        return checkMetadata()
    }

    func rejectAuthority() {
        consumed = true
        rejection = .invalidAuthority
    }

    private func checkMetadata() -> Bool {
        guard rejection != .invalidAuthority, point.x.isFinite, point.y.isFinite,
              ownerPID > 0, now() < deadline else { rejectAuthority(); return false }
        return true
    }

    private func rejectContext() {
        if rejection == nil { rejection = .contextChanged }
    }
}

@MainActor
struct NativeScrollCaptureTarget {
    let id: UUID
    let point: CGPoint
    let ownerPID: pid_t
    let isAtEndOfContent: @MainActor () -> Bool?
    /// Nil is invalid/unavailable metadata, never cancellation alone. Providers
    /// drain native work and return its actual evidence even when cancelled.
    let prepareReceipt: @MainActor (NativeScrollCapturePurpose) async -> NativeScrollCaptureReceipt?

    init(id: UUID, point: CGPoint, ownerPID: pid_t,
         isAtEndOfContent: @escaping @MainActor () -> Bool? = { nil },
         prepareReceipt: @escaping @MainActor (NativeScrollCapturePurpose) async -> NativeScrollCaptureReceipt?) {
        self.id = id
        self.point = point
        self.ownerPID = ownerPID
        self.isAtEndOfContent = isAtEndOfContent
        self.prepareReceipt = prepareReceipt
    }
}

@MainActor
protocol NativeScrollCaptureEnvironment {
    func resolveTarget(in region: ScrollCaptureRegion) async throws -> NativeScrollCaptureTarget
    func hasAccess() -> Bool
    func pointerLocation() -> CGPoint?
    func movePointer(to point: CGPoint) -> Bool
    func focusRestoration() -> @MainActor () -> Void
    func postWheel(_ delta: Int32, using receipt: NativeScrollCaptureReceipt, restoring: Bool) -> Bool
}

/// Owns one immutable target lease from the first suspension through final cleanup.
/// Metadata requests are drained by this task; no effect is delegated or detached.
@MainActor
final class NativeScrollCaptureDriver: ScrollCaptureDriving {
    private enum Phase: Equatable { case idle, beginning, active, restoring }
    private let environment: any NativeScrollCaptureEnvironment
    private var phase: Phase = .idle
    private var generation: UUID?
    private var operationID: UUID?
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var restorationWaiters: [CheckedContinuation<Void, Never>] = []
    private var originalPointer: CGPoint?
    private var restoreFocus: (@MainActor () -> Void)?
    private var target: NativeScrollCaptureTarget?
    private var movedPointer = false
    private var lostTarget = false
    private var observedMovement: CGFloat = 0
    private var pendingMovement: CGFloat = 0
    private var uncertainMovement = false

    init(environment: any NativeScrollCaptureEnvironment = SystemScrollCaptureEnvironment()) {
        self.environment = environment
    }

    func begin(in region: ScrollCaptureRegion) async throws {
        try Task.checkCancellation()
        guard phase == .idle, generation == nil, operationID == nil,
              environment.hasAccess(), let pointer = environment.pointerLocation(),
              pointer.x.isFinite, pointer.y.isFinite else {
            throw CaptureError.failed("The automatic scrolling target is unavailable.")
        }
        // Claim before the first await. A competing begin cannot replace this lease.
        let lease = UUID()
        generation = lease
        phase = .beginning
        originalPointer = pointer
        restoreFocus = environment.focusRestoration()
        let operation = startOperation()
        defer { finishOperation(operation) }
        let resolved = try await environment.resolveTarget(in: region)
        try requireContext(lease: lease, phase: .beginning, pointer: pointer, restoring: false)
        guard resolved.point.x.isFinite, resolved.point.y.isFinite, resolved.ownerPID > 0 else {
            throw loseTarget()
        }
        target = resolved
        let receipt = try await prepare(.initialPointerMove, target: resolved, lease: lease,
            phase: .beginning, pointer: pointer, restoring: false)
        try consume(receipt, lease: lease, phase: .beginning, pointer: pointer, restoring: false)
        // No suspension between the final receipt checks and pointer mutation.
        guard environment.movePointer(to: resolved.point) else { throw loseTarget() }
        movedPointer = true
        try requireContext(lease: lease, phase: .beginning, pointer: resolved.point, restoring: false)
        phase = .active
    }

    func validateTarget() async throws {
        let (target, lease, operation) = try startActiveOperation()
        defer { finishOperation(operation) }
        let receipt = try await prepare(.validation, target: target, lease: lease,
            phase: .active, pointer: target.point, restoring: false)
        try consume(receipt, lease: lease, phase: .active, pointer: target.point, restoring: false)
    }

    func scrollDown(points: CGFloat) async throws {
        guard points.isFinite, points > 0, points < CGFloat(Int32.max),
              let delta = Int32(exactly: points.rounded()), delta > 0 else {
            throw CaptureError.failed("The automatic scrolling distance is invalid.")
        }
        let (target, lease, operation) = try startActiveOperation()
        defer { finishOperation(operation) }
        let receipt = try await prepare(.forwardScroll, target: target, lease: lease,
            phase: .active, pointer: target.point, restoring: false)
        // The delivery consumer performs the final identity/context check itself.
        guard environment.postWheel(-delta, using: receipt, restoring: false) else {
            if receipt.rejection == .invalidAuthority { lostTarget = true }
            try Task.checkCancellation()
            throw loseTarget()
        }
        // Must precede every await or cancellation check after an actual request.
        pendingMovement += CGFloat(delta)
    }

    func recordObservedMovement(points: CGFloat?) {
        guard phase == .active, generation != nil, operationID == nil else { return }
        if let points, points.isFinite, points >= 0 { observedMovement += points }
        else { observedMovement += pendingMovement; uncertainMovement = true }
        pendingMovement = 0
    }

    func isAtEndOfContent() -> Bool? {
        guard phase == .active, operationID == nil, let target else { return nil }
        return target.isAtEndOfContent()
    }

    func restore() async -> String? {
        guard let lease = generation else { return nil }
        if phase == .restoring {
            await withCheckedContinuation { restorationWaiters.append($0) }
            return nil
        }
        // This prevents a still-draining begin/forward operation from producing
        // effects after cleanup has been requested, without abandoning its work.
        phase = .restoring
        if operationID != nil {
            await withCheckedContinuation { operationWaiters.append($0) }
        }
        guard generation == lease, phase == .restoring else { return nil }
        defer { clearLease() }
        guard movedPointer, let target, let originalPointer else { return nil }
        var notices: [String] = []
        let movement = observedMovement + pendingMovement
        do {
            if movement > 0 {
                guard movement.isFinite, let delta = Int32(exactly: movement.rounded()), delta > 0 else {
                    throw loseTarget()
                }
                let receipt = try await prepare(.pageRestoration, target: target, lease: lease,
                    phase: .restoring, pointer: target.point, restoring: true)
                guard environment.postWheel(delta, using: receipt, restoring: true) else { throw loseTarget() }
                notices.append("Page-position restoration was requested but cannot be verified; check the original app.")
            }
            let pointerReceipt = try await prepare(.pointerRestoration, target: target, lease: lease,
                phase: .restoring, pointer: target.point, restoring: true)
            try consume(pointerReceipt, lease: lease, phase: .restoring, pointer: target.point, restoring: true)
            guard environment.movePointer(to: originalPointer),
                  environment.pointerLocation() == originalPointer else { throw loseTarget() }
            let focusReceipt = try await prepare(.focusRestoration, target: target, lease: lease,
                phase: .restoring, pointer: originalPointer, restoring: true)
            try consume(focusReceipt, lease: lease, phase: .restoring, pointer: originalPointer, restoring: true)
            restoreFocus?()
        } catch {
            notices.append("The scrolling target changed or the pointer moved; remaining page, pointer, and focus restoration was not sent. Restore the original page manually.")
        }
        if uncertainMovement || pendingMovement > 0 { notices.append("At least one scroll movement was unverified.") }
        return notices.isEmpty ? nil : notices.joined(separator: " ")
    }

    private func startActiveOperation() throws -> (NativeScrollCaptureTarget, UUID, UUID) {
        guard phase == .active, operationID == nil, let target, let generation else {
            throw CaptureError.failed("The automatic scrolling target is unavailable or already in use.")
        }
        try requireContext(lease: generation, phase: .active, pointer: target.point, restoring: false)
        return (target, generation, startOperation())
    }

    private func prepare(_ purpose: NativeScrollCapturePurpose, target: NativeScrollCaptureTarget,
                         lease: UUID, phase: Phase, pointer: CGPoint,
                         restoring: Bool) async throws -> NativeScrollCaptureReceipt {
        try requireContext(lease: lease, phase: phase, pointer: pointer, restoring: restoring)
        let receipt = await target.prepareReceipt(purpose)
        // Record the actual preparation outcome before a cancellation check can
        // hide it. A later good lookup must not repair observed bad metadata.
        if let receipt {
            if receipt.targetID != target.id || receipt.purpose != purpose ||
                receipt.ownerPID != target.ownerPID || receipt.point != target.point ||
                !receipt.validateMetadata() {
                receipt.rejectAuthority()
                lostTarget = true
            }
        } else {
            lostTarget = true
        }
        try requireContext(lease: lease, phase: phase, pointer: pointer, restoring: restoring)
        guard let receipt else { throw loseTarget() }
        return receipt
    }

    private func consume(_ receipt: NativeScrollCaptureReceipt, lease: UUID, phase: Phase,
                         pointer: CGPoint, restoring: Bool) throws {
        guard receipt.consume(while: {
            self.contextMatches(lease: lease, phase: phase, pointer: pointer, restoring: restoring)
        }) else {
            if receipt.rejection == .invalidAuthority { lostTarget = true }
            if !restoring { try Task.checkCancellation() }
            throw loseTarget()
        }
    }

    private func requireContext(lease: UUID, phase: Phase, pointer: CGPoint, restoring: Bool) throws {
        guard contextMatches(lease: lease, phase: phase, pointer: pointer, restoring: restoring) else {
            if !restoring { try Task.checkCancellation() }
            throw CaptureError.failed("Automatic scrolling stopped because its target changed or the pointer moved. No further scrolling or page restoration will be sent.")
        }
    }

    private func contextMatches(lease: UUID, phase: Phase, pointer: CGPoint, restoring: Bool) -> Bool {
        guard generation == lease, self.phase == phase, !lostTarget else { return false }
        guard environment.hasAccess(), environment.pointerLocation() == pointer else {
            lostTarget = true
            return false
        }
        return restoring || !Task.isCancelled
    }

    private func loseTarget() -> CaptureError {
        lostTarget = true
        return .failed("Automatic scrolling stopped because its target changed or the pointer moved. No further scrolling or page restoration will be sent.")
    }

    private func startOperation() -> UUID {
        let id = UUID()
        operationID = id
        return id
    }

    private func finishOperation(_ id: UUID) {
        guard operationID == id else { return }
        operationID = nil
        let waiters = operationWaiters
        operationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func clearLease() {
        generation = nil
        target = nil
        originalPointer = nil
        restoreFocus = nil
        movedPointer = false
        lostTarget = false
        observedMovement = 0
        pendingMovement = 0
        uncertainMovement = false
        phase = .idle
        let waiters = restorationWaiters
        restorationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

@MainActor
struct SystemScrollCaptureEnvironment: NativeScrollCaptureEnvironment {
    func resolveTarget(in region: ScrollCaptureRegion) async throws -> NativeScrollCaptureTarget {
        try Task.checkCancellation()
        guard hasAccess() else {
            throw CaptureError.failed("Automatic scrolling needs Accessibility access. Enable SwiftShot in System Settings → Privacy & Security → Accessibility, or use Add Frame manually.")
        }
        guard let primaryFrame = NSScreen.screens.first?.frame else {
            throw CaptureError.failed("The scrolling display is unavailable.")
        }
        let point = CGPoint(x: region.displayFrame.minX + region.rect.midX,
            y: primaryFrame.maxY - region.displayFrame.maxY + region.rect.midY)
        let displayIsCurrent = {
            NSScreen.screens.first?.frame == primaryFrame && NSScreen.screens.contains {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == region.displayID &&
                    $0.frame == region.displayFrame
            }
        }
        guard point.x.isFinite, point.y.isFinite, displayIsCurrent() else {
            throw CaptureError.failed("The scrolling target is invalid.")
        }
        let preparation = ScrollTargetMetadataPreparation(now: { ContinuousClock.now }, read: {
            await ScrollTargetWindowMetadata.readAsync(windowID: $0)
        })
        guard let nativePoint = ScrollTargetWindowPolicy.appKitPoint(fromQuartz: point,
            primaryScreenFrame: primaryFrame) else { throw CaptureError.failed("The scrolling target is invalid.") }
        let binding = ScrollTargetInitialBindingPreparation(metadata: preparation, readInput: {
            guard self.hasAccess(), displayIsCurrent(), !Task.isCancelled else {
                return .init(windowNumber: 0, foregroundPID: nil)
            }
            return .init(windowNumber: NSWindow.windowNumber(at: nativePoint, belowWindowWithWindowNumber: 0),
                foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        }, resolve: { snapshot in
            guard self.hasAccess(), displayIsCurrent(), !Task.isCancelled else { return nil }
            return ScrollTargetIdentity.resolve(at: point, using: snapshot)
        })
        let preparedIdentity = await binding.prepare()
        try Task.checkCancellation()
        guard hasAccess(), displayIsCurrent(), let identity = preparedIdentity else {
            throw CaptureError.failed("Could not identify a stable scroll area and its window. Use Add Frame manually.")
        }
        try Task.checkCancellation()
        let id = UUID()
        return NativeScrollCaptureTarget(id: id, point: point, ownerPID: identity.pid,
            isAtEndOfContent: { self.isAtEndOfContent(identity) }) { purpose in
            guard self.hasAccess(), displayIsCurrent() else { return nil }
            let prepared = await preparation.prepare(boundTo: identity)
            // Return known validity, not a cancellation-shaped nil. The driver
            // suppresses cancelled effects after preserving this observation.
            guard self.hasAccess(), displayIsCurrent(), let prepared else { return nil }
            return NativeScrollCaptureReceipt(targetID: id, point: point, ownerPID: identity.pid,
                purpose: purpose, deadline: prepared.deadline, now: { ContinuousClock.now }, isCurrent: {
                    guard self.hasAccess(), displayIsCurrent(),
                          let current = ScrollTargetIdentity.resolve(at: point, using: prepared, boundTo: identity),
                          identity.matches(current), self.hasAccess(), displayIsCurrent() else {
                        scrollTargetLogger.error("validation_failed stage=prepared_identity")
                        return false
                    }
                    return true
                })
        }
    }

    private func isAtEndOfContent(_ identity: ScrollTargetIdentity) -> Bool? {
        guard hasAccess() else { return nil }
        var scrollbarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(identity.scrollArea, kAXVerticalScrollBarAttribute as CFString,
                                             &scrollbarValue) == .success,
              let scrollbarValue, CFGetTypeID(scrollbarValue) == AXUIElementGetTypeID() else { return nil }
        let scrollbar = scrollbarValue as! AXUIElement
        func number(_ attribute: String) -> Double? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(scrollbar, attribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
            let number = value as! NSNumber
            let result = number.doubleValue
            return result.isFinite ? result : nil
        }
        guard let value = number(kAXValueAttribute), let maximum = number(kAXMaxValueAttribute),
              let minimum = number(kAXMinValueAttribute), maximum >= minimum else { return nil }
        let tolerance = max(0.5, (maximum - minimum) * 0.01)
        return value >= maximum - tolerance
    }
    func hasAccess() -> Bool { AXIsProcessTrusted() && CGPreflightPostEventAccess() }
    func pointerLocation() -> CGPoint? { CGEvent(source: nil)?.location }
    func movePointer(to point: CGPoint) -> Bool { CGWarpMouseCursorPosition(point) == .success }
    func focusRestoration() -> @MainActor () -> Void {
        let application = NSWorkspace.shared.frontmostApplication
        return { if let application, !application.isTerminated { application.activate(options: []) } }
    }
    func postWheel(_ delta: Int32, using receipt: NativeScrollCaptureReceipt, restoring: Bool) -> Bool {
        NativeScrollWheelDelivery().post(delta, using: receipt, restoring: restoring)
    }
}

/// The final synchronous boundary before public system routing. Posting returns
/// no acknowledgement. Pointer excursions between observations and target
/// changes after the final check remain OS routing races, not guaranteed away.
@MainActor
struct NativeScrollWheelDelivery {
    var hasAccess: () -> Bool = { CGPreflightPostEventAccess() }
    var pointerLocation: () -> CGPoint? = { CGEvent(source: nil)?.location }
    var isCancelled: () -> Bool = { Task.isCancelled }
    var dispatch: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }

    func post(_ delta: Int32, using receipt: NativeScrollCaptureReceipt, restoring: Bool) -> Bool {
        guard receipt.point.x.isFinite, receipt.point.y.isFinite, receipt.ownerPID > 0,
              let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                  wheel1: delta, wheel2: 0, wheel3: 0) else {
            receipt.rejectAuthority()
            return false
        }
        event.location = receipt.point
        let purpose: NativeScrollCapturePurpose = restoring ? .pageRestoration : .forwardScroll
        guard receipt.consume(while: {
            guard receipt.purpose == purpose, restoring ? delta > 0 : delta < 0,
                  hasAccess(), pointerLocation() == receipt.point else {
                receipt.rejectAuthority()
                return false
            }
            return restoring || !isCancelled()
        }) else { return false }
        // No suspension or another authority-producing operation may separate
        // receipt consumption from the associated public HID request.
        dispatch(event)
        return true
    }

}
