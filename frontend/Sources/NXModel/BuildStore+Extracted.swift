import Foundation
import NXCore

extension BuildStore {
    package var inputsReady: Bool {
        dumpMode ? (dumpLayout != nil && dumpProblem.isEmpty && target == BuildTarget.mac) : (slot("base").ok && slot("keys").ok)
    }

    package var selectedSourcePath: String { dumpMode ? dumpFolder : basePath }
    package var selectedTitleID: String {
        if dumpMode { return dumpLayout?.titleID ?? "" }
        return TitleID.parse(basePath).map { String(format: "%016llX", $0) } ?? ""
    }

    package func resetExtractedInputs() {
        dumpMode = false; dumpFolder = ""; dumpLayout = nil; dumpProblem = ""
    }

    package func restoreExtractedInputs(_ folder: String?) {
        if let folder { selectDump(folder) } else { dumpMode = false }
    }

    package var inputFolder: String { dumpMode ? dumpFolder : gameDir }
    package var defaultOutputFolder: String {
        dumpMode ? dumpFolder : (basePath as NSString).deletingLastPathComponent
    }

    package func setDumpMode(_ enabled: Bool) {
        guard !running else { return }
        dumpMode = enabled
        done = false; doneNote = ""
        if enabled {
            target = BuildTarget.mac
            if !dumpFolder.isEmpty { _ = validateDump() }
        }
    }

    package func selectDump(_ folder: String) {
        guard !running else { return }
        dumpMode = true
        target = BuildTarget.mac
        dumpFolder = ExtractedGame.root(for: folder)
        done = false; doneNote = ""
        _ = validateDump()
    }

    /// Deeply verifies a NUP archive, extracts it into the app's managed import
    /// area, validates the nxnative folder layout, then selects it for building.
    package func importNup(_ path: String) {
        guard !running, !nupImporting else { return }
        nupImporting = true
        nupImportMessage = t("dump.importing")
        let zstd = BundledTools.tool("zstd") ?? ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"].first(where: FileManager.default.isExecutableFile(atPath:)) ?? "/usr/bin/false"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                var destination: URL?
                do {
                    let archive = try NupArchive(url: URL(fileURLWithPath: path), zstdPath: zstd)
                    guard archive.packages.contains(where: { $0.kind == 0 }) else {
                        throw NupArchive.Failure("NUP import requires a base package")
                    }
                    let directory = NSHomeDirectory() + "/Library/Application Support/NS Port Builder/NUP Imports"
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    let target = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
                    destination = target
                    try archive.extract(to: target, zstdPath: zstd)
                    _ = try ExtractedGame.inspect(target.path)
                    return .success(target.path)
                } catch {
                    if let destination { try? FileManager.default.removeItem(at: destination) }
                    return .failure(error)
                }
            }.value
            self.nupImporting = false
            switch result {
            case .success(let folder):
                self.nupImportMessage = self.t("dump.imported")
                self.selectDump(folder)
            case .failure(let error):
                self.nupImportMessage = String(format: self.t("dump.importFailed"), error.localizedDescription)
            }
        }
    }

    /// Re-read on every build, since a removable volume or its contents may have changed.
    @discardableResult package func validateDump() -> Bool {
        do {
            dumpLayout = try ExtractedGame.inspect(dumpFolder)
            dumpProblem = ""
            return true
        } catch let problem as ExtractedGame.Problem {
            dumpLayout = nil
            dumpProblem = problem.detail.isEmpty ? t(problem.key) : String(format: t(problem.key), shortPath(problem.detail))
        } catch {
            dumpLayout = nil
            dumpProblem = error.localizedDescription
        }
        return false
    }
}
