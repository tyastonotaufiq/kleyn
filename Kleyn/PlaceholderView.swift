//
//  PlaceholderView.swift
//  Kleyn
//

import SwiftUI

/// The page for a feature that isn't built yet: what it will do, and that it's coming.
struct PlaceholderView: View {
    let page: Page

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: page.systemImage)
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(height: 64)

            VStack(spacing: 6) {
                Text(page.title)
                    .font(.title.bold())
                Text(page.comingSoon ?? "")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            Text("Coming soon")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.quaternary, in: .capsule)
        }
        .frame(maxWidth: 380)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    PlaceholderView(page: .cleaner)
}
