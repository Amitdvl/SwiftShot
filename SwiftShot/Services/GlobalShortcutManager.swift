import Carbon
import AppKit
import Foundation

// MARK: - Global Shortcut Manager

/// Registers global keyboard shortcuts using Carbon Event API.
/// Carbon hot keys are the most reliable approach on macOS for global shortcuts.
@MainActor
final class GlobalShortcutManager {
    static let shared = GlobalShortcutManager()

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextId: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    private init() {
        installEventHandler()
    }

    nonisolated deinit {
        // Intentionally empty — singleton lives for app lifetime.
        // unregisterAll() handles cleanup when needed.
    }

    // MARK: - Public

    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        let id = nextId
        nextId += 1

        handlers[id] = handler

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x5353) // "SS" for SwiftShot
        hotKeyID.id = id

        var hotKeyRef: EventHotKeyRef?
        let carbonMods = carbonModifiers(from: modifiers)

        let status = RegisterEventHotKey(
            keyCode,
            carbonMods,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr, let ref = hotKeyRef {
            hotKeyRefs.append(ref)
        }
    }

    func unregisterAll() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        handlers.removeAll()
        nextId = 1
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
                DispatchQueue.main.async {
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
