//
//  UninstallerRules.swift
//  Kleyn
//
//  The parts of the Uninstaller that need no I/O, kept apart so they can be tested:
//  where apps leave files, how a file is matched to an app, and what may be shown
//  in Finder to be moved to the Trash.
//  Ported from claude-mods/mac-uninstaller/hooks/uninstaller.ts.
//

import Foundation

/// An app in /Applications or ~/Applications, from its Info.plist.
nonisolated struct InstalledApp: Equatable, Hashable, Identifiable, Sendable {
    var path: String
    var bundleID: String
    var name: String
    var version: String
    /// CFBundleName and the like: names the app may use for its folders.
    var names: [String]

    var id: String { path }
}

/// A folder in ~/Library where apps leave files, one per app or per bundle ID.
nonisolated struct LeftoverPlace: Equatable, Sendable {
    var rel: String
    /// Where it is, in words: App data, Cache, Container…
    var label: String
    /// Apps here often name their folder after themselves, not their bundle ID.
    var byName = false
    /// Folders here are shared by a developer's apps (Office's UBF8T346G9.Office).
    var shared = false
}

/// How a row belongs to the app: it is the app, or it's named after its bundle ID or its name.
nonisolated enum LeftoverMatch: Equatable, Sendable {
    case app, id, name
}

/// A row on an app's page: the app itself, or a file it left.
nonisolated struct Leftover: Equatable, Identifiable, Sendable {
    var path: String
    var place: String
    var match: LeftoverMatch
    var reason: String
    /// In a folder other apps from the same developer may use too.
    var shared = false

    var id: String { path }
    /// Measuring it makes macOS ask for access to other apps' data, so it waits for a click.
    var isContainer: Bool { UninstallerRules.isContainer(path) }
}

/// What an app that's already gone left behind, under one bundle ID.
nonisolated struct Orphan: Equatable, Identifiable, Sendable {
    var bundleID: String
    var paths: [String]
    var places: [String]
    /// The name of a system extension of this app that's still running: its containers can't be moved.
    var runningExtension: String?

    var id: String { bundleID }
}

/// A row of `systemextensionsctl list`.
nonisolated struct SystemExtension: Equatable, Identifiable, Sendable {
    var bundleID: String
    var teamID: String
    var name: String
    /// "activated enabled", "terminated waiting to uninstall on reboot"…
    var state: String
    var active: Bool

    var id: String { bundleID }
}

nonisolated enum UninstallerRules {
    static let places: [LeftoverPlace] = [
        LeftoverPlace(rel: "Library/Application Support", label: "App data", byName: true),
        LeftoverPlace(rel: "Library/Caches", label: "Cache", byName: true),
        LeftoverPlace(rel: "Library/Logs", label: "Logs", byName: true),
        LeftoverPlace(rel: "Library/Preferences", label: "Settings"),
        LeftoverPlace(rel: "Library/Preferences/ByHost", label: "Settings"),
        LeftoverPlace(rel: "Library/Saved Application State", label: "Window state"),
        LeftoverPlace(rel: "Library/HTTPStorages", label: "Web data"),
        LeftoverPlace(rel: "Library/WebKit", label: "Web data"),
        LeftoverPlace(rel: "Library/Cookies", label: "Cookies"),
        LeftoverPlace(rel: "Library/Containers", label: "Container"),
        LeftoverPlace(rel: "Library/Group Containers", label: "Shared container", shared: true),
        LeftoverPlace(rel: "Library/Application Scripts", label: "App scripts"),
        LeftoverPlace(rel: "Library/LaunchAgents", label: "Starts at login"),
    ]

    /// Where apps are installed.
    static func appFolders(home: String) -> [String] {
        ["/Applications", cleanPath(home) + "/Applications"]
    }

    /// Apps that are part of macOS even though they sit in /Applications.
    private static let systemAppIDs = ["com.apple.Safari"]

    /// Children of a place that are never an app's leftovers.
    private static let keptChildren = ["ByHost", ".GlobalPreferences.plist", "com.apple.loginwindow.plist"]

    private static let suffixes = [".plist", ".savedState", ".binarycookies", ".lockfile"]

    /// A developer team ID before a group container's name: U5SR49N3PT.only.if.Amphetamine.
    nonisolated(unsafe) private static let teamPrefix = try! Regex(#"^(?=[a-z]*\d)[a-z0-9]{10}\."#).ignoresCase()

    /// A reverse-DNS bundle ID, starting with a domain ending (com, de, io, info…), so log and
    /// cache names like warp.log.old.1 or main.kts.compiled.cache don't count.
    nonisolated(unsafe) private static let looksLikeID = try! Regex(
        #"^([a-z]{2,3}|info|tech|cloud|studio|design|games|software)\.[a-z0-9_-]+\.[a-z0-9_.-]+$"#
    ).ignoresCase()

    /// IDs that belong to macOS itself, even outside com.apple (Shortcuts is is.workflow).
    private static let applePrefixes = ["com.apple.", "is.workflow."]

    // MARK: - Paths

    /// Collapses repeated slashes and strips a trailing one.
    static func cleanPath(_ path: String) -> String {
        CleanerRules.cleanPath(path)
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash > path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    private static func lastComponent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// "Slack" for /Applications/Slack.app.
    private static func appFileName(_ path: String) -> String {
        let file = lastComponent(path)
        return file.hasSuffix(".app") ? String(file.dropLast(4)) : file
    }

    private static func hasDotSegments(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
            .contains { $0 == ".." || $0 == "." || $0.isEmpty }
    }

    // MARK: - What may be shown

    /// Whether an app is part of macOS and can't be uninstalled.
    static func isSystemApp(path: String, bundleID: String) -> Bool {
        path.hasPrefix("/System/") || systemAppIDs.contains(bundleID)
    }

    /// Whether `path` is an app bundle Kleyn may show to be moved to the Trash: a `.app` in
    /// /Applications or ~/Applications, or one folder below (apps installed in a folder of their own).
    static func isRemovableApp(_ path: String, home: String) -> Bool {
        let path = cleanPath(path)
        guard path.hasSuffix(".app"), !hasDotSegments(path), !path.hasPrefix("/System/") else { return false }
        let folder = parent(of: path)
        return appFolders(home: home).contains { root in
            folder == root || (parent(of: folder) == root && !folder.hasSuffix(".app"))
        }
    }

    /// Whether `path` may be shown to be moved to the Trash as an app's leftover: directly
    /// inside one of the places, never the place itself, and never one of the kept children.
    ///
    /// Narrower than the mod's rule, which also allowed dotfolders in home (~/.vscode)
    /// for Claude's findings. Kleyn has no findings, so nothing outside the places is ever shown.
    static func isRemovableLeftover(_ path: String, home: String) -> Bool {
        let path = cleanPath(path)
        let home = cleanPath(home)
        guard !home.isEmpty, home != "/", path.hasPrefix(home + "/"), !hasDotSegments(path) else { return false }
        let rel = String(path.dropFirst(home.count + 1))
        guard let slash = rel.lastIndex(of: "/") else { return false }
        let folder = String(rel[..<slash])
        let name = String(rel[rel.index(after: slash)...])
        if keptChildren.contains(name) { return false }
        return places.contains { $0.rel == folder }
    }

    /// Whether `path` is an app's container, which macOS protects: measuring one asks for access
    /// to other apps' data, and while the app's extension runs, it can't be moved.
    static func isContainer(_ path: String) -> Bool {
        let folder = parent(of: cleanPath(path))
        return folder.hasSuffix("/Library/Containers") || folder.hasSuffix("/Library/Group Containers")
    }

    // MARK: - Matching files to apps

    /// The bundle IDs a file or folder name may stand for, lowercased.
    static func ids(in name: String) -> [String] {
        var base = name
        for suffix in suffixes where base.hasSuffix(suffix) {
            base.removeLast(suffix.count)
        }
        var out = [base]
        // Either comes first: group.TEAMID.x or TEAMID.group.x
        if base.hasPrefix("group.") {
            base = String(base.dropFirst("group.".count))
            out.append(base)
        }
        if let match = base.prefixMatch(of: teamPrefix) {
            base = String(base[match.range.upperBound...])
            out.append(base)
        }
        if base.hasPrefix("group.") {
            out.append(String(base.dropFirst("group.".count)))
        }
        return out.map { $0.lowercased() }
    }

    /// Whether `candidate` is the bundle ID `id` or one of its helpers (`id.helper`).
    private static func isIDOrChild(_ candidate: String, _ id: String) -> Bool {
        candidate == id || candidate.hasPrefix(id + ".")
    }

    /// The installed app a leftover belongs to by bundle ID, lowercased: the longest installed ID
    /// that `name` is or extends, so com.google.Chrome.canary goes to Canary when both are installed.
    static func owner(of name: String, installedIDs: [String]) -> String? {
        var best: String?
        for candidate in ids(in: name) {
            for id in installedIDs {
                let id = id.lowercased()
                if isIDOrChild(candidate, id) && id.count > (best?.count ?? 0) {
                    best = id
                }
            }
        }
        return best
    }

    /// The names an app may use for its folders: file name, bundle name, display name.
    static func names(of app: InstalledApp) -> [String] {
        let file = appFileName(app.path)
        var seen: [String] = []
        for name in [file] + app.names {
            let name = name.trimmingCharacters(in: .whitespaces).lowercased()
            if name.count >= 3 && !seen.contains(name) {
                seen.append(name)
            }
        }
        return seen
    }

    /// How a child of `place` belongs to `app`: by bundle ID (sure), by name (worth a look),
    /// or not at all. A name another installed app also uses doesn't count.
    static func match(_ name: String, in place: LeftoverPlace, app: InstalledApp, installed: [InstalledApp]) -> LeftoverMatch? {
        if keptChildren.contains(name) { return nil }
        if let owner = owner(of: name, installedIDs: installed.map(\.bundleID)) {
            return owner == app.bundleID.lowercased() ? .id : nil
        }
        guard place.byName else { return nil }
        let lowercased = name.lowercased()
        guard names(of: app).contains(lowercased) else { return nil }
        let others = installed.filter { $0.path != app.path }.flatMap(names(of:))
        return others.contains(lowercased) ? nil : .name
    }

    /// One line on why a leftover is listed, shown under its row.
    static func reason(place: LeftoverPlace, match: LeftoverMatch) -> String {
        if place.shared { return "Shared by apps from the same developer; check before removing" }
        if match == .name { return "Matched by the app's name, not its ID; check it's this app's" }
        return "Matches the app's bundle ID"
    }

    /// The rows marked when an app is opened: the app and what matches its bundle ID.
    static func markedByDefault(_ rows: [Leftover]) -> Set<String> {
        Set(rows.filter { $0.match == .app || ($0.match == .id && !$0.shared) }.map(\.path))
    }

    // MARK: - Leftovers of removed apps

    /// `com.google` for com.google.Chrome.
    static func vendor(of id: String) -> String {
        id.lowercased().split(separator: ".", omittingEmptySubsequences: false).prefix(2).joined(separator: ".")
    }

    /// Groups the bundle-ID-named children of each place whose app is gone into one orphan per ID.
    /// Apple's own, anything an installed app owns, and anything from a developer that still has
    /// an app installed (com.google.Keystone while Chrome is there) are left out. An app's helpers
    /// (com.x.app.helper) go in the app's row (com.x.app).
    static func orphans(in children: [(path: String, place: LeftoverPlace)], installedIDs: [String]) -> [Orphan] {
        let installed = installedIDs.map { $0.lowercased() }
        let vendors = Set(installed.map(vendor(of:)))
        var order: [String] = []
        var byID: [String: Orphan] = [:]

        for (path, place) in children {
            let name = lastComponent(path)
            if keptChildren.contains(name) { continue }
            let candidates = ids(in: name)
            guard let id = candidates.last,
                  id.wholeMatch(of: looksLikeID) != nil,
                  !applePrefixes.contains(where: { id.hasPrefix($0) })
            else { continue }
            if candidates.contains(where: { c in installed.contains { isIDOrChild(c, $0) || $0.hasPrefix(c + ".") } }) { continue }
            if vendors.contains(vendor(of: id)) { continue }

            var orphan = byID[id] ?? Orphan(bundleID: id, paths: [], places: [])
            if byID[id] == nil { order.append(id) }
            orphan.paths.append(path)
            if !orphan.places.contains(place.label) { orphan.places.append(place.label) }
            byID[id] = orphan
        }

        // Shortest IDs first, so an app's row exists before its helpers look for it.
        let rows = order.enumerated()
            .sorted { a, b in a.element.count != b.element.count ? a.element.count < b.element.count : a.offset < b.offset }
            .compactMap { byID[$0.element] }
        var merged: [Orphan] = []
        for orphan in rows {
            if let index = merged.firstIndex(where: { orphan.bundleID.hasPrefix($0.bundleID + ".") }) {
                merged[index].paths += orphan.paths
                for place in orphan.places where !merged[index].places.contains(place) {
                    merged[index].places.append(place)
                }
            } else {
                merged.append(orphan)
            }
        }
        return merged
    }

    // MARK: - System extensions

    /// Parses `systemextensionsctl list`. Each extension is a tab-separated row:
    /// enabled (*), active (*), team ID, `bundle.id (version)`, name, `[state]`.
    static func parseSystemExtensions(_ output: String) -> [SystemExtension] {
        var list: [SystemExtension] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6 else { continue }
            let (active, teamID, idVersion, name) = (fields[1], fields[2], fields[3], fields[4])
            let state = fields[5].trimmingCharacters(in: .whitespaces)
            guard let space = idVersion.firstIndex(of: " "),
                  idVersion[space...].hasPrefix(" ("),
                  state.hasPrefix("["), state.hasSuffix("]"),
                  teamID.count == 10 && teamID.allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) })
            else { continue }
            list.append(SystemExtension(
                bundleID: String(idVersion[..<space]),
                teamID: teamID,
                name: name,
                state: String(state.dropFirst().dropLast()),
                active: active.trimmingCharacters(in: .whitespaces) == "*"
            ))
        }
        return list
    }

    /// System extensions whose app is gone: no installed app's ID is theirs or a prefix of theirs,
    /// and no installed app comes from the same developer (an extension's ID may not start with its app's).
    static func strayExtensions(_ extensions: [SystemExtension], installedIDs: [String]) -> [SystemExtension] {
        let ids = installedIDs.map { $0.lowercased() }
        let vendors = Set(ids.map(vendor(of:)))
        return extensions.filter { ext in
            let id = ext.bundleID.lowercased()
            if applePrefixes.contains(where: { id.hasPrefix($0) }) { return false }
            return !ids.contains { isIDOrChild(id, $0) } && !vendors.contains(vendor(of: id))
        }
    }

    /// The running extension of the app with bundle ID `id` (com.example.app.extension for com.example.app).
    static func runningExtension(of id: String, in extensions: [SystemExtension]) -> SystemExtension? {
        let id = id.lowercased()
        return extensions.first { $0.active && isIDOrChild($0.bundleID.lowercased(), id) }
    }

    /// An extension's state in words.
    static func status(of ext: SystemExtension) -> String {
        if ext.state.contains("uninstall") { return "removed when you restart" }
        return ext.active ? "still running" : ext.state
    }

    // MARK: - Apps

    /// An app from its Info.plist, or nil when it has no bundle ID.
    static func app(fromInfo info: [String: Any], path: String) -> InstalledApp? {
        func string(_ key: String) -> String {
            (info[key] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        let bundleID = string("CFBundleIdentifier")
        guard !bundleID.isEmpty else { return nil }
        let file = appFileName(path)
        let displayName = string("CFBundleDisplayName")
        let shortVersion = string("CFBundleShortVersionString")
        return InstalledApp(
            path: path,
            bundleID: bundleID,
            name: displayName.isEmpty ? file : displayName,
            version: shortVersion.isEmpty ? string("CFBundleVersion") : shortVersion,
            names: ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"].map(string).filter { !$0.isEmpty }
        )
    }

    /// Whether an app's name, file name or bundle ID matches what was typed. The file name
    /// counts because Finder shows it: VS Code's name is "Code", its file "Visual Studio Code.app".
    static func matches(_ app: InstalledApp, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty
            || app.name.lowercased().contains(query)
            || appFileName(app.path).lowercased().contains(query)
            || app.bundleID.lowercased().contains(query)
    }

    /// The paths to show in Finder, in turn: the leftovers first, then the apps, so the apps'
    /// window ends up in front, to be moved to the Trash first.
    static func revealBatches(_ paths: [String]) -> [[String]] {
        let apps = paths.filter { $0.hasSuffix(".app") }
        let others = paths.filter { !$0.hasSuffix(".app") }
        return [others, apps].filter { !$0.isEmpty }
    }
}
