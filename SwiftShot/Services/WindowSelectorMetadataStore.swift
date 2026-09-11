import Foundation
import CoreGraphics

/// Metadata for one explicitly owned live selector. Native values stay on the
/// main actor; scalar identity/geometry is copied independently of those values.
/// An over-cap selector keeps its ownership/layout contract but no metadata refs,
/// so callers may use their existing fresh-query path without truncating its UI.
@MainActor
final class WindowSelectorMetadataStore<Window, Display> {
    struct WindowEntry {
        let id: UInt32
        let frame: CGRect
        let ownerPID: Int32
        let layer: Int
        let value: Window
    }

    struct DisplayEntry {
        let id: UInt32
        let frame: CGRect
        let value: Display
    }

    private let windowLimit: Int
    private let displayLimit: Int
    private var currentOwner: UUID?
    private var originalLayout: [CaptureDisplayLayout] = []
    private var windows: [UInt32: WindowEntry]?
    private var displays: [UInt32: DisplayEntry]?

    init(windowLimit: Int = 256, displayLimit: Int = 16) {
        self.windowLimit = max(1, min(256, windowLimit))
        self.displayLimit = max(1, min(16, displayLimit))
    }

    /// Callers supply a new capture-session UUID for each selector attempt.
    /// Clearing before the query prevents an older selector from being reused
    /// while its replacement is still loading metadata.
    func begin(owner: UUID, layout: [CaptureDisplayLayout]) {
        currentOwner = owner
        originalLayout = layout
        windows = nil
        displays = nil
    }

    /// Publication is conditional: an old awaited query cannot revive an
    /// invalidated selector or overwrite a newer owner's references.
    func publish(owner: UUID, windows: [WindowEntry], displays: [DisplayEntry]) throws {
        try requireOwner(owner: owner, layout: originalLayout)
        guard windows.count <= windowLimit, displays.count <= displayLimit else {
            self.windows = nil
            self.displays = nil
            return
        }

        var nextWindows: [UInt32: WindowEntry] = [:]
        var nextDisplays: [UInt32: DisplayEntry] = [:]
        for entry in windows {
            guard entry.id != 0, entry.ownerPID > 0,
                  CaptureAcquisitionPolicy.isSelectableWindowLayer(entry.layer),
                  Self.validFrame(entry.frame), nextWindows[entry.id] == nil else {
                throw CaptureError.failed("Window selector metadata is unavailable. Press Esc and start a new capture.")
            }
            nextWindows[entry.id] = entry
        }
        for entry in displays {
            guard entry.id != 0, Self.validFrame(entry.frame), nextDisplays[entry.id] == nil else {
                throw CaptureError.failed("Display selector metadata is unavailable. Press Esc and start a new capture.")
            }
            nextDisplays[entry.id] = entry
        }
        // Validate both collections before replacing any existing references.
        self.windows = nextWindows
        self.displays = nextDisplays
    }

    func requireOwner(owner: UUID, layout: [CaptureDisplayLayout]) throws {
        guard currentOwner == owner else {
            throw CaptureError.failed("This window selector expired. Press Esc and start a new capture.")
        }
        guard Self.validLayout(originalLayout), Self.validLayout(layout),
              CaptureAcquisitionPolicy.layoutMatches(originalLayout, layout) else {
            throw CaptureError.failed("The display layout changed. Press Esc and start a new capture on the current display.")
        }
    }

    /// nil means a valid selector has no reusable entry, never that its owner or
    /// display may be silently replaced. Failed lookups leave the snapshot intact
    /// so another unchanged target in this selector can still be chosen.
    func lookup(owner: UUID, windowID: UInt32, displayID: UInt32,
                layout: [CaptureDisplayLayout]) throws -> (window: WindowEntry, display: DisplayEntry)? {
        try requireOwner(owner: owner, layout: layout)
        guard originalLayout.contains(where: { $0.id == displayID }) else {
            throw CaptureError.failed("This display is not part of the window selector. Press Esc and start a new capture.")
        }
        guard let windows, let displays else { return nil }
        guard let display = displays[displayID] else {
            throw CaptureError.failed("This display is unavailable in the window selector. Press Esc and start a new capture.")
        }
        guard let window = windows[windowID] else { return nil }
        let intersection = window.frame.intersection(display.frame)
        guard !intersection.isNull, intersection.width >= 2, intersection.height >= 2 else {
            throw CaptureError.failed("This window is not on the selected display. Choose another window or start a new capture.")
        }
        return (window, display)
    }

    /// An operation may invalidate only its own selector. Explicit lifecycle
    /// invalidation (nil) also revokes publication by pending metadata queries.
    func invalidate(owner: UUID? = nil) {
        if let owner, owner != currentOwner { return }
        currentOwner = nil
        originalLayout = []
        windows = nil
        displays = nil
    }

    private static func validLayout(_ layout: [CaptureDisplayLayout]) -> Bool {
        !layout.isEmpty && Set(layout.map(\.id)).count == layout.count && layout.allSatisfy {
            $0.id != 0 && validFrame($0.frame) && $0.scale.isFinite && $0.scale > 0
        }
    }

    private static func validFrame(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite && frame.maxX.isFinite && frame.maxY.isFinite &&
            frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0
    }
}
