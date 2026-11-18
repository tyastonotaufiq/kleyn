//
//  CleanerView.swift
//  Kleyn
//

import SwiftUI

/// The Cleaner page: what's using space, grouped into Safe to remove and Review first,
/// with marks and Move to Trash.
struct CleanerView: View {
    let cleaner: Cleaner

    /// The move waiting for confirmation.
    @State private var pendingMove: Cleaner.MovePlan?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Divider()
            content
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
        .onAppear(perform: cleaner.scanIfNeeded)
        // A scan stops when you leave the page, and starts again when you come back.
        .onDisappear(perform: cleaner.cancelScan)
        .alert(
            pendingMove.map(confirmationTitle) ?? "",
            isPresented: Binding(get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil } }),
            presenting: pendingMove
        ) { _ in
            Button("Move to Trash") {
                Task { await cleaner.moveMarkedToTrash() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("You can put them back from the Trash. Empty the Trash to get the space back.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cleaner")
                        .font(.title2.bold())
                    if let disk = cleaner.disk {
                        Text("\(CleanerRules.sizeLabel(disk.free)) free of \(CleanerRules.sizeLabel(disk.total))")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Rescan", systemImage: "arrow.clockwise", action: cleaner.scan)
                    .keyboardShortcut("r")
                    .disabled(cleaner.isMoving)
            }

            status

            if cleaner.needsFullDiskAccess {
                fullDiskAccessNote
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if cleaner.phase == .scanning {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(
                    value: Double(cleaner.measuredCount),
                    total: Double(max(cleaner.pendingCount, 1))
                )
                Text(cleaner.progressText)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else if cleaner.isMoving {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Moving to the Trash…")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        } else if !cleaner.message.isEmpty {
            // No fixedSize here: the window takes its minimum size from the page, measured
            // at a tiny width, where a fixed-height text would wrap into a very tall column.
            Text(cleaner.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }

    private var fullDiskAccessNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label {
                Text("Some folders couldn't be measured, so a few sizes may be low. Give Kleyn Full Disk Access to measure them, then rescan.")
                    .lineLimit(4)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            Button("Open System Settings", action: cleaner.openFullDiskAccessSettings)
        }
        .font(.callout)
        .padding(12)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 10))
    }

    // MARK: - Rows

    @ViewBuilder
    private var content: some View {
        if cleaner.rows.isEmpty {
            Group {
                switch cleaner.phase {
                case .scanning, .notScanned:
                    ContentUnavailableView {
                        Label("Measuring…", systemImage: "internaldrive")
                    } description: {
                        Text("App caches, logs, Xcode, Gradle, emulators, npm and CocoaPods.")
                    }
                case .scanned:
                    ContentUnavailableView {
                        Label("Nothing Large Found", systemImage: "checkmark.circle")
                    } description: {
                        Text("The usual places are using less than \(CleanerRules.sizeLabel(CleanerRules.minSize)) each.")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                let safe = cleaner.safeRows
                if !safe.isEmpty {
                    Section {
                        ForEach(safe) { row($0) }
                    } header: {
                        HStack {
                            groupTitle("Safe to remove", rows: safe, color: .green)
                            Spacer()
                            Button("Mark All", action: cleaner.markAllSafe)
                                .buttonStyle(.link)
                        }
                    }
                }
                let review = cleaner.reviewRows
                if !review.isEmpty {
                    Section {
                        ForEach(review) { row($0) }
                    } header: {
                        groupTitle("Review first", rows: review, color: .orange)
                    }
                }
            }
        }
    }

    private func groupTitle(_ title: String, rows: [CleanItem], color: Color) -> some View {
        Text("\(title) · \(CleanerRules.sizeLabel(rows.reduce(0) { $0 + $1.size }))")
            .font(.headline)
            .foregroundStyle(color)
    }

    private func row(_ item: CleanItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Toggle(isOn: Binding(get: { cleaner.isMarked(item) }, set: { cleaner.setMarked(item, $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(CleanerRules.rowLabel(item, home: cleaner.home))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.reason.isEmpty ? item.category : "\(item.category) · \(item.reason)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: 8)
            Text(CleanerRules.sizeLabel(item.size))
                .monospacedDigit()
                .fontWeight(item.size >= 1_000_000_000 ? .semibold : .regular)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Show in Finder") { cleaner.showInFinder(item) }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if cleaner.marked.isEmpty {
                Text("Nothing marked")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Text("\(CleanerRules.count(cleaner.marked.count, "item")) marked, \(CleanerRules.sizeLabel(cleaner.markedBytes))")
                        .monospacedDigit()
                    Button("Unmark All", action: cleaner.unmarkAll)
                        .buttonStyle(.link)
                }
            }
            Spacer()
            Button("Show in Finder", action: cleaner.showMarkedInFinder)
                .disabled(cleaner.marked.isEmpty)
            Button("Move to Trash", action: confirmMove)
                .keyboardShortcut(.delete)
                .buttonStyle(.borderedProminent)
                // Rows can be marked while a scan runs, but nothing moves until it's done.
                .disabled(cleaner.marked.isEmpty || cleaner.phase != .scanned || cleaner.isMoving)
        }
    }

    private func confirmMove() {
        pendingMove = cleaner.movePlan()
    }

    private func confirmationTitle(_ plan: Cleaner.MovePlan) -> String {
        "Move \(CleanerRules.count(plan.paths.count, "item")), \(CleanerRules.sizeLabel(plan.bytes)), to the Trash?"
    }
}

#Preview {
    CleanerView(cleaner: Cleaner())
}
