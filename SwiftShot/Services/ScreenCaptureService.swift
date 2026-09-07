import AppKit
import ScreenCaptureKit
import OSLog

/// Acquires every display before any selection UI is presented.
@MainActor
final class ScreenCaptureService: ScreenCaptureProviding {
    static let shared = ScreenCaptureService()
    private let logger = Logger(subsystem: "com.swiftshot.app", category: "Capture")

    func freeze(mode: CaptureMode = .region) async throws -> [FrozenScreen] {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }
        let started = ContinuousClock.now
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windowInfo = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let orderedIDs = windowInfo.compactMap { row -> UInt32? in
            guard (row[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return row[kCGWindowNumber as String] as? UInt32
        }
        let rank = Dictionary(orderedIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let windows = content.windows.filter {
            $0.isOnScreen && $0.windowLayer == 0 && $0.owningApplication?.processID != ownPID && $0.frame.width > 20 && $0.frame.height > 20
        }.sorted { rank[$0.windowID, default: Int.max] < rank[$1.windowID, default: Int.max] }

        var snapshots: [FrozenScreen] = []
        for screen in NSScreen.screens {
            try Task.checkCancellation()
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { $0.owningApplication?.processID == ownPID })
            let configuration = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            guard scale.isFinite, scale > 0 else { throw CaptureError.failed("Couldn't determine this display's resolution. Try again.") }
            configuration.width = Int((display.frame.width * scale).rounded())
            configuration.height = Int((display.frame.height * scale).rounded())
            configuration.captureResolution = .best
            configuration.showsCursor = false
            configuration.scalesToFit = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            var localWindows: [FrozenWindow] = []
            var covered: [CGRect] = []
            for window in windows {
                try Task.checkCancellation()
                let intersection = window.frame.intersection(display.frame)
                guard !intersection.isNull, intersection.width >= 2, intersection.height >= 2 else { continue }
                guard WindowVisibility.hasVisibleArea(intersection, behind: covered) else { continue }
                covered.append(intersection)
                var snapshot: CGImage?
                if mode == .window {
                    let windowFilter = SCContentFilter(desktopIndependentWindow: window)
                    let windowConfig = SCStreamConfiguration()
                    let windowScale = CGFloat(windowFilter.pointPixelScale)
                    guard windowScale.isFinite, windowScale > 0 else {
                        throw CaptureError.failed("Couldn’t determine this window’s resolution. Try again.")
                    }
                    windowConfig.width = Int((window.frame.width * windowScale).rounded())
                    windowConfig.height = Int((window.frame.height * windowScale).rounded())
                    guard windowConfig.width * windowConfig.height <= 64_000_000 else {
                        throw CaptureError.failed("A window is too large to freeze safely. Use region capture for this display.")
                    }
                    windowConfig.captureResolution = .best
                    windowConfig.showsCursor = false
                    windowConfig.ignoreShadowsSingleWindow = true
                    windowConfig.shouldBeOpaque = true
                    let windowImage = try await SCScreenshotManager.captureImage(contentFilter: windowFilter, configuration: windowConfig)
                    let sx = CGFloat(windowImage.width) / window.frame.width
                    let sy = CGFloat(windowImage.height) / window.frame.height
                    let crop = CGRect(x: (intersection.minX - window.frame.minX) * sx, y: (intersection.minY - window.frame.minY) * sy,
                                      width: intersection.width * sx, height: intersection.height * sy).integral
                    snapshot = windowImage.cropping(to: crop)
                    guard snapshot != nil else { throw CaptureError.failed("A window changed while freezing. Try capturing again.") }
                }
                localWindows.append(FrozenWindow(id: window.windowID, title: window.title ?? window.owningApplication?.applicationName ?? "Window",
                    frame: intersection.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY), snapshot: snapshot))
            }
            snapshots.append(FrozenScreen(id: display.displayID, frame: screen.frame, image: image, windows: localWindows))
        }
        guard !snapshots.isEmpty else { throw CaptureError.failed("No display is available. Reconnect your display and try again.") }
        let currentScreens = NSScreen.screens
        guard snapshots.count == currentScreens.count, snapshots.allSatisfy({ snapshot in
            currentScreens.contains { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == snapshot.id && screen.frame == snapshot.frame
            }
        }) else { throw CaptureError.failed("The display layout changed while capturing. Try again on the current display.") }
        logger.info("Frozen \(snapshots.count) display(s) in \(String(describing: started.duration(to: .now)), privacy: .public)")
        return snapshots
    }
}

enum WindowVisibility {
    /// Fully covered windows cannot be selected, so don't allocate snapshots for them.
    static func hasVisibleArea(_ rect: CGRect, behind covers: [CGRect]) -> Bool {
        var pieces = [rect]
        for cover in covers {
            pieces = pieces.flatMap { piece -> [CGRect] in
                let overlap = piece.intersection(cover)
                guard !overlap.isNull, !overlap.isEmpty else { return [piece] }
                return [
                    CGRect(x: piece.minX, y: piece.minY, width: piece.width, height: overlap.minY - piece.minY),
                    CGRect(x: piece.minX, y: overlap.maxY, width: piece.width, height: piece.maxY - overlap.maxY),
                    CGRect(x: piece.minX, y: overlap.minY, width: overlap.minX - piece.minX, height: overlap.height),
                    CGRect(x: overlap.maxX, y: overlap.minY, width: piece.maxX - overlap.maxX, height: overlap.height)
                ].filter { $0.width >= 1 && $0.height >= 1 }
            }
            if pieces.isEmpty { return false }
            // Preserve correctness if a highly fragmented desktop would make analysis expensive.
            if pieces.count > 512 { return true }
        }
        return !pieces.isEmpty
    }
}

enum CaptureError: LocalizedError {
    case cancelled
    case failed(String)
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .cancelled: "Capture was cancelled."
        case .failed(let message): message
        case .permissionDenied: "Allow SwiftShot in System Settings → Privacy & Security → Screen & System Audio Recording, then try again. You may need to reopen SwiftShot after granting access."
        }
    }
}
