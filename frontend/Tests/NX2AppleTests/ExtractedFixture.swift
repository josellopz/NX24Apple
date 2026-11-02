import Foundation

/// Minimal synthetic headers for launcher tests. Contains no executable game code or game data.
enum ExtractedFixture {
    static let titleID = "040074A01BF12000"
    static func make(at root: URL) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("base/exefs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("base/romfs"), withIntermediateDirectories: true)
        var main = Data(repeating: 0, count: 0x100)
        main.replaceSubrange(0..<4, with: "NSO0".utf8)
        try main.write(to: root.appendingPathComponent("base/exefs/main"))
        var d = Data(repeating: 0, count: 0x100)
        d.replaceSubrange(0..<4, with: "META".utf8); d[0x70] = 0x80; d[0x74] = 0x20
        d.replaceSubrange(0x80..<0x84, with: "ACI0".utf8)
        let id = UInt64(titleID, radix: 16)!
        for i in 0..<8 { d[0x90 + i] = UInt8(truncatingIfNeeded: id >> (8 * i)) }
        try d.write(to: root.appendingPathComponent("base/exefs/main.npdm"))
    }
}
