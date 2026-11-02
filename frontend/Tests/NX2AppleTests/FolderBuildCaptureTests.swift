import XCTest
import SwiftUI
@testable import NX2Apple
import NXModel
import NXCore
import NXLauncher

@MainActor final class FolderBuildCaptureTests: XCTestCase {
    func testRenderLauncherForVisualQAFolderBuild() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR") }
        let stores = LauncherStores()
        stores.build.lang = CaptureLanguage.current(.en)
        let oldOutput = stores.build.outDir
        defer { stores.build.outDir = oldOutput }
        stores.build.outDir = "/Volumes/Games"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nx2apple-capture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try ExtractedFixture.make(at: root)
        let selected = try ExtractedGame.inspect(root.path)
        try capture("folder-build", stores: stores, directory: directory)
        if ProcessInfo.processInfo.environment["NX_CAPTURE_BASELINE"] == "1" { return }
        stores.build.dumpMode = true
        stores.build.dumpFolder = "/Volumes/Games/ExampleGame"
        stores.build.dumpLayout = selected
        let oldTarget = stores.build.target
        defer { stores.build.target = oldTarget }
        stores.build.target = BuildTarget.mac
        try capture("folder-build-selected", stores: stores, directory: directory)
        stores.build.dumpLayout = nil
        stores.build.dumpProblem = String(format: stores.build.t("dump.folderMissing"), "ExampleGame/base/romfs")
        try capture("folder-build-invalid", stores: stores, directory: directory, width: 620)
    }

    private func capture(_ name: String, stores: LauncherStores, directory: String, width: CGFloat = 800) throws {
        let view = VStack(spacing: 20) {
            FilesCard(build: stores.build, extrasOpen: .constant(false))
            TargetCard(build: stores.build)
            ActionCard(build: stores.build, dependencies: stores.dependencies, repo: stores.repo)
        }.padding(24).frame(width: width).background(LauncherPalette.background)
            .environmentObject(stores.localizer).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: view)
        let window = OffscreenWindow(size: NSSize(width: width, height: 850), styleMask: [.titled])
        window.contentView = host
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let out = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent(name + ".png"))
        window.orderOut(nil)
    }
}
