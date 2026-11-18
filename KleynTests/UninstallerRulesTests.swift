//
//  UninstallerRulesTests.swift
//  KleynTests
//
//  Ported from claude-mods/mac-uninstaller/tests/uninstaller.test.ts. The findings,
//  du and osascript tests aren't ported: Kleyn doesn't use those. Dotfolders in home
//  (~/.vscode), which the mod allowed for Claude's findings, are never shown.
//

import Foundation
import Testing
@testable import Kleyn

private let H = "/Users/t"

private func place(_ rel: String) -> LeftoverPlace {
    UninstallerRules.places.first { $0.rel == rel }!
}

private let slack = InstalledApp(
    path: "/Applications/Slack.app", bundleID: "com.tinyspeck.slackmacgap", name: "Slack", version: "4.41", names: ["Slack"]
)
private let chrome = InstalledApp(
    path: "/Applications/Google Chrome.app", bundleID: "com.google.Chrome", name: "Google Chrome", version: "130", names: ["Chrome"]
)
private let canary = InstalledApp(
    path: "/Applications/Google Chrome Canary.app", bundleID: "com.google.Chrome.canary",
    name: "Google Chrome Canary", version: "132", names: ["Chrome Canary"]
)

private func children(_ items: [(String, String)]) -> [(path: String, place: LeftoverPlace)] {
    items.map { (H + "/" + $0.0, place($0.1)) }
}

@Suite("What may be shown in Finder")
struct RemovableTests {
    @Test("Apps in /Applications, ~/Applications, and one folder down")
    func apps() {
        #expect(UninstallerRules.isRemovableApp("/Applications/Slack.app", home: H))
        #expect(UninstallerRules.isRemovableApp(H + "/Applications/Tool.app", home: H))
        #expect(UninstallerRules.isRemovableApp("/Applications/Example Studio 2025/Example Studio 2025.app", home: H))
    }

    @Test("Never anything else as an app")
    func notApps() {
        #expect(!UninstallerRules.isRemovableApp("/Applications", home: H))
        #expect(!UninstallerRules.isRemovableApp("/Applications/Example Studio 2025", home: H))
        #expect(!UninstallerRules.isRemovableApp("/System/Applications/Notes.app", home: H))
        #expect(!UninstallerRules.isRemovableApp("/Applications/Xcode.app/Contents/Applications/Simulator.app", home: H))
        #expect(!UninstallerRules.isRemovableApp("/Applications/../System/Applications/Mail.app", home: H))
        #expect(!UninstallerRules.isRemovableApp(H + "/Downloads/Thing.app", home: H))
    }

    @Test("Leftovers directly inside the places apps write to")
    func leftovers() {
        #expect(UninstallerRules.isRemovableLeftover(H + "/Library/Caches/com.tinyspeck.slackmacgap", home: H))
        #expect(UninstallerRules.isRemovableLeftover(H + "/Library/Preferences/com.tinyspeck.slackmacgap.plist", home: H))
        #expect(UninstallerRules.isRemovableLeftover(H + "/Library/Preferences/ByHost/com.x.y.ABC.plist", home: H))
        #expect(UninstallerRules.isRemovableLeftover(H + "/Library/Containers/com.x.y", home: H))
    }

    @Test("Never the places themselves, deeper files, or keys and shell setup")
    func notLeftovers() {
        #expect(!UninstallerRules.isRemovableLeftover(H + "/Library/Caches", home: H))
        #expect(!UninstallerRules.isRemovableLeftover(H + "/Library/Preferences/ByHost", home: H))
        #expect(!UninstallerRules.isRemovableLeftover(H + "/Library/Caches/com.x.y/data", home: H))
        #expect(!UninstallerRules.isRemovableLeftover(H + "/Library/Keychains/login.keychain-db", home: H))
        #expect(!UninstallerRules.isRemovableLeftover(H + "/Library/Mail/V10", home: H))
        #expect(!UninstallerRules.isRemovableLeftover(H + "/Documents/thesis", home: H))
        #expect(!UninstallerRules.isRemovableLeftover(H + "/.ssh", home: H))
        #expect(!UninstallerRules.isRemovableLeftover(H + "/.zshrc", home: H))
        #expect(!UninstallerRules.isRemovableLeftover(H + "/.config", home: H))
        #expect(!UninstallerRules.isRemovableLeftover(H + "/Library/Caches/../Keychains", home: H))
        #expect(!UninstallerRules.isRemovableLeftover("/Library/Caches/com.x.y", home: H))
        #expect(!UninstallerRules.isRemovableLeftover("/Users/other/Library/Caches/com.x.y", home: H))
        #expect(!UninstallerRules.isRemovableLeftover(H + "/Library/Preferences/.GlobalPreferences.plist", home: H))
    }

    @Test("Dotfolders in home are never shown, unlike the mod, which allowed them for Claude's findings")
    func noDotfolders() {
        #expect(!UninstallerRules.isRemovableLeftover(H + "/.vscode", home: H))
        #expect(!UninstallerRules.isRemovableLeftover(H + "/.config/gh", home: H))
    }

    @Test("macOS apps are never offered")
    func systemApps() {
        #expect(UninstallerRules.isSystemApp(path: "/Applications/Safari.app", bundleID: "com.apple.Safari"))
        #expect(UninstallerRules.isSystemApp(path: "/System/Applications/Notes.app", bundleID: "com.apple.Notes"))
        #expect(!UninstallerRules.isSystemApp(path: "/Applications/Xcode.app", bundleID: "com.apple.dt.Xcode"))
    }
}

@Suite("Matching files to apps")
struct MatchingTests {
    @Test("Bundle IDs inside file names")
    func idsInNames() {
        #expect(UninstallerRules.ids(in: "com.x.y.plist") == ["com.x.y"])
        #expect(UninstallerRules.ids(in: "group.com.x.y") == ["group.com.x.y", "com.x.y"])
        #expect(UninstallerRules.ids(in: "ABCDE12345.com.x.y") == ["abcde12345.com.x.y", "com.x.y"])
    }

    @Test("Group and team prefixes come off in turn")
    func prefixes() {
        #expect(UninstallerRules.ids(in: "group.U5SR49N3PT.only.if.Amphetamine") == [
            "group.u5sr49n3pt.only.if.amphetamine",
            "u5sr49n3pt.only.if.amphetamine",
            "only.if.amphetamine",
        ])
        #expect(UninstallerRules.ids(in: "EXAMPLE123.group.com.example.app") == [
            "example123.group.com.example.app",
            "group.com.example.app",
            "com.example.app",
        ])
    }

    @Test("The longest installed ID owns a file")
    func owner() {
        let ids = [chrome.bundleID, canary.bundleID]
        #expect(UninstallerRules.owner(of: "com.google.Chrome", installedIDs: ids) == "com.google.chrome")
        #expect(UninstallerRules.owner(of: "com.google.Chrome.canary.plist", installedIDs: ids) == "com.google.chrome.canary")
        #expect(UninstallerRules.owner(of: "com.google.Chrome.helper", installedIDs: ids) == "com.google.chrome")
        #expect(UninstallerRules.owner(of: "com.google.Chromebook", installedIDs: ids) == nil)
    }

    @Test("By ID anywhere, by name only where apps use names")
    func idAndName() {
        let installed = [slack, chrome, canary]
        #expect(UninstallerRules.match("com.tinyspeck.slackmacgap", in: place("Library/Containers"), app: slack, installed: installed) == .id)
        #expect(UninstallerRules.match("com.tinyspeck.slackmacgap.savedState", in: place("Library/Saved Application State"), app: slack, installed: installed) == .id)
        #expect(UninstallerRules.match("Slack", in: place("Library/Application Support"), app: slack, installed: installed) == .name)
        #expect(UninstallerRules.match("Slack", in: place("Library/Containers"), app: slack, installed: installed) == nil)
        #expect(UninstallerRules.match("Slacker", in: place("Library/Application Support"), app: slack, installed: installed) == nil)
    }

    @Test("Chrome's files aren't Canary's, and a shared name belongs to nobody")
    func chromeAndCanary() {
        let installed = [chrome, canary]
        #expect(UninstallerRules.match("com.google.Chrome.canary", in: place("Library/Caches"), app: chrome, installed: installed) == nil)
        #expect(UninstallerRules.match("com.google.Chrome.canary", in: place("Library/Caches"), app: canary, installed: installed) == .id)
        var twin = slack
        twin.path = "/Applications/Slack Beta.app"
        twin.bundleID = "com.tinyspeck.beta"
        #expect(UninstallerRules.match("Slack", in: place("Library/Application Support"), app: slack, installed: [slack, twin]) == nil)
    }

    @Test("ID matches are marked; name matches and shared containers are not")
    func markedByDefault() {
        let rows = [
            Leftover(path: slack.path, place: "App", match: .app, reason: ""),
            Leftover(path: H + "/Library/Caches/com.tinyspeck.slackmacgap", place: "Cache", match: .id, reason: ""),
            Leftover(path: H + "/Library/Application Support/Slack", place: "App data", match: .name, reason: ""),
            Leftover(path: H + "/Library/Group Containers/X.com.tinyspeck", place: "Shared container", match: .id, reason: "", shared: true),
        ]
        #expect(UninstallerRules.markedByDefault(rows) == [slack.path, H + "/Library/Caches/com.tinyspeck.slackmacgap"])
    }

    @Test("Reasons")
    func reasons() {
        #expect(UninstallerRules.reason(place: place("Library/Group Containers"), match: .id).hasPrefix("Shared by apps"))
        #expect(UninstallerRules.reason(place: place("Library/Caches"), match: .name).hasPrefix("Matched by the app's name"))
        #expect(UninstallerRules.reason(place: place("Library/Caches"), match: .id) == "Matches the app's bundle ID")
    }
}

@Suite("Leftovers of removed apps")
struct OrphanTests {
    @Test("Grouped by ID, without Apple, installed apps or their developers")
    func grouped() {
        let found = UninstallerRules.orphans(in: children([
            ("Library/Caches/com.spotify.client", "Library/Caches"),
            ("Library/Preferences/com.spotify.client.plist", "Library/Preferences"),
            ("Library/Preferences/com.apple.finder.plist", "Library/Preferences"),
            ("Library/Preferences/com.google.Keystone.Agent.plist", "Library/Preferences"),
            ("Library/Caches/com.tinyspeck.slackmacgap", "Library/Caches"),
            ("Library/Application Support/Spotify", "Library/Application Support"),
        ]), installedIDs: [slack.bundleID, chrome.bundleID])
        #expect(found == [Orphan(
            bundleID: "com.spotify.client",
            paths: [H + "/Library/Caches/com.spotify.client", H + "/Library/Preferences/com.spotify.client.plist"],
            places: ["Cache", "Settings"]
        )])
    }

    @Test("A removed app's TEAMID.group container is its leftover")
    func teamGroup() {
        let found = UninstallerRules.orphans(in: children([
            ("Library/Group Containers/EXAMPLE123.group.com.example.app", "Library/Group Containers"),
            ("Library/Application Scripts/EXAMPLE123.group.com.example.app", "Library/Application Scripts"),
        ]), installedIDs: [])
        #expect(found.map(\.bundleID) == ["com.example.app"])
        #expect(found.first?.paths.count == 2)
    }

    @Test("Log files, cache names and Apple's Shortcuts aren't removed apps")
    func notApps() {
        let names = ["warp.log.old.1", "main.kts.compiled.cache", "is.workflow.shortcuts", "groups.com.apple.podcasts", "net.whatsapp.whatsapp"]
        let found = UninstallerRules.orphans(in: children(names.map { ("Library/Caches/" + $0, "Library/Caches") }), installedIDs: [])
        #expect(found.map(\.bundleID) == ["net.whatsapp.whatsapp"])
    }

    @Test("An app's helpers share its row")
    func helpers() {
        let found = UninstallerRules.orphans(in: children([
            ("Library/Containers/net.whatsapp.whatsapp.intents", "Library/Containers"),
            ("Library/Containers/net.whatsapp.whatsapp", "Library/Containers"),
            ("Library/Application Scripts/net.whatsapp.whatsapp.shared", "Library/Application Scripts"),
            ("Library/Containers/net.whatsapp.whatsappsmb", "Library/Containers"),
        ]), installedIDs: [])
        #expect(found == [
            Orphan(
                bundleID: "net.whatsapp.whatsapp",
                paths: [
                    H + "/Library/Containers/net.whatsapp.whatsapp",
                    H + "/Library/Application Scripts/net.whatsapp.whatsapp.shared",
                    H + "/Library/Containers/net.whatsapp.whatsapp.intents",
                ],
                places: ["Container", "App scripts"]
            ),
            Orphan(bundleID: "net.whatsapp.whatsappsmb", paths: [H + "/Library/Containers/net.whatsapp.whatsappsmb"], places: ["Container"]),
        ])
    }
}

@Suite("System extensions")
struct ExtensionTests {
    /// `systemextensionsctl list` as macOS 26 prints it.
    private let extensions = UninstallerRules.parseSystemExtensions([
        "4 extension(s)",
        "--- com.apple.system_extension.network_extension (Go to 'System Settings > General > Login Items & Extensions > Network Extensions' to modify these system extension(s))",
        "enabled\tactive\tteamID\tbundleID (version)\tname\t[state]",
        "*\t*\tSAMPLE1234\torg.sample.agent.nwextension (7.2.3/0822)\tprovider\t[activated enabled]",
        "\t*\tWIDGET1234\tnet.widget.client.extension (6.3.3-1121/1)\tWidget Extension\t[activated waiting for user]",
        "*\t*\tEXAMPLE123\tcom.example.app.extension (6.5.2/3624198.2610060731)\tExample Extension\t[activated enabled]",
        "\t\tEXAMPLE123\tcom.example.app.helper (6.4.0/2903266.2602091446)\tExample Helper\t[terminated waiting to uninstall on reboot]",
    ].joined(separator: "\n"))

    @Test("Parsed one per row, the header and notes skipped")
    func parsed() {
        #expect(extensions.map(\.bundleID) == [
            "org.sample.agent.nwextension", "net.widget.client.extension", "com.example.app.extension", "com.example.app.helper",
        ])
        #expect(extensions.map(\.name) == ["provider", "Widget Extension", "Example Extension", "Example Helper"])
        #expect(extensions.map(\.active) == [true, true, true, false])
        #expect(extensions.map(UninstallerRules.status(of:)) == [
            "still running", "still running", "still running", "removed when you restart",
        ])
    }

    @Test("Listed when no installed app owns them, nor one from the same developer")
    func stray() {
        let stray = UninstallerRules.strayExtensions(extensions, installedIDs: ["com.example.app", "net.widget.desktop"])
        #expect(stray.map(\.name) == ["provider"])
    }

    @Test("A removed app's running extension holds its containers")
    func running() {
        #expect(UninstallerRules.runningExtension(of: "com.example.app", in: extensions)?.name == "Example Extension")
        #expect(UninstallerRules.runningExtension(of: "com.example", in: extensions)?.name == "Example Extension")
        #expect(UninstallerRules.runningExtension(of: "com.spotify.client", in: extensions) == nil)
        #expect(UninstallerRules.isContainer(H + "/Library/Containers/com.example.app"))
        #expect(UninstallerRules.isContainer(H + "/Library/Group Containers/EXAMPLE123.group.com.example.app"))
        #expect(!UninstallerRules.isContainer(H + "/Library/Caches/com.example.app"))
        #expect(!UninstallerRules.isContainer(H + "/Library/Containers/com.example.app/Data"))
    }
}

@Suite("Apps and Finder")
struct AppTests {
    @Test("An Info.plist")
    func infoPlist() {
        let app = UninstallerRules.app(
            fromInfo: ["CFBundleIdentifier": "com.microsoft.VSCode", "CFBundleName": "Code", "CFBundleShortVersionString": "1.95.0"],
            path: "/Applications/Visual Studio Code.app"
        )
        #expect(app == InstalledApp(
            path: "/Applications/Visual Studio Code.app",
            bundleID: "com.microsoft.VSCode",
            name: "Visual Studio Code",
            version: "1.95.0",
            names: ["Code"]
        ))
        #expect(UninstallerRules.app(fromInfo: [:], path: "/Applications/X.app") == nil)
        #expect(UninstallerRules.app(fromInfo: ["CFBundleIdentifier": 42], path: "/Applications/X.app") == nil)
    }

    @Test("Search by name or bundle ID")
    func search() {
        #expect(UninstallerRules.matches(slack, query: "sla"))
        #expect(UninstallerRules.matches(slack, query: "tinyspeck"))
        #expect(!UninstallerRules.matches(slack, query: "zoom"))
        #expect(UninstallerRules.matches(slack, query: "  "))
        let code = InstalledApp(path: "/Applications/Visual Studio Code.app", bundleID: "com.microsoft.VSCode", name: "Code", version: "", names: [])
        #expect(UninstallerRules.matches(code, query: "visual"))
    }

    @Test("Names an app may use for its folders")
    func names() {
        #expect(UninstallerRules.names(of: chrome) == ["google chrome", "chrome"])
        let short = InstalledApp(path: "/Applications/Go.app", bundleID: "x.y.go", name: "Go", version: "", names: ["Go"])
        #expect(UninstallerRules.names(of: short) == [])
    }

    @Test("Finder shows the leftovers first, then the apps in front")
    func revealOrder() {
        #expect(UninstallerRules.revealBatches(["/Applications/Slack.app", H + "/Library/Caches/x", H + "/Library/Logs/Slack"]) == [
            [H + "/Library/Caches/x", H + "/Library/Logs/Slack"],
            ["/Applications/Slack.app"],
        ])
        #expect(UninstallerRules.revealBatches(["/Applications/Slack.app"]) == [["/Applications/Slack.app"]])
        #expect(UninstallerRules.revealBatches([]) == [])
    }
}
