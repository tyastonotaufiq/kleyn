//
//  ScreenView.swift
//  Kleyn
//

import SwiftUI

/// The screen cleaning page.
struct ScreenView: View {
    let screenCleaner: ScreenCleaner
    let keyboardLocked: Bool

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "display")
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(height: 64)

            VStack(spacing: 6) {
                Text("Clean Screen")
                    .font(.title.bold())
                Text("Covers every display in black so smudges stand out. Click or press Space to switch to white for dust, and press Esc when you're done.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            Button(action: screenCleaner.start) {
                Text("Clean Screen")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            // The keyboard lock would swallow Esc, leaving no way to end screen cleaning.
            .disabled(keyboardLocked)

            if keyboardLocked {
                PageNotice(
                    "Unlock the keyboard first: the lock would block Esc.",
                    systemImage: "lock.fill",
                    tint: .orange
                )
            }
        }
        .frame(maxWidth: 380)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ScreenView(screenCleaner: ScreenCleaner(), keyboardLocked: false)
}
