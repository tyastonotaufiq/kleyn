//
//  ScreenCleaner.swift
//  Kleyn
//

import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// Covers every display with plain black or white so smudges and dust are easy to see.
///
/// Nothing is locked and no permission is needed: Esc ends it, and a click or Space switches
/// between black and white. It also ends if Kleyn stops being the active app, because Esc
/// would then go to another app while the screens stayed covered.
@Observable
final class ScreenCleaner {
    private(set) var isActive = false
    private(set) var isWhite = false
    /// Whether the instructions at the bottom of each screen are showing.
    private(set) var isHintVisible = false

    @ObservationIgnored private var windows: [CleaningWindow] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var hintTask: Task<Void, Never>?

    func start() {
        guard !isActive else { return }
        isActive = true
        isWhite = false

        NSApp.activate()
        showWindows()

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            },
            // Cover displays that are connected, disconnected or rearranged while cleaning.
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isActive else { return }
                    self.closeWindows()
                    self.showWindows()
                }
            },
        ]

        showHint()
    }

    func stop() {
        guard isActive else { return }
        isActive = false

        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        hintTask?.cancel()
        hintTask = nil
        isHintVisible = false

        closeWindows()
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    func toggleColor() {
        guard isActive else { return }
        isWhite.toggle()
        for window in windows {
            window.backgroundColor = isWhite ? .white : .black
        }
        showHint()
    }

    // MARK: - Private

    private func showWindows() {
        windows = NSScreen.screens.map(makeWindow)
        windows.forEach { $0.orderFrontRegardless() }
        // Key events go to one window; the one on the main screen is as good as any.
        let keyWindow = windows.first { $0.screen == NSScreen.main } ?? windows.first
        keyWindow?.makeKeyAndOrderFront(nil)
    }

    private func closeWindows() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows = []
    }

    private func makeWindow(for screen: NSScreen) -> CleaningWindow {
        let window = CleaningWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.cleaner = self
        window.isReleasedWhenClosed = false
        // Above the menu bar and Dock.
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.backgroundColor = isWhite ? .white : .black
        window.hasShadow = false
        window.contentView = NSHostingView(rootView: CleaningView(cleaner: self))
        window.setFrame(screen.frame, display: true)
        return window
    }

    /// Shows the instructions for a few seconds, then fades them out. Hides the cursor too.
    private func showHint() {
        NSCursor.setHiddenUntilMouseMoves(true)
        isHintVisible = true
        hintTask?.cancel()
        hintTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            isHintVisible = false
        }
    }

    /// Handles input for all of the cleaning windows.
    fileprivate func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown:
            // Let ⌘Q and other menu shortcuts through.
            if event.modifierFlags.contains(.command) { return false }
            switch Int(event.keyCode) {
            case kVK_Escape: stop()
            case kVK_Space: if !event.isARepeat { toggleColor() }
            default: break   // Ignore stray keys silently, without a beep.
            }
            return true
        case .keyUp:
            return !event.modifierFlags.contains(.command)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            toggleColor()
            return true
        default:
            return false
        }
    }
}

/// A borderless full-screen window that can take key events.
private final class CleaningWindow: NSWindow {
    weak var cleaner: ScreenCleaner?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if cleaner?.handle(event) == true { return }
        super.sendEvent(event)
    }
}

private struct CleaningView: View {
    let cleaner: ScreenCleaner

    var body: some View {
        (cleaner.isWhite ? Color.white : Color.black)
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                Text("Click or press Space to switch to \(cleaner.isWhite ? "black" : "white")  ·  Press Esc to finish")
                    .font(.title3)
                    .foregroundStyle(.gray)
                    .padding(.bottom, 80)
                    .opacity(cleaner.isHintVisible ? 1 : 0)
                    .animation(.easeOut(duration: 0.6), value: cleaner.isHintVisible)
            }
    }
}
