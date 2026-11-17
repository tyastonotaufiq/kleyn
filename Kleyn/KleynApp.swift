//
//  KleynApp.swift
//  Kleyn
//
//  Created by Tyastono Taufiq on 29/10/26.
//

import SwiftUI

@main
struct KleynApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var locker = KeyboardLocker()
    @State private var screenCleaner = ScreenCleaner()

    private var keepAwake: KeepAwake { appDelegate.keepAwake }

    var body: some Scene {
        Window("Kleyn", id: "main") {
            ContentView(locker: locker, screenCleaner: screenCleaner, keepAwake: keepAwake)
        }
        .windowResizability(.contentMinSize)

        // Shown only while Keep Awake is on, so it can be stopped after the window is closed.
        MenuBarExtra(
            "Keep Awake",
            systemImage: "cup.and.saucer.fill",
            isInserted: Binding(get: { keepAwake.isActive }, set: { _ in })
        ) {
            KeepAwakeMenu(keepAwake: keepAwake)
        }
    }
}

/// Owns Keep Awake, so it can decide whether closing the window quits Kleyn.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let keepAwake = KeepAwake()

    override init() {
        super.init()
        // If the window was closed while Keep Awake was on, Kleyn stayed for the menu bar
        // icon. Once the session ends, that icon is gone too, so quit as closing would have.
        keepAwake.onSessionEnded = {
            let hasWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
            if !hasWindow {
                NSApp.terminate(nil)
            }
        }
    }

    /// Closing the window quits Kleyn, unless Keep Awake is on: then Kleyn keeps running
    /// in the menu bar until the session ends or you stop it there.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !keepAwake.isActive
    }
}

/// The menu of the Keep Awake menu bar icon.
private struct KeepAwakeMenu: View {
    let keepAwake: KeepAwake
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(keepAwake.statusText())
        Divider()
        Button("Stop Keeping Awake", action: keepAwake.stop)
        Button("Open Kleyn") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Divider()
        Button("Quit Kleyn") {
            NSApplication.shared.terminate(nil)
        }
    }
}
