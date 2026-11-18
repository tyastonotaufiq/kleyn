//
//  AdbExplorer.swift
//  Kleyn
//

import AppKit
import Observation

/// Browses and manages files on an Android device over adb.
///
/// Safety rules, enforced here and not left to the page:
///  - Deletes only touch paths strictly inside user storage (/sdcard/…), checked with
///    `AdbRules.isDeletable` before asking and again right before running.
///  - The page asks before every delete, and the default moves items to a trash
///    folder on the device instead of removing them.
///  - Every adb call is an argument list with -s <serial>, so it never acts on the
///    wrong device and never goes through a shell on the Mac.
@Observable
final class AdbExplorer {
    private(set) var adbPath: String?
    /// Looked for adb and found none.
    private(set) var adbMissing = false

    private(set) var devices: [AdbDevice] = []
    /// The serial of the device showing; empty when none is ready.
    private(set) var serial = ""
    private(set) var info: AdbInfo?

    private(set) var folder = AdbRules.homeFolder
    private(set) var entries: [AdbEntry] = []
    /// The selected items, by path, as in Finder: the list's selection. Cleared when you change folders.
    var selection: Set<String> = []
    private(set) var folderSizes: [String: Int64] = [:]

    /// What's running, like "Pulling 2 of 5: VID_2026.mp4"; empty when idle.
    private(set) var busy = ""
    /// Whether what's running is a copy Stop can end.
    private(set) var canStop = false
    /// What just happened, like "Pulled 3 items to ~/Downloads/adb-explorer/Pixel-8."
    private(set) var message = ""
    /// The folder the last pull went to, for Show in Finder.
    private(set) var lastPullFolder: URL?

    var showHidden = UserDefaults.standard.bool(forKey: AdbExplorer.showHiddenKey) {
        didSet { UserDefaults.standard.set(showHidden, forKey: Self.showHiddenKey) }
    }

    let home = Paths.clean(NSHomeDirectory())

    private static let showHiddenKey = "adbShowHidden"
    private static let foldersKey = "adbFolders"

    /// File icons and thumbnails for the list.
    @ObservationIgnored let thumbnails = AdbThumbnails()

    @ObservationIgnored private var copyTask: Task<Void, Never>?
    @ObservationIgnored private var serverStarted = false

    init() {
        AdbDragItem.clearTemporaryFolder()
    }

    var readyDevices: [AdbDevice] { devices.filter(\.isReady) }
    var device: AdbDevice? { devices.first { $0.serial == serial } }
    var visibleEntries: [AdbEntry] { entries.filter { showHidden || !$0.name.hasPrefix(".") } }
    var isBusy: Bool { !busy.isEmpty }

    /// The device's name for the header: its marketing name, else its model, else its serial.
    var deviceName: String {
        if let name = info?.name, !name.isEmpty { return name }
        return device?.model ?? serial
    }

    // MARK: - Devices

    /// While the page shows: finds adb, then checks for devices every 2 seconds while none is
    /// ready, so plugging a phone in or tapping Allow shows it without a Retry.
    func watch() async {
        while !Task.isCancelled {
            if serial.isEmpty && !isBusy {
                await refresh()
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Checks devices again, then lists the folder and reads the header.
    func refresh() async {
        guard let adb = findAdb() else { return }
        if !serverStarted {
            // Started on its own first, with its output going nowhere: a server started by a
            // command whose output Kleyn reads would hold that pipe open and never let it finish.
            _ = await Adb.run(adb, ["start-server"], quiet: true, timeout: 20)
            serverStarted = true
        }
        let result = await Adb.run(adb, ["devices", "-l"], timeout: 10)
        devices = AdbRules.parseDevices(result.stdout)
        if !readyDevices.contains(where: { $0.serial == serial }) {
            choose(readyDevices.first?.serial ?? "", listing: false)
        }
        guard !serial.isEmpty else {
            entries = []
            info = nil
            return
        }
        await list(folder)
        await refreshInfo()
    }

    /// Refresh: looks for adb again if it was missing, then checks devices and the folder.
    func refreshNow() {
        if adbMissing { adbPath = nil }
        Task { await work("Refreshing…") { await self.refresh() } }
    }

    /// Shows another device, in the folder it showed last.
    func selectDevice(_ newSerial: String) {
        guard newSerial != serial else { return }
        choose(newSerial, listing: true)
    }

    private func choose(_ newSerial: String, listing: Bool) {
        serial = newSerial
        selection = []
        info = nil
        entries = []
        folderSizes = [:]
        folder = rememberedFolder(for: newSerial) ?? AdbRules.homeFolder
        if listing && !newSerial.isEmpty {
            Task {
                await list(folder)
                await refreshInfo()
            }
        }
    }

    /// The header's name, Android version, free space and battery. It's extra, so a failure keeps what was there.
    private func refreshInfo() async {
        guard let adb = adbPath, !serial.isEmpty else { return }
        let device = serial
        let result = await Adb.run(adb, ["-s", device, "shell", AdbRules.infoCommand], timeout: 10)
        guard device == serial, result.status == 0 else { return }
        info = AdbRules.parseInfo(result.stdout)
    }

    /// The first adb found where Android Studio, Homebrew or PATH put it.
    private func findAdb() -> String? {
        if let adbPath { return adbPath }
        let environment = ProcessInfo.processInfo.environment
        let candidates = AdbRules.adbCandidates(
            home: home,
            androidHome: environment["ANDROID_HOME"],
            sdkRoot: environment["ANDROID_SDK_ROOT"],
            pathFolders: (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        )
        adbPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        adbMissing = adbPath == nil
        return adbPath
    }

    // MARK: - Browsing

    func openFolder(_ path: String) {
        Task { await work("Opening \(AdbRules.baseName(path))…") { await self.list(path) } }
    }

    func goUp() {
        openFolder(AdbRules.parentPath(folder))
    }

    func goHome() {
        openFolder(AdbRules.homeFolder)
    }

    /// Double-click or Return, as in Finder: one folder opens in the list; files open on the Mac.
    func openItems(_ paths: Set<String>) {
        let items = entries.filter { paths.contains($0.path) }
        if items.count == 1, let only = items.first, only.isDir {
            openFolder(only.path)
            return
        }
        let files = items.filter { !$0.isDir }
        if !files.isEmpty { openOnMac(files) }
    }

    /// Pulls files into the temporary folder and opens each in its usual app on the Mac.
    private func openOnMac(_ files: [AdbEntry]) {
        guard let adb = adbPath, !serial.isEmpty, !isBusy else { return }
        let device = serial
        copyTask = Task {
            canStop = true
            message = ""
            var opened: [URL] = []
            var failed: [String] = []
            for file in files {
                if Task.isCancelled { break }
                busy = "Opening \(file.name)…"
                let folder = AdbDragItem.temporaryFolder
                    .appendingPathComponent("open", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let result = await Adb.run(adb, ["-s", device, "pull", "-a", file.path, folder.path + "/"])
                let url = folder.appendingPathComponent(file.name)
                if result.status == 0, FileManager.default.fileExists(atPath: url.path) {
                    opened.append(url)
                } else {
                    failed.append(file.name)
                }
            }
            busy = ""
            canStop = false
            for url in opened {
                NSWorkspace.shared.open(url)
            }
            if !failed.isEmpty && !Task.isCancelled {
                message = "Couldn't open \(failed.joined(separator: ", "))."
            }
        }
    }

    /// Lists `path`, or says why it can't be opened.
    private func list(_ path: String) async {
        guard let adb = adbPath, !serial.isEmpty else { return }
        let device = serial
        let result = await Adb.run(adb, ["-s", device, "shell", AdbRules.listCommand(path)], timeout: 30)
        guard device == serial else { return }
        let list = AdbRules.parseList(result.stdout, folder: path)
        if list.isEmpty && result.status != 0 {
            // stat fails on an empty folder too, so only give up when cd does.
            let probe = await Adb.run(adb, ["-s", device, "shell", AdbRules.canOpenCommand(path)], timeout: 10)
            if !probe.stdout.contains("ok") {
                let error = probe.stderr.lowercased()
                if error.contains("offline") || error.contains("no devices") || (error.contains("device") && error.contains("not found")) {
                    // Unplugged or gone from Wi-Fi: back to waiting for a device.
                    devices = []
                    choose("", listing: false)
                    message = "The device disconnected."
                } else if probe.failed && probe.stderr.isEmpty {
                    message = "The device didn't answer. Check it's connected, then click Refresh."
                } else {
                    message = "Can't open \(path) (no permission or not found)."
                }
                return
            }
        }
        if path != folder { selection = [] }
        folder = path
        entries = list
        folderSizes = [:]
        selection.formIntersection(list.map(\.path))
        remember(path, for: device)
    }

    /// Measures every folder in the folder showing.
    func measureFolders() {
        guard let adb = adbPath, !serial.isEmpty else { return }
        let device = serial
        let path = folder
        Task {
            await work("Measuring folders…") {
                let result = await Adb.run(adb, ["-s", device, "shell", AdbRules.sizesCommand(path)], timeout: 180)
                guard device == self.serial, path == self.folder else { return }
                self.folderSizes = AdbRules.parseSizes(result.stdout, folder: path)
            }
        }
    }

    // MARK: - Marking

    /// The size of the selected items that's known: files, and folders measured.
    var selectedBytes: Int64 {
        entries.filter { selection.contains($0.path) }
            .reduce(0) { $0 + ($1.isDir ? (folderSizes[$1.path] ?? 0) : $1.size) }
    }

    // MARK: - Pulling

    /// Where Pull puts things: ~/Downloads/adb-explorer/<model>.
    var downloadsFolder: URL {
        URL(fileURLWithPath: home)
            .appendingPathComponent("Downloads/adb-explorer", isDirectory: true)
            .appendingPathComponent(AdbRules.folderName(forModel: device?.model ?? serial), isDirectory: true)
    }

    /// Copies the selected items to `destination`, or to ~/Downloads/adb-explorer/<model>.
    func pull(to destination: URL? = nil) {
        guard let adb = adbPath, !serial.isEmpty, !isBusy else { return }
        let paths = selection.sorted()
        guard !paths.isEmpty else {
            message = "Select items first."
            return
        }
        let device = serial
        let folder = destination ?? downloadsFolder
        copyTask = Task {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                message = "Couldn't make \(Paths.tildify(folder.path, home: home)): \(error.localizedDescription)"
                return
            }
            var failed: [String] = []
            var done = 0
            canStop = true
            message = ""
            for (index, path) in paths.enumerated() {
                if Task.isCancelled { break }
                busy = paths.count > 1
                    ? "Pulling \(index + 1) of \(paths.count): \(AdbRules.baseName(path))…"
                    : "Pulling \(AdbRules.baseName(path))…"
                let result = await Adb.run(adb, ["-s", device, "pull", "-a", path, folder.path + "/"])
                if result.status == 0 { done += 1 } else { failed.append(path) }
            }
            let stopped = Task.isCancelled
            busy = ""
            canStop = false
            lastPullFolder = folder
            if device == serial {
                selection = Set(failed + (stopped ? paths.dropFirst(done + failed.count) : []))
            }
            let place = Paths.tildify(folder.path, home: home)
            if stopped {
                message = "Stopped. Pulled \(done) of \(Formatting.count(paths.count, "item")) to \(place)."
            } else if failed.isEmpty {
                message = "Pulled \(Formatting.count(done, "item")) to \(place)."
            } else {
                message = "Pulled \(done), \(failed.count) failed and \(failed.count == 1 ? "is" : "are") still selected."
            }
        }
    }

    /// Lets you pick a folder, then pulls the selected items there. Choosing it in the panel
    /// gives Kleyn access, so macOS doesn't ask.
    func pullToChosenFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Pull Here"
        panel.message = "Choose where to copy the selected items."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pull(to: url)
    }

    func showLastPullInFinder() {
        guard let lastPullFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastPullFolder])
    }

    /// Ends the copy running.
    func stop() {
        copyTask?.cancel()
    }

    // MARK: - Pushing

    /// Lets you pick files and folders on the Mac, then pushes them into the folder showing.
    func pushChosenItems() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Push"
        panel.message = "Choose files or folders to copy to \(folder) on the device."
        guard panel.runModal() == .OK else { return }
        push(panel.urls)
    }

    /// Copies files and folders from the Mac into the folder showing, for Push… and drops.
    func push(_ urls: [URL]) {
        guard let adb = adbPath, !serial.isEmpty, !isBusy else { return }
        let sources = urls.filter(\.isFileURL).map(\.path)
        guard !sources.isEmpty else { return }
        let missing = sources.filter { !FileManager.default.fileExists(atPath: $0) }
        guard missing.isEmpty else {
            message = "Not found on this Mac: \(missing.joined(separator: ", "))"
            return
        }
        let device = serial
        let destination = folder
        copyTask = Task {
            var failed: [String] = []
            var lastError = ""
            var done = 0
            canStop = true
            message = ""
            for (index, source) in sources.enumerated() {
                if Task.isCancelled { break }
                let name = AdbRules.baseName(source)
                busy = sources.count > 1 ? "Pushing \(index + 1) of \(sources.count): \(name)…" : "Pushing \(name)…"
                let result = await Adb.run(adb, ["-s", device, "push", source, destination + "/"])
                if result.status == 0 {
                    done += 1
                } else {
                    failed.append(name)
                    lastError = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            let stopped = Task.isCancelled
            busy = ""
            canStop = false
            if device == serial {
                await list(destination)
                await refreshInfo()
            }
            if stopped {
                message = "Stopped. Pushed \(done) of \(Formatting.count(sources.count, "item")) to \(destination)."
            } else if failed.isEmpty {
                message = sources.count == 1
                    ? "Pushed \(AdbRules.baseName(sources[0])) to \(destination)."
                    : "Pushed \(Formatting.count(done, "item")) to \(destination)."
            } else {
                message = "Pushed \(done) to \(destination); failed: \(failed.joined(separator: ", "))" + (lastError.isEmpty ? "." : " (\(lastError)).")
            }
        }
    }

    // MARK: - Deleting

    /// What a delete would touch: the selected paths inside user storage, and those refused.
    func deletePlan() -> (allowed: [String], refused: [String]) {
        let paths = selection.sorted()
        return (paths.filter(AdbRules.isDeletable), paths.filter { !AdbRules.isDeletable($0) })
    }

    /// Moves the selected items to the device trash, or deletes them for good, after the page has asked.
    func delete(permanently: Bool) {
        guard let adb = adbPath, !serial.isEmpty, !isBusy else { return }
        // Checked again here, not left to the page.
        let (allowed, refused) = deletePlan()
        guard !allowed.isEmpty else {
            message = "Only items inside /sdcard can be deleted from here."
            return
        }
        let device = serial
        let command = permanently
            ? AdbRules.deleteCommand(allowed)
            : AdbRules.trashCommand(allowed, stamp: AdbRules.stamp(of: .now))
        Task {
            await work(permanently ? "Deleting…" : "Moving to the device trash…") {
                let result = await Adb.run(adb, ["-s", device, "shell", command], timeout: 120)
                guard result.status == 0 else {
                    let why = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                    self.message = why.isEmpty ? "The device refused the delete." : why
                    return
                }
                self.selection = Set(refused)
                await self.list(self.folder)
                await self.refreshInfo()
                self.message = permanently
                    ? "Deleted \(Formatting.count(allowed.count, "item"))."
                    : "Moved \(Formatting.count(allowed.count, "item")) to \(AdbRules.trashFolder). Delete them there when you're sure."
            }
        }
    }

    // MARK: - Dragging out

    /// What a drag to Finder needs to pull each item when it's dropped.
    func dragItems(for paths: [String]) -> [AdbDragItem] {
        paths.compactMap { path in
            entries.first { $0.path == path }.map { AdbDragItem(entry: $0, serial: serial, adb: adbPath ?? "") }
        }
    }

    // MARK: - Private

    /// Runs `body` with the busy line showing. One thing at a time.
    private func work(_ label: String, _ body: () async -> Void) async {
        guard !isBusy else { return }
        busy = label
        message = ""
        await body()
        busy = ""
    }

    private func rememberedFolder(for serial: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: Self.foldersKey) as? [String: String])?[serial]
    }

    private func remember(_ folder: String, for serial: String) {
        var folders = (UserDefaults.standard.dictionary(forKey: Self.foldersKey) as? [String: String]) ?? [:]
        folders[serial] = folder
        UserDefaults.standard.set(folders, forKey: Self.foldersKey)
    }
}

/// Running adb, off the main thread.
nonisolated enum Adb {
    struct Result: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
        /// adb couldn't be started, or was stopped.
        var failed = false
    }

    /// Runs adb with `arguments`, as an argument list, never through a shell on the Mac.
    /// Ends it after `timeout` seconds if given, and when the calling task is cancelled.
    /// With `quiet`, its output goes nowhere and isn't read.
    @concurrent
    static func run(_ adb: String, _ arguments: [String], quiet: Bool = false, timeout: TimeInterval? = nil) async -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = quiet ? FileHandle.nullDevice : output
        process.standardError = quiet ? FileHandle.nullDevice : errors
        let box = ProcessBox(process)

        return await withTaskCancellationHandler {
            do {
                try process.run()
            } catch {
                return Result(status: -1, stdout: "", stderr: error.localizedDescription, failed: true)
            }
            if Task.isCancelled { box.stop() }
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { box.stop() }
            }
            var out = Data()
            var err = Data()
            if !quiet {
                // Both pipes at once, so a full one can't stall adb.
                async let readOut = readAll(output.fileHandleForReading)
                async let readErr = readAll(errors.fileHandleForReading)
                (out, err) = await (readOut, readErr)
            }
            process.waitUntilExit()
            return Result(
                status: process.terminationStatus,
                stdout: String(decoding: out, as: UTF8.self),
                stderr: String(decoding: err, as: UTF8.self),
                failed: process.terminationReason == .uncaughtSignal
            )
        } onCancel: {
            box.stop()
        }
    }

    @concurrent
    private static func readAll(_ handle: FileHandle) async -> Data {
        (try? handle.readToEnd()) ?? Data()
    }

    /// Lets a cancel or a timeout end the process from another thread.
    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
        func stop() {
            if process.isRunning { process.terminate() }
        }
    }
}
