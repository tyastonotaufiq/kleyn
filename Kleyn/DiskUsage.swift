//
//  DiskUsage.swift
//  Kleyn
//
//  How much disk space a file or folder takes, shared by the Cleaner and the Uninstaller.
//

import Foundation

nonisolated enum DiskUsage {
    /// The disk space a file or folder takes, adding up every file inside, as `du` counts it.
    /// Symbolic links aren't followed. `unreadable` is true when part of it couldn't be read,
    /// so the size is low. Stops early when the task is cancelled. Blocks: call it off the main thread.
    static func allocatedSize(of path: String) -> (bytes: Int64, unreadable: Bool) {
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
    private final class Flag: @unchecked Sendable {
        var isSet = false
    }
}
