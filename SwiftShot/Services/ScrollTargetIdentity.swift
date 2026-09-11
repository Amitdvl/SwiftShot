import AppKit
import ApplicationServices
import OSLog

/// A bounded AX lookup plus the native input window establishes event
/// ownership. Unsupported accessibility hierarchies safely remain manual-only.
@MainActor
struct ScrollTargetIdentity {
    private static let logger = Logger(subsystem: "com.swiftshot.app", category: "ScrollTarget")
    let pid: pid_t
    let windowID: CGWindowID
    let windowFrame: CGRect
    let scrollFrame: CGRect
    let window: AXUIElement
    let scrollArea: AXUIElement

    func matches(_ other: ScrollTargetIdentity) -> Bool {
        pid == other.pid && windowID == other.windowID && windowFrame == other.windowFrame &&
            scrollFrame == other.scrollFrame && CFEqual(window, other.window) && CFEqual(scrollArea, other.scrollArea)
    }

    static func isScrollSurfaceRole(_ role: String?, hasVerticalScrollBar: Bool) -> Bool {
        role == kAXScrollAreaRole || role == "AXWebArea" || hasVerticalScrollBar
    }

    /// The only production resolution path consumes already prepared scalar
    /// metadata. AX and native input remain synchronous on the main actor, with
    /// the same deadline that began before metadata left that actor.
    static func resolve(at point: CGPoint, using snapshot: ScrollTargetMetadataSnapshot,
                        boundTo expected: ScrollTargetIdentity? = nil) -> ScrollTargetIdentity? {
        var stage = "point"
        var succeeded = false
        let started = snapshot.deadline.advanced(by: .milliseconds(-200))
        let axStarted = ContinuousClock.now
        func milliseconds(since instant: ContinuousClock.Instant) -> Double {
            let elapsed = instant.duration(to: ContinuousClock.now).components
            return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        }
        var axMilliseconds = 0.0
        let quartzMilliseconds = milliseconds(since: started)
        var inputRead = 0
        defer {
            if !succeeded { logger.error("resolve_failed stage=\(stage, privacy: .public) elapsed_ms=\(milliseconds(since: started), privacy: .public) ax_ms=\(axMilliseconds, privacy: .public) quartz_ms=\(quartzMilliseconds, privacy: .public) input_read=\(inputRead, privacy: .public)") }
        }
        guard point.x.isFinite, point.y.isFinite,
              Float(point.x).isFinite, Float(point.y).isFinite else { return nil }
        let deadline = snapshot.deadline
        guard ContinuousClock.now < deadline else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var hit: AXUIElement?
        stage = "ax_hit"
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        var pid: pid_t = 0
        stage = "ax_hit_owner"
        guard AXUIElementGetPid(hit, &pid) == .success, pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        stage = "ax_hit_foreground"
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }

        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            guard ContinuousClock.now < deadline else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        func element(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        func frame(_ item: AXUIElement) -> CGRect? {
            guard let position = attribute(item, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
                  let size = attribute(item, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var origin = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
                  AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
                  dimensions.width > 0, dimensions.height > 0 else { return nil }
            let result = CGRect(origin: origin, size: dimensions)
            return ScrollTargetWindowPolicy.finiteFrame(result) ? result : nil
        }
        stage = "ax_hierarchy"
        var candidate: AXUIElement? = hit
        var scrollArea: AXUIElement?
        var window = element(attribute(hit, kAXWindowAttribute))
        for _ in 0..<32 {
            guard let current = candidate, ContinuousClock.now < deadline else { break }
            let role = attribute(current, kAXRoleAttribute) as? String
            // Chromium exposes the document under the pointer as AXWebArea,
            // not AXScrollArea. It is still a stable, window-owned native
            // input surface; its scrollbar is optional and is queried later
            // only as end-of-content evidence.
            if scrollArea == nil && Self.isScrollSurfaceRole(role,
                hasVerticalScrollBar: element(attribute(current, kAXVerticalScrollBarAttribute)) != nil) {
                scrollArea = current
            }
            if window == nil && role == kAXWindowRole { window = current }
            if scrollArea != nil && window != nil { break }
            candidate = element(attribute(current, kAXParentAttribute))
        }
        guard let window, let scrollArea else { return nil }
        var windowPID: pid_t = 0
        var scrollPID: pid_t = 0
        stage = "ax_ownership_geometry"
        guard AXUIElementGetPid(window, &windowPID) == .success, windowPID == pid,
              AXUIElementGetPid(scrollArea, &scrollPID) == .success, scrollPID == pid,
              let scrollWindow = element(attribute(scrollArea, kAXWindowAttribute)), CFEqual(scrollWindow, window),
              let axWindowFrame = frame(window), let scrollFrame = frame(scrollArea),
              axWindowFrame.contains(point), scrollFrame.contains(point), ContinuousClock.now < deadline else { return nil }
        if let expected {
            stage = "bound_accessibility"
            let accessibility = ScrollTargetIdentity(pid: pid, windowID: expected.windowID,
                windowFrame: axWindowFrame, scrollFrame: scrollFrame, window: window, scrollArea: scrollArea)
            guard expected.matches(accessibility) else { return nil }
        }
        axMilliseconds = milliseconds(since: axStarted)
        let windows = snapshot.windows
        stage = "screen_conversion"
        guard let primaryFrame = NSScreen.screens.first?.frame,
              let nativePoint = ScrollTargetWindowPolicy.appKitPoint(fromQuartz: point, primaryScreenFrame: primaryFrame) else { return nil }
        stage = "native_input_window"
        let readCurrentInput = {
                inputRead += 1
                guard ContinuousClock.now < deadline else {
                    stage = "native_input_deadline"
                    return ScrollTargetWindowPolicy.InputObservation(windowNumber: 0, foregroundPID: nil)
                }
                guard NSScreen.screens.first?.frame == primaryFrame else {
                    stage = "native_input_display"
                    return ScrollTargetWindowPolicy.InputObservation(windowNumber: 0, foregroundPID: nil)
                }
                return ScrollTargetWindowPolicy.InputObservation(windowNumber: NSWindow.windowNumber(at: nativePoint, belowWindowWithWindowNumber: 0),
                    foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
            }
        let resolvedID: CGWindowID?
        if let expected {
            guard windows.count == 1, let metadata = windows.first else { return nil }
            resolvedID = ScrollTargetWindowPolicy.resolveBoundStable(point: point, ownerPID: pid,
                axWindowFrame: axWindowFrame, windowID: expected.windowID, window: metadata,
                readCurrentInput: readCurrentInput)
        } else {
            resolvedID = ScrollTargetWindowPolicy.resolveStable(point: point, ownerPID: pid,
                axWindowFrame: axWindowFrame, windows: windows, readCurrentInput: readCurrentInput)
        }
        guard let id = resolvedID else { return nil }
        stage = "final_deadline"
        guard ContinuousClock.now < deadline else { return nil }
        succeeded = true
        return ScrollTargetIdentity(pid: pid, windowID: id, windowFrame: axWindowFrame, scrollFrame: scrollFrame,
            window: window, scrollArea: scrollArea)
    }
}

/// Public per-ID metadata query. CFArray uses raw CGWindowID values with no
/// callbacks, as required by CGWindowListCreateDescriptionFromArray—not boxed
/// NSNumber pointers. Returned data is validated before it authorizes anything.
enum ScrollTargetWindowMetadata {
    private static let queue = DispatchQueue(label: "com.swiftshot.scroll-target-metadata", qos: .userInitiated)

    /// Only scalar IDs enter this serial queue; only parsed Sendable values leave.
    /// A cancelled caller still awaits the uncancellable CF request and rejects
    /// its late result at the owning lifecycle boundary.
    static func readAsync(windowID: CGWindowID?) async -> [ScrollTargetWindowPolicy.Window]? {
        await withCheckedContinuation { continuation in
            queue.async {
                let windows: [ScrollTargetWindowPolicy.Window]? = autoreleasepool {
                    if let windowID {
                        guard let window = readBound(windowID: windowID) else { return nil }
                        return [window]
                    }
                    guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                        kCGNullWindowID) as? [[String: Any]] else { return nil }
                    // Preserve the complete initial ambiguity evidence and the
                    // existing initial parser contract; never preselect an ID.
                    return rows.compactMap { row in
                        guard let bounds = row[kCGWindowBounds as String] as? [String: Any],
                              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
                        return .init(id: (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0,
                            ownerPID: (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0,
                            frame: frame, alpha: (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? .nan)
                    }
                }
                continuation.resume(returning: windows)
            }
        }
    }

    static func readBound(windowID: CGWindowID) -> ScrollTargetWindowPolicy.Window? {
        guard windowID != 0 else { return nil }
        var value = UnsafeRawPointer(bitPattern: Int(windowID))
        guard let identifiers = CFArrayCreate(kCFAllocatorDefault, &value, 1, nil),
              let rows = CGWindowListCreateDescriptionFromArray(identifiers) as? [[String: Any]] else { return nil }
        return parseBound(rows, windowID: windowID)
    }

    static func parseBound(_ rows: [[String: Any]], windowID: CGWindowID) -> ScrollTargetWindowPolicy.Window? {
        guard windowID != 0, rows.count == 1, let row = rows.first,
              let number = row[kCGWindowNumber as String] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let id = CGWindowID(exactly: number.doubleValue), id == windowID,
              let owner = row[kCGWindowOwnerPID as String] as? NSNumber,
              CFGetTypeID(owner) != CFBooleanGetTypeID(),
              let pid = pid_t(exactly: owner.doubleValue), pid > 0,
              let onScreen = row[kCGWindowIsOnscreen as String] as? NSNumber,
              CFGetTypeID(onScreen) == CFBooleanGetTypeID(), onScreen.boolValue,
              let alpha = row[kCGWindowAlpha as String] as? NSNumber,
              CFGetTypeID(alpha) != CFBooleanGetTypeID(), alpha.doubleValue.isFinite,
              alpha.doubleValue > 0, alpha.doubleValue <= 1,
              let dictionary = row[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
              ScrollTargetWindowPolicy.finiteFrame(frame) else { return nil }
        return .init(id: id, ownerPID: pid, frame: frame, alpha: alpha.doubleValue, isOnScreen: true)
    }
}

/// A single preparation's value snapshot and original monotonic deadline.
/// No accessibility objects or mutable Core Foundation dictionaries cross queues.
struct ScrollTargetMetadataSnapshot: Sendable {
    let windows: [ScrollTargetWindowPolicy.Window]
    let deadline: ContinuousClock.Instant
}

@MainActor
struct ScrollTargetMetadataPreparation {
    let now: @MainActor () -> ContinuousClock.Instant
    let read: @MainActor (CGWindowID?) async -> [ScrollTargetWindowPolicy.Window]?

    func prepare(boundTo expected: ScrollTargetIdentity?) async -> ScrollTargetMetadataSnapshot? {
        // Start before calling the asynchronous provider: queueing and main-actor
        // resumption are part of the same evidence budget as the native request.
        let deadline = now().advanced(by: .milliseconds(200))
        guard let windows = await read(expected?.windowID), now() < deadline,
              !windows.isEmpty else { return nil }
        if let expected {
            guard expected.windowID != 0, expected.pid > 0,
                  ScrollTargetWindowPolicy.finiteFrame(expected.windowFrame),
                  windows.count == 1, let window = windows.first,
                  window.id == expected.windowID, window.ownerPID == expected.pid,
                  window.isOnScreen, ScrollTargetWindowPolicy.finiteFrame(window.frame),
                  window.frame == expected.windowFrame,
                  window.alpha.isFinite, window.alpha > 0, window.alpha <= 1 else { return nil }
        }
        // Initial binding keeps the complete snapshot; only the real native-hit
        // policy may select a row and refuse coincident same-owner ambiguity.
        guard now() < deadline else { return nil }
        return ScrollTargetMetadataSnapshot(windows: windows, deadline: deadline)
    }
}

/// Pins the native recipient around the first asynchronous metadata boundary.
/// The full AX/native resolver remains the authority for the completed binding.
@MainActor
struct ScrollTargetInitialBindingPreparation {
    let metadata: ScrollTargetMetadataPreparation
    let readInput: @MainActor () -> ScrollTargetWindowPolicy.InputObservation
    let resolve: @MainActor (ScrollTargetMetadataSnapshot) -> ScrollTargetIdentity?

    func prepare() async -> ScrollTargetIdentity? {
        let original = readInput()
        guard let originalID = CGWindowID(exactly: original.windowNumber), originalID != 0,
              let originalPID = original.foregroundPID, originalPID > 0 else { return nil }
        func recipientIsUnchanged() -> Bool {
            let input = readInput()
            return input.windowNumber == Int(originalID) && input.foregroundPID == originalPID
        }
        guard let snapshot = await metadata.prepare(boundTo: nil),
              metadata.now() < snapshot.deadline, recipientIsUnchanged(),
              metadata.now() < snapshot.deadline,
              let identity = resolve(snapshot), identity.windowID == originalID, identity.pid == originalPID,
              metadata.now() < snapshot.deadline, recipientIsUnchanged(),
              metadata.now() < snapshot.deadline else { return nil }
        return identity
    }
}
