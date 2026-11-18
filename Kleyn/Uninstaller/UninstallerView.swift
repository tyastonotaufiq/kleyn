//
//  UninstallerView.swift
//  Kleyn
//

import SwiftUI

/// The Uninstaller page: all apps, one app with what it left, and leftovers of removed apps.
struct UninstallerView: View {
    @Bindable var uninstaller: Uninstaller

    var body: some View {
        NavigationStack(path: $uninstaller.path) {
            AppListView(uninstaller: uninstaller)
                .navigationDestination(for: Uninstaller.Screen.self) { screen in
                    switch screen {
                    case .app(let app):
                        AppLeftoversView(uninstaller: uninstaller, app: app)
                    case .removedApps:
                        RemovedAppsView(uninstaller: uninstaller)
                    }
                }
        }
        // After you move things to the Trash in Finder and come back, rows for what's gone disappear.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            uninstaller.dropMissing()
        }
    }
}

// MARK: - All apps

private struct AppListView: View {
    @Bindable var uninstaller: Uninstaller

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Uninstaller")
                            .font(.title2.bold())
                        Text(uninstaller.isLoadingApps && uninstaller.apps.isEmpty
                             ? "Reading installed apps…"
                             : Formatting.count(uninstaller.apps.count, "app"))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reload", systemImage: "arrow.clockwise") {
                        Task { await uninstaller.loadApps() }
                    }
                    .keyboardShortcut("r")
                    .disabled(uninstaller.isLoadingApps)
                }
                TextField("Search", text: $uninstaller.query, prompt: Text("Find an app by name or bundle ID"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(uninstaller.openFirstMatch)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()

            List {
                Section {
                    NavigationLink(value: Uninstaller.Screen.removedApps) {
                        Label("Leftovers of Removed Apps", systemImage: "questionmark.folder")
                    }
                }
                Section {
                    ForEach(uninstaller.filteredApps) { app in
                        NavigationLink(value: Uninstaller.Screen.app(app)) {
                            AppRow(app: app)
                        }
                    }
                } footer: {
                    if !uninstaller.apps.isEmpty && uninstaller.filteredApps.isEmpty {
                        Text("No app matches \u{201C}\(uninstaller.query.trimmingCharacters(in: .whitespaces))\u{201D}.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task { await uninstaller.loadAppsIfNeeded() }
    }
}

private struct AppRow: View {
    let app: InstalledApp

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(path: app.path, size: 24)
            Text(app.name)
            Spacer()
            Text(app.version)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private struct AppIcon: View {
    let path: String
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .frame(width: size, height: size)
    }
}

// MARK: - One app

private struct AppLeftoversView: View {
    let uninstaller: Uninstaller
    let app: InstalledApp

    @State private var isRunning = false

    private var rows: [Leftover] { uninstaller.leftovers }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Divider()
            if rows.isEmpty {
                ContentUnavailableView {
                    Label(uninstaller.isScanningApp ? "Looking…" : "Nothing Left", systemImage: "magnifyingglass")
                } description: {
                    Text(uninstaller.isScanningApp
                         ? "Looking for what \(app.name) left in your Library folder."
                         : "\(app.name) and what it left are gone.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(rows) { row in
                    LeftoverRow(uninstaller: uninstaller, row: row)
                }
            }
            Divider()
            MarkFooter(
                markedCount: uninstaller.markedLeftovers.count,
                markedBytes: rows.filter(uninstaller.isMarked).reduce(0) { $0 + (uninstaller.size(of: $1) ?? 0) },
                markAll: uninstaller.markAllLeftovers,
                unmarkAll: uninstaller.unmarkAllLeftovers,
                showInFinder: uninstaller.showMarkedLeftovers
            )
        }
        .navigationTitle(app.name)
        .task(id: uninstaller.scanGeneration) { await uninstaller.scan(app) }
        .onAppear(perform: checkRunning)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            checkRunning()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            checkRunning()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                AppIcon(path: app.path, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.title2.bold())
                    Text(summary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button("Rescan", systemImage: "arrow.clockwise", action: uninstaller.rescan)
                    .keyboardShortcut("r")
            }
            StatusLine(
                isWorking: uninstaller.isScanningApp,
                progress: progressText,
                message: uninstaller.message
            )
            if isRunning && rows.contains(where: { $0.match == .app }) {
                PageNotice(
                    "\(app.name) is open. Quit it before moving it to the Trash.",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange
                )
            }
        }
    }

    /// "1.2 GB in 7 items"
    private var summary: String {
        let total = rows.reduce(0) { $0 + (uninstaller.size(of: $1) ?? 0) }
        guard !rows.isEmpty else { return [app.version, app.bundleID].filter { !$0.isEmpty }.joined(separator: " · ") }
        return "\(Formatting.size(total)) in \(Formatting.count(rows.count, "item"))"
    }

    private var progressText: String {
        let toMeasure = rows.filter { !$0.isContainer }.count
        let measured = rows.filter { !$0.isContainer && (uninstaller.sizes[$0.path] != nil || uninstaller.unreadable.contains($0.path)) }.count
        return toMeasure > 0 ? "Measuring \(measured) of \(toMeasure)…" : "Looking for what \(app.name) left…"
    }

    private func checkRunning() {
        isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
    }
}

private struct LeftoverRow: View {
    let uninstaller: Uninstaller
    let row: Leftover

    /// Name matches and shared containers are worth a look before they go.
    private var needsCheck: Bool { row.match == .name || row.shared }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Toggle(isOn: Binding(get: { uninstaller.isMarked(row) }, set: { uninstaller.setMarked(row, $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Paths.tildify(row.path, home: uninstaller.home))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(row.reason.isEmpty ? row.place : "\(row.place) · \(row.reason)")
                        .font(.callout)
                        .foregroundStyle(needsCheck ? Color.orange : Color.secondary)
                }
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: 8)
            SizeView(
                bytes: uninstaller.size(of: row),
                isMeasuring: uninstaller.measuring.contains(row.path),
                isUnreadable: uninstaller.unreadable.contains(row.path),
                measure: row.isContainer ? { uninstaller.measureOnRequest([row.path]) } : nil
            )
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Removed apps

private struct RemovedAppsView: View {
    let uninstaller: Uninstaller

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Leftovers of Removed Apps")
                        .font(.title2.bold())
                    Spacer()
                    Button("Rescan", systemImage: "arrow.clockwise", action: uninstaller.rescan)
                        .keyboardShortcut("r")
                }
                StatusLine(
                    isWorking: uninstaller.isScanningOrphans,
                    progress: "Looking for leftovers of removed apps…",
                    message: uninstaller.message
                )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()

            if uninstaller.orphans.isEmpty && uninstaller.strayExtensions.isEmpty {
                ContentUnavailableView {
                    Label(uninstaller.isScanningOrphans ? "Looking…" : "Nothing Found", systemImage: "questionmark.folder")
                } description: {
                    Text(uninstaller.isScanningOrphans
                         ? "Files in your Library folder named after apps that aren't installed."
                         : "No leftovers from removed apps in the usual places.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !uninstaller.orphans.isEmpty {
                        Section {
                            ForEach(uninstaller.orphans) { orphan in
                                OrphanRow(uninstaller: uninstaller, orphan: orphan)
                            }
                        } footer: {
                            Text("Some rows belong to command-line tools rather than apps, and are usually tiny.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !uninstaller.strayExtensions.isEmpty {
                        Section {
                            ForEach(uninstaller.strayExtensions) { ext in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ext.name)
                                    Text("\(ext.bundleID) · \(UninstallerRules.status(of: ext))")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 3)
                            }
                        } header: {
                            Text("System Extensions of Removed Apps")
                                .font(.headline)
                        } footer: {
                            if uninstaller.strayExtensions.contains(where: { !$0.state.contains("uninstall") }) {
                                Text("Kleyn can't remove these. Use System Settings → General → Login Items & Extensions, or the app's own uninstaller.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Divider()
            MarkFooter(
                markedCount: uninstaller.markedOrphans.count,
                markedBytes: uninstaller.orphans.filter(uninstaller.isMarked).reduce(0) { $0 + uninstaller.size(of: $1) },
                markAll: uninstaller.markAllOrphans,
                unmarkAll: uninstaller.unmarkAllOrphans,
                showInFinder: uninstaller.showMarkedOrphans
            )
        }
        .navigationTitle("Leftovers of Removed Apps")
        .task(id: uninstaller.scanGeneration) { await uninstaller.scanOrphans() }
    }
}

private struct OrphanRow: View {
    let uninstaller: Uninstaller
    let orphan: Orphan

    var body: some View {
        let containers = uninstaller.unmeasuredContainers(of: orphan)
        let isMeasuring = orphan.paths.contains(where: uninstaller.measuring.contains)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Toggle(isOn: Binding(get: { uninstaller.isMarked(orphan) }, set: { uninstaller.setMarked(orphan, $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(orphan.bundleID)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(orphan.runningExtension == nil ? Color.secondary : Color.orange)
                }
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                let bytes = uninstaller.size(of: orphan)
                if isMeasuring && bytes == 0 {
                    ProgressView().controlSize(.small)
                } else if bytes > 0 || containers.isEmpty {
                    Text(Formatting.size(bytes))
                        .monospacedDigit()
                        .fontWeight(bytes >= 1_000_000_000 ? .semibold : .regular)
                }
                if !containers.isEmpty && !isMeasuring {
                    Button(bytes > 0 ? "+ Measure" : "Measure") { uninstaller.measureOnRequest(containers) }
                        .buttonStyle(.link)
                        .font(.callout)
                        .help("Measuring a container makes macOS ask whether Kleyn may access other apps' data.")
                }
            }
        }
        .padding(.vertical, 3)
    }

    /// "Cache, Settings · 2 items · no app with this ID (may be a command-line tool)"
    private var detail: String {
        let why = orphan.runningExtension.map { "its extension \u{201C}\($0)\u{201D} is still running" }
            ?? "no app with this ID (may be a command-line tool)"
        return "\(orphan.places.joined(separator: ", ")) · \(Formatting.count(orphan.paths.count, "item")) · \(why)"
    }
}

// MARK: - Shared parts

/// A row's size: the size, a spinner while measuring, — when it couldn't be read,
/// or a Measure button for a container that waits for a click.
private struct SizeView: View {
    let bytes: Int64?
    let isMeasuring: Bool
    let isUnreadable: Bool
    let measure: (() -> Void)?

    var body: some View {
        if isMeasuring {
            ProgressView().controlSize(.small)
        } else if let bytes {
            Text(Formatting.size(bytes))
                .monospacedDigit()
                .fontWeight(bytes >= 1_000_000_000 ? .semibold : .regular)
        } else if isUnreadable {
            Text("—")
                .foregroundStyle(.secondary)
                .help("macOS didn't let Kleyn read it.")
        } else if let measure {
            Button("Measure", action: measure)
                .buttonStyle(.link)
                .help("Measuring a container makes macOS ask whether Kleyn may access other apps' data.")
        }
    }
}

/// The progress while working, or what just happened.
private struct StatusLine: View {
    let isWorking: Bool
    let progress: String
    let message: String

    var body: some View {
        if isWorking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progress)
                    .lineLimit(1)
                    .monospacedDigit()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else if !message.isEmpty {
            // No fixedSize: the window takes its minimum size from the page, measured at a tiny width.
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
    }
}

/// "3 items marked, 1.2 GB", Mark All or Unmark All, and Show in Finder.
private struct MarkFooter: View {
    let markedCount: Int
    let markedBytes: Int64
    let markAll: () -> Void
    let unmarkAll: () -> Void
    let showInFinder: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if markedCount == 0 {
                HStack(spacing: 6) {
                    Text("Nothing marked")
                        .foregroundStyle(.secondary)
                    Button("Mark All", action: markAll)
                        .buttonStyle(.link)
                }
            } else {
                HStack(spacing: 6) {
                    Text("\(Formatting.count(markedCount, "item")) marked" + (markedBytes > 0 ? ", \(Formatting.size(markedBytes))" : ""))
                        .monospacedDigit()
                    Button("Unmark All", action: unmarkAll)
                        .buttonStyle(.link)
                }
            }
            Spacer()
            Button("Show in Finder", action: showInFinder)
                .buttonStyle(.borderedProminent)
                .disabled(markedCount == 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

#Preview {
    UninstallerView(uninstaller: Uninstaller())
}
