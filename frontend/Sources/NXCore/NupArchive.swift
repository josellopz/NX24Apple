import Foundation
import CryptoKit

/// Reader for NUP v1 packages, following the public format specification at
/// https://github.com/a55uka/nup/blob/meow/SPEC.md. Only package ExeFS and
/// RomFS trees are imported; metadata and arbitrary data trees are ignored.
package struct NupArchive {
    package struct Package: Equatable {
        package let titleID: UInt64
        package let version: UInt32
        package let kind: UInt8
        package let root: UInt32
        package let exefs: UInt32
        package let romfs: UInt32
        package let flags: UInt8
    }

    package struct Entry: Equatable {
        package let name: String
        package let isDirectory: Bool
        package let index: UInt32
    }

    package struct Failure: Error, Equatable, LocalizedError {
        package let message: String
        package var errorDescription: String? { message }
        package init(_ message: String) { self.message = message }
    }

    private struct Directory {
        let name: String
        let first: UInt32
        let count: UInt32
    }
    private struct File {
        let name: String
        let size: UInt64
        let extent: UInt64
        let storedSize: UInt64
        let hash: Data
        let codec: UInt8
    }

    package let url: URL
    package let packages: [Package]
    private let toc: Data
    private let directories: [Directory]
    private let files: [File]
    private let children: [UInt32]
    private let blobOffset: UInt64

    /// Validates the header, TOC digest, record bounds, package references, tree
    /// shape, member names, and (by default) every uncompressed file digest.
    package init(url: URL, verifyContents: Bool = true, zstdPath: String = "/usr/bin/zstd") throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let actualSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        guard actualSize >= 0x80 else { throw Failure("NUP header is truncated") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try Self.read(handle, offset: 0, count: 0x80)
        guard header.subdata(in: 0..<3) == Data("NUP".utf8), header[3] == 1 else { throw Failure("Unsupported NUP format") }
        let headerSize = UInt64(Self.u16(header, 4))
        let tocOffset = Self.u64(header, 8), tocSize = Self.u64(header, 16)
        let expectedTOCHash = header.subdata(in: 24..<56)
        let blobOffset = Self.u64(header, 56), declaredSize = Self.u64(header, 64)
        let packageCount = Self.u32(header, 72)
        guard headerSize >= 0x80, tocOffset == headerSize, declaredSize == actualSize,
              packageCount > 0, Self.u32(header, 76) == 0,
              header.subdata(in: 96..<128).allSatisfy({ $0 == 0 }),
              tocSize >= 0x30, tocSize <= 256 * 1024 * 1024,
              tocOffset <= actualSize, tocSize <= actualSize - tocOffset,
              blobOffset % 16 == 0, blobOffset >= tocOffset + tocSize, blobOffset <= actualSize else {
            throw Failure("Invalid NUP header bounds or flags")
        }
        let toc = try Self.read(handle, offset: tocOffset, count: Int(tocSize))
        guard Data(SHA256.hash(data: toc)) == expectedTOCHash else { throw Failure("NUP TOC SHA-256 mismatch") }
        guard toc.subdata(in: 0..<4) == Data([0x54, 0x4f, 0x43, 1]),
              Self.u32(toc, 4) == packageCount else { throw Failure("Invalid NUP table of contents") }
        let dirCount64 = Self.u64(toc, 8), fileCount64 = Self.u64(toc, 16)
        let poolOffset64 = Self.u64(toc, 24), poolSize64 = Self.u64(toc, 32)
        guard dirCount64 <= UInt64(UInt32.max), fileCount64 <= UInt64(UInt32.max),
              poolOffset64 <= UInt64(toc.count), poolSize64 <= UInt64(toc.count),
              poolOffset64 + poolSize64 <= UInt64(toc.count),
              Self.u64(toc, 40) == 0 else { throw Failure("NUP TOC counts or string pool are invalid") }
        let dirCount = Int(dirCount64), fileCount = Int(fileCount64), poolOffset = Int(poolOffset64), poolSize = Int(poolSize64)
        let packageStart = 48
        let dirStart = packageStart + Int(packageCount) * 64
        let fileStart = dirStart + dirCount * 24
        guard dirStart >= packageStart, fileStart >= dirStart, fileStart <= poolOffset,
              (poolOffset - fileStart) % 4 == 0 else { throw Failure("NUP TOC records are truncated") }
        let pool = toc.subdata(in: poolOffset..<(poolOffset + poolSize))
        func string(_ offset: UInt32, _ length: UInt32, allowEmpty: Bool = false) throws -> String {
            let lo = Int(offset), n = Int(length)
            guard lo <= pool.count, n >= 0, n <= pool.count - lo,
                  let value = String(data: pool.subdata(in: lo..<(lo + n)), encoding: .utf8),
                  (allowEmpty || !value.isEmpty), value != ".", value != "..",
                  !value.contains("/"), !value.contains("\\"), !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw Failure("NUP contains an unsafe or invalid path component")
            }
            return value
        }
        var packages: [Package] = []
        for i in 0..<Int(packageCount) {
            let p = packageStart + i * 64
            let flags = toc[p + 25]
            guard toc[p + 26] == 0, toc[p + 27] == 0,
                  toc[p + 28..<p + 32].allSatisfy({ $0 == 0 }), toc[p + 44..<p + 64].allSatisfy({ $0 == 0 }),
                  flags & ~UInt8(1) == 0 else { throw Failure("NUP package reserved fields or flags are invalid") }
            packages.append(Package(titleID: Self.u64(toc, p), version: Self.u32(toc, p + 20), kind: toc[p + 24],
                                    root: Self.u32(toc, p + 8), exefs: Self.u32(toc, p + 12),
                                    romfs: Self.u32(toc, p + 16), flags: flags))
        }
        var identity = Data()
        for package in packages {
            var title = package.titleID.littleEndian, version = package.version.littleEndian
            withUnsafeBytes(of: &title) { identity.append(contentsOf: $0) }
            withUnsafeBytes(of: &version) { identity.append(contentsOf: $0) }
            identity.append(package.kind)
        }
        guard Data(SHA256.hash(data: identity).prefix(16)) == header.subdata(in: 80..<96) else { throw Failure("NUP content UUID does not match its packages") }
        var dirs: [Directory] = []
        for i in 0..<dirCount {
            let p = dirStart + i * 24
            guard Self.u64(toc, p + 16) == 0 else { throw Failure("NUP directory reserved field is nonzero") }
            dirs.append(Directory(name: try string(Self.u32(toc, p), Self.u32(toc, p + 4), allowEmpty: true),
                                  first: Self.u32(toc, p + 8), count: Self.u32(toc, p + 12)))
        }
        var files: [File] = []
        for i in 0..<fileCount {
            let p = fileStart + i * 80
            guard toc[p + 65] == 0, toc[p + 66] == 0, toc[p + 68..<p + 80].allSatisfy({ $0 == 0 }),
                  toc[p + 64] <= 1 else { throw Failure("NUP file codec or reserved fields are invalid") }
            let size = Self.u64(toc, p + 8), extent = Self.u64(toc, p + 16), stored = Self.u64(toc, p + 24)
            guard (size == 0 && extent == 0 && stored == 0 && toc[p + 64] == 0) || (size > 0 && stored > 0),
                  extent >= blobOffset, extent <= actualSize, stored <= actualSize - extent,
                  size == 0 || extent % 16 == 0 else { throw Failure("NUP file extent is out of bounds") }
            files.append(File(name: try string(Self.u32(toc, p), Self.u32(toc, p + 4)), size: size,
                              extent: extent, storedSize: stored, hash: toc.subdata(in: (p + 32)..<(p + 64)), codec: toc[p + 64]))
        }
        let childrenOffset = fileStart + fileCount * 80
        let childCount = (poolOffset - childrenOffset) / 4
        var children: [UInt32] = []
        for i in 0..<childCount { children.append(Self.u32(toc, childrenOffset + i * 4)) }
        for dir in dirs where UInt64(dir.first) + UInt64(dir.count) > UInt64(children.count) {
            throw Failure("NUP directory child range is out of bounds")
        }
        let childRanges = dirs.enumerated().map { (Int($0.element.first), Int($0.element.first) + Int($0.element.count), $0.offset) }.sorted { $0.0 < $1.0 }
        if childRanges.count > 1 {
            for i in 1..<childRanges.count where childRanges[i - 1].1 > childRanges[i].0 {
                throw Failure("NUP directory child ranges overlap")
            }
        }
        guard dirs.reduce(UInt64(0), { $0 + UInt64($1.count) }) == UInt64(children.count) else {
            throw Failure("NUP child slot count does not match")
        }
        let bases = packages.filter { $0.kind == 0 }
        guard bases.count <= 1, packages.allSatisfy({ $0.titleID != 0 }) else { throw Failure("NUP base package or title IDs are invalid") }
        var packageKeys = Set<String>()
        for package in packages where !packageKeys.insert("\(package.kind):\(package.titleID):\(package.version)").inserted {
            throw Failure("NUP has duplicate package identities")
        }
        let hasBase = !bases.isEmpty
        for package in packages {
            guard Int(package.root) < dirs.count,
                  package.exefs == UInt32.max || Int(package.exefs) < dirs.count,
                  package.romfs == UInt32.max || Int(package.romfs) < dirs.count else { throw Failure("NUP package directory reference is invalid") }
            guard package.kind <= 2 else { throw Failure("NUP contains an unsupported package kind") }
            if package.kind == 1 && !hasBase && package.flags & 1 == 0 { throw Failure("NUP update is not marked standalone") }
            if package.exefs != UInt32.max && dirs[Int(package.exefs)].name != "exefs" { throw Failure("NUP ExeFS directory name does not match its reference") }
            if package.romfs != UInt32.max && dirs[Int(package.romfs)].name != "romfs" { throw Failure("NUP RomFS directory name does not match its reference") }
            let root = dirs[Int(package.root)]
            let packageChildren = children[Int(root.first)..<(Int(root.first) + Int(root.count))]
            for selected in [package.exefs, package.romfs] where selected != UInt32.max {
                guard packageChildren.contains(selected) else { throw Failure("NUP ExeFS/RomFS must be direct children of its package root") }
            }
        }
        try Self.validateTree(dirs: dirs, files: files, children: children, packages: packages)
        self.url = url; self.packages = packages; self.toc = toc; self.directories = dirs; self.files = files
        self.children = children; self.blobOffset = blobOffset
        if verifyContents { try verifyFileHashes(zstdPath: zstdPath) }
    }

    /// Extracts one base, all update versions and every add-on into the folder
    /// layout consumed by nxnative. Writes only under a new private destination.
    package func extract(to destination: URL, zstdPath: String) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw Failure("Import destination already exists") }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            for package in packages {
                let root: URL
                switch package.kind {
                case 0: root = destination.appendingPathComponent("base", isDirectory: true)
                case 1: root = destination.appendingPathComponent("updates/\(package.version)", isDirectory: true)
                case 2: root = destination.appendingPathComponent("dlc/\(String(format: "%016llX", package.titleID))/\(package.version)", isDirectory: true)
                default: continue
                }
                if package.kind == 2 {
                    let parent = destination.appendingPathComponent("dlc/\(String(format: "%016llX", package.titleID))", isDirectory: true)
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                }
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                if package.exefs != UInt32.max { try extractTree(Int(package.exefs), to: root.appendingPathComponent("exefs", isDirectory: true), zstdPath: zstdPath) }
                if package.romfs != UInt32.max { try extractTree(Int(package.romfs), to: root.appendingPathComponent("romfs", isDirectory: true), zstdPath: zstdPath) }
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func verifyFileHashes(zstdPath: String) throws {
        for file in files {
            let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: output) }
            try materialize(file, to: output, zstdPath: zstdPath)
        }
    }

    private func extractTree(_ directory: Int, to output: URL, zstdPath: String) throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let range = Int(directories[directory].first)..<(Int(directories[directory].first) + Int(directories[directory].count))
        for child in range.map({ children[$0] }) {
            if child < UInt32(directories.count) {
                let node = directories[Int(child)]
                try extractTree(Int(child), to: output.appendingPathComponent(node.name, isDirectory: true), zstdPath: zstdPath)
            } else {
                let index = Int(child - UInt32(directories.count)), file = files[index]
                let destination = output.appendingPathComponent(file.name, isDirectory: false)
                try materialize(file, to: destination, zstdPath: zstdPath)
            }
        }
    }

    private func materialize(_ file: File, to output: URL, zstdPath: String) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: output.path) else { throw Failure("NUP extraction tried to overwrite a file") }
        let compressed = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zst")
        defer { try? fm.removeItem(at: compressed) }
        let source = try FileHandle(forReadingFrom: url)
        try source.seek(toOffset: file.extent)
        let target = try FileHandle(forWritingTo: createEmptyFile(file.codec == 0 ? output : compressed))
        do {
            var remaining = file.storedSize
            while remaining > 0 {
                let count = Int(min(remaining, 1 << 20))
                guard let chunk = try source.read(upToCount: count), chunk.count == count else { throw Failure("NUP extent ended unexpectedly") }
                try target.write(contentsOf: chunk)
                remaining -= UInt64(count)
            }
            try target.close(); try source.close()
        } catch { try? target.close(); try? source.close(); try? fm.removeItem(at: output); throw error }
        if file.codec == 1 {
            let selected = fm.isExecutableFile(atPath: zstdPath) ? zstdPath : "/usr/bin/false"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: selected)
            process.arguments = ["-q", "-d", "-f", "--max-output-size=\(file.size)", compressed.path, "-o", output.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do { try process.run(); process.waitUntilExit() }
            catch { try? fm.removeItem(at: output); throw Failure("The bundled zstd decompressor could not start") }
            guard process.terminationStatus == 0 else { try? fm.removeItem(at: output); throw Failure("NUP zstd stream is invalid") }
        }
        do {
            let (size, digest) = try Self.digest(output)
            guard size == file.size, digest == file.hash else { throw Failure("NUP file content hash or size mismatch: \(file.name)") }
        } catch { try? fm.removeItem(at: output); throw error }
    }

    private func createEmptyFile(_ url: URL) throws -> URL {
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else { throw Failure("Could not create a private NUP extraction file") }
        return url
    }

    private static func digest(_ url: URL) throws -> (UInt64, Data) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256(), size: UInt64 = 0
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data); size += UInt64(data.count)
        }
        return (size, Data(hasher.finalize()))
    }

    private static func validateTree(dirs: [Directory], files: [File], children: [UInt32], packages: [Package]) throws {
        var references = Set<UInt32>(), fileReferences = Set<UInt32>()
        for i in dirs.indices {
            let d = dirs[i], ids = children[Int(d.first)..<(Int(d.first) + Int(d.count))]
            var names: [String] = []
            for id in ids {
                if id < UInt32(dirs.count) {
                    guard Int(id) != i else { throw Failure("NUP directory cycle detected") }
                    names.append(dirs[Int(id)].name)
                } else {
                    let fi = id - UInt32(dirs.count)
                    guard Int(fi) < files.count else { throw Failure("NUP child references a missing file") }
                    names.append(files[Int(fi)].name); fileReferences.insert(fi)
                }
                guard references.insert(id).inserted else { throw Failure("NUP node is referenced more than once") }
            }
            guard names == names.sorted(), Set(names).count == names.count else { throw Failure("NUP directory children are unsorted or duplicated") }
        }
        guard fileReferences.count == files.count else { throw Failure("NUP contains unreachable file entries") }
        var visited = Set<UInt32>()
        func walk(_ id: UInt32, _ ancestry: Set<UInt32>) throws {
            guard id < UInt32(dirs.count) else { return }
            guard !ancestry.contains(id) else { throw Failure("NUP directory cycle detected") }
            if !visited.insert(id).inserted { return }
            var path = ancestry; path.insert(id)
            let d = dirs[Int(id)]
            for child in children[Int(d.first)..<(Int(d.first) + Int(d.count))] { try walk(child, path) }
        }
        for package in packages {
            try walk(package.root, [])
            for selected in [package.exefs, package.romfs] where selected != UInt32.max {
                guard isDescendant(selected, of: package.root, dirs: dirs, children: children) else {
                    throw Failure("NUP package ExeFS/RomFS reference is outside its package tree")
                }
            }
        }
        guard visited.count == dirs.count else { throw Failure("NUP contains unreachable directories") }
    }

    private static func isDescendant(_ target: UInt32, of root: UInt32, dirs: [Directory], children: [UInt32]) -> Bool {
        var stack = [root], seen = Set<UInt32>()
        while let current = stack.popLast() {
            if current == target { return true }
            guard seen.insert(current).inserted else { continue }
            let d = dirs[Int(current)]
            for child in children[Int(d.first)..<(Int(d.first) + Int(d.count))] where child < UInt32(dirs.count) { stack.append(child) }
        }
        return false
    }

    private static func read(_ handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw Failure("NUP file ended unexpectedly") }
        return data
    }
    private static func u16(_ d: Data, _ p: Int) -> UInt16 { UInt16(d[p]) | UInt16(d[p + 1]) << 8 }
    private static func u32(_ d: Data, _ p: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(d[p + $1]) << ($1 * 8) } }
    private static func u64(_ d: Data, _ p: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(d[p + $1]) << ($1 * 8) } }
}
