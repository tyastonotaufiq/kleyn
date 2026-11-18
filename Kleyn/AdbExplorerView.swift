//
//  AdbExplorerView.swift
//  Kleyn
//

import SwiftUI

/// The ADB Explorer page: files on an Android device, with pull, push and delete.
struct AdbExplorerView: View {
    @Bindable var explorer: AdbExplorer

    @State private var deleteRequest: (allowed: [String], refused: [String])?
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if explorer.serial.isEmpty {
                noDevice
            } else {
                browser
            }
        }
        // Looks for adb and devices while the page shows, and stops when you leave it.
        .task { await explorer.watch() }
    }

    // MARK: - No device

    @ViewBuilder
    private var noDevice: some View {
        if explorer.adbMissing {
            ContentUnavailableView {
                Label("adb Not Found", systemImage: "wrench.and.screwdriver")
            } description: {
                Text("ADB Explorer uses adb, which comes with Android Studio. Without Android Studio, install it with Homebrew:")
                Text("brew install android-platform-tools")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            } actions: {
                Button("Look Again", action: explorer.refreshNow)
            }
        } else {
            ContentUnavailableView {
                Label(noDeviceTitle, systemImage: "smartphone")
            } description: {
                Text(noDeviceAdvice)
            } actions: {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for devices…")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var noDeviceTitle: String {
        if explorer.devices.contains(where: { $0.state == "unauthorized" }) { return "Allow USB Debugging" }
        if explorer.devices.contains(where: { $0.state == "offline" }) { return "Device Offline" }
        return "No Android Device"
    }

    private var noDeviceAdvice: String {
        if explorer.devices.contains(where: { $0.state == "unauthorized" }) {
            return "Unlock the phone and tap Allow on the \u{201C}Allow USB debugging?\u{201D} prompt."
        }
        if explorer.devices.contains(where: { $0.state == "offline" }) {
            return "On USB, unplug the phone and plug it back in. On Wi-Fi, turn Wireless debugging off and on."
        }
        return "Connect the phone by USB with USB debugging on (Settings › Developer options), or turn on Wireless debugging there and pair the phone in Android Studio with Pair Devices Using Wi-Fi."
    }

    // MARK: - Browser

    private var browser: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Divider()
            fileList
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(get: { deleteRequest != nil }, set: { if !$0 { deleteRequest = nil } })
        ) {
            Button("Move to Device Trash") { explorer.delete(permanently: false) }
            Button("Delete Permanently", role: .destructive) { explorer.delete(permanently: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(explorer.deviceName)
                        .font(.title2.bold())
                    if let info = explorer.info, !AdbRules.infoLine(info).isEmpty {
                        Text(AdbRules.infoLine(info))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer()
                if explorer.readyDevices.count > 1 {
                    Picker("Device", selection: Binding(get: { explorer.serial }, set: explorer.selectDevice)) {
                        ForEach(explorer.readyDevices) { device in
                            Text("\(device.model) (\(device.serial))").tag(device.serial)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            HStack(spacing: 8) {
                Button("Up", systemImage: "arrow.up", action: explorer.goUp)
                    .labelStyle(.iconOnly)
                    .keyboardShortcut(.upArrow)
                    .help("Up one folder (⌘↑)")
                    .disabled(explorer.folder == "/")
                Button("Home", systemImage: "house", action: explorer.goHome)
                    .labelStyle(.iconOnly)
                    .help("Go to \(AdbRules.homeFolder)")
                Button("Refresh", systemImage: "arrow.clockwise", action: explorer.refreshNow)
                    .labelStyle(.iconOnly)
                    .keyboardShortcut("r")
                    .help("Check devices and list this folder again (⌘R)")
                Text(explorer.folder)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
                    .help(explorer.folder)
                Spacer(minLength: 8)
                Button("Folder Sizes", systemImage: "chart.bar.xaxis", action: explorer.measureFolders)
                    .labelStyle(.iconOnly)
                    .help("Measure the folders in this folder")
                Button(
                    explorer.showHidden ? "Hide Hidden Files" : "Show Hidden Files",
                    systemImage: explorer.showHidden ? "eye" : "eye.slash"
                ) {
                    explorer.showHidden.toggle()
                }
                .labelStyle(.iconOnly)
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .help(explorer.showHidden ? "Hide files starting with a dot (⌘⇧.)" : "Show files starting with a dot (⌘⇧.)")
                Button("Push…", systemImage: "square.and.arrow.up", action: explorer.pushChosenItems)
                    .help("Copy files or folders from this Mac into this folder. You can also drag them onto the list.")
            }
            .disabled(explorer.isBusy)

            status
        }
    }

    @ViewBuilder
    private var status: some View {
        if explorer.isBusy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(explorer.busy)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if explorer.canStop {
                    Button("Stop", action: explorer.stop)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else if !explorer.message.isEmpty {
            // No fixedSize: the window takes its minimum size from the page, measured at a tiny width.
            Text(explorer.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }

    private var fileList: some View {
        // Works like a Finder list: click selects, ⌘-click and ⇧-click select more, ⌘A selects all.
        List(selection: $explorer.selection) {
            ForEach(explorer.visibleEntries) { entry in
                EntryRow(explorer: explorer, entry: entry)
                    .draggable(containerItemID: entry.path)
            }
        }
        // Double-click or Return opens: a folder in the list, files on the Mac.
        .contextMenu(forSelectionType: String.self) { paths in
            itemMenu(paths)
        } primaryAction: { paths in
            explorer.openItems(paths)
        }
        // Dragging to Finder pulls what's dragged there: every selected item when you drag one of them.
        .dragContainer(for: AdbDragItem.self, itemID: \.entry.path) { paths in
            explorer.dragItems(for: paths)
        }
        .dragContainerSelection(Array(explorer.selection))
        .overlay {
            if explorer.visibleEntries.isEmpty && !explorer.isBusy {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            }
        }
        // Dropping files or folders from Finder pushes them into this folder.
        .dropDestination(for: URL.self) { urls, _ in
            explorer.push(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The menu for a right-click: on items, what you can do with them; on empty space, Push.
    @ViewBuilder
    private func itemMenu(_ paths: Set<String>) -> some View {
        if paths.isEmpty {
            Button("Push…", action: explorer.pushChosenItems)
        } else {
            Button("Open") { explorer.openItems(paths) }
            Divider()
            Button("Pull to Downloads") {
                explorer.selection = paths
                explorer.pull()
            }
            Button("Pull To…") {
                explorer.selection = paths
                explorer.pullToChosenFolder()
            }
            Divider()
            Button("Delete…") {
                explorer.selection = paths
                confirmDelete()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(selectionText)
                .foregroundStyle(explorer.selection.isEmpty ? .secondary : .primary)
                .monospacedDigit()
            Spacer()
            Button("Delete…", action: confirmDelete)
                .keyboardShortcut(.delete)
                .disabled(explorer.selection.isEmpty || explorer.isBusy)
                .help("Move the selected items to the device trash, or delete them (⌘⌫). Asks first.")
            Menu("Pull") {
                Button("Pull To…", action: explorer.pullToChosenFolder)
                    .disabled(explorer.selection.isEmpty || explorer.isBusy)
                Divider()
                Button("Show Last Pull in Finder", action: explorer.showLastPullInFinder)
                    .disabled(explorer.lastPullFolder == nil)
            } primaryAction: {
                explorer.pull()
            }
            .fixedSize()
            .disabled(explorer.isBusy)
            .help("Copy the selected items to \(CleanerRules.tildify(explorer.downloadsFolder.path, home: explorer.home)). You can also drag items to Finder.")
        }
    }

    /// "3 of 120 selected, 1.2 MB", or "120 items", as Finder's status bar says it.
    private var selectionText: String {
        let total = explorer.visibleEntries.count
        guard !explorer.selection.isEmpty else { return CleanerRules.count(total, "item") }
        let bytes = explorer.selectedBytes
        return "\(explorer.selection.count) of \(total) selected" + (bytes > 0 ? ", \(AdbRules.sizeLabel(bytes))" : "")
    }

    private func confirmDelete() {
        let plan = explorer.deletePlan()
        if plan.allowed.isEmpty {
            // Says why nothing can be deleted, without asking.
            explorer.delete(permanently: false)
        } else {
            deleteRequest = plan
        }
    }

    private var deleteTitle: String {
        "Delete \(CleanerRules.count(deleteRequest?.allowed.count ?? 0, "item")) from the device?"
    }

    private var deleteMessage: String {
        var text = "Move to Device Trash puts them in \(AdbRules.trashFolder) on the phone, where you can get them back. Delete Permanently can't be undone."
        if let refused = deleteRequest?.refused.count, refused > 0 {
            text += " \(CleanerRules.count(refused, "item")) outside /sdcard will be skipped."
        }
        return text
    }
}

private struct EntryRow: View {
    let explorer: AdbExplorer
    let entry: AdbEntry

    @State private var thumbnail: NSImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: thumbnail ?? explorer.thumbnails.icon(for: entry))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(Date(timeIntervalSince1970: TimeInterval(entry.mtime)).formatted(date: .numeric, time: .shortened))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Text(sizeText)
                .monospacedDigit()
                .foregroundStyle(entry.isDir && explorer.folderSizes[entry.path] == nil ? .secondary : .primary)
                .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.vertical, 2)
        // Pulled for its thumbnail once the row shows; scrolling away cancels the pull.
        .task(id: thumbnailKey) {
            thumbnail = explorer.thumbnails.cachedThumbnail(for: entry, serial: explorer.serial)
            guard thumbnail == nil, AdbThumbnails.wantsThumbnail(entry) else { return }
            thumbnail = await explorer.thumbnails.thumbnail(
                for: entry,
                serial: explorer.serial,
                adb: explorer.adbPath ?? "",
                scale: displayScale
            )
        }
    }

    private var thumbnailKey: String {
        "\(explorer.serial)|\(entry.path)|\(entry.size)|\(entry.mtime)"
    }

    /// A file's size; a folder's once measured, else "--" as Finder shows it.
    private var sizeText: String {
        if entry.isDir {
            return explorer.folderSizes[entry.path].map { AdbRules.sizeLabel($0) } ?? "--"
        }
        return AdbRules.sizeLabel(entry.size)
    }
}

#Preview {
    AdbExplorerView(explorer: AdbExplorer())
}
