import Foundation

/// The extracted layout accepted by nxnative's scripts/pack_dump.py. Validation reads only
/// small executable headers, never walks or copies the multi-GB RomFS tree.
package enum ExtractedGame {
    package struct Layout: Equatable {
        package var root: String
        package var titleID: String
        package var versions: [UInt64]
    }

    package struct Problem: Error, Equatable {
        package var key: String
        package var detail: String
        package init(_ key: String, _ detail: String) { self.key = key; self.detail = detail }
    }

    package static func root(for selection: String) -> String {
        let url = URL(fileURLWithPath: selection).standardizedFileURL
        // Accept the base folder too, while always passing the root (updates and DLC included).
        if url.lastPathComponent == "base", isDirectory(url.appendingPathComponent("exefs").path) {
            return url.deletingLastPathComponent().path
        }
        return url.path
    }

    package static func looksLikeDump(_ path: String) -> Bool {
        let path = root(for: path)
        return isDirectory(path + "/base/exefs") || isDirectory(path + "/base/romfs")
    }

    package static func inspect(_ selection: String) throws -> Layout {
        guard !selection.isEmpty else { throw Problem("dump.choose", "") }
        let root = root(for: selection), fm = FileManager.default
        // The engine prefers package files beside base/, which could silently build another game.
        let names = try contents(root)
        if let package = names.first(where: {
            !$0.hasPrefix("._") && ["nsp", "xci", "nsz", "xcz"].contains(($0 as NSString).pathExtension.lowercased())
        }) { throw Problem("dump.mixed", package) }
        let app = try version(root + "/base")
        guard app != 0, app & 0xFFF == 0 else { throw Problem("dump.baseID", String(format: "%016llX", app)) }
        var versions: [UInt64] = []
        if fm.fileExists(atPath: root + "/updates") {
            var seen = Set<UInt64>()
            for name in try contents(root + "/updates") where !name.hasPrefix(".") {
                guard !name.isEmpty, name.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                      let number = UInt64(name), number > 0, seen.insert(number).inserted else {
                    throw Problem("dump.updateVersion", name)
                }
                guard try version(root + "/updates/" + name) == app else { throw Problem("dump.updateID", name) }
                versions.append(number)
            }
        }
        if fm.fileExists(atPath: root + "/dlc") {
            for name in try contents(root + "/dlc") where !name.hasPrefix(".") {
                guard name.count == 16, let tid = UInt64(name, radix: 16), tid > app,
                      tid - app > 0x1000, tid - app - 0x1000 <= 2000 else { throw Problem("dump.dlcID", name) }
                let path = root + "/dlc/" + name
                let children = try contents(path)
                let nested = children.filter { isDirectory(path + "/" + $0 + "/romfs") }
                let roms = nested.isEmpty ? (isDirectory(path + "/romfs") ? [path + "/romfs"] : []) : nested.map { path + "/" + $0 + "/romfs" }
                guard roms.count == 1 else { throw Problem("dump.dlcRomfs", name) }
                _ = try contents(roms[0])
            }
        }
        return Layout(root: root, titleID: String(format: "%016llX", app), versions: versions.sorted())
    }

    private static func version(_ path: String) throws -> UInt64 {
        _ = try contents(path + "/romfs")
        let main = try header(path + "/exefs/main", count: 0x100)
        guard main.count >= 0x100, Array(main.prefix(4)) == Array("NSO0".utf8) else { throw Problem("dump.nso", path + "/exefs/main") }
        let npdmPath = path + "/exefs/main.npdm"
        let npdm = try header(npdmPath, count: 0x80)
        guard npdm.count >= 0x80, Array(npdm.prefix(4)) == Array("META".utf8) else { throw Problem("dump.npdm", npdmPath) }
        func u32(_ offset: Int) -> UInt64 {
            (0..<4).reduce(0) { $0 | UInt64(npdm[offset + $1]) << ($1 * 8) }
        }
        let offset = u32(0x70), size = u32(0x74)
        guard offset >= 0x80, size >= 0x18 else { throw Problem("dump.npdm", npdmPath) }
        let aci = try header(npdmPath, count: 0x18, offset: offset)
        guard aci.count == 0x18, Array(aci.prefix(4)) == Array("ACI0".utf8) else { throw Problem("dump.npdm", npdmPath) }
        return (0..<8).reduce(0) { $0 | UInt64(aci[0x10 + $1]) << ($1 * 8) }
    }

    private static func header(_ path: String, count: Int, offset: UInt64 = 0) throws -> [UInt8] {
        guard FileManager.default.isReadableFile(atPath: path), !isDirectory(path),
              let file = FileHandle(forReadingAtPath: path) else { throw Problem("dump.unreadable", path) }
        defer { try? file.close() }
        do {
            try file.seek(toOffset: offset)
            return Array(try file.read(upToCount: count) ?? Data())
        } catch { throw Problem("dump.unreadable", path) }
    }

    private static func contents(_ path: String) throws -> [String] {
        guard isDirectory(path), let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            throw Problem("dump.folderMissing", path)
        }
        return names.sorted()
    }

    private static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    package static func supportsEngine(_ root: String) -> Bool {
        let script = try? String(contentsOfFile: root + "/scripts/build_ipa_from_nsp.py", encoding: .utf8)
        return FileManager.default.fileExists(atPath: root + "/scripts/pack_dump.py") && script?.contains("scan_dump(") == true
    }
}
