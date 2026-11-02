import XCTest
@testable import NXCore

final class ExtractedGameTests: XCTestCase {
    private var root: URL!
    private let tid: UInt64 = 0x040074A01BF12000
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func version(_ name: String = "base", id: UInt64? = nil) throws {
        let path = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path.appendingPathComponent("exefs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: path.appendingPathComponent("romfs"), withIntermediateDirectories: true)
        var nso = Data(repeating: 0, count: 0x100)
        nso.replaceSubrange(0..<4, with: "NSO0".utf8)
        try nso.write(to: path.appendingPathComponent("exefs/main"))
        var npdm = Data(repeating: 0, count: 0x100)
        npdm.replaceSubrange(0..<4, with: "META".utf8)
        npdm[0x70] = 0x80; npdm[0x74] = 0x20
        npdm.replaceSubrange(0x80..<0x84, with: "ACI0".utf8)
        for i in 0..<8 { npdm[0x90 + i] = UInt8(truncatingIfNeeded: (id ?? tid) >> (i * 8)) }
        try npdm.write(to: path.appendingPathComponent("exefs/main.npdm"))
    }
    private func rejects(_ key: String, _ action: () throws -> Void = {}) throws {
        try action()
        XCTAssertThrowsError(try ExtractedGame.inspect(root.path)) { XCTAssertEqual(($0 as? ExtractedGame.Problem)?.key, key) }
    }
    func testRootAndBaseSelectionsKeepTheRootAndReadIDFromNPDM() throws {
        try version()
        let a = try ExtractedGame.inspect(root.path)
        XCTAssertEqual(a.titleID, "040074A01BF12000")
        XCTAssertEqual(a, try ExtractedGame.inspect(root.appendingPathComponent("base").path))
        XCTAssertEqual(a.versions, [])
    }
    func testUpdateRomfsWorksWithoutBaseRomfsAndNormalizesChildSelections() throws {
        try version(); try version("updates/655360"); try version("updates/9")
        try FileManager.default.removeItem(at: root.appendingPathComponent("base/romfs"))
        let layout = try ExtractedGame.inspect(root.path)
        XCTAssertFalse(layout.hasBaseRomfs)
        XCTAssertEqual(layout.versions, [9, 655360])
        for child in ["base", "base/exefs", "updates", "updates/655360", "updates/655360/exefs", "updates/655360/romfs"] {
            XCTAssertEqual(try ExtractedGame.inspect(root.appendingPathComponent(child).path), layout)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path + "/base/romfs"))
    }
    func testMissingRomfsEverywhereIsReportedAndIncompleteUpdatesAreNotMixedWithBase() throws {
        try version()
        try FileManager.default.removeItem(at: root.appendingPathComponent("base/romfs"))
        try rejects("dump.noRomfs")
        try version(); try version("updates/655360")
        try FileManager.default.removeItem(at: root.appendingPathComponent("updates/655360/romfs"))
        try rejects("dump.folderMissing")
    }
    func testOldEngineNeedsTheUpdateOnlyCapabilityButStillAcceptsStandardDumps() throws {
        let scripts = root.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try Data().write(to: scripts.appendingPathComponent("pack_dump.py"))
        let build = scripts.appendingPathComponent("build_ipa_from_nsp.py")
        try Data("scan_dump(".utf8).write(to: build)
        XCTAssertTrue(ExtractedGame.supportsEngine(root.path))
        XCTAssertFalse(ExtractedGame.supportsEngine(root.path, needsUpdateRomfs: true))
        try Data("scan_dump( def dump_versions(".utf8).write(to: build)
        XCTAssertTrue(ExtractedGame.supportsEngine(root.path, needsUpdateRomfs: true))
    }
    func testUpdatesAndDLCUseEngineLayoutAndNumericVersionOrder() throws {
        try version(); try version("updates/9"); try version("updates/10")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dlc/040074a01bf13001/0/romfs"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("._game.nsp"))
        XCTAssertEqual(try ExtractedGame.inspect(root.path).versions, [9, 10])
    }
    func testMalformedAndTruncatedMetadataNeverReadsOutOfBounds() throws {
        try version()
        for count in [0, 4, 0x70, 0x80, 0x90] {
            try rejects("dump.npdm") {
                var d = Data(repeating: 0, count: count)
                if count >= 4 { d.replaceSubrange(0..<4, with: "META".utf8) }
                if count >= 0x80 { d[0x70] = 0x80; d[0x74] = 0x20 }
                try d.write(to: root.appendingPathComponent("base/exefs/main.npdm"))
            }
        }
        try version()
        try rejects("dump.npdm") {
            let url = root.appendingPathComponent("base/exefs/main.npdm")
            var d = try Data(contentsOf: url)
            for i in 0x70..<0x74 { d[i] = 0xFF }
            try d.write(to: url)
        }
    }
    func testWrongTitleAndMismatchedUpdateAreRejected() throws {
        try version(id: tid + 0x800); try rejects("dump.baseID")
        try version(); try version("updates/458752", id: tid + 0x2000); try rejects("dump.updateID")
    }
    func testMissingFoldersAndInvalidCodeAreRejected() throws {
        try rejects("dump.folderMissing")
        try version()
        try rejects("dump.nso") { try Data("NSO0".utf8).write(to: root.appendingPathComponent("base/exefs/main")) }
        try version()
        try rejects("dump.unreadable") { try FileManager.default.removeItem(at: root.appendingPathComponent("base/exefs/main")) }
    }
    func testPackageMixingCannotSilentlySelectThePackagePipeline() throws {
        try version()
        for ext in ["nsp", "xci", "NSZ", "XCZ"] {
            let url = root.appendingPathComponent("another." + ext)
            try rejects("dump.mixed") { try Data([1]).write(to: url) }
            try FileManager.default.removeItem(at: url)
        }
    }
    func testMalformedUpdateNamesAndDuplicateVersionsAreRejected() throws {
        try version(); try version("updates/latest"); try rejects("dump.updateVersion")
        try FileManager.default.removeItem(at: root.appendingPathComponent("updates"))
        try version("updates/01"); try version("updates/1"); try rejects("dump.updateVersion")
    }
    func testDLCMustBelongToBaseAndContainOneRomfs() throws {
        try version()
        let dlc = root.appendingPathComponent("dlc")
        try FileManager.default.createDirectory(at: dlc.appendingPathComponent("0100000000000001/0/romfs"), withIntermediateDirectories: true)
        try rejects("dump.dlcID")
        try FileManager.default.removeItem(at: dlc)
        try FileManager.default.createDirectory(at: dlc.appendingPathComponent("040074A01BF13001/0/romfs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dlc.appendingPathComponent("040074A01BF13001/1/romfs"), withIntermediateDirectories: true)
        try rejects("dump.dlcRomfs")
    }
}
