//
//  KeepAwake.swift
//  Kleyn
//

import AppKit
import IOKit.pwr_mgt
import Observation

/// Keeps the Mac from idle sleep until stopped, for a while, until a time, or while an app runs.
///
/// Holds IOKit power assertions, like `caffeinate` does. They belong to this process, so macOS
/// drops them as soon as Kleyn quits or crashes, and the Mac sleeps as usual again.
/// Needs no permission.
@Observable
final class KeepAwake {
    private static let displaySleepKey = "keepAwakeDisplaySleep"

    private(set) var session: KeepAwakeSession?
    /// What just happened, like "Time's up: your Mac can sleep again."
    private(set) var message = ""

    /// Let the display sleep while the Mac stays awake. Remembered across launches.
    /// A running session goes on with the new setting.
    var displaySleep = UserDefaults.standard.bool(forKey: displaySleepKey) {
        didSet {
            UserDefaults.standard.set(displaySleep, forKey: Self.displaySleepKey)
            if session != nil, !takeAssertions() {
                end(message: "macOS refused to keep the Mac awake.")
            }
        }
    }

    var isActive: Bool { session != nil }

    /// "Awake until 18:30", for the page and the menu bar.
    func statusText(now: Date = .now) -> String {
        guard let session else { return "Off: your Mac sleeps as usual" }
        return "Awake " + KeepAwakeRules.describe(session, now: now)
    }

    /// Called after a session ends: its time was up, its app quit, or it was stopped.
    @ObservationIgnored var onSessionEnded: (() -> Void)?

    @ObservationIgnored private var assertionIDs: [IOPMAssertionID] = []
    @ObservationIgnored private var endTask: Task<Void, Never>?
    @ObservationIgnored private var appObserver: NSObjectProtocol?

    // MARK: - Starting and stopping

    func startUntilStopped() {
        begin(KeepAwakeSession(startedAt: .now))
    }

    func start(minutes: Int) {
        let now = Date.now
        begin(KeepAwakeSession(startedAt: now, endsAt: now.addingTimeInterval(TimeInterval(minutes * 60)), minutes: minutes))
    }

    /// Starts a session until a typed time, or explains why the text isn't one.
    func start(untilTime text: String) {
        let now = Date.now
        guard let endsAt = KeepAwakeRules.parseClockTime(text, now: now) else {
            message = "\"\(text.trimmingCharacters(in: .whitespaces))\" isn't a time. Type one like 18:30 or 6:30 pm."
            return
        }
        begin(KeepAwakeSession(startedAt: now, endsAt: endsAt))
    }

    func start(whileRunning app: RunningApp) {
        begin(KeepAwakeSession(startedAt: .now, app: app))
    }

    func stop() {
        guard session != nil else { return }
        end(message: "Stopped: your Mac can sleep again.")
    }

    /// The apps with a Dock icon, for "While an app is open".
    func runningApps() -> [RunningApp] {
        KeepAwakeRules.appsToList(NSWorkspace.shared.runningApplications.map {
            KeepAwakeRules.AppCandidate(
                localizedName: $0.localizedName,
                bundleURL: $0.bundleURL,
                bundleIdentifier: $0.bundleIdentifier,
                pid: $0.processIdentifier,
                isRegular: $0.activationPolicy == .regular
            )
        })
    }

    // MARK: - Private

    /// Starts `newSession`, replacing the one running.
    private func begin(_ newSession: KeepAwakeSession) {
        clearSession()
        guard takeAssertions() else {
            message = "macOS refused to keep the Mac awake."
            return
        }
        session = newSession
        message = ""

        if let endsAt = newSession.endsAt {
            endTask = Task { [weak self] in
                // Checks the wall clock, so the end time holds even across a sleep (lid closed).
                while !Task.isCancelled {
                    if Date.now >= endsAt {
                        self?.end(message: "Time's up: your Mac can sleep again.")
                        return
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }

        if let app = newSession.app {
            appObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let quit = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard quit?.processIdentifier == app.pid else { return }
                MainActor.assumeIsolated {
                    self?.end(message: "\(app.name) quit: your Mac can sleep again.")
                }
            }
            // It may have quit while the list was open.
            if NSRunningApplication(processIdentifier: app.pid) == nil {
                end(message: "\(app.name) quit: your Mac can sleep again.")
            }
        }
    }

    private func end(message: String) {
        clearSession()
        self.message = message
        onSessionEnded?()
    }

    private func clearSession() {
        endTask?.cancel()
        endTask = nil
        if let appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appObserver)
        }
        appObserver = nil
        releaseAssertions()
        session = nil
    }

    /// Takes the assertions for the current display setting, replacing any held. False if macOS refused.
    private func takeAssertions() -> Bool {
        releaseAssertions()
        for assertion in KeepAwakeRules.assertions(displaySleep: displaySleep) {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                assertion.rawValue as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Kleyn: Keep Awake" as CFString,
                &id
            )
            guard result == kIOReturnSuccess else {
                releaseAssertions()
                return false
            }
            assertionIDs.append(id)
        }
        return true
    }

    private func releaseAssertions() {
        for id in assertionIDs {
            IOPMAssertionRelease(id)
        }
        assertionIDs = []
    }
}
