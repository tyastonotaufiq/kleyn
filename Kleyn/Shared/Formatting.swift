//
//  Formatting.swift
//  Kleyn
//
//  Small helpers the pages share: tidying and shortening paths, sizes, and counts.
//

import Foundation

nonisolated enum Paths {
    /// Collapses repeated slashes and strips a trailing one.
    static func clean(_ path: String) -> String {
        var clean = path
        while clean.contains("//") {
            clean = clean.replacing("//", with: "/")
        }
        while clean.count > 1 && clean.hasSuffix("/") {
            clean.removeLast()
        }
        return clean
    }

    /// A path shown relative to home, as `~/...`.
    static func tildify(_ path: String, home: String) -> String {
        !home.isEmpty && path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

nonisolated enum Formatting {
    /// A size as Finder shows it: "1.5 GB", "340 MB". "—" when there's nothing to show.
    static func size(_ bytes: Int64, locale: Locale = .current) -> String {
        bytes > 0 ? bytes.formatted(.byteCount(style: .file).locale(locale)) : "—"
    }

    /// "1 item", "3 items".
    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}
