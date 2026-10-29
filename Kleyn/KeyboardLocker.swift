//
//  KeyboardLocker.swift
//  Kleyn
//
//  Created by Tyastono Taufiq on 29/10/26.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Observation

/// Blocks keyboard input system-wide with an active HID-level event tap.
///
/// Requires the Accessibility permission (active event taps can't run in the App Sandbox).
/// The tap belongs to this process, so it disappears if the app quits or crashes.
@Observable
final class KeyboardLocker {
    static let autoUnlockInterval: TimeInterval = 120
    private static let autoUnlockEnabledKey = "autoUnlockEnabled"

    /// Whether locking starts the auto-unlock countdown. Remembered across launches.
    var autoUnlockEnabled = UserDefaults.standard.object(forKey: autoUnlockEnabledKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoUnlockEnabled, forKey: Self.autoUnlockEnabledKey) }
    }

    private(set) var isLocked = false
    private(set) var secondsRemaining = 0
    /// Another app has Secure Event Input on, which hides key events from event taps.
    private(set) var isSecureInputActive = false
    /// Whether Kleyn has the Accessibility permission. Kept current by polling, so it
    /// updates as soon as the permission is granted or revoked in System Settings.
    private(set) var hasPermission = AXIsProcessTrusted()
    private(set) var errorMessage: String?

    @ObservationIgnored private var eventTap: CFMachPort?
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var lockTask: Task<Void, Never>?
    @ObservationIgnored private var permissionPollTask: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?

    init() {
        permissionPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let trusted = AXIsProcessTrusted()
                if trusted != hasPermission {
                    hasPermission = trusted
                }
            }
        }
    }

    func toggle() {
        isLocked ? unlock() : lock()
    }

    func lock() {
        guard !isLocked else { return }
        errorMessage = nil

        guard AXIsProcessTrusted() else {
            hasPermission = false
            // Adds Kleyn to the Accessibility list and shows the system prompt (only the first time).
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: keyboardTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            errorMessage = "macOS refused to start the keyboard lock. If Kleyn is already enabled in Accessibility settings, remove it from the list, add it again, then relaunch Kleyn."
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source

        // Keep App Nap from delaying the event tap or auto-unlock while the window is in the background.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Keyboard is locked")

        isLocked = true
        hasPermission = true
        startLockTask()
    }

    func unlock() {
        guard isLocked else { return }

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil

        lockTask?.cancel()
        lockTask = nil

        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil

        isLocked = false
        secondsRemaining = 0
        isSecureInputActive = false
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Private

    /// Runs while locked: drives the auto-unlock countdown (if enabled) and watches for Secure Event Input.
    private func startLockTask() {
        let deadline = autoUnlockEnabled ? ProcessInfo.processInfo.systemUptime + Self.autoUnlockInterval : nil
        lockTask = Task {
            while !Task.isCancelled {
                if let deadline {
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    if remaining <= 0 {
                        unlock()
                        return
                    }
                    secondsRemaining = Int(remaining.rounded(.up))
                }
                isSecureInputActive = IsSecureEventInputEnabled()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Called on the main run loop for every event matching `eventMask`. Returns true to drop the event.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if isLocked, let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return false
        case .keyDown, .keyUp, .flagsChanged:
            return isLocked
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp, .scrollWheel:
            // Modifiers held while wiping would otherwise turn clicks into Cmd-clicks,
            // Control-clicks into right clicks, and so on.
            if isLocked {
                event.flags.subtract(Self.modifierFlags)
            }
            return false
        default:
            // Volume, mute, brightness, keyboard backlight, media and eject keys.
            return isLocked
                && type.rawValue == Self.systemDefinedEventType
                && NSEvent(cgEvent: event)?.subtype.rawValue == Self.auxControlButtonsSubtype
        }
    }

    /// `NX_SYSDEFINED`, which has no `CGEventType` case.
    private static let systemDefinedEventType: UInt32 = 14
    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS`
    private static let auxControlButtonsSubtype: Int16 = 8

    private static let modifierFlags: CGEventFlags = [
        .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn, .maskHelp,
    ]

    private static let eventMask: CGEventMask = {
        let types: [UInt32] = [
            CGEventType.keyDown.rawValue,
            CGEventType.keyUp.rawValue,
            CGEventType.flagsChanged.rawValue,
            CGEventType.leftMouseDown.rawValue,
            CGEventType.leftMouseUp.rawValue,
            CGEventType.rightMouseDown.rawValue,
            CGEventType.rightMouseUp.rawValue,
            CGEventType.otherMouseDown.rawValue,
            CGEventType.otherMouseUp.rawValue,
            CGEventType.scrollWheel.rawValue,
            systemDefinedEventType,
        ]
        return types.reduce(0) { $0 | (1 << CGEventMask($1)) }
    }()
}

/// C callback for the event tap. The tap's run loop source is on the main run loop,
/// so it's safe to hop straight into the main actor.
private nonisolated func keyboardTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let shouldDrop = MainActor.assumeIsolated {
        Unmanaged<KeyboardLocker>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
    }
    return shouldDrop ? nil : Unmanaged.passUnretained(event)
}
