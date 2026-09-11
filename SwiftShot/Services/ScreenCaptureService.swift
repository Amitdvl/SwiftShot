import AppKit
import ScreenCaptureKit
import OSLog
import CoreVideo

/// Region/OCR freeze display pixels; Window presents a live metadata-only selector.
@MainActor
final class ScreenCaptureService: ScreenCaptureProviding {
    static let shared = ScreenCaptureService()
    private let logger = Logger(subsystem: "com.swiftshot.app", category: "Capture")
    private let memoryBudget = CaptureMemoryBudget()
    private let displayCache = CaptureDisplayMetadataCache<SCDisplay, SCRunningApplication>(
        ownProcessID: ProcessInfo.processInfo.processIdentifier, processID: { $0.processID })
    private var liveSurfaceImage: CGImage?
    // One bounded selector snapshot; never retain SCShareableContent, filters,
    // screenshots, or a continuously running capture stream here.
    private let windowMetadata = WindowSelectorMetadataStore<SCWindow, SCDisplay>()

    func freeze(mode: CaptureMode = .region) async throws -> [FrozenScreen] {
        try await freeze(mode: mode, windowSelectorID: nil)
    }

    func freeze(mode: CaptureMode, selectorID: UUID) async throws -> [FrozenScreen] {
        try await freeze(mode: mode, windowSelectorID: mode == .window ? selectorID : nil)
    }

    private func freeze(mode: CaptureMode, windowSelectorID: UUID?) async throws -> [FrozenScreen] {
        let traceRun = CaptureLatencyTrace.shared.activeRunID
        CaptureLatencyTrace.shared.mark(.permissionCheckStarted, for: traceRun)
        try requirePermission()
        CaptureLatencyTrace.shared.mark(.permissionCheckFinished, for: traceRun)
        let started = ContinuousClock.now
        let layout = currentLayout()
        let targets = try CaptureAcquisitionPolicy.targets(mode: mode, pointer: NSEvent.mouseLocation, displays: layout)
        if let windowSelectorID { windowMetadata.begin(owner: windowSelectorID, layout: layout) }
        do {
            if mode == .window {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try Task.checkCancellation()
                if let windowSelectorID { try windowMetadata.requireOwner(owner: windowSelectorID, layout: currentLayout()) }
                let windows = try await selectableWindows(in: content)
                try validateLayout(layout)
                if let windowSelectorID { try windowMetadata.requireOwner(owner: windowSelectorID, layout: currentLayout()) }
                let placeholder = try liveSurfaceBacking()
                let surfaces = try targets.map { target in
                    guard let display = content.displays.first(where: { $0.displayID == target.id }) else {
                        throw CaptureError.failed("A display disconnected. Try capturing again.")
                    }
                    return FrozenScreen(id: target.id, frame: target.frame, image: placeholder,
                        windows: localWindows(windows, display: display), isLive: true)
                }
                if let windowSelectorID {
                    try windowMetadata.publish(owner: windowSelectorID,
                        windows: windows.compactMap { window in
                            guard let pid = window.owningApplication?.processID else { return nil }
                            return .init(id: window.windowID, frame: window.frame, ownerPID: pid,
                                         layer: window.windowLayer, value: window)
                        },
                        displays: content.displays.map { .init(id: $0.displayID, frame: $0.frame, value: $0) })
                }
                logger.info("Live selector ready for \(surfaces.count) display(s) in \(String(describing: started.duration(to: .now)), privacy: .public); no pixels acquired")
                return surfaces
            }

            // macOS 14 requires display/application metadata to build the display
            // filter. Reuse it while layout is unchanged; never cache pixels.
            // No CG window enumeration, content.windows traversal, or currentProcess
            // query occurs on Region/OCR/Fullscreen paths.
            let metadata = try await displayMetadata(for: layout, includeOwnApplication: true)
            let jobs = try targets.map { target -> DisplayCaptureJob in
                guard let display = metadata.displays.first(where: { $0.displayID == target.id }) else {
                    throw CaptureError.failed("A display disconnected. Try capturing again.")
                }
                let filter = SCContentFilter(display: display,
                    excludingApplications: metadata.excludedApplications, exceptingWindows: [])
                let size = try CaptureAcquisitionPolicy.dimensions(points: display.frame.size, scale: CGFloat(filter.pointPixelScale))
                return DisplayCaptureJob(target: target, filter: filter, size: size)
            }
            // Bound the aggregate, not just each image: two 8K displays may be
            // individually legal but unsafe to retain together. The budget also
            // accounts for overlapping cancelled requests still awaiting SCK.
            let total = try jobs.reduce(0) { sum, job in
                let addition = sum.addingReportingOverflow(job.size.reservedBytes)
                guard !addition.overflow else { throw CaptureError.failed("The display set is too large to capture safely.") }
                return addition.partialValue
            }
            try memoryBudget.reserve(total)
            defer { memoryBudget.release(total) }
            let snapshots = try await CaptureAcquisitionBatch.run(jobs, maximumConcurrent: 2) { job in
                let configuration = Self.configuration(size: job.size, window: false)
                let image = try await SCScreenshotManager.captureImage(contentFilter: job.filter, configuration: configuration)
                try Self.validate(image: image, size: job.size)
                return FrozenScreen(id: job.target.id, frame: job.target.frame, image: image, windows: [])
            }
            try validateLayout(layout)
            logger.info("Frozen \(snapshots.count) display(s) in \(String(describing: started.duration(to: .now)), privacy: .public)")
            return snapshots
        } catch {
            displayCache.invalidate()
            if let windowSelectorID { windowMetadata.invalidate(owner: windowSelectorID) }
            throw error
        }
    }

    /// Acquires exactly the clicked window, at click time. The returned image and
    /// placement retain the established display-clipped window semantics.
    func captureWindow(id: UInt32, onDisplayID displayID: UInt32) async throws -> FrozenWindow {
        try await captureWindow(id: id, onDisplayID: displayID, traceRunID: nil)
    }

    /// Retain the originating optional run across every suspension. An unarmed or
    /// stale operation must never attach its timing to a subsequently armed run.
    func captureWindow(id: UInt32, onDisplayID displayID: UInt32, traceRunID: UUID?) async throws -> FrozenWindow {
        try await captureWindow(id: id, onDisplayID: displayID, windowSelectorID: nil, traceRunID: traceRunID)
    }

    func captureWindow(id: UInt32, onDisplayID displayID: UInt32, selectorID: UUID, traceRunID: UUID?) async throws -> FrozenWindow {
        try await captureWindow(id: id, onDisplayID: displayID, windowSelectorID: selectorID, traceRunID: traceRunID)
    }

    private func captureWindow(id: UInt32, onDisplayID displayID: UInt32, windowSelectorID: UUID?, traceRunID: UUID?) async throws -> FrozenWindow {
        CaptureLatencyTrace.shared.mark(.windowCaptureStarted, for: traceRunID)
        try requirePermission()
        let layout = currentLayout()
        guard layout.contains(where: { $0.id == displayID }) else {
            throw CaptureError.failed("This display disconnected. Try capturing again.")
        }
        do {
            CaptureLatencyTrace.shared.mark(.windowMetadataStarted, for: traceRunID)
            let cached = try windowSelectorID.flatMap {
                try windowMetadata.lookup(owner: $0, windowID: id, displayID: displayID, layout: layout)
            }
            let window: SCWindow
            let display: SCDisplay
            let originalIdentity: WindowIdentity
            if let cached {
                window = cached.window.value
                display = cached.display.value
                originalIdentity = WindowIdentity(frame: cached.window.frame, ownerPID: cached.window.ownerPID, layer: cached.window.layer)
                guard display.frame == cached.display.frame else {
                    throw CaptureError.failed("This display changed. Select the window again.")
                }
            } else {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try Task.checkCancellation()
                if let windowSelectorID { try windowMetadata.requireOwner(owner: windowSelectorID, layout: currentLayout()) }
                var selected = content.windows.first(where: { $0.windowID == id })
                if selected == nil, #available(macOS 14.4, *) {
                    selected = try await SCShareableContent.currentProcess.windows.first(where: { $0.windowID == id })
                }
                try Task.checkCancellation()
                if let windowSelectorID { try windowMetadata.requireOwner(owner: windowSelectorID, layout: currentLayout()) }
                guard let selected, let selectedDisplay = content.displays.first(where: { $0.displayID == displayID }),
                      let pid = selected.owningApplication?.processID else {
                    throw CaptureError.failed("This window closed or became unavailable. Select it again.")
                }
                window = selected
                display = selectedDisplay
                originalIdentity = WindowIdentity(frame: selected.frame, ownerPID: pid, layer: selected.windowLayer)
            }
            CaptureLatencyTrace.shared.mark(.windowMetadataResolved, for: traceRunID)
            guard window.isOnScreen, CaptureAcquisitionPolicy.isSelectableWindowLayer(window.windowLayer),
                  let identity = currentWindowIdentity(id: id),
                  identity == originalIdentity,
                  identity.frame == window.frame,
                  identity.ownerPID == window.owningApplication?.processID else {
                throw CaptureError.failed("This window closed, moved, or became unavailable. Select it again.")
            }
            let intersection = window.frame.intersection(display.frame)
            guard !intersection.isNull, intersection.width >= 2, intersection.height >= 2 else {
                throw CaptureError.failed("This window moved off the selected display. Select it again.")
            }
            try validateLayout(layout)
            if let windowSelectorID { try windowMetadata.requireOwner(owner: windowSelectorID, layout: currentLayout()) }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let size = try CaptureAcquisitionPolicy.dimensions(points: window.frame.size, scale: CGFloat(filter.pointPixelScale))
            try memoryBudget.reserve(size.reservedBytes)
            defer { memoryBudget.release(size.reservedBytes) }
            CaptureLatencyTrace.shared.mark(.windowImageRequestStarted, for: traceRunID)
            let image = try await WindowImageCallbackBridge.capture(traceRunID: traceRunID) { callback in
                SCScreenshotManager.captureImage(contentFilter: filter,
                    configuration: Self.configuration(size: size, window: true), completionHandler: callback)
            }
            CaptureLatencyTrace.shared.mark(.windowImageRequestReturned, for: traceRunID)
            try Task.checkCancellation()
            try Self.validate(image: image, size: size)
            try validateLayout(layout)
            if let windowSelectorID { try windowMetadata.requireOwner(owner: windowSelectorID, layout: currentLayout()) }
            guard currentWindowIdentity(id: id) == identity else {
                throw CaptureError.failed("This window changed while capturing. Select it again.")
            }
            let sx = CGFloat(image.width) / window.frame.width
            let sy = CGFloat(image.height) / window.frame.height
            let crop = CGRect(x: (intersection.minX - window.frame.minX) * sx,
                              y: (intersection.minY - window.frame.minY) * sy,
                              width: intersection.width * sx, height: intersection.height * sy).integral
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let snapshot = image.cropping(to: crop) else {
                throw CaptureError.failed("This window changed while capturing. Select it again.")
            }
            let result = FrozenWindow(id: id, title: window.title ?? window.owningApplication?.applicationName ?? "Window",
                frame: intersection.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY), snapshot: snapshot,
                ownerPID: window.owningApplication?.processID)
            CaptureLatencyTrace.shared.mark(.windowResultPrepared, for: traceRunID)
            return result
        } catch {
            displayCache.invalidate()
            // A failed target must not disable every other window in the live
            // selector. Retain its original advisory metadata; each retry still
            // checks current identity/layout. Navigation/lifecycle revokes it.
            throw error
        }
    }

    /// Session coordinator calls this for sleep/wake, memory pressure, and capture
    /// resets; layout changes and SCK errors also invalidate automatically.
    func invalidateDisplayCache() {
        displayCache.invalidate()
        invalidateWindowMetadata()
    }

    func invalidateWindowMetadata() {
        windowMetadata.invalidate()
    }

    /// Native-resolution acquisition for scrolling sessions. Rect is local display
    /// points with a top-left origin; unlike a full display crop this requests only
    /// the selected source rectangle from ScreenCaptureKit.
    func captureRegion(displayID: UInt32, rect: CGRect) async throws -> CGImage {
        try requirePermission()
        let layout = currentLayout()
        guard let target = layout.first(where: { $0.id == displayID }),
              rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.width >= 2, rect.height >= 2,
              CGRect(origin: .zero, size: target.frame.size).contains(rect) else {
            throw CaptureError.failed("The scrolling region is outside the current display. Select it again.")
        }
        do {
            let metadata = try await displayMetadata(for: layout, includeOwnApplication: true)
            guard let display = metadata.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError.failed("The scrolling display disconnected. Select it again.")
            }
            let filter = SCContentFilter(display: display,
                excludingApplications: metadata.excludedApplications, exceptingWindows: [])
            let size = try CaptureAcquisitionPolicy.dimensions(points: rect.size, scale: CGFloat(filter.pointPixelScale))
            try memoryBudget.reserve(size.reservedBytes)
            defer { memoryBudget.release(size.reservedBytes) }
            let configuration = Self.configuration(size: size, window: false)
            configuration.sourceRect = rect
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            try Self.validate(image: image, size: size)
            try validateLayout(layout)
            return image
        } catch {
            displayCache.invalidate()
            throw error
        }
    }

    private func displayMetadata(for layout: [CaptureDisplayLayout], includeOwnApplication: Bool) async throws -> CaptureDisplayMetadataCache<SCDisplay, SCRunningApplication>.Resolved {
        do {
            let metadata = try await displayCache.metadata(for: layout, includeOwnApplication: includeOwnApplication) { onScreenOnly in
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: onScreenOnly)
                try self.validateLayout(layout)
                // Display metadata is enough for the normal capture paths. The
                // caller chooses whether this filter includes SwiftShot's own UI;
                // never inspect content.windows here.
                return (content.displays, content.applications)
            }
            logger.debug("Display capture metadata resolved; own app included: \(includeOwnApplication, privacy: .public)")
            return metadata
        } catch {
            displayCache.invalidate()
            logger.error("Display capture metadata failed; own app included: \(includeOwnApplication, privacy: .public)")
            throw error
        }
    }

    static func configuration(size: CapturePixelDimensions, window: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.scalesToFit = false
        // Capture the composed surface with a stable backing. Without this,
        // translucent SwiftUI/AppKit windows (especially menus and popovers)
        // can reveal the window beneath them and look washed out in the
        // resulting region or window image.
        configuration.shouldBeOpaque = true
        if window {
            configuration.ignoreShadowsSingleWindow = true
        }
        return configuration
    }

    private static func validate(image: CGImage, size: CapturePixelDimensions) throws {
        let actual = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard image.width == size.width, image.height == size.height, !actual.overflow,
              actual.partialValue <= size.reservedBytes / 2 else {
            throw CaptureError.failed("The capture resolution changed or exceeded the reserved memory. Try again.")
        }
    }

    private func requirePermission() throws {
        try Task.checkCancellation()
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }
        try Task.checkCancellation()
    }

    private func currentLayout() -> [CaptureDisplayLayout] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CaptureDisplayLayout(id: number.uint32Value, frame: screen.frame, scale: screen.backingScaleFactor)
        }
    }

    private func validateLayout(_ original: [CaptureDisplayLayout]) throws {
        try Task.checkCancellation()
        guard CaptureAcquisitionPolicy.layoutMatches(original, currentLayout()) else {
            throw CaptureError.failed("The display layout changed while capturing. Try again on the current display.")
        }
    }

    private func liveSurfaceBacking() throws -> CGImage {
        if let liveSurfaceImage { return liveSurfaceImage }
        // This transparent backing satisfies FrozenScreen's image ownership
        // contract without sampling the desktop. isLive consumers must not use it
        // for crops or scale calculations: the actual desktop remains visible.
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.failed("Could not create the window selector.")
        }
        context.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let image = context.makeImage() else { throw CaptureError.failed("Could not create the window selector.") }
        liveSurfaceImage = image
        return image
    }

    private func selectableWindows(in content: SCShareableContent) async throws -> [SCWindow] {
        // The normal content query can omit the caller's windows. Ask ScreenCaptureKit
        // for them explicitly so SwiftShot windows can participate in Window capture.
        let ownWindows: [SCWindow]
        if #available(macOS 14.4, *) {
            ownWindows = try await SCShareableContent.currentProcess.windows
        } else {
            let ownPID = ProcessInfo.processInfo.processIdentifier
            ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
        }
        try Task.checkCancellation()
        var seenWindowIDs = Set<UInt32>()
        let availableWindows = (content.windows + ownWindows).filter { seenWindowIDs.insert($0.windowID).inserted }
        let windowInfo = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let orderedIDs = windowInfo.compactMap { row -> UInt32? in
            guard let layer = row[kCGWindowLayer as String] as? Int,
                  CaptureAcquisitionPolicy.isSelectableWindowLayer(layer) else { return nil }
            return row[kCGWindowNumber as String] as? UInt32
        }
        let rank = Dictionary(orderedIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return availableWindows.filter {
            $0.isOnScreen && CaptureAcquisitionPolicy.isSelectableWindowOwner($0.owningApplication?.applicationName) &&
                CaptureAcquisitionPolicy.isSelectableWindowLayer($0.windowLayer) &&
                $0.frame.width > 20 && $0.frame.height > 20
        }.sorted { rank[$0.windowID, default: Int.max] < rank[$1.windowID, default: Int.max] }

    }

    private func localWindows(_ windows: [SCWindow], display: SCDisplay) -> [FrozenWindow] {
        var result: [FrozenWindow] = []
        var covered: [CGRect] = []
        for window in windows {
            let intersection = window.frame.intersection(display.frame)
            guard !intersection.isNull, intersection.width >= 2, intersection.height >= 2,
                  WindowVisibility.hasVisibleArea(intersection, behind: covered) else { continue }
            covered.append(intersection)
            result.append(FrozenWindow(id: window.windowID, title: window.title ?? window.owningApplication?.applicationName ?? "Window",
                frame: intersection.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY),
                ownerPID: window.owningApplication?.processID))
        }
        return result
    }

    private struct WindowIdentity: Equatable {
        let frame: CGRect
        let ownerPID: pid_t
        let layer: Int
    }

    private func currentWindowIdentity(id: UInt32) -> WindowIdentity? {
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let row = rows.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == id }),
              (row[kCGWindowIsOnscreen as String] as? Bool) == true,
              let layer = row[kCGWindowLayer as String] as? Int,
              CaptureAcquisitionPolicy.isSelectableWindowLayer(layer),
              let bounds = row[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              let ownerPID = row[kCGWindowOwnerPID as String] as? Int32 else { return nil }
        return WindowIdentity(frame: frame, ownerPID: ownerPID, layer: layer)
    }
}

/// Main-actor ownership keeps mutable SCK filter objects confined while the
/// screenshot operations themselves can suspend and finish concurrently.
@MainActor
private final class DisplayCaptureJob {
    let target: CaptureDisplayLayout
    let filter: SCContentFilter
    let size: CapturePixelDimensions
    init(target: CaptureDisplayLayout, filter: SCContentFilter, size: CapturePixelDimensions) {
        self.target = target
        self.filter = filter
        self.size = size
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
