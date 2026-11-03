import SwiftUI
import AppKit
import NXCore
import NXLauncher
import NXModel

/// The Builds page's first card: the game folder, the four input rows (base game, update, add-on content, prod.keys) and where the
/// build goes. Observes the build store. It stays in the app target because it runs `KeyCheck` (KeyCheck.swift, which needs
/// CommonCrypto) on the chosen files.
struct FilesCard: View {
    @ObservedObject var build: BuildStore
    @EnvironmentObject var loc: Localizer
    @Binding var extrasOpen: Bool   // the optional input rows, kept by the page so they stay as they were when it is left and back
    @State private var keyCheck: KeyCheck.Outcome?   // prod.keys against the chosen files (KeyCheck.swift)

    var body: some View {
        // The report's own mistake, and a reasonable one: the output folder silently decides where
        // the build cache lives, so changing it threw away a finished build. Say it under Save to, all the time.
        CardGroup(loc.t("section.files"), footnote: loc.t("msg.workdirHint")) {
            CardRow(loc.t("dump.source")) {
                Picker("", selection: Binding(get: { build.dumpMode }, set: { build.setDumpMode($0) })) {
                    Text(loc.t("dump.packages")).tag(false)
                    Text(loc.t("dump.experimental")).tag(true)
                }.labelsHidden().pickerStyle(.menu)
            }
            CardDivider()
            Button(action: pickFolder) {
                CardRow(loc.t(build.inputFolder.isEmpty ? "build.folderCTA" : "build.folderSelected"),
                    detail: build.inputFolder.isEmpty ? loc.t("build.folderNote") : build.shortPath(build.inputFolder), help: build.inputFolder) {
                    Text(loc.t(build.inputFolder.isEmpty ? "data.choose" : "data.change"))
                        .font(.manrope(13, .semibold)).foregroundStyle(.black)
                        .launcherRowControlFrame()
                        .background(LauncherPalette.cream, in: Capsule())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if build.dumpMode {
                CardDivider()
                CardRow(loc.t("dump.experimental"), detail: loc.t("dump.hint")) { EmptyView() }
                if let layout = build.dumpLayout {
                    CardDivider()
                    CardRow(layout.titleID, detail: layout.versions.isEmpty ? loc.t("dump.baseOnly") : String(format: loc.t(layout.hasBaseRomfs ? "dump.versions" : "dump.updateOnlyVersions"), layout.versions.map(String.init).joined(separator: ", "))) { EmptyView() }
                }
                if !build.dumpProblem.isEmpty {
                    Text(build.dumpProblem).font(.manrope(13)).foregroundStyle(LauncherPalette.building)
                        .fixedSize(horizontal: false, vertical: true).padding(18)
                }
            } else {
                ForEach(build.slots.filter { !$0.optional }, id: \.id) { s in
                    CardDivider(); slotRow(s)
                    if s.id == "keys", let keyCheck { KeyCheckLine(outcome: keyCheck, t: loc.t) }
                }
                CardDivider()
                CardDisclosure(loc.t("build.options"), isOpen: extrasOpen) { extrasOpen.toggle() }
                if extrasOpen {
                    ForEach(build.slots.filter(\.optional), id: \.id) { s in CardDivider(); slotRow(s) }
                }
            }
            CardDivider()
            CardRow(loc.t("build.saveTo"), detail: build.outDir.isEmpty ? loc.t("build.saveDefault") : build.shortPath(build.outDir), help: build.outDir) {
                Button(loc.t("data.change")) { build.chooseBuildFolder() }
            }
        }
        .task(id: KeyCheck.Inputs(keys: build.dumpMode ? "" : build.keysPath, files: build.dumpMode ? [] : [build.basePath, build.updatePath] + build.dlcPaths)) {
            keyCheck = await KeyCheck.runDetached(KeyCheck.Inputs(keys: build.dumpMode ? "" : build.keysPath, files: build.dumpMode ? [] : [build.basePath, build.updatePath] + build.dlcPaths))
        }
        .disabled(build.running)
    }

    private func slotRow(_ s: Slot) -> some View {
        // An empty prod.keys row says where the file comes from.
        CardRow(loc.t(s.title), detail: s.id == "keys" && s.paths.isEmpty ? loc.t("build.keyHint") : s.summary(loc.t), dot: s.ok ? LauncherPalette.ready : LauncherPalette.unbuilt,
            help: s.paths.joined(separator: "\n")) {
            if !s.paths.isEmpty {
                Button(loc.t("data.clear")) { build.clear(s.id) }.buttonStyle(.plain)
                    .font(.manrope(13)).foregroundStyle(.secondary)
            }
            Button(s.paths.isEmpty ? loc.t("data.choose") : loc.t("data.change")) { build.pickFiles(kind: s.kind) }
        }
    }

    private func pickFolder() {
        let d = NSOpenPanel()
        d.message = loc.t(build.dumpMode ? "dump.panel" : "build.folderNote")
        d.canChooseDirectories = true; d.canChooseFiles = false
        if d.runModal() == .OK, let u = d.url { build.scan(folder: u.path) }
    }
}
