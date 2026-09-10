import CoreGraphics
import Foundation

/// Binds the native input hit to public window metadata, independently of AX.
enum ScrollTargetWindowPolicy {
    struct Window: Sendable {
        let id: CGWindowID
        let ownerPID: pid_t
        let frame: CGRect
        let alpha: Double
        var isOnScreen: Bool = true
    }

    struct InputObservation {
        let windowNumber: Int
        let foregroundPID: pid_t?
    }

    /// Revalidates one previously bound window; never selects a replacement.
    /// Initial binding still uses the complete ambiguity check below.
    static func resolveBoundStable(point: CGPoint, ownerPID: pid_t, axWindowFrame: CGRect,
                                   windowID: CGWindowID, window: Window,
                                   readCurrentInput: () -> InputObservation) -> CGWindowID? {
        guard windowID != 0, window.id == windowID, window.isOnScreen else { return nil }
        return resolveStable(point: point, ownerPID: ownerPID, axWindowFrame: axWindowFrame,
            windows: [window], readCurrentInput: readCurrentInput)
    }

    static func resolveStable(point: CGPoint, ownerPID: pid_t, axWindowFrame: CGRect,
                              windows: [Window], readCurrentInput: () -> InputObservation) -> CGWindowID? {
        let input = readCurrentInput()
        guard input.foregroundPID == ownerPID else { return nil }
        guard let id = resolve(point: point, ownerPID: ownerPID, axWindowFrame: axWindowFrame,
            mouseHitWindowNumber: input.windowNumber, windows: windows) else { return nil }
        let finalInput = readCurrentInput()
        guard finalInput.windowNumber == Int(id), finalInput.foregroundPID == ownerPID else { return nil }
        return id
    }

    static func appKitPoint(fromQuartz point: CGPoint, primaryScreenFrame: CGRect) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite, finiteFrame(primaryScreenFrame) else { return nil }
        let converted = CGPoint(x: point.x, y: primaryScreenFrame.maxY - point.y)
        return converted.x.isFinite && converted.y.isFinite ? converted : nil
    }

    static func resolve(point: CGPoint, ownerPID: pid_t, axWindowFrame: CGRect,
                        mouseHitWindowNumber: Int, windows: [Window]) -> CGWindowID? {
        guard point.x.isFinite, point.y.isFinite, ownerPID > 0,
              finiteFrame(axWindowFrame), axWindowFrame.contains(point),
              let hitID = CGWindowID(exactly: mouseHitWindowNumber), hitID != 0 else { return nil }
        let hits = windows.filter { $0.id == hitID }
        guard hits.count == 1, let hit = hits.first,
              hit.ownerPID == ownerPID, finiteFrame(hit.frame), hit.frame == axWindowFrame,
              hit.alpha.isFinite, hit.alpha > 0, hit.alpha <= 1 else { return nil }
        // Public AX has no window-number attribute: coincident windows owned
        // by one process cannot be disambiguated by owner and frame alone.
        guard !windows.contains(where: {
            $0.id != hitID && $0.ownerPID == ownerPID && $0.frame == axWindowFrame
        }) else { return nil }
        return hitID
    }

    static func finiteFrame(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite && frame.origin.x.isFinite && frame.origin.y.isFinite &&
            frame.size.width.isFinite && frame.size.height.isFinite &&
            frame.size.width > 0 && frame.size.height > 0 && frame.maxX.isFinite && frame.maxY.isFinite
    }
}
