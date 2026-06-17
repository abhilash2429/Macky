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

/// The user-configurable push-to-talk hotkey. Macky only supports modifier-only
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

    /// Fires when the user taps Control three times in quick succession (a
    /// modifier-only gesture, separate from the push-to-talk hotkey). Drives the
    /// continuous-listening mode toggle in `CompanionManager`.
    let controlTriplePressPublisher = PassthroughSubject<Void, Never>()

    /// How many pure-Control taps toggle continuous mode, and the window each
    /// consecutive tap must land within. A "tap" is a down→up cycle of Control with
    /// no other modifier held.
    private static let controlTapsToToggle = 3
    private static let controlTapMaxGap: TimeInterval = 0.4

    /// Whether Control was down as of the previous `.flagsChanged`, so we can detect
    /// the down/up edges of the Control key itself.
    private var wasControlDown = false
    /// Whether the in-progress Control press has stayed "pure" — Control held with no
    /// other modifier at any point. Cleared the moment another modifier joins, so
    /// engaging ctrl+option (Control then Option) is never mistaken for a Control tap.
    private var currentControlPressIsPure = false
    /// Timestamps of recent completed pure-Control taps. Trimmed to the most recent
    /// `controlTapsToToggle` and reset when a gap exceeds `controlTapMaxGap`.
    private var recentControlTapTimes: [TimeInterval] = []

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
        wasControlDown = false
        currentControlPressIsPure = false
        recentControlTapTimes.removeAll()

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

        detectControlTriplePress(eventType: eventType, modifierFlagsRawValue: event.flags.rawValue)

        return Unmanaged.passUnretained(event)
    }

    /// Detects three quick Control-only taps and emits `controlTriplePressPublisher`.
    /// A "tap" is a down→up cycle of the Control key during which no other modifier
    /// was ever held, so the gesture never collides with the ctrl+option push-to-talk
    /// hotkey: pressing Control then adding Option taints the press (Option is
    /// another modifier) and it isn't counted. Skipped entirely when the user has
    /// configured push-to-talk to Control-only, so the two can't fight over the key.
    private func detectControlTriplePress(eventType: CGEventType, modifierFlagsRawValue: UInt64) {
        guard eventType == .flagsChanged else { return }
        guard currentHotkey.modifierFlags != [.control] else { return }

        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
            .intersection(.deviceIndependentFlagsMask)
        let controlDown = flags.contains(.control)
        let otherModifierHeld = !flags.subtracting(.control).isEmpty

        defer { wasControlDown = controlDown }

        if controlDown && !wasControlDown {
            // Control pressed: pure only if nothing else is held at that instant.
            currentControlPressIsPure = !otherModifierHeld
        } else if controlDown {
            // Another modifier changed while Control stays down — taint the press.
            if otherModifierHeld { currentControlPressIsPure = false }
        } else if wasControlDown {
            // Control released → completes a tap. Count it only if it stayed pure.
            guard currentControlPressIsPure else {
                currentControlPressIsPure = false
                return
            }
            currentControlPressIsPure = false
            registerControlTap()
        }
    }

    /// Records one completed pure-Control tap and toggles when three land within the
    /// window. Consecutive taps must each land within `controlTapMaxGap` of the prior.
    private func registerControlTap() {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = recentControlTapTimes.last, now - last > Self.controlTapMaxGap {
            recentControlTapTimes.removeAll()
        }
        recentControlTapTimes.append(now)
        if recentControlTapTimes.count > Self.controlTapsToToggle {
            recentControlTapTimes.removeFirst(recentControlTapTimes.count - Self.controlTapsToToggle)
        }
        if recentControlTapTimes.count == Self.controlTapsToToggle {
            recentControlTapTimes.removeAll()
            controlTriplePressPublisher.send(())
        }
    }
}
