//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

/// The user-configurable push-to-talk hotkey. Speed only supports modifier-only
/// combos (e.g. ctrl + option), so this stores just the device-independent
/// modifier flags that must be held. Persisted in UserDefaults so the choice
/// survives relaunches; defaults to ctrl + option when nothing is stored.
struct HotkeyConfiguration: Equatable {
    /// Device-independent modifier flags that must be held for push-to-talk.
    /// Always non-empty — an empty set would `contains([])`-match every keystroke.
    let modifierFlags: NSEvent.ModifierFlags

    /// UInt64 bitfield of the `NSEvent.ModifierFlags` rawValue.
    static let userDefaultsModifiersKey = "hotkeyModifiers"
    /// Int virtual key code. We only support modifier-only combos, so this is
    /// always the `modifierOnlyKeyCode` sentinel — stored for spec/forward-compat.
    static let userDefaultsKeyCodeKey = "hotkeyKeyCode"
    /// Sentinel meaning "no key required" (modifier-only shortcut).
    static let modifierOnlyKeyCode = -1

    static let `default` = HotkeyConfiguration(modifierFlags: [.control, .option])

    init(modifierFlags: NSEvent.ModifierFlags) {
        self.modifierFlags = modifierFlags.intersection(.deviceIndependentFlagsMask)
    }

    /// Human-readable combo, e.g. "ctrl + option". Mirrors the wording the old
    /// fixed presets used so the notch panel copy stays consistent.
    var displayText: String {
        var parts: [String] = []
        if modifierFlags.contains(.control) { parts.append("ctrl") }
        if modifierFlags.contains(.option) { parts.append("option") }
        if modifierFlags.contains(.shift) { parts.append("shift") }
        if modifierFlags.contains(.command) { parts.append("cmd") }
        if modifierFlags.contains(.function) { parts.append("fn") }
        if modifierFlags.contains(.capsLock) { parts.append("caps lock") }
        return parts.joined(separator: " + ")
    }

    /// Reads the saved hotkey, falling back to ctrl + option when nothing is
    /// stored or the stored modifier set is empty (which would match everything).
    static func load(from defaults: UserDefaults = .standard) -> HotkeyConfiguration {
        guard let storedNumber = defaults.object(forKey: userDefaultsModifiersKey) as? NSNumber else {
            return .default
        }
        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(storedNumber.uint64Value))
            .intersection(.deviceIndependentFlagsMask)
        guard !modifierFlags.isEmpty else { return .default }
        return HotkeyConfiguration(modifierFlags: modifierFlags)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(UInt64(modifierFlags.rawValue), forKey: Self.userDefaultsModifiersKey)
        defaults.set(Self.modifierOnlyKeyCode, forKey: Self.userDefaultsKeyCodeKey)
    }
}

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    /// The combo the tap currently watches for. Loaded from UserDefaults on init;
    /// call `refreshHotkey()` after the user saves a new shortcut so the running
    /// tap starts matching it without a relaunch.
    private(set) var currentHotkey: HotkeyConfiguration = .load()

    deinit {
        stop()
    }

    /// Re-reads the saved hotkey from UserDefaults. Safe to call while the tap is
    /// running — only `currentHotkey` changes; the tap itself is untouched.
    func refreshHotkey() {
        currentHotkey = .load()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed,
            hotkey: currentHotkey
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        return Unmanaged.passUnretained(event)
    }
}
