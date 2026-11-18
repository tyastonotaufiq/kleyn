//
//  AdbThumbnails.swift
//  Kleyn
//

import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Icons and thumbnails for the files on the device.
///
/// Every file gets the icon for its type right away, from its name alone. Images, PDFs and
/// videos up to `maxBytes` also get a real thumbnail: the file is pulled into the temporary
/// folder, Quick Look draws it, and the copy is deleted. Thumbnails stay in memory only,
/// so nothing piles up on disk.
final class AdbThumbnails {
    /// Bigger files keep their icon: pulling them just for a thumbnail costs too much.
    nonisolated static let maxBytes: Int64 = 25_000_000

    /// How many files are pulled for thumbnails at once.
    private static let jobs = 2

    private let images = NSCache<NSString, NSImage>()
    /// Files Quick Look couldn't draw, so they aren't pulled again.
    private var failed: Set<String> = []
    private var icons: [String: NSImage] = [:]
    private let gate = Gate(slots: AdbThumbnails.jobs)

    init() {
        images.countLimit = 2000
    }

    /// The icon for a file's type, from its extension, or the folder icon.
    func icon(for entry: AdbEntry) -> NSImage {
        let key = entry.isDir ? "/folder" : (entry.name as NSString).pathExtension.lowercased()
        if let icon = icons[key] { return icon }
        let type: UTType = entry.isDir ? .folder : (UTType(filenameExtension: key) ?? .data)
        let icon = NSWorkspace.shared.icon(for: type)
        icons[key] = icon
        return icon
    }

    /// Whether a file gets a real thumbnail: an image, PDF or video small enough to pull.
    nonisolated static func wantsThumbnail(_ entry: AdbEntry) -> Bool {
        guard !entry.isDir, entry.size > 0, entry.size <= maxBytes,
              let type = UTType(filenameExtension: (entry.name as NSString).pathExtension)
        else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .movie)
    }

    /// A thumbnail already made, without pulling anything.
    func cachedThumbnail(for entry: AdbEntry, serial: String) -> NSImage? {
        images.object(forKey: Self.key(entry, serial: serial) as NSString)
    }

    /// The thumbnail of `entry`, pulling it if needed. Nil when it doesn't get one, Quick Look
    /// can't draw it, or the calling task is cancelled (its row scrolled away), which stops the pull.
    func thumbnail(for entry: AdbEntry, serial: String, adb: String, scale: CGFloat) async -> NSImage? {
        guard Self.wantsThumbnail(entry), !adb.isEmpty, !serial.isEmpty else { return nil }
        let key = Self.key(entry, serial: serial)
        if let image = images.object(forKey: key as NSString) { return image }
        guard !failed.contains(key) else { return nil }

        await gate.enter()
        defer { Task { await gate.leave() } }
        // It may have scrolled away while waiting its turn, or another row made it meanwhile.
        if Task.isCancelled { return nil }
        if let image = images.object(forKey: key as NSString) { return image }

        let folder = AdbDragItem.temporaryFolder
            .appendingPathComponent("thumbnails", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let result = await Adb.run(adb, ["-s", serial, "pull", entry.path, folder.path + "/"])
        if Task.isCancelled { return nil }
        let file = folder.appendingPathComponent(entry.name)
        guard result.status == 0, FileManager.default.fileExists(atPath: file.path) else {
            failed.insert(key)
            return nil
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: file,
            size: CGSize(width: 64, height: 64),
            scale: scale,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            failed.insert(key)
            return nil
        }
        let image = representation.nsImage
        images.setObject(image, forKey: key as NSString)
        return image
    }

    /// One file as it is now: a new size or date makes a new thumbnail.
    private static func key(_ entry: AdbEntry, serial: String) -> String {
        "\(serial)|\(entry.path)|\(entry.size)|\(entry.mtime)"
    }

    /// Lets `slots` pulls run at once; the rest wait their turn.
    private actor Gate {
        private var free: Int
        private var waiting: [CheckedContinuation<Void, Never>] = []

        init(slots: Int) {
            free = slots
        }

        func enter() async {
            if free > 0 {
                free -= 1
                return
            }
            await withCheckedContinuation { waiting.append($0) }
        }

        func leave() {
            if waiting.isEmpty {
                free += 1
            } else {
                waiting.removeFirst().resume()
            }
        }
    }
}
