import RawLabKit
import Foundation
import UIKit
import SwiftUI
@testable import RawLabSubtoolCoreUI

@MainActor
enum SubtoolDraftProbe {
    static var attached: ContentView?
    static var checks = 0

    static func installHooks() {
        SubtoolProbeBridge.onAttach = { view in
            if attached == nil {
                attached = view
                DispatchQueue.main.async {
                    Task { @MainActor in
                        await runSuite()
                    }
                }
            }
        }
    }

    static func fail(_ message: String) -> Never {
        fputs("FAIL: \(message)\n", stderr)
        writeResult(passed: false, error: message)
        exit(1)
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fail(message) }
        checks += 1
        print("PASS: \(message)")
    }

    static func writeResult(passed: Bool, error: String? = nil) {
        guard let path = ProcessInfo.processInfo.environment["RAWLAB_SUBTOOL_RESULT"], !path.isEmpty else { return }
        var payload: [String: Any] = ["passed": passed, "checks": checks]
        if let error { payload["error"] = error }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    static func yieldFrames(_ count: Int = 6) async {
        for _ in 0..<count {
            await Task.yield()
            await withCheckedContinuation { cont in
                DispatchQueue.main.async { cont.resume() }
            }
        }
    }

    static func waitUntil(_ timeout: TimeInterval = 15, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await yieldFrames(1)
        }
        return condition()
    }

    static func makeSamplePNG() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("subtool-draft-\(UUID().uuidString).png")
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let size = CGSize(width: 128, height: 96)
        let renderer = UIGraphicsImageRenderer(size: size, format: fmt)
        let r = CGFloat.random(in: 0.25...0.75)
        let g = CGFloat.random(in: 0.3...0.75)
        let b = CGFloat.random(in: 0.35...0.85)
        let img = renderer.image { ctx in
            UIColor(red: r, green: g, blue: b, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        try! img.pngData()!.write(to: url)
        return url
    }

    static func prepareClipboard(for view: ContentView) -> AdjustmentTransferPayload {
        var source = view.settings
        source.exposure = 0.75
        do {
            try view.viewModel.copyAdjustments(scope: .all, settings: source)
        } catch {
            fail("Failed to seed adjustment clipboard: \(error)")
        }
        guard let payload = view.viewModel.adjustmentSession?.clipboard else {
            fail("Clipboard missing after copyAdjustments")
        }
        return payload
    }

    static func runSuite() async {
        defer { exit(0) }
        guard let view = attached else { fail("ContentView did not attach") }
        let sampleURL = makeSamplePNG()
        defer { try? FileManager.default.removeItem(at: sampleURL) }

        var imported = false
        view.viewModel.importImage(from: .raster(sampleURL), onImported: { imported = true },
                                   onSettingsRestored: { restored in view.settings = restored })
        let loaded = await waitUntil(15) { (imported || view.viewModel.hasImage) && !view.viewModel.isBusy }
        check(loaded && view.viewModel.hasImage, "Sample image loads into ContentView")
        await yieldFrames(6)

        let clipboard = prepareClipboard(for: view)
        let presetName = "SubtoolMenuDraft-\(UUID().uuidString.prefix(8))"
        let store = AdjustmentPresetStore()
        var createdPreset: AdjustmentPreset?
        do {
            createdPreset = try store.create(name: presetName, payload: clipboard)
        } catch {
            fail("Failed to create test preset: \(error)")
        }
        defer {
            if let createdPreset { try? store.delete(createdPreset) }
        }
        guard let preset = createdPreset else { fail("Created preset missing") }

        let subtools: [(String, EditorToolSelection)] = [
            ("contrast", .adjustment(.contrast)),
            ("hsl", .adjustment(.hsl)),
            ("film", .film),
            ("geometry", .geometry)
        ]

        func noPresentedSheet() -> Bool {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.windows.first?.rootViewController }
                .allSatisfy { $0.presentedViewController == nil }
        }

        func resetToCleanEditor() async {
            view.finishEditorTool()
            view.draftExitPresented = false
            view.adjustmentSheet = nil
            view.viewModel.closeQuickPresets()
            view.viewModel.cancelQuickPreset()
            view.viewModel.hasAdjustmentDraft = false
            _ = await waitUntil(5) { noPresentedSheet() && !view.viewModel.adjustmentPreparing }
            await yieldFrames(6)
        }

        // 1. Unchanged non-Exposure sub-tools must allow Copy, Paste, History, and Preset apply cleanly.
        for (label, tool) in subtools {
            for actionName in ["copy", "paste", "history", "presetApply"] {
                await resetToCleanEditor()
                view.selectEditorTool(tool)
                await yieldFrames(6)
                check(view.toolWorkspaceOpen && view.isEditorDraftActive && !view.isEditorDraftChanged,
                      "[\(label)+\(actionName)] opened clean draft workspace (active=\(view.isEditorDraftActive) changed=\(view.isEditorDraftChanged))")

                let action: IOSAdjustmentAction
                switch actionName {
                case "copy": action = .copy
                case "paste": action = .paste
                case "history": action = .history
                default: action = .presetApply(preset)
                }
                view.requestAdjustmentAction(action)
                await yieldFrames(8)

                check(!view.draftExitPresented, "[\(label)+\(actionName)] unchanged subtool skips draft exit alert")
                check(!view.toolWorkspaceOpen && !view.isEditorDraftActive,
                      "[\(label)+\(actionName)] exited tool workspace cleanly (open=\(view.toolWorkspaceOpen) active=\(view.isEditorDraftActive))")
                check(!view.viewModel.hasAdjustmentDraft,
                      "[\(label)+\(actionName)] cleared viewModel.hasAdjustmentDraft after snapshot observer")

                switch actionName {
                case "copy":
                    check(view.adjustmentSheet == .copy, "[\(label)+copy] opened copy sheet")
                    do {
                        try view.viewModel.copyAdjustments(scope: .all, settings: view.settings)
                        check(true, "[\(label)+copy] copyAdjustments succeeded without draftRequiresPreflight")
                    } catch {
                        fail("[\(label)+copy] copyAdjustments threw \(error)")
                    }
                case "paste":
                    check(view.adjustmentSheet == .paste, "[\(label)+paste] opened paste sheet")
                    view.adjustmentSheet = nil
                    _ = await waitUntil(5) { noPresentedSheet() && !view.viewModel.adjustmentPreparing }
                    await yieldFrames(4)
                    guard let target = view.viewModel.currentAdjustmentPhoto else {
                        fail("[\(label)+paste] missing currentAdjustmentPhoto")
                    }
                    var pasteOutcome: String?
                    view.viewModel.prepareAdjustmentPaste(clipboard, photos: [target]) { res in
                        switch res {
                        case .success(let prepared):
                            pasteOutcome = prepared.targets.first?.error.map { "\($0)" } ?? "ok"
                        case .failure(let error):
                            pasteOutcome = "ERR:\(error)"
                        }
                    }
                    _ = await waitUntil(15) { pasteOutcome != nil }
                    check(pasteOutcome == "ok", "[\(label)+paste] prepareAdjustmentPaste succeeded (got \(pasteOutcome ?? "nil"))")
                case "history":
                    check(view.adjustmentSheet == .history, "[\(label)+history] opened history sheet")
                default:
                    let settled = await waitUntil(30) {
                        if case .preparing = view.viewModel.quickPresetState { return false }
                        return true
                    }
                    check(settled, "[\(label)+presetApply] settled preset application")
                    switch view.viewModel.quickPresetState {
                    case .saved, .unchanged:
                        check(true, "[\(label)+presetApply] succeeded (\(view.viewModel.quickPresetState))")
                    default:
                        fail("[\(label)+presetApply] unexpected state \(view.viewModel.quickPresetState)")
                    }
                }
            }
        }

        // 2. Modified sub-tool draft MUST still prompt draftExitPresented and resolve after confirmation.
        await resetToCleanEditor()
        view.selectEditorTool(.adjustment(.contrast))
        await yieldFrames(6)
        view.workingSettings.contrast = (view.settings.contrast > 1.2 ? 0.8 : 1.25)
        await yieldFrames(4)
        check(view.isEditorDraftChanged, "Modified contrast draft reports isEditorDraftChanged=true")
        view.requestAdjustmentAction(.paste)
        await yieldFrames(4)
        check(view.draftExitPresented && view.adjustmentSheet == nil,
              "Modified contrast draft triggers draftExitPresented before paste sheet")

        view.draftExitPresented = false
        view.finishDraftNavigation(apply: false)
        await yieldFrames(8)
        check(!view.draftExitPresented && !view.toolWorkspaceOpen && !view.viewModel.hasAdjustmentDraft,
              "Discarding modified contrast draft closes workspace and clears hasAdjustmentDraft")
        check(view.adjustmentSheet == .paste, "Pending paste sheet opens after discarding modified draft")

        await resetToCleanEditor()
        view.selectEditorTool(.geometry)
        await yieldFrames(6)
        view.geometryDraft?.straightenDegrees = 3.0
        await yieldFrames(4)
        check(view.isEditorDraftChanged, "Modified geometry draft reports isEditorDraftChanged=true")
        view.requestAdjustmentAction(.copy)
        await yieldFrames(4)
        check(view.draftExitPresented && view.adjustmentSheet == nil,
              "Modified geometry draft triggers draftExitPresented before copy sheet")

        // 3. Batch-sync resolveCollectionDraft must close workspaceDraft/toolWorkspaceOpen so
        //    the async editorDraftSnapshot observer does not re-enable hasAdjustmentDraft.
        guard let sourceKey = view.viewModel.sourceIdentity?.key else {
            fail("Missing sourceIdentity key for resolveCollectionDraft test")
        }

        await resetToCleanEditor()
        view.selectEditorTool(.adjustment(.contrast))
        await yieldFrames(6)
        view.workingSettings.contrast = (view.settings.contrast > 1.2 ? 0.8 : 1.25)
        await yieldFrames(4)
        check(view.resolveCollectionDraft(sourceKey, apply: false),
              "resolveCollectionDraft(apply: false) succeeds for modified contrast draft")
        await yieldFrames(8)
        check(!view.toolWorkspaceOpen && !view.isEditorDraftActive && !view.viewModel.hasAdjustmentDraft,
              "resolveCollectionDraft(apply: false) closes workspace and keeps hasAdjustmentDraft=false")
        check(view.viewModel.adjustmentTargetIsCurrent(sourceKey),
              "resolveCollectionDraft(apply: false) leaves batch sync target check button enabled")

        await resetToCleanEditor()
        view.selectEditorTool(.adjustment(.contrast))
        await yieldFrames(6)
        check(view.resolveCollectionDraft(sourceKey, apply: true),
              "resolveCollectionDraft(apply: true) succeeds for unchanged contrast draft")
        await yieldFrames(8)
        check(!view.toolWorkspaceOpen && !view.isEditorDraftActive && !view.viewModel.hasAdjustmentDraft,
              "resolveCollectionDraft(apply: true) on unchanged draft closes workspace and keeps hasAdjustmentDraft=false")
        check(view.viewModel.adjustmentTargetIsCurrent(sourceKey),
              "resolveCollectionDraft(apply: true) on unchanged draft leaves batch sync target check button enabled")

        await resetToCleanEditor()
        view.selectEditorTool(.geometry)
        await yieldFrames(6)
        view.geometryDraft?.straightenDegrees = 2.0
        await yieldFrames(4)
        check(view.resolveCollectionDraft(sourceKey, apply: true),
              "resolveCollectionDraft(apply: true) succeeds for modified geometry draft")
        await yieldFrames(8)
        check(!view.toolWorkspaceOpen && !view.isEditorDraftActive && !view.geometrySelected && !view.viewModel.hasAdjustmentDraft,
              "resolveCollectionDraft(apply: true) on modified geometry draft closes workspace and keeps hasAdjustmentDraft=false")
        check(view.viewModel.adjustmentTargetIsCurrent(sourceKey),
              "resolveCollectionDraft(apply: true) on modified geometry draft leaves batch sync target check button enabled")

        // 4. showQuickPresets must cleanly commit/close an active draft before opening quick presets.
        await resetToCleanEditor()
        view.selectEditorTool(.adjustment(.contrast))
        await yieldFrames(6)
        view.showQuickPresets()
        await yieldFrames(8)
        check(view.viewModel.quickPresetsVisible && !view.toolWorkspaceOpen && !view.isEditorDraftActive && !view.viewModel.hasAdjustmentDraft,
              "showQuickPresets closes unchanged subtool draft and clears hasAdjustmentDraft")

        await resetToCleanEditor()
        view.selectEditorTool(.adjustment(.contrast))
        await yieldFrames(6)
        let targetContrast: Double = view.settings.contrast > 1.2 ? 0.85 : 1.3
        view.workingSettings.contrast = targetContrast
        await yieldFrames(4)
        view.showQuickPresets()
        await yieldFrames(8)
        check(view.viewModel.quickPresetsVisible && !view.toolWorkspaceOpen && !view.isEditorDraftActive && !view.viewModel.hasAdjustmentDraft,
              "showQuickPresets commits modified subtool draft and clears hasAdjustmentDraft")
        check(abs(view.settings.contrast - targetContrast) < 0.001,
              "showQuickPresets preserves committed contrast value")

        // 5. Export menu actions must cleanly commit/close an active draft before exporting.
        await resetToCleanEditor()
        view.selectEditorTool(.adjustment(.contrast))
        await yieldFrames(6)
        let exportContrast: Double = view.settings.contrast > 1.2 ? 0.9 : 1.35
        view.workingSettings.contrast = exportContrast
        await yieldFrames(4)
        view.requestSingleExport(.jpeg)
        await yieldFrames(8)
        check(view.showingExportSize && view.singleExportFormat == .jpeg,
              "requestSingleExport opens export size sheet with active draft")
        check(!view.toolWorkspaceOpen && !view.isEditorDraftActive && !view.viewModel.hasAdjustmentDraft,
              "requestSingleExport closes workspace and clears hasAdjustmentDraft")
        check(abs(view.settings.contrast - exportContrast) < 0.001,
              "requestSingleExport commits modified contrast before export")
        view.showingExportSize = false
        _ = await waitUntil(5) { noPresentedSheet() }

        await resetToCleanEditor()
        view.selectEditorTool(.adjustment(.contrast))
        await yieldFrames(6)
        view.openBatchExport()
        await yieldFrames(8)
        check(view.showingBatchExport && view.batchModel != nil,
              "openBatchExport opens batch export with active draft")
        check(!view.toolWorkspaceOpen && !view.isEditorDraftActive && !view.viewModel.hasAdjustmentDraft,
              "openBatchExport closes workspace and clears hasAdjustmentDraft")
        view.batchModel = nil
        view.showingBatchExport = false
        _ = await waitUntil(5) { noPresentedSheet() }

        // 6. Collection navigation and openBatchSelection must close active draft cleanly so
        //    onChange(of: editorDraftSnapshot) does not re-enable hasAdjustmentDraft.
        await resetToCleanEditor()
        view.selectEditorTool(.adjustment(.contrast))
        await yieldFrames(6)
        view.requestCollectionNavigation(.returnToCollection)
        await yieldFrames(8)
        check(view.showingBatchSelection && !view.draftExitPresented,
              "requestCollectionNavigation(.returnToCollection) opens collection sheet for unchanged draft")
        check(!view.toolWorkspaceOpen && !view.isEditorDraftActive && !view.viewModel.hasAdjustmentDraft,
              "requestCollectionNavigation(.returnToCollection) closes workspace and keeps hasAdjustmentDraft=false")
        view.showingBatchSelection = false
        view.pendingCollectionNavigation = nil
        _ = await waitUntil(5) { noPresentedSheet() }

        await resetToCleanEditor()
        view.selectEditorTool(.adjustment(.contrast))
        await yieldFrames(6)
        view.openBatchSelection()
        await yieldFrames(8)
        check(view.showingBatchSelection,
              "openBatchSelection opens collection sheet with unchanged active draft")
        check(!view.toolWorkspaceOpen && !view.isEditorDraftActive && !view.viewModel.hasAdjustmentDraft,
              "openBatchSelection closes unchanged draft workspace and keeps hasAdjustmentDraft=false")
        view.showingBatchSelection = false
        _ = await waitUntil(5) { noPresentedSheet() }

        await resetToCleanEditor()
        view.selectEditorTool(.adjustment(.contrast))
        await yieldFrames(6)
        let batchContrast: Double = view.settings.contrast > 1.2 ? 0.92 : 1.4
        view.workingSettings.contrast = batchContrast
        await yieldFrames(4)
        view.openBatchSelection()
        await yieldFrames(8)
        check(view.showingBatchSelection,
              "openBatchSelection opens collection sheet with modified active draft")
        check(!view.toolWorkspaceOpen && !view.isEditorDraftActive && !view.viewModel.hasAdjustmentDraft,
              "openBatchSelection closes modified draft workspace and keeps hasAdjustmentDraft=false")
        check(abs(view.settings.contrast - batchContrast) < 0.001,
              "openBatchSelection commits modified contrast before opening collection")
        view.showingBatchSelection = false
        _ = await waitUntil(5) { noPresentedSheet() }

        writeResult(passed: true)
        print("PASS: subtool menu draft suite (\(checks) checks)")
    }
}

@main
final class SubtoolDraftAppDelegate: UIResponder, UIApplicationDelegate, UIWindowSceneDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let cfg = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        cfg.delegateClass = SubtoolDraftAppDelegate.self
        return cfg
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        SubtoolDraftProbe.installHooks()
        guard let ws = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: ws)
        w.rootViewController = UIHostingController(rootView: ContentView())
        w.makeKeyAndVisible()
        self.window = w
    }
}
