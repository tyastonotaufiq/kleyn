//
//  CleanerRules.swift
//  Kleyn
//
//  The parts of the Cleaner that need no I/O, kept apart so they can be tested:
//  what's scanned, how results become rows, and what may be moved to the Trash.
//  Ported from claude-mods/mac-cleaner/hooks/cleaner.ts.
//

import Foundation

/// Whether an item is rebuilt automatically (`safe`), or worth a look before it goes (`review`).
nonisolated enum CleanRisk: String, Equatable, Sendable {
    case safe, review
}

/// A row on the Cleaner page: one measured item, or a summary row of small items in one category.
nonisolated struct CleanItem: Equatable, Identifiable, Sendable {
    /// One of the small items a summary row stands for.
    struct Member: Equatable, Sendable {
        var path: String
        var size: Int64
    }

    /// The item's full path, or `small:<category>` for a summary row.
    var path: String
    /// Allocated size in bytes.
    var size: Int64
    var category: String
    var risk: CleanRisk
    var reason: String
    /// The items a summary row stands for, biggest first. Nil for other rows.
    var members: [Member]?

    var id: String { path }
    var isSummary: Bool { members != nil }
}

/// A place the scan measures. `rel` is relative to the home folder ("" is the home folder itself).
nonisolated struct CleanTarget: Sendable {
    var rel: String
    var category: String
    var risk: CleanRisk
    var reason: String
    /// Measure each child separately instead of the folder as a whole.
    var expand = false
    /// With `expand`, only children whose name ends with this.
    var onlySuffix: String?
    /// With `expand`, children left out when their name starts with one of these (ignoring case).
    var skipPrefixes: [String] = []

    /// Whether the scan measures the child called `name`.
    func includes(_ name: String) -> Bool {
        if let onlySuffix, !name.hasSuffix(onlySuffix) { return false }
        let lowercased = name.lowercased()
        return !skipPrefixes.contains { lowercased.hasPrefix($0.lowercased()) }
    }
}

nonisolated enum CleanerRules {
    static let targets: [CleanTarget] = [
        CleanTarget(
            rel: "Library/Caches", category: "App caches", risk: .safe,
            reason: "Cache files; the app rebuilds them when needed. Quit the app first.",
            expand: true,
            // The Music app's caches: macOS asks for Media & Apple Music access to read
            // them, which a scan shouldn't. They're small (about 20 MB).
            skipPrefixes: ["com.apple.Music", "com.apple.AMPLibraryAgent", "com.apple.iTunes"]
        ),
        CleanTarget(rel: "Library/Logs", category: "Logs", risk: .safe, reason: "Old app and system logs."),
        CleanTarget(
            rel: "Library/Developer/Xcode/DerivedData", category: "Xcode", risk: .safe,
            reason: "Build products; Xcode rebuilds them on the next build."
        ),
        CleanTarget(
            rel: "Library/Developer/Xcode/iOS DeviceSupport", category: "Xcode", risk: .safe,
            reason: "Debug symbols for iOS versions; downloaded again when you connect a device."
        ),
        CleanTarget(
            rel: "Library/Developer/CoreSimulator/Caches", category: "Xcode", risk: .safe,
            reason: "iOS Simulator caches."
        ),
        CleanTarget(
            rel: "Library/Developer/Xcode/Archives", category: "Xcode", risk: .review,
            reason: "App archives. Keep ones you may need to re-submit or to symbolicate crashes."
        ),
        CleanTarget(
            rel: ".gradle/caches", category: "Android / Gradle", risk: .safe,
            reason: "Gradle dependency and build caches; downloaded again on the next build (first build is slower)."
        ),
        CleanTarget(
            rel: ".gradle/wrapper/dists", category: "Android / Gradle", risk: .safe,
            reason: "Gradle distributions; each project re-downloads the version it needs."
        ),
        CleanTarget(
            rel: ".android/avd", category: "Android emulators", risk: .review,
            reason: "An emulator and its data. Remove ones you no longer use (or delete them in Device Manager).",
            expand: true, onlySuffix: ".avd"
        ),
        CleanTarget(
            rel: "Library/Android/sdk/system-images", category: "Android SDK", risk: .review,
            reason: "Emulator system images for one API level; reinstall from the SDK Manager if needed.",
            expand: true
        ),
        CleanTarget(rel: ".npm/_cacache", category: "npm", risk: .safe, reason: "npm download cache."),
        CleanTarget(
            rel: ".cocoapods/repos", category: "CocoaPods", risk: .safe,
            reason: "Pod spec repos; fetched again when needed."
        ),
        CleanTarget(
            rel: "", category: "Java heap dumps", risk: .safe,
            reason: "Memory snapshot a Java app (often Android Studio) wrote when it crashed; nothing needs it to run.",
            expand: true, onlySuffix: ".hprof"
        ),
    ]

    /// Measured items smaller than this don't get a row of their own. They're summed per
    /// category into one summary row, shown when the sum reaches this size too. 10 MB, as Finder counts.
    static let minSize: Int64 = 10_000_000

    private static let summaryPrefix = "small:"

    /// Home-relative paths that are never trashed from here, whatever finds them:
    /// cloud sync, mail, photos, keys, and folders whose children are the user's own work.
    private static let protectedPrefixes = [
        "Library/Mobile Documents",
        "Library/CloudStorage",
        "Library/Keychains",
        "Library/Mail",
        "Library/Messages",
        "Library/Photos",
        "Library/Preferences",
        "Library/Application Support/MobileSync",
        "Library/Group Containers",
        "Library/Containers",
        "Pictures/Photos Library.photoslibrary",
        ".ssh",
        ".gnupg",
        ".Trash",
    ].map { $0.lowercased() }

    /// Folders that may hold trashable children but are never trashed themselves.
    private static let protectedExact: Set<String> = Set([
        "Library/Caches",
        "Library/Application Support",
        "Library/Developer",
        "Library/Android",
        "Library/Android/sdk",
        ".gradle",
        ".android",
        ".npm",
    ].map { $0.lowercased() })

    // MARK: - What may be trashed

    /// Collapses repeated slashes and strips a trailing one.
    static func cleanPath(_ path: String) -> String {
        var clean = path
        while clean.contains("//") {
            clean = clean.replacing("//", with: "/")
        }
        while clean.count > 1 && clean.hasSuffix("/") {
            clean.removeLast()
        }
        return clean
    }

    /// Whether `path` may be moved to the Trash: inside the home folder, with no `..`, and not
    /// in or above a protected place. Directly in home, only a file the caller has checked is
    /// one (`isFile`), and never a hidden one: never ~/Downloads itself, only things in it,
    /// and never ~/.zshrc and the like.
    ///
    /// The protected places are compared ignoring case, as the Mac's disk does, so
    /// `~/library/keychains` is refused too.
    static func isTrashable(_ path: String, home: String, isFile: Bool = false) -> Bool {
        let path = cleanPath(path)
        let home = cleanPath(home)
        guard !home.isEmpty, home != "/", path.hasPrefix(home + "/") else { return false }
        let rel = String(path.dropFirst(home.count + 1))
        let parts = rel.split(separator: "/", omittingEmptySubsequences: false)
        if parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) { return false }
        if parts.count < 2 && (!isFile || rel.hasPrefix(".")) { return false }

        let key = rel.lowercased()
        if protectedExact.contains(key) { return false }
        if protectedPrefixes.contains(where: { key == $0 || key.hasPrefix($0 + "/") || $0.hasPrefix(key + "/") }) {
            return false
        }
        return true
    }

    // MARK: - Rows

    /// Turns measured items into the page's rows: one row per path (the last wins), rows
    /// inside another row dropped so nothing is counted twice, and items under `minSize`
    /// summed per category into one summary row, shown once the sum reaches `minSize`.
    /// Safe rows come first, biggest first within each group.
    static func rows(from items: [CleanItem]) -> [CleanItem] {
        var order: [String] = []
        var byPath: [String: CleanItem] = [:]
        for item in items {
            if byPath[item.path] == nil { order.append(item.path) }
            byPath[item.path] = item
        }
        // A row is nested when one of its parent folders is a row too. Checking each parent
        // keeps this quick, since the rows are rebuilt as each folder is measured.
        let kept = order.compactMap { byPath[$0] }.filter { item in
            var folder = item.path
            while let slash = folder.lastIndex(of: "/"), slash > folder.startIndex {
                folder = String(folder[..<slash])
                if byPath[folder] != nil { return false }
            }
            return true
        }

        var rows: [CleanItem] = []
        var smallCategories: [String] = []
        var small: [String: [CleanItem]] = [:]
        for item in kept {
            if item.size >= minSize {
                rows.append(item)
            } else if item.size > 0 {
                if small[item.category] == nil { smallCategories.append(item.category) }
                small[item.category, default: []].append(item)
            }
        }

        for category in smallCategories {
            let group = small[category] ?? []
            let size = group.reduce(0) { $0 + $1.size }
            guard size >= minSize, let first = group.first else { continue }
            rows.append(CleanItem(
                path: summaryPrefix + category,
                size: size,
                category: category,
                risk: group.allSatisfy { $0.risk == .safe } ? .safe : .review,
                reason: group.allSatisfy { $0.reason == first.reason } ? first.reason : "",
                members: stableSorted(group.map { CleanItem.Member(path: $0.path, size: $0.size) }) { $0.size > $1.size }
            ))
        }

        return stableSorted(rows) { a, b in
            a.risk != b.risk ? a.risk == .safe : a.size > b.size
        }
    }

    /// The paths a row moves to the Trash: each of its members for a summary row, else its own.
    static func rowPaths(_ item: CleanItem) -> [String] {
        item.members?.map(\.path) ?? [item.path]
    }

    /// The deepest folder holding every path.
    static func commonFolder(_ paths: [String]) -> String {
        let folders = paths.map { $0.split(separator: "/", omittingEmptySubsequences: false).dropLast() }
        guard let first = folders.first else { return "/" }
        var count = first.count
        for parts in folders {
            var i = 0
            while i < count && i < parts.count && parts[parts.startIndex + i] == first[first.startIndex + i] {
                i += 1
            }
            count = i
        }
        let joined = first.prefix(count).joined(separator: "/")
        return joined.isEmpty ? "/" : joined
    }

    /// What a row shows as its name: "~/Library/Logs", or "3 items under 10 MB in ~/Library/Caches".
    static func rowLabel(_ item: CleanItem, home: String, locale: Locale = .current) -> String {
        guard let members = item.members else { return tildify(item.path, home: home) }
        let folder = tildify(commonFolder(members.map(\.path)), home: home)
        return "\(members.count) items under \(sizeLabel(minSize, locale: locale)) in \(folder)"
    }

    // MARK: - Formatting

    /// A path shown relative to home, as `~/...`.
    static func tildify(_ path: String, home: String) -> String {
        !home.isEmpty && path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// A size as Finder shows it: "1.5 GB", "340 MB". "—" when there's nothing to show.
    static func sizeLabel(_ bytes: Int64, locale: Locale = .current) -> String {
        bytes > 0 ? bytes.formatted(.byteCount(style: .file).locale(locale)) : "—"
    }

    /// "1 item", "3 items".
    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    /// Sorted by `areInOrder`, keeping the original order of ties.
    private static func stableSorted<T>(_ items: [T], by areInOrder: (T, T) -> Bool) -> [T] {
        items.enumerated()
            .sorted { a, b in
                if areInOrder(a.element, b.element) { return true }
                if areInOrder(b.element, a.element) { return false }
                return a.offset < b.offset
            }
            .map(\.element)
    }
}
