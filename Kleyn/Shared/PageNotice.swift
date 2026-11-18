//
//  PageNotice.swift
//  Kleyn
//

import SwiftUI

/// A tinted message box, used for warnings and errors on the pages.
struct PageNotice: View {
    let message: String
    let systemImage: String
    let tint: Color

    init(_ message: String, systemImage: String, tint: Color) {
        self.message = message
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: 10))
    }
}
