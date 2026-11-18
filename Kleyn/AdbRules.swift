//
//  AdbRules.swift
//  Kleyn
//
//  The parts of ADB Explorer that run nothing, kept apart so they can be tested:
//  where adb is, the commands sent to the phone's shell and their quoting, parsing
//  what adb prints, and the rules for what may be deleted.
//  Ported from claude-mods/adb-explorer/hooks/adb.ts.
//

import Foundation

/// A device `adb devices -l` lists.
nonisolated struct AdbDevice: Equatable, Identifiable, Sendable {
    var serial: String
    /// "device" when ready; "unauthorized" until USB debugging is allowed; "offline"…
    var state: String
    var model: String

    var id: String { serial }
    var isReady: Bool { state == "device" }
}

/// What the header shows about a device; empty or nil when the device doesn't say.
nonisolated struct AdbInfo: Equatable, Sendable {
    var name = ""
    var release = ""
    var sdk = ""
    var freeBytes: Int64?
    var totalBytes: Int64?
    var battery: Int?
    var charging = false
}

/// A file or folder on the device.
nonisolated struct AdbEntry: Equatable, Hashable, Identifiable, Sendable {
    var name: String
    var path: String
    var isDir: Bool
    var size: Int64
    /// Seconds since 1970.
    var mtime: Int64

    var id: String { path }
}

nonisolated enum AdbRules {
    /// Where browsing starts.
    static let homeFolder = "/sdcard"

    /// Folders a user's files live under. Deletes are only allowed inside them.
    static let storageRoots = ["/sdcard", "/storage/emulated/0", "/storage/self/primary"]

    /// Where Move to Device Trash puts things. In user storage, so it's a cheap rename.
    static let trashFolder = "/sdcard/_adb_trash"

    // MARK: - Finding adb

    /// Where to look for adb, in order. The Android SDK comes first, so Kleyn uses the same adb
    /// as Android Studio: two adb versions keep killing each other's server and drop Studio's
    /// connection. An app opened from Finder rarely has the shell's ANDROID_HOME or PATH, so
    /// they're checked but the usual places are too.
    static func adbCandidates(home: String, androidHome: String? = nil, sdkRoot: String? = nil, pathFolders: [String] = []) -> [String] {
        let sdks = [androidHome, sdkRoot, home + "/Library/Android/sdk", home + "/Android/Sdk"]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .map { trimTrailingSlashes($0) + "/platform-tools/adb" }
        let list = sdks
            + pathFolders.filter { !$0.isEmpty }.map { trimTrailingSlashes($0) + "/adb" }
            + ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        var seen: [String] = []
        for path in list where !seen.contains(path) {
            seen.append(path)
        }
        return seen
    }

    // MARK: - The device's shell

    /// Quotes a string for the Android device's /system/bin/sh.
    static func shQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// One shell command for the header: the marketing name, Android version, free space in user
    /// storage and the battery. Each value is on its own labelled line, so a value the device
    /// doesn't have is just blank.
    static let infoCommand = [
        #"echo "name=$(getprop ro.product.marketname)""#,
        #"echo "release=$(getprop ro.build.version.release)""#,
        #"echo "sdk=$(getprop ro.build.version.sdk)""#,
        #"echo "df=$(df -k /sdcard 2>/dev/null | tail -n 1)""#,
        "dumpsys battery 2>/dev/null | grep -E '^ *(level|status):'",
    ].joined(separator: "; ")

    /// The shell command that lists one folder. Each line is `<type>/<size>/<mtime>/<name>`:
    /// `/` can't appear in a file name, so the name is everything after the third slash.
    /// `-L` follows symbolic links, so links to folders (like /sdcard) list as folders.
    static func listCommand(_ folder: String) -> String {
        "cd \(shQuote(folder)) && stat -L -c '%F/%s/%Y/%n' -- * .* 2>/dev/null"
    }

    /// The shell command that checks a folder can be opened, for when a listing comes back empty.
    static func canOpenCommand(_ folder: String) -> String {
        "cd \(shQuote(folder)) && echo ok"
    }

    /// The shell command that sizes every subfolder of `folder`, in KiB.
    static func sizesCommand(_ folder: String) -> String {
        #"cd \#(shQuote(folder)) && for d in * .*; do [ -d "$d" ] && [ "$d" != . ] && [ "$d" != .. ] && du -sk -- "$d" 2>/dev/null; done"#
    }

    /// The shell command that moves `paths` into a time-stamped trash folder.
    static func trashCommand(_ paths: [String], stamp: String) -> String {
        let destination = "\(trashFolder)/\(stamp)"
        return "mkdir -p \(shQuote(destination)) && mv -- \(paths.map(shQuote).joined(separator: " ")) \(shQuote(destination))/"
    }

    /// The shell command that permanently deletes `paths`.
    static func deleteCommand(_ paths: [String]) -> String {
        "rm -rf -- " + paths.map(shQuote).joined(separator: " ")
    }

    // MARK: - Parsing

    /// Parses `adb devices -l`.
    static func parseDevices(_ output: String) -> [AdbDevice] {
        var devices: [AdbDevice] = []
        for raw in lines(output) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("List of devices") || line.hasPrefix("*") { continue }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2 else { continue }
            let model = parts.first { $0.hasPrefix("model:") }
                .map { String($0.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ") }
            devices.append(AdbDevice(serial: parts[0], state: parts[1], model: model ?? parts[0]))
        }
        return devices
    }

    /// Parses the output of `infoCommand`.
    static func parseInfo(_ output: String) -> AdbInfo {
        var info = AdbInfo()
        var seen: Set<String> = []
        /// The first line's value for each label, as the mod's regular expressions find it.
        func once(_ key: String, _ apply: () -> Void) {
            guard !seen.contains(key) else { return }
            seen.insert(key)
            apply()
        }
        for raw in lines(output) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("name=") {
                once("name") { info.name = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            } else if line.hasPrefix("release=") {
                once("release") { info.release = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
            } else if line.hasPrefix("sdk=") {
                once("sdk") { info.sdk = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
            } else if line.hasPrefix("df=") {
                // df -k: filesystem, 1K-blocks, used, available, ...
                let fields = line.dropFirst(3).split(whereSeparator: \.isWhitespace)
                if fields.count >= 4, let total = Int64(fields[1]), Int64(fields[2]) != nil, let free = Int64(fields[3]) {
                    once("df") {
                        info.totalBytes = total * 1024
                        info.freeBytes = free * 1024
                    }
                }
            } else if trimmed.hasPrefix("level:"), let level = Int(trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)) {
                once("level") { info.battery = level }
            } else if trimmed.hasPrefix("status:"), let status = Int(trimmed.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                // BatteryManager.BATTERY_STATUS_CHARGING
                once("status") { info.charging = status == 2 }
            }
        }
        return info
    }

    /// The header line under the device's name: "Android 16 (API 36) · 3.2 GB free of 10.7 GB · Battery 80%".
    static func infoLine(_ info: AdbInfo, locale: Locale = .current) -> String {
        var parts: [String] = []
        if !info.release.isEmpty {
            parts.append("Android \(info.release)" + (info.sdk.isEmpty ? "" : " (API \(info.sdk))"))
        }
        if let free = info.freeBytes, let total = info.totalBytes, total > 0 {
            parts.append("\(sizeLabel(free, locale: locale)) free of \(sizeLabel(total, locale: locale))")
        }
        if let battery = info.battery {
            parts.append("Battery \(battery)%" + (info.charging ? ", charging" : ""))
        }
        return parts.joined(separator: " · ")
    }

    /// Parses the output of `listCommand`: folders first, then files, each by name.
    static func parseList(_ output: String, folder: String) -> [AdbEntry] {
        var entries: [AdbEntry] = []
        for raw in lines(output) {
            let line = String(raw)
            let fields = line.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, !fields[0].isEmpty,
                  let size = Int64(fields[1]), fields[1].allSatisfy(\.isNumber),
                  let mtime = Int64(fields[2]), fields[2].allSatisfy(\.isNumber),
                  !fields[3].isEmpty
            else { continue }
            let name = String(fields[3])
            if [".", "..", "*", ".*"].contains(name) { continue }
            entries.append(AdbEntry(
                name: name,
                path: joinPath(folder, name),
                isDir: fields[0] == "directory",
                size: size,
                mtime: mtime
            ))
        }
        return entries.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.compare(b.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedAscending
        }
    }

    /// Parses `du -sk` lines into bytes by full path.
    static func parseSizes(_ output: String, folder: String) -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for raw in lines(output) {
            let line = String(raw)
            guard let gap = line.firstIndex(where: \.isWhitespace),
                  let kib = Int64(line[..<gap]), line[..<gap].allSatisfy(\.isNumber)
            else { continue }
            var name = line[gap...].drop(while: \.isWhitespace)
            if name.hasSuffix("/") { name = name.dropLast() }
            guard !name.isEmpty else { continue }
            sizes[joinPath(folder, String(name))] = kib * 1024
        }
        return sizes
    }

    // MARK: - Paths

    /// Joins a folder and a name on the device.
    static func joinPath(_ folder: String, _ name: String) -> String {
        folder == "/" ? "/" + name : trimTrailingSlashes(folder) + "/" + name
    }

    /// The parent folder of a device path.
    static func parentPath(_ path: String) -> String {
        let trimmed = trimTrailingSlashes(path)
        guard let slash = trimmed.lastIndex(of: "/"), slash > trimmed.startIndex else { return "/" }
        return String(trimmed[..<slash])
    }

    /// The last part of a path, for messages: `/a/b/` gives `b`.
    static func baseName(_ path: String) -> String {
        let trimmed = trimTrailingSlashes(path)
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed.isEmpty ? path : trimmed }
        let name = String(trimmed[trimmed.index(after: slash)...])
        return name.isEmpty ? path : name
    }

    /// Whether a path may be deleted or moved to the device trash: strictly inside a storage
    /// root (never the root itself), and never the trash folder itself.
    static func isDeletable(_ path: String) -> Bool {
        let clean = trimTrailingSlashes(path)
        if clean.contains("/../") || clean.hasSuffix("/..") { return false }
        if clean == trashFolder { return false }
        return storageRoots.contains { root in clean.hasPrefix(root + "/") && clean.count > root.count + 1 }
    }

    // MARK: - Formatting

    /// A time stamp safe for a folder name: 2026-10-15_14-55-02.
    static func stamp(of date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d_%02d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// A device model made safe for a folder name: "Pixel 8 Pro" gives "Pixel-8-Pro".
    static func folderName(forModel model: String) -> String {
        var name = ""
        var lastWasDash = false
        for character in model {
            if character.isLetter || character.isNumber || character == "_" || character == "." || character == "-" {
                name.append(character)
                lastWasDash = false
            } else if !lastWasDash {
                name.append("-")
                lastWasDash = true
            }
        }
        return name.isEmpty ? "device" : name
    }

    /// A size as Finder shows it, like the rest of Kleyn; "0 bytes" for an empty file.
    static func sizeLabel(_ bytes: Int64, locale: Locale = .current) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }

    /// The lines of what adb printed. Some devices end lines with \r\n, which Swift counts as one
    /// character, so splitting on \n alone would miss them: carriage returns go first.
    private static func lines(_ output: String) -> [Substring] {
        output.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false)
    }

    private static func trimTrailingSlashes(_ path: String) -> String {
        var path = path
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
