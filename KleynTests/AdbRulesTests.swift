//
//  AdbRulesTests.swift
//  KleynTests
//
//  Ported from claude-mods/adb-explorer/tests/adb.test.ts. Sizes count as Finder does
//  (1 GB = 1,000,000,000 bytes), so the header's numbers differ from the mod's. Dropped
//  paths aren't parsed: Kleyn gets dropped files as file URLs.
//

import Foundation
import Testing
@testable import Kleyn

/// A fixed locale, so the size labels don't depend on this Mac's settings.
private let en = Locale(identifier: "en_US")

@Suite("ADB parsing")
struct AdbParsingTests {
    @Test("adb devices -l")
    func devices() {
        let output = [
            "List of devices attached",
            "R5CT1234ABC    device usb:1-1 product:a54xns model:SM_A546E device:a54x transport_id:3",
            "emulator-5554  unauthorized transport_id:1",
            "* daemon started successfully",
            "",
        ].joined(separator: "\n")
        #expect(AdbRules.parseDevices(output) == [
            AdbDevice(serial: "R5CT1234ABC", state: "device", model: "SM A546E"),
            AdbDevice(serial: "emulator-5554", state: "unauthorized", model: "emulator-5554"),
        ])
    }

    @Test("Device info for the header, with \\r\\n line ends like older adb shells")
    func info() {
        let phone = [
            "name=Galaxy A54 5G",
            "release=14",
            "sdk=34",
            "df=/dev/fuse 115343360 80740352 34603008 70% /storage/emulated",
            "  status: 2",
            "  level: 64",
            "",
        ].joined(separator: "\r\n")
        let info = AdbRules.parseInfo(phone)
        #expect(info == AdbInfo(
            name: "Galaxy A54 5G",
            release: "14",
            sdk: "34",
            freeBytes: 34_603_008 * 1024,
            totalBytes: 115_343_360 * 1024,
            battery: 64,
            charging: true
        ))
        #expect(AdbRules.infoLine(info, locale: en) == "Android 14 (API 34) · 35.43 GB free of 118.11 GB · Battery 64%, charging")
    }

    @Test("The emulator: no marketing name, not charging; and a device that says nothing")
    func emulatorInfo() {
        let emulator = AdbRules.parseInfo("name=\nrelease=16\nsdk=36\ndf=/dev/fuse 10474476 6710460 3145728 68% /storage/emulated\n  status: 4\n  level: 100\n")
        #expect(emulator.name == "")
        #expect(AdbRules.infoLine(emulator, locale: en) == "Android 16 (API 36) · 3.22 GB free of 10.73 GB · Battery 100%")
        #expect(AdbRules.infoLine(AdbRules.parseInfo("")) == "")
    }

    @Test("A folder listing: folders first, odd names intact")
    func listing() {
        let output = [
            "regular file/2048/1700000000/b photo.jpg",
            "directory/3488/1700000000/DCIM",
            "directory/3488/1700000000/.",
            "directory/3488/1700000000/..",
            "regular file/10/1700000000/it's a -> file.txt\r",
            "directory/3488/1700000000/Android",
            "regular file/7/1700000000/a/b",
        ].joined(separator: "\n")
        let list = AdbRules.parseList(output, folder: "/sdcard")
        #expect(list.map(\.name) == ["Android", "DCIM", "a/b", "b photo.jpg", "it's a -> file.txt"])
        #expect(list[1] == AdbEntry(name: "DCIM", path: "/sdcard/DCIM", isDir: true, size: 3488, mtime: 1_700_000_000))
    }

    @Test("du -sk output into bytes")
    func sizes() {
        #expect(AdbRules.parseSizes("120\tDCIM\n4\t.thumbnails\n", folder: "/sdcard") == [
            "/sdcard/DCIM": 120 * 1024,
            "/sdcard/.thumbnails": 4096,
        ])
        #expect(AdbRules.parseSizes("8\tMy Photos/\r\n", folder: "/sdcard") == ["/sdcard/My Photos": 8192])
    }
}

@Suite("ADB paths and commands")
struct AdbCommandTests {
    @Test("Paths")
    func paths() {
        #expect(AdbRules.joinPath("/", "sdcard") == "/sdcard")
        #expect(AdbRules.joinPath("/sdcard/", "DCIM") == "/sdcard/DCIM")
        #expect(AdbRules.parentPath("/sdcard/DCIM/Camera") == "/sdcard/DCIM")
        #expect(AdbRules.parentPath("/sdcard") == "/")
        #expect(AdbRules.parentPath("/") == "/")
        #expect(AdbRules.baseName("/Users/me/My Photos/") == "My Photos")
        #expect(AdbRules.baseName("/a/b.jpg") == "b.jpg")
    }

    @Test("Quoting for the device's shell, including single quotes")
    func quoting() {
        #expect(AdbRules.shQuote("it's") == #"'it'\''s'"#)
        #expect(AdbRules.deleteCommand(["/sdcard/a b", "/sdcard/it's"]) == #"rm -rf -- '/sdcard/a b' '/sdcard/it'\''s'"#)
        #expect(AdbRules.trashCommand(["/sdcard/x"], stamp: "S") == "mkdir -p '/sdcard/_adb_trash/S' && mv -- '/sdcard/x' '/sdcard/_adb_trash/S'/")
        #expect(AdbRules.listCommand("/sdcard/it's") == #"cd '/sdcard/it'\''s' && stat -L -c '%F/%s/%Y/%n' -- * .* 2>/dev/null"#)
    }

    @Test("Deletes only strictly inside user storage")
    func deletable() {
        #expect(AdbRules.isDeletable("/sdcard/DCIM/a.jpg"))
        #expect(AdbRules.isDeletable("/storage/emulated/0/Download"))
        #expect(!AdbRules.isDeletable("/sdcard"))
        #expect(!AdbRules.isDeletable("/sdcard/"))
        #expect(!AdbRules.isDeletable("/storage/emulated/0"))
        #expect(!AdbRules.isDeletable("/system/app"))
        #expect(!AdbRules.isDeletable("/data/local/tmp/x"))
        #expect(!AdbRules.isDeletable("/sdcard/../system"))
        #expect(!AdbRules.isDeletable("/sdcard/_adb_trash"))
        #expect(!AdbRules.isDeletable("/sdcardx/file"))
    }

    @Test("Looks for adb in the Android SDK before PATH and Homebrew")
    func adbCandidates() {
        #expect(AdbRules.adbCandidates(home: "/Users/me") == [
            "/Users/me/Library/Android/sdk/platform-tools/adb",
            "/Users/me/Android/Sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ])
        let custom = AdbRules.adbCandidates(home: "/Users/me", androidHome: "/opt/sdk/", sdkRoot: "/opt/sdk", pathFolders: ["/usr/bin", "/opt/homebrew/bin"])
        #expect(custom.first == "/opt/sdk/platform-tools/adb")
        #expect(custom.filter { $0 == "/opt/sdk/platform-tools/adb" }.count == 1)
        #expect(custom[1] == "/Users/me/Library/Android/sdk/platform-tools/adb")
        #expect(custom.contains("/usr/bin/adb"))
        #expect(custom.filter { $0 == "/opt/homebrew/bin/adb" }.count == 1)
    }

    @Test("Time stamps and folder names")
    func names() {
        let date = Date(timeIntervalSince1970: 1_760_540_102)  // 15 Oct 2025, 14:55:02 UTC
        #expect(AdbRules.stamp(of: date, timeZone: TimeZone(identifier: "UTC")!) == "2025-10-15_14-55-02")
        #expect(AdbRules.folderName(forModel: "Pixel 8 Pro") == "Pixel-8-Pro")
        #expect(AdbRules.folderName(forModel: "SM A546E/x") == "SM-A546E-x")
        #expect(AdbRules.folderName(forModel: "") == "device")
    }

    @Test("Sizes as Finder shows them")
    func sizeLabels() {
        #expect(AdbRules.sizeLabel(512, locale: en) == "512 bytes")
        #expect(AdbRules.sizeLabel(250 * 1024 * 1024, locale: en) == "262.1 MB")
    }
}
