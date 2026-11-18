//
//  CleanerRulesTests.swift
//  KleynTests
//
//  Ported from claude-mods/mac-cleaner/tests/cleaner.test.ts. Sizes count as Finder
//  does (1 MB = 1,000,000 bytes). The du, df, findings and AppleScript tests aren't
//  ported: Kleyn doesn't use those.
//

import Foundation
import Testing
@testable import Kleyn

private let H = "/Users/t"
private let MB: Int64 = 1_000_000
/// A fixed locale, so the size labels don't depend on this Mac's settings.
private let en = Locale(identifier: "en_US")

private func item(
    _ path: String, _ size: Int64, category: String = "", risk: CleanRisk = .safe, reason: String = ""
) -> CleanItem {
    CleanItem(path: path, size: size, category: category, risk: risk, reason: reason)
}

@Suite("What may be trashed")
struct TrashableTests {
    @Test("Caches, build output and things inside Downloads")
    func allowed() {
        #expect(CleanerRules.isTrashable(H + "/Library/Caches/com.spotify.client", home: H))
        #expect(CleanerRules.isTrashable(H + "/Library/Developer/Xcode/DerivedData", home: H))
        #expect(CleanerRules.isTrashable(H + "/.gradle/caches", home: H))
        #expect(CleanerRules.isTrashable(H + "/Downloads/big.dmg", home: H))
    }

    @Test("Never the home folder, top-level folders, or parents of protected places")
    func topLevel() {
        #expect(!CleanerRules.isTrashable(H, home: H))
        #expect(!CleanerRules.isTrashable(H + "/Downloads", home: H))
        #expect(!CleanerRules.isTrashable(H + "/Library", home: H))
        #expect(!CleanerRules.isTrashable(H + "/Library/Caches", home: H))
        #expect(!CleanerRules.isTrashable(H + "/.gradle", home: H))
    }

    @Test("A file directly in home only when the caller checked it is one, and never a hidden one")
    func filesInHome() {
        #expect(!CleanerRules.isTrashable(H + "/java_error_in_studio.hprof", home: H))
        #expect(CleanerRules.isTrashable(H + "/java_error_in_studio.hprof", home: H, isFile: true))
        #expect(!CleanerRules.isTrashable(H + "/.zshrc", home: H, isFile: true))
        #expect(!CleanerRules.isTrashable(H + "/.Trash", home: H, isFile: true))
    }

    @Test("Never iCloud, Mail, Photos, keys or anything outside home")
    func protected() {
        #expect(!CleanerRules.isTrashable(H + "/Library/Mobile Documents/com~apple~CloudDocs/x", home: H))
        #expect(!CleanerRules.isTrashable(H + "/Library/Mail/V10", home: H))
        #expect(!CleanerRules.isTrashable(H + "/Pictures/Photos Library.photoslibrary", home: H))
        #expect(!CleanerRules.isTrashable(H + "/Library/Keychains/login.keychain-db", home: H))
        #expect(!CleanerRules.isTrashable(H + "/.ssh/id_ed25519", home: H))
        #expect(!CleanerRules.isTrashable(H + "/Library/Containers/com.docker.docker", home: H))
        #expect(!CleanerRules.isTrashable("/System/Library/Caches", home: H))
        #expect(!CleanerRules.isTrashable("/Users/other/Library/Caches/x", home: H))
        #expect(!CleanerRules.isTrashable(H + "x/Library/Caches/y", home: H))
        #expect(!CleanerRules.isTrashable(H + "/Library/Caches/../Keychains", home: H))
    }

    @Test("Protected places are refused whatever their case, as the Mac's disk ignores it")
    func ignoresCase() {
        #expect(!CleanerRules.isTrashable(H + "/library/keychains/login.keychain-db", home: H))
        #expect(!CleanerRules.isTrashable(H + "/LIBRARY/CACHES", home: H))
        #expect(!CleanerRules.isTrashable(H + "/.SSH/id_ed25519", home: H))
    }

    @Test("Repeated and trailing slashes don't get around the rules")
    func slashes() {
        #expect(Paths.clean(H + "//Library///Logs/") == H + "/Library/Logs")
        #expect(!CleanerRules.isTrashable(H + "//Library/Caches/", home: H))
        #expect(!CleanerRules.isTrashable(H + "/Downloads/", home: H + "/"))
    }

    @Test("The scan leaves out the Music app's caches, which make macOS ask for Media & Apple Music access")
    func musicCaches() throws {
        let caches = try #require(CleanerRules.targets.first { $0.rel == "Library/Caches" })
        #expect(!caches.includes("com.apple.Music"))
        #expect(!caches.includes("com.apple.AMPLibraryAgent"))
        #expect(!caches.includes("com.apple.iTunes"))
        #expect(!caches.includes("com.apple.itunescloudd"))
        #expect(!caches.includes("com.apple.iTunesCloud"))
        #expect(caches.includes("com.apple.python"))
        #expect(caches.includes("Google"))

        let dumps = try #require(CleanerRules.targets.first { $0.category == "Java heap dumps" })
        #expect(dumps.includes("java_error_in_studio.hprof"))
        #expect(!dumps.includes("Music"))
    }

    @Test("Every folder the scan measures as a whole may be trashed")
    func wholeTargets() {
        for target in CleanerRules.targets where !target.expand {
            #expect(CleanerRules.isTrashable(H + "/" + target.rel, home: H), "\(target.rel)")
        }
    }
}

@Suite("Rows")
struct RowTests {
    @Test("One row per path, nested rows dropped, small rows hidden, safe first")
    func merging() {
        let scan = [
            item(H + "/Library/Logs", 50 * MB, category: "Logs"),
            item(H + "/.gradle/caches", 900 * MB, category: "Gradle"),
            item(H + "/.npm/_cacache", 1 * MB, category: "npm"),
            item(H + "/.gradle/caches/modules-2", 800 * MB, category: "x"),
            item(H + "/Downloads/a.dmg", 2000 * MB, category: "Downloads", risk: .review),
        ]
        #expect(CleanerRules.rows(from: scan).map(\.path) == [
            H + "/.gradle/caches",
            H + "/Library/Logs",
            H + "/Downloads/a.dmg",
        ])
    }

    @Test("The last result for a path wins")
    func samePath() {
        let rows = CleanerRules.rows(from: [item(H + "/Library/Logs", 20 * MB), item(H + "/Library/Logs", 30 * MB)])
        #expect(rows.map(\.size) == [30 * MB])
    }

    @Test("Small rows are summed per category into one row once they add up")
    func summaryRows() {
        let cache = { (name: String, mb: Int64) in
            item(H + "/Library/Caches/" + name, mb * MB, category: "App caches", reason: "Cache files.")
        }
        let scan = [
            cache("big", 500),
            cache("a", 4),
            cache("b", 3),
            cache("c", 4),
            cache("empty", 0),
            item(H + "/Library/Logs", 2 * MB, category: "Logs"),
        ]
        let rows = CleanerRules.rows(from: scan)
        // The big cache and one summary of 11 MB; 2 MB of logs alone stays hidden.
        #expect(rows.map(\.path) == [H + "/Library/Caches/big", "small:App caches"])
        let summary = rows[1]
        #expect(summary.isSummary)
        #expect(summary.size == 11 * MB)
        #expect(summary.risk == .safe)
        #expect(summary.reason == "Cache files.")
        #expect(CleanerRules.rowPaths(summary) == [H + "/Library/Caches/a", H + "/Library/Caches/c", H + "/Library/Caches/b"])
        #expect(CleanerRules.rowLabel(summary, home: H, locale: en) == "3 items under 10 MB in ~/Library/Caches")
    }

    @Test("A summary row needs review if any of its items does, and drops differing reasons")
    func mixedSummary() {
        let rows = CleanerRules.rows(from: [
            item(H + "/.android/avd/a.avd", 6 * MB, category: "Emulators", risk: .safe, reason: "One"),
            item(H + "/.android/avd/b.avd", 6 * MB, category: "Emulators", risk: .review, reason: "Two"),
        ])
        #expect(rows.count == 1)
        #expect(rows[0].risk == .review)
        #expect(rows[0].reason == "")
    }

    @Test("Common folder of a summary row")
    func commonFolder() {
        #expect(CleanerRules.commonFolder([H + "/.gradle/caches/x", H + "/.gradle/wrapper/dists"]) == H + "/.gradle")
        #expect(CleanerRules.commonFolder([H + "/Library/Caches/a"]) == H + "/Library/Caches")
        #expect(CleanerRules.rowLabel(item(H + "/Library/Logs", 1), home: H) == "~/Library/Logs")
    }
}
