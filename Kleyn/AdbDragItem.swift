//
//  AdbDragItem.swift
//  Kleyn
//

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A file or folder on the device, dragged out of ADB Explorer to Finder or the Desktop.
///
/// Finder asks for the item only when it's dropped (a file promise). Kleyn then pulls it
/// into a folder of its own in the temporary folder and hands it over, and Finder copies it
/// where it was dropped.
nonisolated struct AdbDragItem: Transferable {
    let entry: AdbEntry
    let serial: String
    let adb: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .folder) { try await $0.pull() }
            .exportingCondition { $0.entry.isDir }
            .suggestedFileName { $0.entry.name }
        FileRepresentation(exportedContentType: .data) { try await $0.pull() }
            .exportingCondition { !$0.entry.isDir }
            .suggestedFileName { $0.entry.name }
    }

    /// Where dragged items are pulled to. Cleared when Kleyn starts.
    static var temporaryFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Kleyn-adb", isDirectory: true)
    }

    /// Removes what earlier drags left in the temporary folder.
    static func clearTemporaryFolder() {
        try? FileManager.default.removeItem(at: temporaryFolder)
    }

    private func pull() async throws -> SentTransferredFile {
        let folder = Self.temporaryFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = await Adb.run(adb, ["-s", serial, "pull", "-a", entry.path, folder.path + "/"])
        let file = folder.appendingPathComponent(entry.name, isDirectory: entry.isDir)
        guard result.status == 0, FileManager.default.fileExists(atPath: file.path) else {
            let why = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw PullError(message: why.isEmpty ? "Couldn't pull \(entry.name) from the device." : why)
        }
        return SentTransferredFile(file)
    }

    private struct PullError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
