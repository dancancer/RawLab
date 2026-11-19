import RawLabKit
import AppKit
import Combine
import SwiftUI

@main
struct MacUISmokeRunner {
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await run()
                exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    @MainActor
    static func run() async throws {
        let args = CommandLine.arguments
        let scenario = args.firstIndex(of: "--scenario").flatMap { idx in
            args.indices.contains(idx + 1) ? args[idx + 1] : nil
        } ?? "all"
        let output = URL(fileURLWithPath: args.firstIndex(of: "--output").flatMap { idx in
            args.indices.contains(idx + 1) ? args[idx + 1] : nil
        } ?? NSTemporaryDirectory())
        let stateRoot = output.appendingPathComponent("mac-ui-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateRoot) }

        let (jpg, png) = try MacUITestRobot.makeRasterFixtures(in: stateRoot.appendingPathComponent("fixtures"))
        UserDefaults.standard.setVolatileDomain([L10n.preferenceKey: "en", "photoFolders": [String]()], forName: UserDefaults.argumentDomain)

        let selected = scenario == "all"
            ? ["workspace", "single-preview", "quick-preset", "edited-photo", "batch-flow"]
            : [scenario]

        for item in selected {
            switch item {
            case "workspace":
                try await runWorkspaceSmoke(photo: jpg, root: stateRoot.appendingPathComponent("workspace"))
            case "single-preview":
                try await runSinglePreviewSmoke(photo: png, root: stateRoot.appendingPathComponent("single-preview"))
            case "quick-preset":
                try await runQuickPresetSmoke(photo: jpg, root: stateRoot.appendingPathComponent("quick-preset"))
            case "edited-photo":
                try await runEditedPhotoSmoke(photo: png, root: stateRoot.appendingPathComponent("edited-photo"))
            case "batch-flow":
                try await runBatchFlowSmoke(photos: [jpg, png], root: stateRoot.appendingPathComponent("batch-flow"))
            default:
                throw RenderError.failed("Unknown scenario: \(item)")
            }
        }
    }

    @MainActor
    private static func runWorkspaceSmoke(photo: URL, root: URL) async throws {
        let model = MacUITestRobot.makeEditorModel(root: root)
        let (win, host) = MacUITestRobot.window(EditorView(model: model), width: 950, height: 620, title: "Workspace")
        defer { win.contentView = nil; win.close() }
        model.open(photo)
        try await MacUITestRobot.settle(model)
        model.selectAdjustmentTool(.exposure)
        host.layoutSubtreeIfNeeded()
        try MacUITestRobot.check(!MacUITestRobot.fields(host).isEmpty, "Workspace renders numeric parameter controls")
        try MacUITestRobot.check(model.beginGeometryDraft(tab: .perspective), "Workspace opens geometry draft")
        model.cancelGeometryDraft()
        try MacUITestRobot.check(!MacUITestRobot.png(host).isEmpty, "Workspace renders non-empty snapshot")
    }

    @MainActor
    private static func runSinglePreviewSmoke(photo: URL, root: URL) async throws {
        let model = MacUITestRobot.makeEditorModel(root: root)
        let (win, host) = MacUITestRobot.window(EditorView(model: model), width: 1320, height: 850, title: "SinglePreview")
        defer { win.contentView = nil; win.close() }
        model.open(photo)
        try await MacUITestRobot.settle(model)
        try MacUITestRobot.check(model.result != nil && model.neutral != nil, "Single preview renders result and neutral")
        model.selectAdjustmentTool(.exposure)
        model.settings.exposure = 0.75
        try await MacUITestRobot.settle(model)
        try MacUITestRobot.check(!MacUITestRobot.png(host).isEmpty, "Single preview snapshot succeeds")
    }

    @MainActor
    private static func runQuickPresetSmoke(photo: URL, root: URL) async throws {
        let model = MacUITestRobot.makeEditorModel(root: root)
        let payload = try AdjustmentTransferPayload(
            source: .init(identifier: "quick-ui-fixture", isRaw: false, processingVersion: 2, recipe: nil),
            values: ["light.exposure": .number(0.7)]
        )
        _ = try model.presetStore.create(name: "Smoke Exposure +0.70", payload: payload)
        let (win, host) = MacUITestRobot.window(EditorView(model: model), width: 950, height: 620, title: "QuickPreset")
        defer { win.contentView = nil; win.close() }
        model.open(photo)
        try await MacUITestRobot.settle(model)
        model.showQuickPresets()
        host.layoutSubtreeIfNeeded()
        try MacUITestRobot.check(!MacUITestRobot.png(host).isEmpty, "Quick presets host renders cleanly")
    }

    @MainActor
    private static func runEditedPhotoSmoke(photo: URL, root: URL) async throws {
        let editDir = root.appendingPathComponent("edits", isDirectory: true)
        let store = try MacEditPersistence(directory: editDir)
        var edits = Adjustments()
        edits.exposureMode = .sensor
        edits.exposure = 1.2
        try store.save(photo, state: .init(settings: edits, filmID: ""))
        let model = MacUITestRobot.makeEditorModel(root: root)
        let (win, host) = MacUITestRobot.window(EditorView(model: model), width: 1380, height: 900, title: "EditedPhoto")
        defer { win.contentView = nil; win.close() }
        model.open(photo)
        try await MacUITestRobot.settle(model)
        try MacUITestRobot.check(abs(model.settings.exposure - 1.2) < 0.001, "Edited photo restores persisted exposure")
        try MacUITestRobot.check(!MacUITestRobot.png(host).isEmpty, "Edited photo editor snapshot renders")
    }

    @MainActor
    private static func runBatchFlowSmoke(photos: [URL], root: URL) async throws {
        let model = MacUITestRobot.makeEditorModel(root: root)
        model.addCollectionPhotos(photos)
        let (win, host) = MacUITestRobot.window(BatchSelectionView(model: model), width: 950, height: 620, title: "BatchFlow")
        defer { win.contentView = nil; win.close() }
        host.layoutSubtreeIfNeeded()
        try MacUITestRobot.check(!MacUITestRobot.png(host).isEmpty, "Batch selection view renders collection")
    }
}
