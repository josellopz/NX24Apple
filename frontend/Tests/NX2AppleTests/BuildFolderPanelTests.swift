import XCTest
@testable import NX2Apple

/// The Build tab's Save to dialog must offer "New Folder": the folder for the IPA often does not exist yet (#477).
@MainActor final class BuildFolderPanelTests: XCTestCase {
    func testTheSaveToPanelCanCreateFolders() {
        let panel = PanelSettings()
        LauncherStores.configureBuildFolderPanel(panel)
        XCTAssertTrue(panel.canCreateDirectories)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.canChooseFiles)
    }

    private final class PanelSettings: BuildFolderPanelConfigurable {
        var canCreateDirectories = false
        var canChooseDirectories = false
        var canChooseFiles = true
    }
}
