import Foundation
import NXCore

extension BuildStore {
    /// Preserve package selection and staging for Switch 1. Extracted games are passed directly,
    /// including their updates and DLC, without copying or linking the RomFS tree.
    func inputPlan() -> (baseDir: String, inputDir: String, titleID: String, workDir: String)? {
        if dumpMode {
            guard let layout = dumpLayout else { fail(dumpProblem); return nil }
            staging = nil
            let output = outDir.isEmpty ? layout.root : outDir
            let work = output + "/" + layout.titleID + "_build"
            guard validateOutput(workDir: work) else { return nil }
            return (layout.root, layout.root, layout.titleID, work)
        }
        // One folder when everything lives together; otherwise a staging folder of symlinks. A folder
        // that holds other games too (a ROMs folder with one file per game) is staged as well: the
        // script takes one game per folder and refuses one with several ("more than one game in the
        // folder"), even when only the base game was picked (issue #58; ufooer's PR #31).
        let baseDir = (basePath as NSString).deletingLastPathComponent
        let allPaths = [basePath, updatePath] + dlcPaths
        let dirs = Set(allPaths.filter { !$0.isEmpty }.map { ($0 as NSString).deletingLastPathComponent })
        let picked = Set(allPaths.filter { !$0.isEmpty }.map { ($0 as NSString).lastPathComponent })
        let unpicked = ((try? FileManager.default.contentsOfDirectory(atPath: baseDir)) ?? []).filter {
            ["nsp", "xci", "nsz", "xcz"].contains(($0 as NSString).pathExtension.lowercased()) && !picked.contains($0)
        }
        // Staged, the folder's own update and add-on content would be left behind, where the script
        // used to find them unpicked: bring along those whose file name carries this game's title ID
        // exactly as build_ipa_from_nsp.py:445 reads it: the low 12 bits are 0x000 for a base game,
        // 0x800 for its update, and anything else is add-on content below the base.
        var staged = allPaths
        if let base = TitleID.parse((basePath as NSString).lastPathComponent) {
            let app = base & ~0xFFF
            for f in unpicked {
                guard let tid = TitleID.parse(f) else { continue }
                let low = tid & 0xFFF
                let owner = low == 0 ? tid : (low == 0x800 ? tid & ~0xFFF : (tid & ~0xFFF) - 0x1000)
                guard owner == app else { continue }
                if low == 0x800 && !updatePath.isEmpty { continue }   // the update was picked already
                if low != 0 && low != 0x800 && tid <= app { continue }   // add-on content sits above its base
                staged.append(baseDir + "/" + f)
            }
        }
        let tidHex = TitleID.buildKey(basePath)
        let workDir = (outDir.isEmpty ? baseDir : outDir) + "/" + tidHex + "_build"
        guard validateOutput(workDir: workDir) else { return nil }
        var inputDir = baseDir
        if dirs.count > 1 || !unpicked.isEmpty {
            // A stable folder per game (#132): the script's fingerprints name its files and its profile path.
            let tmp = InputStaging.folder(workDir: workDir)
            let linked = InputStaging.sync(files: staged, into: tmp)
            if linked == 0 { fail(t("msg.stagingFailed")); return nil }
            staging = tmp; inputDir = tmp
            if !unpicked.isEmpty {
                say(String(format: t("msg.stagedFromSharedFolder"), (basePath as NSString).lastPathComponent))
            }
        } else { staging = nil }
        return (baseDir, inputDir, tidHex, workDir)

    }

    private func validateOutput(workDir: String) -> Bool {
        if cloudFolderCheck(workDir) {
            failure = BuildFailure(kind: .cloudFolder, gameName: nil, detail: workDir)
            fail(failureWhat(failure!))
            return false
        }
        // Match v1.0.2: exporting one game's IPA does not write into the shared shell folder.
        if target != BuildTarget.mac, !exportsOneGame, let why = shellRootProblem() { fail(why); return false }

        return true
    }
}
