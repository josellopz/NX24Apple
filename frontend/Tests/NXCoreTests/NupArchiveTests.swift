import XCTest
import CryptoKit
@testable import NXCore

final class NupArchiveTests: XCTestCase {
    func testVerifiesAndExtractsBaseExeFS() throws {
        let archiveURL = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        let archive = try NupArchive(url: archiveURL)
        XCTAssertEqual(archive.packages.map(\.kind), [0])
        XCTAssertEqual(archive.packages.first?.titleID, 0x0100_0000_0000_0000)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try archive.extract(to: destination, zstdPath: "/usr/bin/false")
        defer { try? FileManager.default.removeItem(at: destination) }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("base/exefs/main")), Data("payload".utf8))
    }

    func testRejectsUnsafeMemberNames() throws {
        let archiveURL = try makeArchive(fileName: "../escape")
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        XCTAssertThrowsError(try NupArchive(url: archiveURL))
    }

    func testRejectsCorruptPayloadDigest() throws {
        let archiveURL = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        let handle = try FileHandle(forWritingTo: archiveURL)
        try handle.seek(toOffset: 400)
        try handle.write(contentsOf: Data("corrupt".utf8))
        try handle.close()
        XCTAssertThrowsError(try NupArchive(url: archiveURL))
    }

    private func makeArchive(fileName: String = "main") throws -> URL {
        let content = Data("payload".utf8)
        let pool = Data(("exefs" + fileName).utf8)
        let poolOffset = 48 + 64 + 2 * 24 + 80 + 2 * 4
        let tocSize = poolOffset + pool.count
        var toc = Data(repeating: 0, count: tocSize)
        toc.put(Data([0x54, 0x4f, 0x43, 1]), at: 0)
        toc.put(UInt32(1), at: 4); toc.put(UInt64(2), at: 8); toc.put(UInt64(1), at: 16)
        toc.put(UInt64(poolOffset), at: 24); toc.put(UInt64(pool.count), at: 32)
        let package = 48
        toc.put(UInt64(0x0100_0000_0000_0000), at: package)
        toc.put(UInt32(0), at: package + 8); toc.put(UInt32(1), at: package + 12)
        toc.put(UInt32.max, at: package + 16); toc.put(UInt32(0), at: package + 20)
        toc[package + 24] = 0
        let dirs = package + 64
        toc.put(UInt32(0), at: dirs); toc.put(UInt32(0), at: dirs + 4)
        toc.put(UInt32(0), at: dirs + 8); toc.put(UInt32(1), at: dirs + 12)
        toc.put(UInt32(0), at: dirs + 24); toc.put(UInt32(5), at: dirs + 28)
        toc.put(UInt32(1), at: dirs + 32); toc.put(UInt32(1), at: dirs + 36)
        let file = dirs + 48
        toc.put(UInt32(5), at: file); toc.put(UInt32(fileName.utf8.count), at: file + 4)
        toc.put(UInt64(content.count), at: file + 8)
        let blobOffset = UInt64((0x80 + tocSize + 15) & ~15)
        toc.put(blobOffset, at: file + 16); toc.put(UInt64(content.count), at: file + 24)
        toc.put(Data(SHA256.hash(data: content)), at: file + 32)
        toc[file + 64] = 0
        toc.put(UInt32(1), at: file + 80); toc.put(UInt32(2), at: file + 84)
        toc.put(pool, at: poolOffset)
        var identity = Data(repeating: 0, count: 13)
        identity.put(UInt64(0x0100_0000_0000_0000), at: 0)
        identity.put(UInt32(0), at: 8); identity[12] = 0
        let uuid = Data(SHA256.hash(data: identity).prefix(16))
        let fileSize = blobOffset + UInt64(content.count)
        var header = Data(repeating: 0, count: 0x80)
        header.put(Data([0x4e, 0x55, 0x50, 1]), at: 0); header.put(UInt16(0x80), at: 4); header.put(UInt16(1), at: 6)
        header.put(UInt64(0x80), at: 8); header.put(UInt64(tocSize), at: 16)
        header.put(Data(SHA256.hash(data: toc)), at: 24); header.put(blobOffset, at: 56)
        header.put(fileSize, at: 64); header.put(UInt32(1), at: 72); header.put(uuid, at: 80)
        var archive = header; archive.append(toc)
        archive.append(Data(repeating: 0, count: Int(blobOffset) - archive.count)); archive.append(content)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".nup")
        try archive.write(to: url)
        return url
    }
}

private extension Data {
    mutating func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { replaceSubrange(offset..<(offset + $0.count), with: $0) }
    }
    mutating func put(_ value: Data, at offset: Int) { replaceSubrange(offset..<(offset + value.count), with: value) }
}
