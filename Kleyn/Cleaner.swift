//
//  Cleaner.swift
//  Kleyn
//

import AppKit
import Observation

/// Measures the usual space users in the home folder and moves what you mark to the Trash.
///
/// Safety rules, enforced here and not left to the page:
///  - Nothing is deleted. Marked items go to the Trash, where Put Back works.
///  - Only rows from the scan can be moved, and each path is checked again with
///    `CleanerRules.isTrashable` right before it moves.
/// The page asks before every move.
@Observable
final class Cleaner {
    enum Phase {
        /// Not scanned yet, or a scan was cancelled; opening the page scans.
        case notScanned
        case scanning
        case scanned
    }

    /// Free and total space on the home folder's volume.
    struct DiskSpace: Equatable {
        var free: Int64
        var total: Int64
    }

    /// What a confirmed move would move: every trashable path behind the marked rows.
    struct MovePlan: Equatable {
        var paths: [String]
        var bytes: Int64
    }

    private(set) var phase = Phase.notScanned
    private(set) var rows: [CleanItem] = []
    /// The ids of the marked rows.
    private(set) var marked: Set<String> = []
    /// What just happened, like "Moved 3 items, 1.2 GB, to the Trash."
    private(set) var message = ""
    private(set) var isMoving = false
    private(set) var disk: DiskSpace?
    /// Some folders couldn't be read and Kleyn doesn't have Full Disk Access, so a few sizes are low.
    private(set) var needsFullDiskAccess = false

    // Progress of the scan running.
    private(set) var measuredCount = 0
    private(set) var pendingCount = 0
    /// The folders being measured, oldest first.
    private(set) var measuring: [String] = []

    let home = CleanerRules.cleanPath(NSHomeDirectory())

    /// How many folders are measured at once. Measuring mostly waits on the disk, which an
    /// SSD serves in parallel; the mod found 4 about twice as fast as 1, and 8 no faster than 4.
    private static let scanJobs = 4
    nonisolated private static let logLimit = 200

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// Bumped by every scan and cancel, so a scan that was replaced stops touching the page.
    @ObservationIgnored private var scanGeneration = 0

    var safeRows: [CleanItem] { rows.filter { $0.risk == .safe } }
    var reviewRows: [CleanItem] { rows.filter { $0.risk == .review } }
    var markedRows: [CleanItem] { rows.filter { marked.contains($0.id) } }
    var markedBytes: Int64 { markedRows.reduce(0) { $0 + $1.size } }

    /// "Scanning 37 of 152 · found 61.2 GB so far · ~/.gradle/caches…"
    var progressText: String {
        guard pendingCount > 0 else { return "Scanning…" }
        var parts = ["Scanning \(measuredCount) of \(pendingCount)"]
        let found = rows.reduce(0) { $0 + $1.size }
        if found > 0 {
            parts.append("found \(CleanerRules.sizeLabel(found)) so far")
        }
        // The oldest still running, so a big folder stays named.
        if let slowest = measuring.first {
            parts.append(CleanerRules.tildify(slowest, home: home) + "…")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Scanning

    /// Scans if there are no results yet, or the last scan was cancelled.
    func scanIfNeeded() {
        if phase == .notScanned { scan() }
    }

    /// Scans again from scratch. Only this scan's results are shown, so nothing stale can be marked.
    func scan() {
        guard !isMoving else { return }
        scanTask?.cancel()
        scanTask = Task { await runScan() }
    }

    /// Stops a scan that's running, for when you leave the page. The next visit scans again.
    func cancelScan() {
        guard phase == .scanning else { return }
        scanGeneration += 1
        scanTask?.cancel()
        scanTask = nil
        phase = .notScanned
        measuring = []
    }

    private func runScan() async {
        scanGeneration += 1
        let generation = scanGeneration
        phase = .scanning
        rows = []
        message = ""
        needsFullDiskAccess = false
        measuredCount = 0
        pendingCount = 0
        measuring = []
        readDiskSpace()

        let (pending, listingFailed) = await Self.itemsToMeasure(home: home)
        guard generation == scanGeneration, !Task.isCancelled else { return }
        pendingCount = pending.count

        var results: [CleanItem] = []
        var unreadable = listingFailed
        // Measure a few folders at a time and show each result as it comes in.
        await withTaskGroup(of: Measured.self) { group in
            var next = 0
            var running = 0
            while true {
                while next < pending.count && running < Self.scanJobs {
                    let item = pending[next]
                    next += 1
                    running += 1
                    measuring.append(item.path)
                    group.addTask { await Self.measure(item) }
                }
                guard let measured = await group.next() else { break }
                running -= 1
                guard generation == scanGeneration, !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                measuring.removeAll { $0 == measured.item.path }
                measuredCount += 1
                results.append(measured.item)
                if measured.unreadable { unreadable = true }
                rows = CleanerRules.rows(from: results)
            }
        }
        guard generation == scanGeneration, !Task.isCancelled else { return }

        rows = CleanerRules.rows(from: results)
        marked = marked.filter { id in rows.contains { $0.id == id } }
        measuring = []
        phase = .scanned
        needsFullDiskAccess = unreadable ? !(await Self.hasFullDiskAccess(home: home)) : false
        let total = rows.reduce(0) { $0 + $1.size }
        message = rows.isEmpty
            ? "Nothing large found in the usual places."
            : "Found \(CleanerRules.sizeLabel(total)) in \(CleanerRules.count(rows.count, "place")). Mark what to remove, then click Move to Trash."
    }

    private func readDiskSpace() {
        let values = try? URL(fileURLWithPath: home).resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        if let total = values?.volumeTotalCapacity, let free = values?.volumeAvailableCapacityForImportantUsage {
            disk = DiskSpace(free: free, total: Int64(total))
        } else {
            disk = nil
        }
    }

    // MARK: - Marking

    func isMarked(_ row: CleanItem) -> Bool {
        marked.contains(row.id)
    }

    func setMarked(_ row: CleanItem, _ isMarked: Bool) {
        if isMarked {
            marked.insert(row.id)
        } else {
            marked.remove(row.id)
        }
    }

    func markAllSafe() {
        marked.formUnion(safeRows.map(\.id))
    }

    func unmarkAll() {
        marked = []
    }

    // MARK: - Finder

    /// Shows every marked item selected in Finder.
    func showMarkedInFinder() {
        showInFinder(markedRows.flatMap(CleanerRules.rowPaths))
    }

    /// Shows one row's item, or each item of a summary row, selected in Finder.
    func showInFinder(_ row: CleanItem) {
        showInFinder(CleanerRules.rowPaths(row))
    }

    private func showInFinder(_ paths: [String]) {
        let urls = paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else {
            message = "Nothing to show: the marked items are gone."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: - Moving to the Trash

    /// What moving the marked rows would move, for the confirmation. Nil when nothing can move.
    func movePlan() -> MovePlan? {
        let chosen = markedRows
        let candidates = chosen.flatMap(CleanerRules.rowPaths)
        let files = Self.filesInHome(candidates, home: home)
        let paths = candidates
            .filter { CleanerRules.isTrashable($0, home: home, isFile: files.contains($0)) }
        guard !paths.isEmpty else { return nil }
        let sizes = Self.sizes(of: chosen)
        return MovePlan(paths: paths, bytes: paths.reduce(0) { $0 + (sizes[$1] ?? 0) })
    }

    /// Moves the marked rows' items to the Trash, after the page has asked.
    func moveMarkedToTrash() async {
        // Rows can be marked while a scan runs, but nothing moves until it's done.
        guard phase == .scanned, !isMoving else { return }
        guard let plan = movePlan() else {
            message = "Mark items first."
            return
        }
        let chosen = markedRows
        let sizes = Self.sizes(of: chosen)

        isMoving = true
        message = ""
        let result = await Self.trash(plan.paths, home: home)
        isMoving = false

        let moved = Set(result.moved)
        let movedBytes = result.moved.reduce(0) { $0 + (sizes[$1] ?? 0) }

        // Drop what moved; a summary row keeps only its members that are still there.
        let chosenIDs = Set(chosen.map(\.id))
        rows = rows.compactMap { row in
            guard chosenIDs.contains(row.id) else { return row }
            guard let members = row.members else { return moved.contains(row.path) ? nil : row }
            let left = members.filter { !moved.contains($0.path) }
            guard !left.isEmpty else { return nil }
            var kept = row
            kept.members = left
            kept.size = left.reduce(0) { $0 + $1.size }
            return kept
        }
        // What couldn't move stays marked.
        marked = Set(rows.map(\.id).filter { chosenIDs.contains($0) })

        if !result.moved.isEmpty {
            await Self.appendToLog(paths: result.moved, bytes: movedBytes)
        }
        readDiskSpace()

        if let failure = result.firstError {
            message = "Moved \(result.moved.count), but \(result.failedCount) couldn't be moved and \(result.failedCount == 1 ? "is" : "are") still marked: \(failure) Quit the app using \(result.failedCount == 1 ? "it" : "them") and try again."
        } else {
            message = "Moved \(CleanerRules.count(result.moved.count, "item")), \(CleanerRules.sizeLabel(movedBytes)), to the Trash. Empty the Trash to get the space back."
        }
    }

    // MARK: - Full Disk Access

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Work off the main thread

    nonisolated private struct Measured: Sendable {
        var item: CleanItem
        /// Some of it couldn't be read, so the size is low.
        var unreadable: Bool
    }

    nonisolated private struct TrashResult: Sendable {
        var moved: [String] = []
        var failedCount = 0
        var firstError: String?
    }

    /// The items the scan measures, one per row, with no size yet. Whole targets (Gradle,
    /// DerivedData…) come first: they're the slow ones, so they start while the many small
    /// cache folders fill in around them instead of finishing last.
    /// Also says whether a folder to list couldn't be read.
    @concurrent
    nonisolated private static func itemsToMeasure(home: String) async -> ([CleanItem], Bool) {
        let fileManager = FileManager.default
        var whole: [CleanItem] = []
        var children: [CleanItem] = []
        var unreadable = false

        for target in CleanerRules.targets {
            let folder = target.rel.isEmpty ? home : home + "/" + target.rel
            guard fileManager.fileExists(atPath: folder) else { continue }
            let item = { (path: String) in
                CleanItem(path: path, size: 0, category: target.category, risk: target.risk, reason: target.reason)
            }
            guard target.expand else {
                whole.append(item(folder))
                continue
            }
            // Lists only this folder: the home folder's own entries, never what's inside
            // Desktop, Documents or Downloads, which would make macOS ask for access.
            guard let names = try? fileManager.contentsOfDirectory(atPath: folder) else {
                unreadable = true
                continue
            }
            for name in names.sorted() {
                if !target.includes(name) { continue }
                let path = folder + "/" + name
                if isSymbolicLink(path) { continue }
                children.append(item(path))
            }
        }

        let files = filesInHome((whole + children).map(\.path), home: home)
        let items = (whole + children).filter {
            CleanerRules.isTrashable($0.path, home: home, isFile: files.contains($0.path))
        }
        return (items, unreadable)
    }

    @concurrent
    nonisolated private static func measure(_ item: CleanItem) async -> Measured {
        let (size, unreadable) = allocatedSize(of: item.path)
        var measured = item
        measured.size = size
        return Measured(item: measured, unreadable: unreadable)
    }

    /// The disk space a file or folder takes, adding up every file inside, as `du` counts it.
    /// Symbolic links aren't followed. Stops early when the task is cancelled.
    nonisolated private static func allocatedSize(of path: String) -> (Int64, unreadable: Bool) {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return (0, true) }
        if values.isSymbolicLink == true { return (0, false) }
        guard values.isDirectory == true else { return (Int64(values.totalFileAllocatedSize ?? 0), false) }

        let unreadable = Flag()
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [],
            errorHandler: { _, _ in
                unreadable.isSet = true
                return true
            }
        ) else { return (0, true) }

        var total: Int64 = 0
        while let file = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            let size = (try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize
            total += Int64(size ?? 0)
        }
        return (total, unreadable.isSet)
    }

    /// Set from the enumerator's error handler.
    nonisolated private final class Flag: @unchecked Sendable {
        var isSet = false
    }

    /// Moves each path to the Trash, checking it once more right before.
    @concurrent
    nonisolated private static func trash(_ paths: [String], home: String) async -> TrashResult {
        let fileManager = FileManager.default
        let files = filesInHome(paths, home: home)
        var result = TrashResult()
        for path in paths {
            guard CleanerRules.isTrashable(path, home: home, isFile: files.contains(path)) else {
                result.failedCount += 1
                result.firstError = result.firstError ?? "Kleyn doesn't move \(CleanerRules.tildify(path, home: home))."
                continue
            }
            do {
                try fileManager.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                result.moved.append(path)
            } catch {
                // Already gone counts as moved, as in the mod: it's no longer taking space.
                if !fileManager.fileExists(atPath: path) {
                    result.moved.append(path)
                } else {
                    result.failedCount += 1
                    result.firstError = result.firstError ?? error.localizedDescription
                }
            }
        }
        return result
    }

    /// Which of `paths` are regular files directly in home (not folders or links): the only
    /// things there that may be trashed. Looks only at those paths, never at the other
    /// entries in home, so Desktop, Documents, Music and the like are left alone.
    nonisolated private static func filesInHome(_ paths: [String], home: String) -> Set<String> {
        Set(paths.filter { path in
            guard (path as NSString).deletingLastPathComponent == home else { return false }
            // Doesn't follow a symbolic link: a link reports itself, not what it points to.
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return attributes?[.type] as? FileAttributeType == .typeRegular
        })
    }

    nonisolated private static func isSymbolicLink(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// The size of each path behind `rows`.
    private static func sizes(of rows: [CleanItem]) -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for row in rows {
            for member in row.members ?? [CleanItem.Member(path: row.path, size: row.size)] {
                sizes[member.path] = member.size
            }
        }
        return sizes
    }

    /// Whether Kleyn has Full Disk Access. macOS lets only apps with it read the folder of
    /// privacy settings, and reading it never shows a prompt.
    @concurrent
    nonisolated private static func hasFullDiskAccess(home: String) async -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: home + "/Library/Application Support/com.apple.TCC")) != nil
    }

    // MARK: - Log

    nonisolated private struct LogEntry: Codable {
        var at: Date
        var paths: [String]
        var bytes: Int64
    }

    /// Adds a move to `~/Library/Application Support/Kleyn/cleaner-log.json`, keeping the last 200.
    @concurrent
    nonisolated private static func appendToLog(paths: [String], bytes: Int64) async {
        let fileManager = FileManager.default
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let folder = support.appendingPathComponent("Kleyn", isDirectory: true)
        let file = folder.appendingPathComponent("cleaner-log.json")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var log = (try? Data(contentsOf: file)).flatMap { try? decoder.decode([LogEntry].self, from: $0) } ?? []
        log.append(LogEntry(at: .now, paths: paths, bytes: bytes))
        log = Array(log.suffix(logLimit))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try encoder.encode(log).write(to: file, options: .atomic)
        } catch {
            // A log that can't be written doesn't stop the move.
        }
    }
}
