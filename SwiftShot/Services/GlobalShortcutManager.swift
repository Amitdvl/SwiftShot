import Carbon
import AppKit
import Foundation
import OSLog

// MARK: - Global Shortcut Manager

/// Registers global keyboard shortcuts using Carbon Event API.
/// Carbon hot keys are the most reliable approach on macOS for global shortcuts.
@MainActor
final class GlobalShortcutManager {
    private struct MenuReference: @unchecked Sendable {
        let value: NSMenu?
    }

    static let shared = GlobalShortcutManager()

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var registrations: [UInt32: (keyCode: UInt32, modifiers: UInt32)] = [:]
    private var nextId: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var menuTrackingObservers: [NSObjectProtocol] = []
    private var carbonSuspendedForMenu = false
    private weak var trackingMenu: NSMenu?
    private let logger = Logger(subsystem: "com.swiftshot.app", category: "Shortcuts")
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var menuCaptureActive = false

    private init() {
        installEventHandler()
        installMenuTrackingFallback()
        installEventTap()
    }

    nonisolated deinit {
        // Intentionally empty — singleton lives for app lifetime.
        // unregisterAll() handles cleanup when needed.
    }

    // MARK: - Public

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        let id = nextId
        nextId += 1

        handlers[id] = handler

        let carbonMods = carbonModifiers(from: modifiers)
        registrations[id] = (keyCode, carbonMods)

        if carbonSuspendedForMenu { return true }
        if registerCarbonHotKey(id: id, keyCode: keyCode, modifiers: carbonMods) {
            return true
        }
        handlers.removeValue(forKey: id)
        registrations.removeValue(forKey: id)
        return false
    }

    func unregisterAll() {
        unregisterCarbonHotKeys()
        handlers.removeAll()
        registrations.removeAll()
        nextId = 1
    }

    private func registerCarbonHotKey(id: UInt32, keyCode: UInt32, modifiers: UInt32) -> Bool {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x5353) // "SS" for SwiftShot
        hotKeyID.id = id
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr, let hotKeyRef else { return false }
        hotKeyRefs.append(hotKeyRef)
        return true
    }

    private func unregisterCarbonHotKeys() {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
    }

    /// Carbon hot keys are not delivered while an NSMenu is in its tracking
    /// run loop (including a MenuBarExtra status menu). Observe the key event
    /// at the AppKit boundary as a fallback so a shortcut can claim the menu's
    /// pixels before the menu is dismissed. The global monitor covers the
    /// inverse case where AppKit routes the event outside this process.
    private func installMenuTrackingFallback() {
        menuTrackingObservers = [
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                    object: nil, queue: .main) { [weak self] notification in
                let menuReference = MenuReference(value: notification.object as? NSMenu)
                MainActor.assumeIsolated { [weak self] in
                    self?.suspendCarbonHotKeysForMenu(menuReference.value)
                }
            },
            NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification,
                                                    object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { [weak self] in
                    self?.resumeCarbonHotKeysAfterMenu()
                }
            }
        ]
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, !event.isARepeat, self.dispatchFallback(for: event) { return nil }
            // A tracking menu receives key-up separately from key-down. Keep
            // the chord consumed until the compositor has claimed the menu's
            // pixels; AppState dismisses tracking after ScreenCaptureKit returns.
            if event.type == .keyUp, self.hasFallbackMatch(for: event) { return nil }
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !event.isARepeat else { return }
            _ = self.dispatchFallback(for: event)
        }
    }

    /// Status-item menus run a nested tracking loop that can bypass both
    /// Carbon delivery and AppKit's local monitor. A session event tap sees
    /// the physical chord before that loop handles it. It is attached to the
    /// main run loop's common modes so it remains active during menu tracking.
    private func installEventTap() {
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.keyUp.rawValue) |
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = manager.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard type == .keyDown || type == .keyUp || type == .flagsChanged else {
                return Unmanaged.passUnretained(event)
            }
            let consume = MainActor.assumeIsolated { manager.handleEventTap(type: type, event: event) }
            return consume ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            logger.error("Could not install keyboard event tap; AppKit and Carbon shortcuts remain active")
            return
        }
        eventTap = tap
        eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let eventTapSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    func dismissMenuTracking() {
        logger.info("Dismiss menu tracking; menu available: \(self.trackingMenu != nil, privacy: .public)")
        trackingMenu?.cancelTrackingWithoutAnimation()
        if menuCaptureActive && statusMenuIsVisible() {
            // MenuBarExtra does not publish its NSMenu instance to the app.
            // Escape is scoped to the active tracking menu and leaves the
            // previously focused application untouched once tracking ends.
            let source = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
        menuCaptureActive = false
    }

    private func suspendCarbonHotKeysForMenu(_ menu: NSMenu? = nil) {
        guard !carbonSuspendedForMenu else { return }
        carbonSuspendedForMenu = true
        trackingMenu = menu
        logger.info("Menu tracking began; suspending Carbon shortcuts; menu available: \(menu != nil, privacy: .public)")
        unregisterCarbonHotKeys()
    }

    private func resumeCarbonHotKeysAfterMenu() {
        guard carbonSuspendedForMenu else { return }
        carbonSuspendedForMenu = false
        trackingMenu = nil
        logger.info("Menu tracking ended; restoring Carbon shortcuts")
        for (id, registration) in registrations {
            _ = registerCarbonHotKey(id: id, keyCode: registration.keyCode, modifiers: registration.modifiers)
        }
    }

    private func hasFallbackMatch(for event: NSEvent) -> Bool {
        let eventModifiers = Self.carbonModifiers(from: event.modifierFlags)
        return registrations.values.contains { registration in
            registration.keyCode == UInt32(event.keyCode) && registration.modifiers == eventModifiers
        }
    }

    private func handleEventTap(type: CGEventType, event: CGEvent) -> Bool {
        let eventModifiers = Self.carbonModifiers(from: event.flags)
        if type == .flagsChanged { return menuCaptureActive }
        guard let match = registrations.first(where: { registration in
            registration.value.keyCode == UInt32(event.getIntegerValueField(.keyboardEventKeycode)) &&
                registration.value.modifiers == eventModifiers
        }) else { return false }
        if type == .keyUp { return menuCaptureActive }
        let menuVisible = statusMenuIsVisible()
        guard menuVisible else { return false }
        menuCaptureActive = true
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return true }
        guard let handler = handlers[match.key] else { return true }
        logger.info("Event-tap shortcut dispatched for key code \(event.getIntegerValueField(.keyboardEventKeycode), privacy: .public)")
        let traceRunID = CaptureLatencyTrace.shared.activeRunID
        CaptureLatencyTrace.shared.mark(.shortcutReceived, for: traceRunID)
        CaptureLatencyTrace.shared.mark(.shortcutDispatched, for: traceRunID)
        handler()
        return true
    }

    private func statusMenuIsVisible() -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { row in
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 101,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return frame.width >= 100 && frame.height >= 40
        }
    }

    @discardableResult
    private func dispatchFallback(for event: NSEvent) -> Bool {
        let eventModifiers = Self.carbonModifiers(from: event.modifierFlags)
        guard let match = registrations.first(where: { registration in
            registration.value.keyCode == UInt32(event.keyCode) && registration.value.modifiers == eventModifiers
        }), let handler = handlers[match.key] else { return false }
        logger.info("Fallback shortcut dispatched for key code \(event.keyCode, privacy: .public)")
        let traceRunID = CaptureLatencyTrace.shared.activeRunID
        CaptureLatencyTrace.shared.mark(.shortcutReceived, for: traceRunID)
        CaptureLatencyTrace.shared.mark(.shortcutDispatched, for: traceRunID)
        handler()
        return true
    }

    // MARK: - Event Handler

    private func installEventHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handlerBlock: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let event = event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }

            let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(userData!).takeUnretainedValue()
            if let handler = manager.handlers[hotKeyID.id] {
                let traceRunID = CaptureLatencyTrace.shared.activeRunID
                CaptureLatencyTrace.shared.mark(.shortcutReceived, for: traceRunID)
                DispatchQueue.main.async {
                    CaptureLatencyTrace.shared.mark(.shortcutDispatched, for: traceRunID)
                    handler()
                }
            }
            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            handlerBlock,
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )
    }

    // MARK: - Modifier Conversion

    /// Convert our stored modifier flags to Carbon modifier flags
    private func carbonModifiers(from mods: UInt32) -> UInt32 {
        var carbon: UInt32 = 0
        // We store modifiers as: 0x0100 = Cmd, 0x0200 = Shift, 0x0800 = Option, 0x1000 = Control
        if mods & 0x0100 != 0 { carbon |= UInt32(cmdKey) }
        if mods & 0x0200 != 0 { carbon |= UInt32(shiftKey) }     // Shift (0x0200)
        if mods & 0x0800 != 0 { carbon |= UInt32(optionKey) }
        if mods & 0x1000 != 0 { carbon |= UInt32(controlKey) }

        // Also handle NSEvent modifier flags format
        // cmdKey = 256 (0x100), shiftKey = 512 (0x200)
        // Cocoa: .command = 1<<20, .shift = 1<<17, .option = 1<<19, .control = 1<<18
        if mods & (1 << 20) != 0 { carbon |= UInt32(cmdKey) }
        if mods & (1 << 17) != 0 { carbon |= UInt32(shiftKey) }
        if mods & (1 << 19) != 0 { carbon |= UInt32(optionKey) }
        if mods & (1 << 18) != 0 { carbon |= UInt32(controlKey) }

        return carbon
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }

    private static func carbonModifiers(from flags: CGEventFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.maskCommand) { carbon |= UInt32(cmdKey) }
        if flags.contains(.maskShift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.maskAlternate) { carbon |= UInt32(optionKey) }
        if flags.contains(.maskControl) { carbon |= UInt32(controlKey) }
        return carbon
    }
}

// MARK: - Key Code Constants

enum KeyCodes {
    static let key2: UInt32 = 0x13       // '2'
    static let keyD: UInt32 = 0x02       // 'D'
    static let keyF: UInt32 = 0x03       // 'F'
    static let keyO: UInt32 = 0x1F       // 'O'

    // Modifier flags (Carbon format)
    static let cmdShift: UInt32 = UInt32(cmdKey | shiftKey)
}
