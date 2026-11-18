//
//  KeyboardView.swift
//  Kleyn
//

import SwiftUI

/// The keyboard lock page.
struct KeyboardView: View {
    @Bindable var locker: KeyboardLocker

    private let autoUnlockDuration = Duration.seconds(KeyboardLocker.autoUnlockInterval)
        .formatted(.units(allowed: [.minutes, .seconds], width: .wide))

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: locker.isLocked ? "lock.fill" : "lock.open")
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(locker.isLocked ? Color.red : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(height: 64)

            VStack(spacing: 6) {
                Text(locker.isLocked ? "Keyboard Locked" : "Keyboard Unlocked")
                    .font(.title.bold())
                Text(locker.isLocked
                     ? "Wipe away. Click Unlock when you're done."
                     : "Lock the keyboard, then clean it.")
                    .foregroundStyle(.secondary)
            }

            if !locker.isLocked {
                Toggle("Auto-unlock after \(autoUnlockDuration)", isOn: $locker.autoUnlockEnabled)
            } else if locker.autoUnlockEnabled {
                countdown
            }

            Button(action: locker.toggle) {
                Text(locker.isLocked ? "Unlock Keyboard" : "Lock Keyboard")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .tint(locker.isLocked ? .red : .accentColor)

            if locker.isLocked && locker.isSecureInputActive {
                PageNotice(
                    "Another app has Secure Keyboard Entry turned on, so macOS may let some keys through.",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange
                )
            }

            if !locker.hasPermission {
                permissionHelp
            }

            if let errorMessage = locker.errorMessage {
                PageNotice(errorMessage, systemImage: "xmark.octagon.fill", tint: .red)
            }
        }
        .frame(maxWidth: 380)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.default, value: locker.isLocked)
        .animation(.default, value: locker.hasPermission)
    }

    private var countdown: some View {
        VStack(spacing: 6) {
            ProgressView(value: Double(locker.secondsRemaining), total: KeyboardLocker.autoUnlockInterval)
            Text("Auto-unlocks in \(Duration.seconds(locker.secondsRemaining).formatted(.time(pattern: .minuteSecond)))")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var permissionHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Keyboard lock needs Accessibility access", systemImage: "hand.raised.fill")
                .font(.headline)
            Text("macOS only lets apps with Accessibility access block keyboard input.")
            Text("1. Click **Open System Settings**.\n2. Turn on **Kleyn** in the list (use **+** to add it if it's missing).\n3. Come back and click **Lock Keyboard**.")
            Button("Open System Settings", action: locker.openAccessibilitySettings)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 10))
    }
}

#Preview {
    KeyboardView(locker: KeyboardLocker())
}
