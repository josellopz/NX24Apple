import XCTest
@testable import NXModel
@testable import NXCore

/// `BuildStore` without SwiftUI: the other stores are fakes behind the narrow protocols (`RepoLocation`, `DependencyInstalling`,
/// `EngineSyncing`, `InstallTarget`), the panels and the alert are closures that record, the defaults are a suite of their own and
/// the files are in a temporary folder. No process starts and nothing is built: these tests drive the inputs, the script's events,
/// the failure, "Build anyway" and the conditions that stop a build before it starts.
@MainActor final class BuildStoreTests: XCTestCase {
    private final class FakeRepo: RepoLocation {
        var path = "/repo"
        var isRepo = true
        var isGit = true
    }

    private final class FakeDeps: DependencyInstalling {
        var pythonPath = "/usr/bin/python3"
        var dotnetPath = "/usr/bin/true"
        var checked = true
        var allPresent = true
        var deps: [Dep] = []
        var installed: [String] = []
        var busy: Set<String> = []
        func isInstalling(_ id: String) -> Bool { busy.contains(id) }
        func install(_ dep: Dep) -> Task<Void, Never> { installed.append(dep.id); return Task {} }
    }

    private final class FakeEngine: EngineSyncing {
        var syncs = 0
        func syncEngine(then: ((Bool) -> Void)?) -> Task<Void, Never> { syncs += 1; then?(true); return Task {} }
    }

    private final class FakeDevices: InstallTarget {
        var installDevice = ""
        var signingTeam = ""
        var devices: [AppleDevice] = []
        var xcrun = "/usr/bin/true"
        var readTeams: @Sendable () -> [SigningTeam] = { [] }
        func deviceName(_ udid: String) -> String { devices.first { $0.id == udid }?.name ?? "iPhone" }
        nonisolated func askCopy(_ plan: ShellCopyPlan) -> ShellCopyDecision { .skip }
        nonisolated func setWaiting(_ on: Bool) {}
        nonisolated var waitCancelled: Bool { false }
        func copyEnded() {}
    }

    private var suite: String!
    private var defaults: UserDefaults!
    private var temporary: URL!
    private let repo = FakeRepo()
    private let deps = FakeDeps()
    private let engine = FakeEngine()
    private let devices = FakeDevices()
    private let localizer = Localizer(.en)

    override func setUpWithError() throws {
        suite = "nxmodel-build-tests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: temporary)
    }

    private func makeStore(targetChanged: @escaping () -> Void = {}) -> BuildStore {
        BuildStore(localizer: localizer, runner: FakeProcessRunner(), repo: repo, deps: deps, engine: engine, devices: devices,
                   defaults: defaults, targetChanged: targetChanged)
    }

    private func file(_ name: String) throws -> String {
        let url = temporary.appendingPathComponent(name)
        try Data([0]).write(to: url)
        return url.path
    }

    private func extracted() throws -> String {
        let path = temporary.appendingPathComponent("Game")
        try FileManager.default.createDirectory(at: path.appendingPathComponent("base/exefs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: path.appendingPathComponent("base/romfs"), withIntermediateDirectories: true)
        var main = Data(repeating: 0, count: 0x100)
        main.replaceSubrange(0..<4, with: "NSO0".utf8)
        try main.write(to: path.appendingPathComponent("base/exefs/main"))
        var d = Data(repeating: 0, count: 0x100)
        d.replaceSubrange(0..<4, with: "META".utf8); d[0x70] = 0x80; d[0x74] = 0x20
        d.replaceSubrange(0x80..<0x84, with: "ACI0".utf8)
        let tid: UInt64 = 0x040074A01BF12000
        for i in 0..<8 { d[0x90 + i] = UInt8(truncatingIfNeeded: tid >> (8 * i)) }
        try d.write(to: path.appendingPathComponent("base/exefs/main.npdm"))
        return path.path
    }

    func testExtractedBuildCommandPassesTheRootWithoutKeysOrIOSArguments() throws {
        let store = makeStore()
        store.selectDump(try extracted())
        store.outDir = temporary.path + "/Output with spaces"
        store.cloudFolderCheck = { _ in false }
        repo.path = temporary.path + "/engine"
        for name in [RepoLayout.buildScript, RepoLayout.romfsImageTool, "scripts/pack_dump.py", "dm/games/040074A01BF12000/game.tsv"] {
            let file = URL(fileURLWithPath: repo.path + "/" + name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("scan_dump( '--work-dir'".utf8).write(to: file)
        }
        store.startBuild()  // FakeProcessRunner refuses the launch after the command is prepared.
        let args = store.lastBuildCommand
        XCTAssertEqual(Array(args.prefix(3)), [deps.pythonPath, repo.path + "/" + RepoLayout.buildScript, store.dumpFolder])
        XCTAssertFalse(args.contains("-k"))
        XCTAssertFalse(args.contains("--shell-framework"))
        XCTAssertFalse(args.contains("--prepare-xcode"))
        XCTAssertTrue(args.contains("mac-app"))
        XCTAssertTrue(args.contains("json"))
        XCTAssertTrue(args.contains(store.outDir + "/040074A01BF12000.app"))
        XCTAssertEqual(store.effectiveWorkDir, store.outDir + "/040074A01BF12000_build")
        XCTAssertNil(store.staging)
    }

    func testUpdateOnlyRomfsPreparesTheOriginalRootAndRequiresCompatibleEngine() throws {
        let folder = try extracted()
        let update = URL(fileURLWithPath: folder + "/updates/655360")
        try FileManager.default.createDirectory(at: update.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: folder + "/base", toPath: update.path)
        try FileManager.default.removeItem(atPath: folder + "/base/romfs")
        let store = makeStore()
        store.selectDump(update.appendingPathComponent("romfs").path)
        store.outDir = temporary.path + "/output"
        store.cloudFolderCheck = { _ in false }
        XCTAssertTrue(store.canBuild)
        XCTAssertEqual(store.dumpFolder, folder)
        XCTAssertEqual(store.dumpLayout?.versions, [655360])
        repo.path = temporary.path + "/engine"
        for name in [RepoLayout.buildScript, RepoLayout.romfsImageTool, "scripts/pack_dump.py", "dm/games/040074A01BF12000/game.tsv"] {
            let file = URL(fileURLWithPath: repo.path + "/" + name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("scan_dump( '--work-dir'".utf8).write(to: file)
        }
        store.startBuild()
        XCTAssertEqual(store.doneNote, store.t("dump.engineOld"))
        XCTAssertTrue(store.lastBuildCommand.isEmpty)
        let script = URL(fileURLWithPath: repo.path + "/" + RepoLayout.buildScript)
        try Data("scan_dump( def dump_versions( '--work-dir'".utf8).write(to: script)
        store.startBuild()
        XCTAssertEqual(store.lastBuildCommand.dropFirst(2).first, folder)
        XCTAssertFalse(store.lastBuildCommand.contains("-k"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder + "/base/romfs"))
        XCTAssertNil(store.staging)
    }

    func testAnOldEngineOrMissingProfileStopsWithAnActionableMessage() throws {
        let store = makeStore()
        store.selectDump(try extracted())
        repo.path = temporary.path + "/engine"
        for name in [RepoLayout.buildScript, RepoLayout.romfsImageTool] {
            let file = URL(fileURLWithPath: repo.path + "/" + name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("scan_dump(".utf8).write(to: file)
        }
        store.startBuild()
        XCTAssertEqual(store.doneNote, store.t("dump.engineOld"))
        try Data().write(to: URL(fileURLWithPath: repo.path + "/scripts/pack_dump.py"))
        store.startBuild()
        XCTAssertTrue(store.doneNote.contains("040074A01BF12000"))
        XCTAssertTrue(store.lastBuildCommand.isEmpty)
        XCTAssertFalse(store.running)
    }

    func testExtractedSelectionNeedsNoKeysForcesMacAndPreservesPackageChoices() throws {
        let store = makeStore()
        store.take(picked: ["/old/Game.nsp"], kind: .base)
        let folder = try extracted()
        store.scan(folder: folder)
        XCTAssertTrue(store.dumpMode)
        XCTAssertEqual(store.target, BuildTarget.mac)
        XCTAssertEqual(store.selectedTitleID, "040074A01BF12000")
        XCTAssertEqual(store.basePath, "/old/Game.nsp")
        XCTAssertTrue(store.keysPath.isEmpty)
        XCTAssertTrue(store.canBuild)
        store.take(dropped: ["/irrelevant/readme.txt"])
        XCTAssertTrue(store.dumpMode, "an unsupported drop keeps the selected extracted game")
        store.setDumpMode(false)
        XCTAssertFalse(store.canBuild, "package mode still needs keys")
        XCTAssertEqual(store.basePath, "/old/Game.nsp")
        store.setDumpMode(true)
        XCTAssertTrue(store.canBuild)
    }

    func testRemovedInputAndUnsupportedTargetStopBeforeStartingAnyTool() throws {
        let store = makeStore()
        store.selectDump(try extracted())
        store.target = BuildTarget.ios
        store.startBuild()
        XCTAssertFalse(store.running)
        XCTAssertEqual(store.doneNote, store.t("dump.macOnly"))
        store.target = BuildTarget.mac
        try FileManager.default.removeItem(atPath: store.dumpFolder + "/base/exefs/main")
        store.startBuild()
        XCTAssertFalse(store.running)
        XCTAssertFalse(store.canBuild)
        XCTAssertTrue(store.doneNote.contains("main"))
        XCTAssertEqual(engine.syncs, 0)
    }

    func testExtractedInputPlanUsesNPDMIdentityAndNeverStagesRomfs() throws {
        let store = makeStore()
        let folder = try extracted()
        store.selectDump(folder + "/base")
        store.outDir = temporary.path + "/Output with spaces"
        let plan = try XCTUnwrap(store.inputPlan())
        XCTAssertEqual(plan.inputDir, folder)
        XCTAssertEqual(plan.titleID, "040074A01BF12000")
        XCTAssertEqual(plan.workDir, store.outDir + "/040074A01BF12000_build")
        XCTAssertNil(store.staging)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.workDir))
        store.resetExtractedInputs()
        XCTAssertFalse(store.dumpMode)
        store.restoreExtractedInputs(folder)
        XCTAssertEqual(store.dumpFolder, folder)
        XCTAssertTrue(store.inputsReady)
    }

    // MARK: The conditions to start

    func testABuildMayStartOnlyWithARepositoryTheBaseGameTheKeysAndTheToolsAndNoRunningBuild() throws {
        let store = makeStore()
        XCTAssertFalse(store.canBuild, "no files yet")
        store.updateSlot("base") { $0.paths = [try! file("Game [0100000000001000].nsp")] }
        store.updateSlot("keys") { $0.paths = [try! file("prod.keys")] }
        XCTAssertTrue(store.canBuild)
        repo.isRepo = false
        XCTAssertFalse(store.canBuild, "the repository is not usable")
        repo.isRepo = true; deps.allPresent = false
        XCTAssertFalse(store.canBuild, "a tool is missing")
        deps.allPresent = true; store.running = true
        XCTAssertFalse(store.canBuild, "a build runs")
    }

    func testAnIPhoneBuildWithoutADeviceStopsBeforeTheLongSteps() {
        let store = makeStore()
        store.target = "ios"
        store.startBuild()
        XCTAssertFalse(store.running)
        XCTAssertEqual(store.doneNote, store.t("shell.needsDevice"))
        XCTAssertFalse(store.installsDirectly)
        devices.installDevice = "UDID"; devices.signingTeam = "TEAM"
        XCTAssertTrue(store.installsDirectly)
        store.target = "mac-app"
        XCTAssertFalse(store.installsDirectly, "a Mac app is not installed on a device")
    }

    func testABuildWithoutARepositoryEndsWithTheMessageAndRunsNothing() {
        let store = makeStore()
        store.target = "mac-app"
        repo.isRepo = false; repo.path = ""
        store.startBuild()
        XCTAssertFalse(store.running)
        XCTAssertEqual(store.doneNote, store.t("msg.repoInvalidEmpty"))
        XCTAssertTrue(store.log.text.contains("✗"), "the log says it too")
    }

    // MARK: The inputs

    func testTheTargetTheOutputFolderAndTheCompatibilitySwitchAreSavedAndTheTargetTellsTheApp() {
        var changes = 0
        let store = makeStore { changes += 1 }
        store.target = "mac-app"; store.outDir = "/out"; store.bcOnCPU = true
        XCTAssertEqual(defaults.string(forKey: BuildStore.targetKey), "mac-app")
        XCTAssertEqual(defaults.string(forKey: BuildStore.outputKey), "/out")
        XCTAssertTrue(defaults.bool(forKey: BuildStore.bcOnCPUKey))
        XCTAssertEqual(changes, 1)
        store.target = "mac-app"
        XCTAssertEqual(changes, 1, "the same target is no change")
        XCTAssertEqual(makeStore().outDir, "/out", "a new store starts from what was saved")
    }

    func testTakingFilesFillsTheRowAndNamesTheFirstFileThatDoesNotFit() {
        let store = makeStore()
        store.take(picked: ["/g/Game [0100000000001000].nsp"], kind: .base)
        XCTAssertEqual(store.basePath, "/g/Game [0100000000001000].nsp")
        XCTAssertEqual(store.gameDir, "/g")
        store.take(picked: ["/g/Other [0100000000002800].nsp", "/g/Game update [0100000000001800].nsp"], kind: .update)
        XCTAssertEqual(store.updatePath, "/g/Game update [0100000000001800].nsp", "the file that fits is taken")
        XCTAssertFalse(store.slot("update").problem.isEmpty, "the other one is named on the row")
        store.clear("update")
        XCTAssertEqual(store.updatePath, "")
        XCTAssertEqual(store.slot("update").problem, "")
    }

    func testThePickerIsTheAppsAndGetsTheRowsWordsAndFileTypes() {
        let store = makeStore()
        var asked: [FilePick] = []
        store.choosePaths = { asked.append($0); return ["/g/Game dlc [0100000000001001].nsp"] }
        store.pickFiles(kind: .dlc)
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked[0].allowsMultiple)
        XCTAssertEqual(asked[0].fileTypes, GameInputs.allowedFileTypes(for: .dlc))
        XCTAssertEqual(asked[0].message, store.t("data.dlcPanelMessage"))
        store.choosePaths = { _ in [] }
        store.pickFiles(kind: .update)
        XCTAssertEqual(store.updatePath, "", "a cancelled panel changes nothing")
    }

    // MARK: The script's events

    func testTheScriptsJSONEventsBecomeStagesAndLogLines() {
        let store = makeStore()
        store.ingest("{\"ev\":\"stage\",\"k\":1,\"n\":3,\"name\":\"extract\",\"step\":\"keys\"}\n")
        XCTAssertEqual(store.stages.map(\.id), [1])
        XCTAssertEqual(store.stages[0].state, .running)
        XCTAssertEqual(store.stages[0].detail, "keys")
        store.ingest("{\"ev\":\"progress\",\"k\":1,\"frac\":0.5,\"done\":5,\"total\":10}\n{\"ev\":\"stage_end\",\"k\":1,\"name\":\"extract\",\"ok\":true,\"elapsed\":3,\"summary\":\"10 files\"}\n")
        XCTAssertEqual(store.stages[0].state, .done)
        XCTAssertEqual(store.stages[0].detail, "10 files")
        XCTAssertEqual(store.stages[0].percent, 100)
        XCTAssertTrue(store.log.text.contains("[1/3] extract · keys …"))
        XCTAssertTrue(store.log.text.contains("✓ extract (\(BuildProgress.duration(3))): 10 files"))
    }

    func testAChunkThatEndsInTheMiddleOfALineWaitsForTheRest() {
        let store = makeStore()
        store.ingest("{\"ev\":\"stage\",\"k\":2,\"n\":3,\"na")
        XCTAssertTrue(store.stages.isEmpty)
        store.ingest("me\":\"pack\"}\nplain line from a tool\n")
        XCTAssertEqual(store.stages.map(\.id), [2])
        XCTAssertTrue(store.log.text.contains("plain line from a tool\n"), "what is not an event is log text")
    }

    func testTheShaderChainNoticeShowsOncePerBuild() {
        let store = makeStore()
        var notices: [String] = []
        store.showNotice = { notices.append($0) }
        store.ingest("{\"ev\":\"say\",\"msg\":\"[NOTE] chain-changed: recompiling\"}\n")
        store.ingest("[NOTE] chain-changed again\n")
        XCTAssertEqual(notices, [store.t("msg.chainChanged")])
    }

    // MARK: The failure

    func testAFailedBuildsLogIsClassifiedAndAnUnknownStopLeavesTheNote() {
        let store = makeStore()
        store.logTail = "[RED] the iOS SDK is not installed\n"
        store.noteFailure()
        XCTAssertEqual(store.failure?.kind, .iosSDK)
        XCTAssertEqual(store.doneNote, store.t(BuildFailureKind.iosSDK.whatKey))
        store.doneNote = "Build failed: something else"
        store.logTail = "nothing the table knows"
        store.noteFailure()
        XCTAssertNil(store.failure)
        XCTAssertEqual(store.doneNote, "Build failed: something else")
    }

    func testBuildAnywayAsksFirstAndArmsTheFlagForOneBuildOnly() {
        let store = makeStore()
        store.target = "mac-app"
        repo.isRepo = false   // the build that follows ends at once, which is all this test needs
        store.failure = BuildFailure(kind: .iosSDK, gameName: nil)
        store.requestBuildAnyway()
        XCTAssertNil(store.confirmingOverride, "this stop has no override")
        store.failure = BuildFailure(kind: .otherMetal, gameName: nil)
        store.running = true
        store.requestBuildAnyway()
        XCTAssertNil(store.confirmingOverride, "not while a build runs")
        store.running = false
        store.requestBuildAnyway()
        XCTAssertEqual(store.confirmingOverride, .otherMetal)
        XCTAssertNil(store.armedOverride, "nothing is armed before the confirmation")
        store.cancelBuildAnyway()
        XCTAssertNil(store.confirmingOverride)
        store.requestBuildAnyway()
        store.confirmBuildAnyway()
        XCTAssertNil(store.confirmingOverride)
        XCTAssertNil(store.armedOverride, "the build took the flag: the next one asks again")
        XCTAssertNil(store.takeOverrideFlag())
        store.armedOverride = .damagedNSP
        XCTAssertEqual(store.takeOverrideFlag(), "--allow-damaged")
        XCTAssertNil(store.takeOverrideFlag())
    }

    func testTheFixButtonsRunTheDependencyRowsOwnInstall() {
        let store = makeStore()
        deps.deps = [Dep(id: "dotnet", name: "dep.dotnet", hint: "", present: false, installCmd: ["/usr/bin/true"]),
                     Dep(id: "python", name: "dep.python", hint: "", present: false, installCmd: ["/usr/bin/true"])]
        store.fixBuildFailure(.translator)
        store.fixBuildFailure(.zbic)
        store.fixBuildFailure(.iosSDK)
        XCTAssertEqual(deps.installed, ["dotnet", "python", "xcode"])
        XCTAssertFalse(store.fixBusy(.translator))
        deps.busy = ["dotnet"]
        XCTAssertTrue(store.fixBusy(.translator))
        XCTAssertFalse(store.fixBusy(.zbic))
        XCTAssertFalse(store.fixBusy(.keys), "a fix that is no install is never busy")
    }

    func testTheKeysFixUsesTheKeysPickerAndTheCloudFixTheFolderPanel() {
        let store = makeStore()
        var keysAsked = 0
        store.chooseKeys = { keysAsked += 1 }
        store.fixBuildFailure(.keys)
        XCTAssertEqual(keysAsked, 1)
        store.failure = BuildFailure(kind: .cloudFolder, gameName: nil, detail: "/iCloud/x")
        store.doneNote = "stopped"
        store.chooseFolder = { nil }
        store.fixBuildFailure(.cloudFolder)
        XCTAssertEqual(store.failure?.kind, .cloudFolder, "a cancelled panel keeps the stop")
        store.chooseFolder = { "/Users/x/Games" }
        store.fixBuildFailure(.cloudFolder)
        XCTAssertEqual(store.outDir, "/Users/x/Games")
        XCTAssertNil(store.failure, "the next build looks at the new folder")
        XCTAssertEqual(store.doneNote, "")
    }

    func testTheFailureFolderOpensInTheFinderForAFullDisk() throws {
        let store = makeStore()
        let built = temporary.appendingPathComponent("0100_build")
        try FileManager.default.createDirectory(at: built, withIntermediateDirectories: true)
        store.gameDir = temporary.path
        store.failure = BuildFailure(kind: .diskFull, gameName: nil, detail: "40")
        var shown: [URL] = []
        store.revealFolder = { shown.append($0) }
        store.showFailureFolder()
        XCTAssertEqual(shown.map(\.path), [built.path])
    }

    // MARK: The install on a device

    func testReinstallAndResignSayWhyTheyCannotRunInsteadOfStartingATool() {
        let store = makeStore()
        store.reinstallOnDevice()
        XCTAssertFalse(store.running, "nothing was installed: nothing to reinstall")
        store.installedOn = "UDID"; store.installedAppPath = temporary.path + "/gone/DmIOS.app"
        store.reinstallOnDevice()
        XCTAssertFalse(store.running)
        XCTAssertEqual(store.doneNote, String(format: store.t("dev.reinstallMissing"), store.shortPath(store.installedAppPath)))
        store.resignOnDevice(app: store.installedAppPath, device: "UDID")
        XCTAssertEqual(store.doneNote, store.t("dev.resignNoTeam"))
        devices.signingTeam = "TEAM"
        store.resignOnDevice(app: store.installedAppPath, device: "UDID")
        XCTAssertEqual(store.doneNote, store.t("dev.resignOlder"))
        XCTAssertFalse(store.running)
    }

    func testTheSavePanelIsTheAppsAndACancelWritesNothing() {
        let store = makeStore()
        var asked: [(String, String)] = []
        store.chooseSaveLocation = { asked.append(($0, $1)); return nil }
        store.saveIPAPanel()
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.0, store.t("dev.saveIPATitle"))
        XCTAssertEqual(asked.first?.1, "DmIOS.ipa")
        XCTAssertFalse(store.running)
    }

    func testTheRetryOfTheGameDataNeedsAnInstallThatLeftOneToRetry() {
        let store = makeStore()
        store.retryShellData()
        XCTAssertFalse(store.running, "no install ran: nothing to retry")
    }

    func testWhatTheStoreWritesItselfIsInTheLanguageOfTheLocalizer() {
        let store = makeStore()
        localizer.lang = Lang("de")
        XCTAssertEqual(store.lang, Lang("de"))
        XCTAssertEqual(store.t("shell.needsDevice"), L10n.string("shell.needsDevice", Lang("de")))
    }

    func testAStoppedBuildWithNothingRunningDoesNothing() {
        let store = makeStore()
        store.stop()
        XCTAssertFalse(store.stopping)
    }
}
