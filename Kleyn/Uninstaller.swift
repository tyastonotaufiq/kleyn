//
//  Uninstaller.swift
//  Kleyn
//

import AppKit
import Observation

/// Finds an app's leftovers in ~/Library, and what removed apps left behind, and shows
/// what you mark selected in Finder.
///
/// Safety rules, enforced here and not left to the page:
///  - Kleyn never moves or deletes anything here. It shows the marked items in Finder,
///    and you move them to the Trash there, where macOS asks for a password or refuses
///    as it does for any Finder move.
///  - Every path is checked again before it's shown: an app must pass
///    `UninstallerRules.isRemovableApp`, and a leftover `isRemovableLeftover`.
///  - Only files named after the app's bundle ID are marked at first. Name matches and
///    shared containers are listed unmarked, to be checked first.
///  - macOS's own apps aren't listed.
@Observable
final class Uninstaller {
    /// The views the page can push on top of the app list.
    enum Screen: Hashable {
        case app(InstalledApp)
        case removedApps
    }

    /// The page's navigation stack, kept here so it survives switching pages.
    var path: [Screen] = []
    var query = ""

    private(set) var apps: [InstalledApp] = []
    private(set) var isLoadingApps = false

    // One app
    private(set) var leftovers: [Leftover] = []
    private(set) var isScanningApp = false
    /// Rows marked on an app's page, by path.
    private(set) var markedLeftovers: Set<String> = []

    // Removed apps
    private(set) var orphans: [Orphan] = []
    private(set) var strayExtensions: [SystemExtension] = []
    private(set) var isScanningOrphans = false
    /// Rows marked in Removed apps, by bundle ID.
    private(set) var markedOrphans: Set<String> = []

    // Sizes, by path
    private(set) var sizes: [String: Int64] = [:]
    /// Paths that couldn't be read, so their size shows as —.
    private(set) var unreadable: Set<String> = []
    private(set) var measuring: Set<String> = []

    /// What just happened, like "Showed 7 items in Finder."
    private(set) var message = ""

    /// Bumped by Rescan, so the page's scan task starts again.
    private(set) var scanGeneration = 0

    let home = CleanerRules.cleanPath(NSHomeDirectory())

    /// How many folders are measured at once, as in the Cleaner.
    private static let jobs = 4

    // MARK: - All apps

    var filteredApps: [InstalledApp] {
        apps.filter { UninstallerRules.matches($0, query: query) }
    }

    func loadAppsIfNeeded() async {
        if apps.isEmpty && !isLoadingApps { await loadApps() }
    }

    func loadApps() async {
        isLoadingApps = true
        message = ""
        apps = await Self.readApps(home: home)
        isLoadingApps = false
    }

    /// Opens the first app the search matches, for Return in the search field.
    func openFirstMatch() {
        if let first = filteredApps.first {
            path.append(.app(first))
        }
    }

    // MARK: - One app

    /// Starts a scan again from scratch on the page showing.
    func rescan() {
        scanGeneration += 1
    }

    /// Lists the app and what it left in the usual places, then measures them. Containers wait for a click.
    func scan(_ app: InstalledApp) async {
        isScanningApp = true
        message = ""
        leftovers = []
        markedLeftovers = []
        sizes = [:]
        unreadable = []
        measuring = []

        if apps.isEmpty { await loadApps() }
        let installed = apps
        let rows = await Self.findLeftovers(of: app, installed: installed, home: home)
        guard !Task.isCancelled else { return }
        if !rows.contains(where: { $0.match == .app }) {
            // Moved to the Trash in Finder since the list was read.
            apps.removeAll { $0.path == app.path }
        }
        leftovers = rows
        markedLeftovers = UninstallerRules.markedByDefault(rows)

        await measure(rows.filter { !$0.isContainer }.map(\.path))
        guard !Task.isCancelled else { return }
        isScanningApp = false

        let left = rows.filter { $0.match != .app }.count
        if left > 0 {
            message = "\(app.name) left \(CleanerRules.count(left, "item")) behind. Mark what to remove, then click Show in Finder."
        } else if !rows.isEmpty {
            message = "\(app.name) left nothing in the usual places."
        } else {
            message = "\(app.name) and what it left are gone."
        }
    }

    func isMarked(_ row: Leftover) -> Bool {
        markedLeftovers.contains(row.path)
    }

    func setMarked(_ row: Leftover, _ isMarked: Bool) {
        if isMarked { markedLeftovers.insert(row.path) } else { markedLeftovers.remove(row.path) }
    }

    func markAllLeftovers() {
        markedLeftovers = Set(leftovers.map(\.path))
    }

    func unmarkAllLeftovers() {
        markedLeftovers = []
    }

    /// Shows the marked rows selected in Finder: the leftovers first, then the app in front.
    func showMarkedLeftovers() {
        let paths = leftovers
            .filter { markedLeftovers.contains($0.path) }
            .filter { row in
                row.match == .app
                    ? UninstallerRules.isRemovableApp(row.path, home: home)
                    : UninstallerRules.isRemovableLeftover(row.path, home: home)
            }
            .map(\.path)
        reveal(paths)
    }

    // MARK: - Removed apps

    /// Lists what apps that aren't installed any more left behind, reading the app list afresh,
    /// then measures it. Containers wait for a click.
    func scanOrphans() async {
        isScanningOrphans = true
        message = ""
        orphans = []
        strayExtensions = []
        markedOrphans = []
        sizes = [:]
        unreadable = []
        measuring = []

        await loadApps()
        let installedIDs = apps.map(\.bundleID)
        async let candidates = Self.findOrphans(installedIDs: installedIDs, home: home)
        async let extensions = Self.systemExtensions()
        let (found, allExtensions) = await (candidates, extensions)
        guard !Task.isCancelled else { return }

        strayExtensions = UninstallerRules.strayExtensions(allExtensions, installedIDs: installedIDs)
        orphans = found
            // An app installed somewhere else (in Downloads, on another disk) isn't removed.
            .filter { !Self.isInstalledElsewhere($0.bundleID) }
            .map { orphan in
                var orphan = orphan
                // macOS keeps an app's containers while its system extension runs (an app left in the Trash).
                if orphan.paths.contains(where: UninstallerRules.isContainer) {
                    orphan.runningExtension = UninstallerRules.runningExtension(of: orphan.bundleID, in: allExtensions)?.name
                }
                return orphan
            }

        await measure(orphans.flatMap(\.paths).filter { !UninstallerRules.isContainer($0) })
        guard !Task.isCancelled else { return }
        orphans = stableSortedBySize(orphans)
        isScanningOrphans = false

        if orphans.isEmpty {
            message = "No leftovers from removed apps found."
        } else {
            let total = orphans.reduce(0) { $0 + size(of: $1) }
            message = "\(CleanerRules.count(orphans.count, "removed app")) left \(CleanerRules.sizeLabel(total)). Check each one, mark it, then click Show in Finder."
        }
    }

    func isMarked(_ orphan: Orphan) -> Bool {
        markedOrphans.contains(orphan.id)
    }

    func setMarked(_ orphan: Orphan, _ isMarked: Bool) {
        if isMarked { markedOrphans.insert(orphan.id) } else { markedOrphans.remove(orphan.id) }
    }

    func markAllOrphans() {
        markedOrphans = Set(orphans.map(\.id))
    }

    func unmarkAllOrphans() {
        markedOrphans = []
    }

    /// Shows every file of the marked removed apps selected in Finder.
    func showMarkedOrphans() {
        let chosen = orphans.filter { markedOrphans.contains($0.id) }
        let paths = chosen.flatMap(\.paths).filter { UninstallerRules.isRemovableLeftover($0, home: home) }
        // macOS protects the containers of an app whose extension still runs: Finder can't move them either.
        let held = chosen.compactMap(\.runningExtension)
        var note = ""
        if !held.isEmpty {
            let names = held.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
            note = " \(names) \(held.count == 1 ? "is" : "are") still running, so macOS protects \(held.count == 1 ? "its" : "their") containers. Remove \(held.count == 1 ? "it" : "them") in System Settings → General → Login Items & Extensions and restart first."
        }
        reveal(paths, note: note)
    }

    // MARK: - Sizes

    /// The size of a row: its own, or for a removed app, all of its paths measured so far.
    func size(of row: Leftover) -> Int64? {
        sizes[row.path]
    }

    func size(of orphan: Orphan) -> Int64 {
        orphan.paths.reduce(0) { $0 + (sizes[$1] ?? 0) }
    }

    /// The containers of a removed app that haven't been measured.
    func unmeasuredContainers(of orphan: Orphan) -> [String] {
        orphan.paths.filter {
            UninstallerRules.isContainer($0) && sizes[$0] == nil && !unreadable.contains($0) && !measuring.contains($0)
        }
    }

    /// Measures `paths` after a click. For a container, macOS asks first whether Kleyn may
    /// access other apps' data; if that's denied, the size shows as —.
    func measureOnRequest(_ paths: [String]) {
        Task {
            await measure(paths)
            orphans = stableSortedBySize(orphans)
        }
    }

    /// Measures `paths`, a few at a time off the main thread, filling in `sizes` as each finishes.
    private func measure(_ paths: [String]) async {
        await withTaskGroup(of: (path: String, bytes: Int64, unreadable: Bool).self) { group in
            var next = 0
            var running = 0
            while true {
                while next < paths.count && running < Self.jobs {
                    let path = paths[next]
                    next += 1
                    running += 1
                    measuring.insert(path)
                    group.addTask { await Self.measure(path) }
                }
                guard let result = await group.next() else { break }
                running -= 1
                measuring.remove(result.path)
                if Task.isCancelled {
                    group.cancelAll()
                    return
                }
                if result.unreadable && result.bytes == 0 {
                    unreadable.insert(result.path)
                } else {
                    sizes[result.path] = result.bytes
                }
            }
        }
    }

    private func stableSortedBySize(_ list: [Orphan]) -> [Orphan] {
        list.enumerated()
            .sorted { a, b in
                let (sizeA, sizeB) = (size(of: a.element), size(of: b.element))
                return sizeA != sizeB ? sizeA > sizeB : a.offset < b.offset
            }
            .map(\.element)
    }

    // MARK: - Finder

    /// After you come back from Finder: drops the rows whose files are gone.
    func dropMissing() {
        let fileManager = FileManager.default
        let exists = { (path: String) in fileManager.fileExists(atPath: path) }

        let goneApps = leftovers.filter { $0.match == .app && !exists($0.path) }.map(\.path)
        apps.removeAll { goneApps.contains($0.path) }
        leftovers.removeAll { !exists($0.path) }
        markedLeftovers.formIntersection(leftovers.map(\.path))

        orphans = orphans.compactMap { orphan in
            var orphan = orphan
            orphan.paths.removeAll { !exists($0) }
            return orphan.paths.isEmpty ? nil : orphan
        }
        markedOrphans.formIntersection(orphans.map(\.id))
    }

    /// Shows `paths` selected in Finder, one window per folder, for you to move to the Trash there.
    private func reveal(_ paths: [String], note: String = "") {
        guard !paths.isEmpty else {
            message = "Mark items first."
            return
        }
        let batches = UninstallerRules.revealBatches(paths)
        for (index, batch) in batches.enumerated() {
            let urls = batch.map { URL(fileURLWithPath: $0) }
            // Windows from one call open in no set order, so the apps come a moment later, in front.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500 * index)) {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        }
        message = "Showed \(CleanerRules.count(paths.count, "item")) in Finder. Press ⌘⌫ there to move them to the Trash; Finder asks for your password if needed. Their rows disappear here once they're gone." + note
    }

    // MARK: - Work off the main thread

    /// The apps in the app folders, and one folder down (some apps install in a folder of their
    /// own), without macOS's own. Sorted by name.
    @concurrent
    nonisolated private static func readApps(home: String) async -> [InstalledApp] {
        let fileManager = FileManager.default
        var paths: [String] = []
        for root in UninstallerRules.appFolders(home: home) {
            for name in (try? fileManager.contentsOfDirectory(atPath: root)) ?? [] where !name.hasPrefix(".") {
                let path = root + "/" + name
                if name.hasSuffix(".app") {
                    paths.append(path)
                } else if name != "Utilities", !isSymbolicLink(path) {
                    for inner in (try? fileManager.contentsOfDirectory(atPath: path)) ?? [] where inner.hasSuffix(".app") {
                        paths.append(path + "/" + inner)
                    }
                }
            }
        }

        let apps = paths.compactMap { path -> InstalledApp? in
            // iPhone and iPad apps keep their Info.plist in WrappedBundle, a link to the app inside.
            let wrapped = path + "/WrappedBundle/Info.plist"
            let plist = fileManager.fileExists(atPath: wrapped) ? wrapped : path + "/Contents/Info.plist"
            guard let info = NSDictionary(contentsOfFile: plist) as? [String: Any],
                  let app = UninstallerRules.app(fromInfo: info, path: path),
                  !UninstallerRules.isSystemApp(path: app.path, bundleID: app.bundleID)
            else { return nil }
            return app
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Each child of every place, with the place it's in. Lists names only: nothing inside
    /// another app's container is read, so macOS doesn't ask for access.
    nonisolated private static func placeChildren(home: String) -> [(path: String, place: LeftoverPlace)] {
        var children: [(path: String, place: LeftoverPlace)] = []
        for place in UninstallerRules.places {
            let folder = home + "/" + place.rel
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted() {
                children.append((folder + "/" + name, place))
            }
        }
        return children
    }

    @concurrent
    nonisolated private static func findLeftovers(of app: InstalledApp, installed: [InstalledApp], home: String) async -> [Leftover] {
        var rows: [Leftover] = []
        if FileManager.default.fileExists(atPath: app.path) {
            let reason = [app.version.isEmpty ? "" : "Version " + app.version, app.bundleID]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            rows.append(Leftover(path: app.path, place: "App", match: .app, reason: reason))
        }
        for (path, place) in placeChildren(home: home) {
            let name = (path as NSString).lastPathComponent
            guard let match = UninstallerRules.match(name, in: place, app: app, installed: installed),
                  UninstallerRules.isRemovableLeftover(path, home: home)
            else { continue }
            rows.append(Leftover(
                path: path,
                place: place.label,
                match: match,
                reason: UninstallerRules.reason(place: place, match: match),
                shared: place.shared
            ))
        }
        return rows
    }

    @concurrent
    nonisolated private static func findOrphans(installedIDs: [String], home: String) async -> [Orphan] {
        let children = placeChildren(home: home).filter { UninstallerRules.isRemovableLeftover($0.path, home: home) }
        return UninstallerRules.orphans(in: children, installedIDs: installedIDs)
    }

    /// Every system extension macOS knows, or none when `systemextensionsctl` can't tell.
    /// macOS has no API that lists other apps' extensions.
    @concurrent
    nonisolated private static func systemExtensions() async -> [SystemExtension] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/systemextensionsctl")
        process.arguments = ["list"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return UninstallerRules.parseSystemExtensions(String(decoding: data, as: UTF8.self))
    }

    /// Whether Launch Services knows an app with this ID outside the Trash.
    private static func isInstalledElsewhere(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).contains { url in
            !url.path.contains("/.Trash/") && !url.path.contains("/.Trashes/")
        }
    }

    @concurrent
    nonisolated private static func measure(_ path: String) async -> (path: String, bytes: Int64, unreadable: Bool) {
        let (bytes, unreadable) = DiskUsage.allocatedSize(of: path)
        return (path, bytes, unreadable)
    }

    nonisolated private static func isSymbolicLink(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }
}
