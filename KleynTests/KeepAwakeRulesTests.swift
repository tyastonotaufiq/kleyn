//
//  KeepAwakeRulesTests.swift
//  KleynTests
//
//  Ported from claude-mods/mac-caffeinater/tests/awake.test.ts.
//

import Foundation
import Testing
@testable import Kleyn

/// A fixed calendar, so the tests don't depend on this Mac's time zone.
private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Jakarta")!
    return calendar
}()

/// A time on 15 January 2026 (or `day`), in `calendar`'s time zone.
private func at(_ hour: Int, _ minute: Int, day: Int = 15) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 1, day: day, hour: hour, minute: minute))!
}

/// 14:00 on a fixed day.
private let now = at(14, 0)

@Suite("Power assertions")
struct AssertionTests {
    @Test("Keeps the display awake too, unless it may sleep")
    func displaySetting() {
        #expect(KeepAwakeRules.assertions(displaySleep: false) == [.preventSystemSleep, .preventDisplaySleep])
        #expect(KeepAwakeRules.assertions(displaySleep: true) == [.preventSystemSleep])
    }

    @Test("Uses IOKit's assertion types, as caffeinate -i and -d do")
    func assertionTypes() {
        #expect(KeepAwakeRules.Assertion.preventSystemSleep.rawValue == "PreventUserIdleSystemSleep")
        #expect(KeepAwakeRules.Assertion.preventDisplaySleep.rawValue == "PreventUserIdleDisplaySleep")
    }
}

@Suite("Running apps")
struct RunningAppsTests {
    private func app(
        _ name: String?, path: String?, bundleID: String?, pid: pid_t, regular: Bool
    ) -> KeepAwakeRules.AppCandidate {
        KeepAwakeRules.AppCandidate(
            localizedName: name,
            bundleURL: path.map { URL(fileURLWithPath: $0) },
            bundleIdentifier: bundleID,
            pid: pid,
            isRegular: regular
        )
    }

    @Test("Only apps with a Dock icon, named after their bundle, without Finder, sorted by name")
    func appsToList() {
        // The same processes as the mod's `lsappinfo list` sample.
        let candidates = [
            app("loginwindow", path: "/System/Library/CoreServices/loginwindow.app", bundleID: "com.apple.loginwindow", pid: 415, regular: false),
            app("Finder", path: "/System/Library/CoreServices/Finder.app", bundleID: "com.apple.finder", pid: 636, regular: true),
            app("Studio", path: "/Applications/Example Studio.app", bundleID: "com.example.studio", pid: 612, regular: true),
            app("Studio", path: "/Applications/Example Studio.app", bundleID: "com.example.studio", pid: 701, regular: true),
            app("Another App", path: "/Applications/Another App.app", bundleID: "com.example.another", pid: 480, regular: true),
            app("ExampleAgent", path: "/Applications/Example Studio.app/Contents/Library/ExampleAgent.app", bundleID: "com.example.agent", pid: 650, regular: false),
            app("exampled", path: "/usr/libexec/exampled", bundleID: nil, pid: 102, regular: false),
            app("example-emulator", path: "/Users/example/sdk/emulator/example-emulator", bundleID: nil, pid: 900, regular: true),
        ]
        #expect(KeepAwakeRules.appsToList(candidates) == [
            RunningApp(name: "Another App", pid: 480),
            RunningApp(name: "Example Studio", pid: 612),
            RunningApp(name: "example-emulator", pid: 900),
        ])
    }
}

@Suite("Times typed by the person")
struct ClockTimeTests {
    private func parse(_ text: String) -> Date? {
        KeepAwakeRules.parseClockTime(text, now: now, calendar: calendar)
    }

    @Test("24-hour and am/pm times, later today")
    func laterToday() {
        #expect(parse("18:30") == at(18, 30))
        #expect(parse("6:30 pm") == at(18, 30))
        #expect(parse("6PM") == at(18, 0))
        #expect(parse("18.05") == at(18, 5))
        #expect(parse("23") == at(23, 0))
    }

    @Test("A time already past today is tomorrow")
    func pastIsTomorrow() {
        #expect(parse("8:00") == at(8, 0, day: 16))
        #expect(parse("12 am") == at(0, 0, day: 16))
        #expect(parse("14:00") == at(14, 0, day: 16))
    }

    @Test("Anything else is not a time", arguments: ["", "soon", "24:00", "18:60", "13 pm", "0 am", "1h"])
    func notATime(_ text: String) {
        #expect(parse(text) == nil)
    }
}

@Suite("What a session says")
struct DescribeTests {
    @Test("Until a time today or tomorrow, while an app runs, or until stopped")
    func describe() {
        #expect(KeepAwakeRules.clockLabel(at(9, 5), now: now, calendar: calendar) == "09:05")
        #expect(KeepAwakeRules.describe(KeepAwakeSession(startedAt: now, endsAt: at(18, 30)), now: now, calendar: calendar) == "until 18:30")
        #expect(KeepAwakeRules.describe(KeepAwakeSession(startedAt: now, endsAt: at(8, 0, day: 16)), now: now, calendar: calendar) == "until tomorrow 08:00")
        #expect(KeepAwakeRules.describe(KeepAwakeSession(startedAt: now, app: RunningApp(name: "Example Studio", pid: 1)), now: now, calendar: calendar) == "while Example Studio runs")
        #expect(KeepAwakeRules.describe(KeepAwakeSession(startedAt: now), now: now, calendar: calendar) == "until you stop it")
    }
}
