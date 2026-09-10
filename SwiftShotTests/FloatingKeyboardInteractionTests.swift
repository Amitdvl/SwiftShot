import AppKit
import SwiftUI
import XCTest
@testable import SwiftShot

/// Native, process-local characterization of the shortcuts installed by our
/// floating content in a regular test host (its original policy is restored).
/// Accessory-app activation and cross-process TextEdit dispatch remain separate
/// native gates: the lead must verify who receives an actual physical chord.
@MainActor
final class FloatingKeyboardInteractionTests: XCTestCase {
    // A floating shortcut escaping its window would save a different capture.
    // The ordinary window's Save callback proves the event was really delivered.
    func testMainWindowSaveDoesNotInvokeVisibleRecentOrPinSave() async throws {
        let fixture = try await FloatingKeyboardFixture(firstIsRecent: true)
        defer { fixture.close() }

        try await fixture.focus(fixture.first)
        try await fixture.press(.save)
        XCTAssertEqual(fixture.actions.events, ["first.save"])
        try await fixture.focus(fixture.second)
        try await fixture.press(.save)
        XCTAssertEqual(fixture.actions.events, ["first.save", "second.save"])

        try await fixture.focus(fixture.main)
        XCTAssertTrue(fixture.first.isVisible)
        XCTAssertTrue(fixture.second.isVisible)
        try await fixture.press(.save)
        try await fixture.press(.copy)
        XCTAssertEqual(fixture.actions.events, ["first.save", "second.save", "main.save", "main.copy"],
            "Copy/Save in the destination window must not export a background capture")
    }

    // Previously focused hosts must unregister/suspend shortcuts when hidden.
    func testMainWindowSaveDoesNotInvokePreviouslyFocusedHiddenPanels() async throws {
        let fixture = try await FloatingKeyboardFixture(firstIsRecent: true)
        defer { fixture.close() }

        try await fixture.focus(fixture.first)
        try await fixture.press(.save)
        try await fixture.focus(fixture.second)
        try await fixture.press(.save)
        XCTAssertEqual(fixture.actions.events, ["first.save", "second.save"])
        fixture.first.orderOut(nil)
        fixture.second.orderOut(nil)
        try await fixture.focus(fixture.main)
        XCTAssertFalse(fixture.first.isVisible)
        XCTAssertFalse(fixture.second.isVisible)

        try await fixture.press(.save)
        try await fixture.press(.edit)
        try await fixture.press(.escape)
        XCTAssertEqual(fixture.actions.events,
            ["first.save", "second.save", "main.save", "main.edit", "main.close"],
            "A hidden host must not retain Save, Edit, or Escape ownership")
    }

    // Choosing the first/last registered pin instead of the key pin breaks this
    // literal first-second-first sequence; removing shortcuts breaks it too.
    func testSaveFollowsKeyPinExactlyOnceWhenSwitchingBetweenPins() async throws {
        let fixture = try await FloatingKeyboardFixture(firstIsRecent: false)
        defer { fixture.close() }

        try await fixture.focus(fixture.first)
        try await fixture.press(.save)
        XCTAssertEqual(fixture.actions.events, ["first.save"])
        try await fixture.focus(fixture.second)
        try await fixture.press(.save)
        XCTAssertEqual(fixture.actions.events, ["first.save", "second.save"])
        try await fixture.focus(fixture.first)
        try await fixture.press(.save)
        XCTAssertEqual(fixture.actions.events, ["first.save", "second.save", "first.save"],
            "The key pin must save exactly once, even when another pin registered the same chord")
    }

    func testRecentAndPinEditAndEscapeOnlyInvokeTheKeyPanel() async throws {
        let fixture = try await FloatingKeyboardFixture(firstIsRecent: true)
        defer { fixture.close() }

        try await fixture.focus(fixture.first)
        try await fixture.press(.edit)
        XCTAssertEqual(fixture.actions.events, ["first.edit"])
        try await fixture.press(.escape)
        XCTAssertEqual(fixture.actions.events, ["first.edit", "first.close"])
        try await fixture.focus(fixture.second)
        try await fixture.press(.edit)
        try await fixture.press(.escape)
        XCTAssertEqual(fixture.actions.events, ["first.edit", "first.close", "second.edit", "second.close"],
            "Edit and Escape must not act on an unrelated recent capture or pin")
    }
}

@MainActor
private final class FloatingKeyboardActions: NSObject {
    var events: [String] = []
    @objc func mainSave(_ sender: Any?) { events.append("main.save") }
    @objc func mainCopy(_ sender: Any?) { events.append("main.copy") }
    @objc func mainEdit(_ sender: Any?) { events.append("main.edit") }
    @objc func mainClose(_ sender: Any?) { events.append("main.close") }
}

@MainActor
private final class FloatingKeyboardFixture {
    enum Chord: String {
        case save, copy, edit, escape
        var characters: String {
            switch self {
            case .save: "s"
            case .copy: "c"
            case .edit: "e"
            case .escape: "\u{1B}"
            }
        }
        var code: UInt16 {
            switch self {
            case .save: 1
            case .copy: 8
            case .edit: 14
            case .escape: 53
            }
        }
        var modifiers: NSEvent.ModifierFlags { self == .escape ? [] : .command }
    }

    let main: NSWindow
    let first: FloatingCapturePanel
    let second: FloatingCapturePanel
    let actions = FloatingKeyboardActions()
    private let originalActivationPolicy = NSApp.activationPolicy()
    private var payloads: [FloatingCapturePayload] = []
    private var closed = false

    init(firstIsRecent: Bool) async throws {
        let image = try Self.image()
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        first = FloatingCaptureController.makePanel(kind: firstIsRecent ? .recent : .pin,
            image: image, visible: visible, cascadeIndex: 0)
        second = FloatingCaptureController.makePanel(kind: .pin, image: image,
            visible: visible, cascadeIndex: 1)
        main = NSWindow(contentRect: CGRect(x: visible.minX + 30, y: visible.minY + 240,
            width: 480, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        main.title = "SwiftShot Keyboard Destination Regression"
        first.title = "SwiftShot Keyboard First Regression"
        second.title = "SwiftShot Keyboard Second Regression"

        installFloating(in: first, name: "first", image: image, isRecent: firstIsRecent)
        installFloating(in: second, name: "second", image: image, isRecent: false)
        installMainContent()
        do {
            // This fixture characterizes production content/window routing,
            // not the menu-bar application's accessory activation behavior.
            let changed = NSApp.setActivationPolicy(.regular)
            _ = try XCTUnwrap(changed && NSApp.activationPolicy() == .regular ? main : nil,
                "The native key-routing fixture could not establish a regular test host")
            // A never-ordered window is not eligible for makeMain(); AppKit
            // asserts in _changeJustMain before any routing can be exercised.
            // focus(main) orders it and acquires native key ownership normally.
            first.orderFrontRegardless()
            second.orderFrontRegardless()
            try await focus(main)
            try await Task.sleep(for: .milliseconds(150))
            for window in [main, first, second] {
                let content = try XCTUnwrap(window.contentView)
                XCTAssertGreaterThan(content.bounds.width, 0)
                XCTAssertGreaterThan(content.bounds.height, 0)
            }
            XCTAssertTrue(actions.events.isEmpty, "Setup must never simulate a shortcut action")
        } catch {
            close()
            throw error
        }
    }

    private func installFloating(in panel: FloatingCapturePanel, name: String, image: CGImage, isRecent: Bool) {
        let payload = FloatingCapturePayload(image: image,
            renderer: SwiftShot.ImageRenderer(cacheByteLimit: 0, cacheEntryLimit: 0))
        payloads.append(payload)
        let actions = actions
        FloatingCaptureController.installContent(FloatingCaptureContent(image: image, payload: payload, isRecent: isRecent,
            onEdit: { actions.events.append("\(name).edit") },
            onSave: { actions.events.append("\(name).save") },
            onPin: { actions.events.append("\(name).pin") },
            onClose: { actions.events.append("\(name).close") }), in: panel)
    }

    private func installMainContent() {
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 480, height: 200))
        // Independent native destination controls are a positive delivery
        // oracle, not a second implementation of floating-window ownership.
        let buttons: [(String, Chord, Selector)] = [
            ("Save destination", .save, #selector(FloatingKeyboardActions.mainSave(_:))),
            ("Copy destination", .copy, #selector(FloatingKeyboardActions.mainCopy(_:))),
            ("Edit destination", .edit, #selector(FloatingKeyboardActions.mainEdit(_:))),
            ("Close destination", .escape, #selector(FloatingKeyboardActions.mainClose(_:)))
        ]
        for (index, definition) in buttons.enumerated() {
            let button = NSButton(title: definition.0, target: actions, action: definition.2)
            button.frame = CGRect(x: CGFloat(20 + (index % 2) * 225),
                y: CGFloat(35 + (index / 2) * 65), width: 210, height: 40)
            button.bezelStyle = .rounded
            button.keyEquivalent = definition.1.characters
            button.keyEquivalentModifierMask = definition.1.modifiers
            content.addSubview(button)
        }
        main.contentView = content
    }

    func focus(_ window: NSWindow) async throws {
        _ = try XCTUnwrap([main, first, second].contains(where: { $0 === window }) ? window : nil,
            "The fixture may only target its own three windows")
        // Materialize/order the native windows before asking macOS to activate
        // their owner. Activating before the two nonactivating panels were
        // ordered left this fixture inactive, without target key ownership.
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(150))
        // Only the test host is activated; no AppleScript, CGEvent posting,
        // session/global monitor, external app, clipboard or file Save.
        // The SDK documents ignoringOtherApps as ineffective since macOS 14.
        // Request only this process; success is not accepted as proof of focus.
        let activationRequested = NSRunningApplication.current.activate(options: [])
        window.makeKeyAndOrderFront(nil)
        // Match the History fixture's native activation/layout settling turn.
        try await Task.sleep(for: .milliseconds(200))
        for _ in 0..<100 {
            if NSApp.isActive, NSApp.keyWindow === window, window.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        print("FloatingKeyboard focus title=\(window.title) visible=\(window.isVisible) key=\(window.isKeyWindow) appActive=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue) activationRequested=\(activationRequested) canKey=\(window.canBecomeKey) canMain=\(window.canBecomeMain) targetIsMain=\(NSApp.mainWindow === window) keyIsNil=\(NSApp.keyWindow == nil) mainIsNil=\(NSApp.mainWindow == nil)")
        _ = try XCTUnwrap(NSApp.isActive && window.isVisible && window.isKeyWindow && NSApp.keyWindow === window ? window : nil,
            "Native routing requires actual active/key ownership; a failed setup is not a shortcut regression")
        // Give native focus and SwiftUI shortcut registration their own turn.
        try await Task.sleep(for: .milliseconds(60))
    }

    func press(_ chord: Chord) async throws {
        let window = try XCTUnwrap(NSApp.keyWindow, "A real key window must receive the chord")
        _ = try XCTUnwrap(NSApp.isActive && window.isVisible && [main, first, second].contains(where: { $0 === window }) ? window : nil,
            "Never send even a process-local event to an unrelated window")
        let before = actions.events
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: chord.modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: chord.characters, charactersIgnoringModifiers: chord.characters,
                isARepeat: false, keyCode: chord.code))
            // NSApplication performs native key-equivalent/responder routing.
            // Never call content actions, button.performClick, or a fake policy.
            NSApp.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(100))
        print("FloatingKeyboard chord=\(chord.rawValue) target=\(window.title) added=\(Array(actions.events.dropFirst(before.count)))")
    }

    func close() {
        guard !closed else { return }
        closed = true
        for window in [first, second, main] {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        for payload in payloads { Task { await payload.close() } }
        payloads.removeAll()
        if NSApp.activationPolicy() != originalActivationPolicy {
            let restored = NSApp.setActivationPolicy(originalActivationPolicy)
            XCTAssertTrue(restored, "Fixture cleanup must restore the test host's original activation policy")
            XCTAssertEqual(NSApp.activationPolicy(), originalActivationPolicy)
        }
    }

    private static func image() throws -> CGImage {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8,
            bytesPerRow: 80 * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        return try XCTUnwrap(context.makeImage())
    }
}
