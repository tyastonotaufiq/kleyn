//
//  KeepAwakeView.swift
//  Kleyn
//

import SwiftUI

/// The Keep Awake page.
struct KeepAwakeView: View {
    @Bindable var keepAwake: KeepAwake

    @State private var untilText = ""
    @State private var apps: [RunningApp] = []

    private var session: KeepAwakeSession? { keepAwake.session }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: keepAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .font(.title2)
                        .foregroundStyle(keepAwake.isActive ? Color.green : Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                    // Redrawn every 30 seconds, so "until tomorrow 08:00" turns into "until 08:00" at midnight.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(keepAwake.statusText(now: context.date))
                            .font(.headline)
                            .foregroundStyle(keepAwake.isActive ? .primary : .secondary)
                    }
                    Spacer()
                    if keepAwake.isActive {
                        Button("Stop", action: keepAwake.stop)
                    }
                }
                if !keepAwake.message.isEmpty {
                    Text(keepAwake.message)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                choice("Until I stop it", isRunning: session != nil && session?.endsAt == nil && session?.app == nil) {
                    keepAwake.startUntilStopped()
                }
                HStack {
                    ForEach(KeepAwakeRules.presets, id: \.minutes) { preset in
                        choice(preset.label, isRunning: session?.minutes == preset.minutes) {
                            keepAwake.start(minutes: preset.minutes)
                        }
                    }
                }
            } header: {
                heading("For a while", isRunning: session != nil && session?.app == nil && (session?.endsAt == nil || session?.minutes != nil))
            }

            Section {
                HStack {
                    TextField("Until", text: $untilText, prompt: Text("18:30"))
                        .onSubmit(startUntil)
                    Button("Start", action: startUntil)
                        .disabled(untilText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Type a time like 18:30 or 6:30 pm. A time already past today means tomorrow.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                heading("Until a time", isRunning: session?.endsAt != nil && session?.minutes == nil)
            }

            Section {
                Picker("App", selection: Binding(
                    get: { session?.app },
                    set: { app in if let app { keepAwake.start(whileRunning: app) } }
                )) {
                    Text("Choose an app…").tag(RunningApp?.none)
                    // Keep the running app selectable even after it leaves the list.
                    if let app = session?.app, !apps.contains(app) {
                        Text(app.name).tag(Optional(app))
                    }
                    ForEach(apps) { app in
                        Text(app.name).tag(Optional(app))
                    }
                }
                Text("The Mac stays awake until the app quits.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                heading("While an app is open", isRunning: session?.app != nil)
            }

            Section {
                Toggle("Let the display sleep", isOn: $keepAwake.displaySleep)
                Text("The Mac stays awake, but the screen turns off as usual.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshApps)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            refreshApps()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            refreshApps()
        }
    }

    private func startUntil() {
        guard !untilText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        keepAwake.start(untilTime: untilText)
        if keepAwake.isActive { untilText = "" }
    }

    private func refreshApps() {
        apps = keepAwake.runningApps()
    }

    /// A start button. The running choice is drawn prominent, as the mod draws it bold and green.
    @ViewBuilder
    private func choice(_ label: String, isRunning: Bool, action: @escaping () -> Void) -> some View {
        if isRunning {
            Button(label, action: action).buttonStyle(.borderedProminent).tint(.green)
        } else {
            Button(label, action: action).buttonStyle(.bordered)
        }
    }

    /// A section heading, with "● on" when the session running was started from that section.
    private func heading(_ title: String, isRunning: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title)
            if isRunning {
                Text("● on").foregroundStyle(.green)
            }
        }
    }
}

#Preview {
    KeepAwakeView(keepAwake: KeepAwake())
}
