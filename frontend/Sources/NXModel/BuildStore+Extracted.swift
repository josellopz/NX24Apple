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
