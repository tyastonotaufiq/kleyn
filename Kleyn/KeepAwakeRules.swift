//
//  KeepAwakeRules.swift
//  Kleyn
//
//  The parts of Keep Awake that need no I/O, kept apart so they can be tested.
//  Ported from claude-mods/mac-caffeinater/hooks/awake.ts.
//

import Foundation

/// An app the Mac can stay awake for, until it quits.
nonisolated struct RunningApp: Equatable, Hashable, Identifiable, Sendable {
    let name: String
    let pid: pid_t
    var id: pid_t { pid }
}

/// A Keep Awake session: until `endsAt`, while `app` runs, or with neither, until stopped.
/// `minutes` is the preset it was started with, and is nil for a typed time.
nonisolated struct KeepAwakeSession: Equatable, Sendable {
    var startedAt: Date
    var endsAt: Date?
    var minutes: Int?
    var app: RunningApp?
}

nonisolated enum KeepAwakeRules {
    static let presets: [(label: String, minutes: Int)] = [
        ("15 min", 15),
        ("30 min", 30),
        ("1 hour", 60),
        ("2 hours", 120),
        ("4 hours", 240),
    ]

    /// The macOS power assertions a session holds. The raw values are IOKit's assertion types.
    enum Assertion: String, Equatable, Sendable {
        case preventSystemSleep = "PreventUserIdleSystemSleep"
        case preventDisplaySleep = "PreventUserIdleDisplaySleep"
    }

    /// Like `caffeinate -i`, plus `-d` unless the display may sleep.
    static func assertions(displaySleep: Bool) -> [Assertion] {
        displaySleep ? [.preventSystemSleep] : [.preventSystemSleep, .preventDisplaySleep]
    }

    /// What's known about a running process, as `NSWorkspace` reports it.
    struct AppCandidate: Sendable {
        var localizedName: String?
        var bundleURL: URL?
        var bundleIdentifier: String?
        var pid: pid_t
        /// Whether it has a Dock icon (`NSApplication.ActivationPolicy.regular`).
        var isRegular: Bool
    }

    /// The apps a person runs: those with a Dock icon, so menu bar and background agents
    /// are left out, and not Finder, which always runs. Named after the `.app` bundle
    /// ("Visual Studio Code", not "Code"), one per name (the oldest process), sorted by name.
    static func appsToList(_ candidates: [AppCandidate]) -> [RunningApp] {
        var byName: [String: RunningApp] = [:]
        for candidate in candidates where candidate.isRegular && candidate.bundleIdentifier != "com.apple.finder" {
            let name: String
            if let url = candidate.bundleURL, url.pathExtension == "app" {
                name = url.deletingPathExtension().lastPathComponent
            } else if let localizedName = candidate.localizedName {
                name = localizedName
            } else {
                continue
            }
            if let seen = byName[name], seen.pid <= candidate.pid { continue }
            byName[name] = RunningApp(name: name, pid: candidate.pid)
        }
        return byName.values.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private static let clockPattern = try! Regex(#"^\s*(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm)?\s*$"#).ignoresCase()

    /// The next time of day matching `text` ("18:30", "6:30 pm", "6pm", "18"), after `now`;
    /// nil when it isn't a time.
    static func parseClockTime(_ text: String, now: Date, calendar: Calendar = .current) -> Date? {
        guard let match = text.wholeMatch(of: clockPattern),
              let hourText = match.output[1].substring,
              var hours = Int(hourText)
        else { return nil }
        let minutes = match.output[2].substring.flatMap { Int($0) } ?? 0
        let half = match.output[3].substring?.lowercased()

        guard minutes <= 59 else { return nil }
        if let half {
            guard (1...12).contains(hours) else { return nil }
            hours = hours % 12 + (half == "pm" ? 12 : 0)
        } else if hours > 23 {
            return nil
        }

        guard let today = calendar.date(bySettingHour: hours, minute: minutes, second: 0, of: now) else { return nil }
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }

    /// "18:30", or "tomorrow 08:00" when `at` isn't on the same day as `now`.
    static func clockLabel(_ at: Date, now: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: at)
        let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        return calendar.isDate(at, inSameDayAs: now) ? time : "tomorrow " + time
    }

    /// What a session does, for the page and the menu bar: "until 18:30".
    static func describe(_ session: KeepAwakeSession, now: Date, calendar: Calendar = .current) -> String {
        if let app = session.app { return "while \(app.name) runs" }
        if let endsAt = session.endsAt { return "until " + clockLabel(endsAt, now: now, calendar: calendar) }
        return "until you stop it"
    }
}
