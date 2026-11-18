//
//  FormattingTests.swift
//  KleynTests
//
//  The helpers the pages share: paths, sizes and counts.
//

import Foundation
import Testing
@testable import Kleyn

private let H = "/Users/t"
/// A fixed locale, so the size labels don't depend on this Mac's settings.
private let en = Locale(identifier: "en_US")

@Suite("Formatting")
struct FormattingTests {
    @Test("Sizes as Finder shows them")
    func sizes() {
        #expect(Formatting.size(0, locale: en) == "—")
        #expect(Formatting.size(1_500_000_000, locale: en) == "1.5 GB")
        #expect(Formatting.size(340_000_000, locale: en) == "340 MB")
    }

    @Test("Counts")
    func counts() {
        #expect(Formatting.count(1, "item") == "1 item")
        #expect(Formatting.count(3, "item") == "3 items")
    }
}

@Suite("Paths")
struct PathsTests {
    @Test("Repeated and trailing slashes")
    func clean() {
        #expect(Paths.clean(H + "//Library///Logs/") == H + "/Library/Logs")
        #expect(Paths.clean("/") == "/")
    }

    @Test("~ paths")
    func tildify() {
        #expect(Paths.tildify(H + "/Library/Logs", home: H) == "~/Library/Logs")
        #expect(Paths.tildify("/tmp/x", home: H) == "/tmp/x")
        #expect(Paths.tildify(H + "x/y", home: H) == H + "x/y")
    }
}
