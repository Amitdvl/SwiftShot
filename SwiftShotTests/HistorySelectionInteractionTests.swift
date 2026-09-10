import AppKit
import SwiftUI
import XCTest
@testable import SwiftShot

/// Characterizes our row gesture boundary, not a simulated selection policy.
/// Every selection change below must come from mouse events through the real List.
@MainActor
final class HistorySelectionInteractionTests: XCTestCase {
    func testSingleClickOnRowTitleSelectsWithoutOpening() async throws {
        let fixture = try await HistorySelectionInteractionFixture()
        defer { fixture.close() }

        try await fixture.clickTitle(fixture.firstTitle)

        XCTAssertEqual(fixture.model.selection, [fixture.firstID], "The double-click gesture must not swallow ordinary title clicks")
        XCTAssertEqual(fixture.model.selectedEntries.map(\.id), [fixture.firstID])
        XCTAssertTrue(fixture.actions.opened.isEmpty, "Selecting a capture must not open the editor")
    }

    func testSingleClickOnRowThumbnailSelectsWithoutOpening() async throws {
        let fixture = try await HistorySelectionInteractionFixture()
        defer { fixture.close() }

        let point = try fixture.thumbnailPoint(forTitle: fixture.firstTitle)
        try await fixture.click(point)

        XCTAssertEqual(fixture.model.selection, [fixture.firstID], "Thumbnail content must have the same selection behavior as the row margin")
        XCTAssertTrue(fixture.actions.opened.isEmpty)
    }

    func testCommandClickTogglesContentSelectionAndOrdinaryClickReplacesIt() async throws {
        let fixture = try await HistorySelectionInteractionFixture()
        defer { fixture.close() }

        try await fixture.clickTitle(fixture.firstTitle)
        XCTAssertEqual(fixture.model.selection, [fixture.firstID])
        try await fixture.clickTitle(fixture.secondTitle, modifiers: .command)
        XCTAssertEqual(fixture.model.selection, [fixture.firstID, fixture.secondID], "Command-click must add, not replace, the selected row")
        try await fixture.clickTitle(fixture.firstTitle, modifiers: .command)
        XCTAssertEqual(fixture.model.selection, [fixture.secondID], "Command-click on a selected row must remove it")
        try await fixture.clickTitle(fixture.firstTitle, modifiers: .command)
        XCTAssertEqual(fixture.model.selection, [fixture.firstID, fixture.secondID])
        try await fixture.clickTitle(fixture.firstTitle)
        XCTAssertEqual(fixture.model.selection, [fixture.firstID], "An ordinary content click must replace the multi-selection")
        XCTAssertTrue(fixture.actions.opened.isEmpty, "Modifier selection must never invoke Open")
    }

    func testDoubleClickOpensClickedContentExactlyOnce() async throws {
        let fixture = try await HistorySelectionInteractionFixture()
        defer { fixture.close() }

        try await fixture.clickTitle(fixture.firstTitle)
        XCTAssertTrue(fixture.actions.opened.isEmpty)
        try await fixture.clickTitle(fixture.secondTitle, count: 2)

        XCTAssertEqual(fixture.model.selection, [fixture.secondID])
        XCTAssertEqual(fixture.actions.opened, [fixture.secondID], "Double-click must open the clicked row exactly once, not the previous selection")
    }

    func testContextMenuOnEachMultiSelectedRowOpensThatClickedRecord() async throws {
        let fixture = try await HistorySelectionInteractionFixture()
        defer { fixture.close() }

        try await fixture.clickTitle(fixture.firstTitle)
        try await fixture.clickTitle(fixture.secondTitle, modifiers: .command)
        // Both attempts use the same two IDs. Picking an arbitrary selection.first
        // cannot satisfy the expected first-then-second sequence below.
        for title in [fixture.firstTitle, fixture.secondTitle] {
            XCTAssertEqual(fixture.model.selection, [fixture.firstID, fixture.secondID])

            let action = try await fixture.contextMenuOpenAction(forTitle: title)
            XCTAssertNotNil(action, "Right-clicking a selected member of a multi-selection must expose its Open Editor menu item")
            if let action {
                let items = action.menu.items
                let item = try XCTUnwrap(items.indices.contains(action.index) ? items[action.index] : nil,
                    "The real tracked Open item must remain available for native action dispatch")
                XCTAssertEqual(item.title, "Open Editor")
                XCTAssertTrue(item.isEnabled, "A recoverable fixture capture must have an enabled Open action")
                action.menu.performActionForItem(at: action.index)
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        XCTAssertEqual(fixture.actions.opened, [fixture.firstID, fixture.secondID],
            "Each native menu action must open its clicked row, never an arbitrary member of the selected set")
    }
}

@MainActor
private final class HistorySelectionInteractionActions {
    var opened: [UUID] = []
}

@MainActor
private final class HistorySelectionMenuProbe: NSObject {
    private let window: NSWindow
    private var timeout: Timer?
    private var cancellationTimer: Timer?
    private var trackedMenus: [NSMenu] = []
    private var activeMenus = Set<ObjectIdentifier>()
    private var stopRequested = false
    private var cancellationAttempts = 0
    private(set) var didTrack = false
    private(set) var didEndTracking = false
    private(set) var itemTitles: [String] = []
    private(set) var openAction: (menu: NSMenu, index: Int)?
    var onTrackingEnded: (() -> Void)?

    init(window: NSWindow) { self.window = window }

    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(menuBeganTracking(_:)),
            name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuEndedTracking(_:)),
            name: NSMenu.didEndTrackingNotification, object: nil)
        let timer = Timer(timeInterval: 1.5, target: self, selector: #selector(cancelTimedOutTracking(_:)),
            userInfo: nil, repeats: false)
        timeout = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    func stop() {
        stopRequested = true
        // Never tear down a still-active tracking loop's watchdog. In particular,
        // didBeginTracking alone does not mean cancelTracking can take effect yet.
        guard !didTrack || didEndTracking else { return }
        NotificationCenter.default.removeObserver(self)
        timeout?.invalidate()
        timeout = nil
        cancellationTimer?.invalidate()
        cancellationTimer = nil
        trackedMenus.removeAll()
    }

    @objc private func menuBeganTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu, trackedMenus.count < 8 else { return }
        trackedMenus.append(menu)
        activeMenus.insert(ObjectIdentifier(menu))
        menu.update()
        itemTitles = Array(menu.items.prefix(20).map(\.title))
        openAction = findOpenAction(in: menu)
        didTrack = true
        didEndTracking = false
        // A cancellation inside didBeginTracking may precede AppKit's event loop
        // and be ignored. Request it on a later event-tracking turn instead.
        if cancellationTimer == nil {
            let timer = Timer(timeInterval: 0.05, target: self, selector: #selector(cancelActiveTracking(_:)),
                userInfo: nil, repeats: true)
            cancellationTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
        }
    }

    @objc private func menuEndedTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu,
              activeMenus.remove(ObjectIdentifier(menu)) != nil else { return }
        didEndTracking = activeMenus.isEmpty
        if didEndTracking {
            cancellationTimer?.invalidate()
            cancellationTimer = nil
            timeout?.invalidate()
            timeout = nil
            if stopRequested { stop() }
            let completion = onTrackingEnded
            onTrackingEnded = nil
            completion?()
        }
    }

    @objc private func cancelActiveTracking(_ timer: Timer) {
        guard !didEndTracking else { timer.invalidate(); return }
        cancellationAttempts += 1
        for menu in trackedMenus where activeMenus.contains(ObjectIdentifier(menu)) {
            menu.cancelTrackingWithoutAnimation()
        }
        // Bounded retry budget, with an independent 1.5-second Escape watchdog.
        // Normal completion cancels this timer in menuEndedTracking above.
        if cancellationAttempts >= 20 { timer.invalidate() }
    }

    private func findOpenAction(in menu: NSMenu, depth: Int = 0) -> (menu: NSMenu, index: Int)? {
        guard depth < 4 else { return nil }
        for (index, item) in menu.items.prefix(40).enumerated() {
            if item.title == "Open Editor" { return (menu, index) }
            if let submenu = item.submenu, let action = findOpenAction(in: submenu, depth: depth + 1) { return action }
        }
        return nil
    }

    @objc private func cancelTimedOutTracking(_ timer: Timer) {
        requestCancellation()
    }

    func requestCancellation() {
        for menu in trackedMenus where activeMenus.contains(ObjectIdentifier(menu)) {
            menu.cancelTrackingWithoutAnimation()
        }
        // A missing tracking notification must not leave a native menu blocking
        // the suite. Escape is process-local and only targets the owned test app.
        guard NSApp.isActive, window.isKeyWindow else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false, keyCode: 53) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }
}

@MainActor
private final class HistorySelectionInteractionFixture {
    let firstID = UUID()
    let secondID = UUID()
    let firstTitle = "History selection first.png"
    let secondTitle = "History selection second.png"
    let root: URL
    let model: CaptureHistoryModel
    let actions: HistorySelectionInteractionActions
    private let window: NSWindow
    private let hosting: NSHostingView<CaptureHistoryView>
    private var eventNumber = 1
    private var menuProbe: HistorySelectionMenuProbe?

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftShotHistorySelection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = RecoveryStore(root: root.appendingPathComponent("recovery"))
        let actions = HistorySelectionInteractionActions()
        self.actions = actions
        model = CaptureHistoryModel(store: store, onOpen: { actions.opened.append($0) },
            onPin: { _ in }, onDelete: { _ in }, onCombine: { _, _ in }, onRetentionChange: { _ in })
        hosting = NSHostingView(rootView: CaptureHistoryView(model: model))
        hosting.frame = CGRect(x: 0, y: 0, width: 1000, height: 650)
        let visibleFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let contentFrame = CGRect(x: visibleFrame.minX + 40,
            y: max(visibleFrame.minY + 20, visibleFrame.maxY - 710), width: 1000, height: 650)
        window = NSWindow(contentRect: contentFrame,
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "SwiftShot History Selection Regression \(firstID.uuidString.prefix(8))"

        do {
            let image = try Self.image()
            let edits = CaptureEdits(crop: CGRect(x: 0, y: 0, width: 32, height: 24))
            try await store.persist(id: firstID, image: image, edits: edits, revision: 0,
                savedURL: root.appendingPathComponent(firstTitle))
            try await store.persist(id: secondID, image: image, edits: edits, revision: 0,
                savedURL: root.appendingPathComponent(secondTitle))
            await model.reload()
            window.contentView = hosting
            window.setContentSize(NSSize(width: 1000, height: 650))
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            // Let SwiftUI/AppKit complete their own layout transactions. Forced
            // layout inside the polling loop can reenter a pending view update.
            try await Task.sleep(for: .milliseconds(200))
            for _ in 0..<100 {
                if window.isKeyWindow, nativeCell(forTitle: firstTitle) != nil, nativeCell(forTitle: secondTitle) != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            if !window.isKeyWindow || nativeCell(forTitle: firstTitle) == nil || nativeCell(forTitle: secondTitle) == nil {
                dumpFixtureViews()
            }
            _ = try XCTUnwrap(nativeCell(forTitle: firstTitle), "Hosted History must materialize the first record's actual native cell")
            _ = try XCTUnwrap(nativeCell(forTitle: secondTitle), "Hosted History must materialize the second record's actual native cell")
            _ = try XCTUnwrap(window.isKeyWindow ? window : nil, "Native-event fixture must own its test window before sending events")
            XCTAssertTrue(model.selection.isEmpty, "Setup must not simulate row selection")
        } catch {
            close()
            throw error
        }
    }

    func close() {
        if let probe = menuProbe, probe.didTrack, !probe.didEndTracking {
            // A failing menu assertion must not synchronously close an NSWindow
            // from inside its still-running tracking loop. Retain the probe and
            // finish cleanup when AppKit acknowledges the end of that loop.
            probe.onTrackingEnded = { [self] in
                menuProbe = nil
                DispatchQueue.main.async { self.close() }
            }
            probe.requestCancellation()
            return
        }
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        try? FileManager.default.removeItem(at: root)
    }

    func clickTitle(_ title: String, modifiers: NSEvent.ModifierFlags = [], count: Int = 1) async throws {
        try await click(contentPoint(forTitle: title, thumbnail: false), modifiers: modifiers, count: count)
    }

    func thumbnailPoint(forTitle title: String) throws -> CGPoint {
        try contentPoint(forTitle: title, thumbnail: true)
    }

    func contextMenuOpenAction(forTitle title: String) async throws -> (menu: NSMenu, index: Int)? {
        let screenPoint = try contentPoint(forTitle: title, thumbnail: false)
        _ = try XCTUnwrap(window.isKeyWindow ? window : nil, "Only the fixture's key window may receive the right-click")
        let probe = HistorySelectionMenuProbe(window: window)
        menuProbe = probe
        probe.start()
        defer {
            probe.stop()
            if !probe.didTrack || probe.didEndTracking { menuProbe = nil }
        }
        let point = window.convertPoint(fromScreen: screenPoint)
        let timestamp = ProcessInfo.processInfo.systemUptime
        for (offset, type) in [NSEvent.EventType.rightMouseDown, .rightMouseUp].enumerated() {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: timestamp + Double(offset) * 0.01,
                windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber,
                clickCount: 1, pressure: type == .rightMouseDown ? 1 : 0))
            eventNumber += 1
            NSApp.postEvent(event, atStart: false)
        }
        for _ in 0..<125 {
            if probe.didTrack && probe.didEndTracking { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        print("HISTORY_SELECTION_MENU title=\(title) tracked=\(probe.didTrack) ended=\(probe.didEndTracking) items=\(probe.itemTitles)")
        if probe.didTrack {
            _ = try XCTUnwrap(probe.didEndTracking ? probe : nil,
                "The native context menu must finish tracking before invoking Open or starting another row click")
            // didEndTracking is posted during AppKit's unwind; let the event stack
            // return before XCTest invokes the retained menu's real action.
            try await Task.sleep(for: .milliseconds(50))
        }
        return probe.openAction
    }

    /// Queue only process-local NSEvents for this fixture window. NSApplication
    /// dispatches them through normal hit testing and gesture recognition; never
    /// call model selection, NSTableView selection, or accessibility Press here.
    func click(_ screenPoint: CGPoint, modifiers: NSEvent.ModifierFlags = [], count: Int = 1) async throws {
        let point = window.convertPoint(fromScreen: screenPoint)
        let localPoint = hosting.convert(point, from: nil)
        _ = try XCTUnwrap(hosting.hitTest(localPoint), "Content click must hit the hosted History view")
        for clickCount in 1...count {
            let timestamp = ProcessInfo.processInfo.systemUptime
            for (offset, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                    modifierFlags: modifiers, timestamp: timestamp + Double(offset) * 0.01,
                    windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber,
                    clickCount: clickCount, pressure: type == .leftMouseDown ? 1 : 0))
                eventNumber += 1
                NSApp.postEvent(event, atStart: false)
            }
            if clickCount < count { try await Task.sleep(for: .milliseconds(30)) }
        }
        // Wait beyond the system double-click interval so an exclusive gesture
        // cannot make a swallowed single click look like a merely delayed one.
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
    }

    private func nativeCell(forTitle title: String) -> NSView? {
        // ForEach presents model.entries in this exact order. Resolve by unique
        // fixture filename, never assume that persistence order equals row order.
        guard let row = model.entries.firstIndex(where: { entry in
            entry.record.savedPath.map { URL(fileURLWithPath: $0).lastPathComponent } == title
        }) else { return nil }
        let tables = nativeViews().compactMap { $0 as? NSTableView }
        guard tables.count == 1, let table = tables.first,
              table.numberOfRows == model.entries.count, table.numberOfColumns == 1,
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false),
              cell.bounds.width >= 130, cell.bounds.height >= 42 else { return nil }
        return cell
    }

    private func contentPoint(forTitle title: String, thumbnail: Bool) throws -> CGPoint {
        let cell = try XCTUnwrap(nativeCell(forTitle: title), "Target must be a materialized native cell for the named fixture record")
        // This fixture deliberately characterizes HistoryCaptureRow's current
        // 60×42 thumbnail + 10-point gap + two-line text layout. These points are
        // deep inside that content, not in the List's separately clickable margin.
        let point = CGPoint(x: cell.bounds.minX + (thumbnail ? 30 : 100),
            y: cell.bounds.midY + (thumbnail ? 0 : cell.isFlipped ? -9 : 9))
        let inWindow = cell.convert(point, to: nil)
        let inHost = hosting.convert(inWindow, from: nil)
        let hit = try XCTUnwrap(hosting.hitTest(inHost), "Content target must participate in real native hit testing")
        let table = try XCTUnwrap(nativeViews().compactMap { $0 as? NSTableView }.first)
        let expectedRow = try XCTUnwrap(model.entries.firstIndex { entry in
            entry.record.savedPath.map { URL(fileURLWithPath: $0).lastPathComponent } == title
        })
        let inTable = table.convert(inWindow, from: nil)
        let actualRow = table.row(at: inTable)
        let backInCell = cell.convert(inWindow, from: nil)
        print("HISTORY_SELECTION_TARGET title=\(title) part=\(thumbnail ? "thumbnail" : "title") expectedRow=\(expectedRow) actualRow=\(actualRow) cell=\(cell.bounds) local=\(point) table=\(inTable) host=\(inHost) hit=\(type(of: hit))")
        _ = try XCTUnwrap(actualRow == expectedRow ? cell : nil,
            "Native table hit location must map to the named fixture record's displayed row")
        _ = try XCTUnwrap(cell.bounds.contains(backInCell) && hosting.bounds.contains(inHost) ? cell : nil,
            "Round-tripped content point must remain inside its actual cell and the fixture host")
        // SwiftUI may route gestures through an ancestor hosting/table view.
        // The public row lookup and cell bounds establish the target, not the
        // implementation-specific class returned by NSView.hitTest.
        return window.convertPoint(toScreen: inWindow)
    }

    private func nativeViews() -> [NSView] {
        var pending: [NSView] = [hosting]
        var result: [NSView] = []
        while let next = pending.popLast(), result.count < 2_000 {
            result.append(next)
            pending.append(contentsOf: next.subviews)
        }
        return result
    }

    private func dumpFixtureViews() {
        print("HISTORY_SELECTION_FIXTURE active=\(NSApp.isActive) visible=\(window.isVisible) key=\(window.isKeyWindow) frame=\(window.frame) host=\(hosting.bounds) records=\(model.entries.count) loading=\(model.isLoading)")
        for view in nativeViews().prefix(30) {
            print("HISTORY_SELECTION_VIEW type=\(type(of: view)) frame=\(view.frame)")
        }
    }

    private static func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        return try XCTUnwrap(context.makeImage())
    }
}
