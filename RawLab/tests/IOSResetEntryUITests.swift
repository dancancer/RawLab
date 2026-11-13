import AppKit
import ApplicationServices
import SwiftUI

enum Sony2FujiProcessor {
    struct RawWhiteBalance: Equatable {
        let temperature: Double
        let tint: Double
        let isCalibrated: Bool
    }
}

final class RawEditorViewModel {
    enum SourceKind: Equatable { case raw, raster }
    enum EditSaveState: Equatable { case idle, failed(String) }

    var sourceFile: PhotoSourceFile?
    var sourceIdentity: PhotoIdentity?
    var sourceKind: SourceKind? = .raw
    var activeImportRevision: UUID?
    var sourceRevision = UUID()
    var editRecordMetadata: EditorRecordMetadata?
    var isBusy = false
    var hasImage = true
    var rawWhiteBalance: Sony2FujiProcessor.RawWhiteBalance? = .init(temperature: 5500, tint: 0, isCalibrated: true)
    var pendingResetMigrationClear: (EditorEditSource, PhotoEditState, Bool)?
    var failedDraftSource: EditorEditSource?
    var persistedEditorSettings: PersistedEditorSettings?
    var editSaveState: EditSaveState = .idle
    var pendingSettings: RawSettings?
    var persistedCandidates: [PhotoEditState] = []

    init(url: URL) {
        sourceFile = .externallyManaged(url)
        sourceIdentity = PhotoIdentity(resourceIdentifier: "ios-reset-entry-test")
    }

    func cancelQueuedSettingsSave() { pendingSettings = nil }
    func persistEditCandidate(_ candidate: PhotoEditState, source: EditorEditSource) -> Bool {
        persistedCandidates.append(candidate)
        return true
    }
    func queueSettingsSave(_ settings: RawSettings) { pendingSettings = settings }
}

@MainActor private final class ResetControlHostModel: ObservableObject {
    @Published var toolWorkspaceOpen = false
    @Published var quickPresetsVisible = false
    @Published var selectedGroup: EditorAdjustmentGroup = .light
    @Published var currentTool: EditorToolSelection = .adjustment(.exposure)
    @Published var hslChannel = 0
    @Published var gradingZone: ColorGradingZone = .shadows
    @Published var isAvailable = true
    @Published var settings = RawSettings.default
    @Published var draft: EditorToolDraft?
    var context = EditorAdjustmentContext(isRaw: true, defaultExposureMode: RawSettings.default.exposureMode,
                                          cameraTemperature: 5500, cameraTint: 0)
    var requestedScopes: [EditorAdjustmentScope] = []

    var effectiveSettings: RawSettings {
        draft?.projecting(on: settings) ?? settings
    }

    var presentation: EditorWorkspaceResetPresentation? {
        let snapshot = PhotoEditState(settings: effectiveSettings)
        return EditorWorkspaceResetPresentation.make(
            toolWorkspaceOpen: toolWorkspaceOpen,
            quickPresetsVisible: quickPresetsVisible,
            selectedGroup: selectedGroup,
            currentTool: currentTool,
            hslChannel: hslChannel,
            gradingZone: gradingZone,
            isAvailable: isAvailable,
            isModified: { EditorAdjustmentRules.isModified($0, snapshot: snapshot, context: self.context) }
        )
    }
}

private struct ResetControlHostView: View {
    @ObservedObject var model: ResetControlHostModel
    var body: some View {
        EditorWorkspaceResetControl(presentation: model.presentation) { scope in
            model.requestedScopes.append(scope)
        }
        .buttonStyle(.plain)
    }
}

@main struct IOSResetEntryUITests {
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }

    enum Failure: Error, CustomStringConvertible {
        case assertion(String)
        var description: String {
            switch self { case .assertion(let message): return message }
        }
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.assertion(message) }
        print("PASS: \(message)")
    }

    @MainActor static func axAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }

    @MainActor static func findElement(_ element: AXUIElement, identifier: String, depth: Int = 0) -> AXUIElement? {
        guard depth < 32 else { return nil }
        if axAttribute(element, kAXIdentifierAttribute as CFString) as? String == identifier {
            return element
        }
        for child in axAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? [] {
            if let found = findElement(child, identifier: identifier, depth: depth + 1) { return found }
        }
        return nil
    }

    @MainActor static func perform(_ element: AXUIElement, _ action: CFString) throws {
        guard AXUIElementPerformAction(element, action) == .success else {
            throw Failure.assertion("Accessibility action \(action) failed")
        }
    }

    @MainActor fileprivate static func settle(_ host: NSHostingView<ResetControlHostView>) async throws {
        host.invalidateIntrinsicContentSize()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
    }

    @MainActor static func requirePresentation(_ value: EditorWorkspaceResetPresentation?, _ message: String) throws -> EditorWorkspaceResetPresentation {
        guard let value else { throw Failure.assertion(message) }
        return value
    }

    @MainActor static func menuItems(of presentation: EditorWorkspaceResetPresentation) throws -> [EditorWorkspaceResetItem] {
        guard case .menu(let items, _) = presentation.style else {
            throw Failure.assertion("Expected menu reset presentation, got \(presentation.style)")
        }
        return items
    }

    @MainActor static func run() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dummyURL = tempDir.appendingPathComponent("sample.ARW")
        try Data("raw".utf8).write(to: dummyURL)

        let viewModel = RawEditorViewModel(url: dummyURL)
        let hostModel = ResetControlHostModel()
        var neutral = RawSettings.default
        neutral.temperature = 5500
        neutral.tint = 0
        hostModel.settings = neutral

        let host = NSHostingView(rootView: ResetControlHostView(model: hostModel))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await settle(host)

        let axTrusted = AXIsProcessTrusted()
        let appElement = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)

        // 1. 一级总览态：重置当前分组 + 重置全部调整入口存在、本地化文案与可用状态正确
        let initialOverview = try requirePresentation(
            hostModel.presentation,
            "Missing Level 1 editor.reset presentation in overview state"
        )
        try check(initialOverview.identifier == "editor.reset",
                  "Level 1 overview uses accessibilityIdentifier editor.reset")
        try check(initialOverview.label == L10n.text("重置调整"),
                  "Level 1 editor.reset reuses localized accessibility label")
        try check(!initialOverview.isEnabled,
                  "Level 1 editor.reset is disabled when no adjustments are modified")
        try check(host.fittingSize.width >= 44 && host.fittingSize.height >= 44,
                  "Rendered SwiftUI Level 1 reset menu meets 44x44 minimum hit target")
        if axTrusted {
            guard let axOverview = findElement(appElement, identifier: "editor.reset") else {
                throw Failure.assertion("Missing Level 1 editor.reset AX element")
            }
            try check((axAttribute(axOverview, kAXEnabledAttribute as CFString) as? Bool) == false,
                      "AX tree reports Level 1 editor.reset disabled when unedited")
        }

        hostModel.quickPresetsVisible = true
        try await settle(host)
        try check(hostModel.presentation == nil && host.fittingSize.height < 1,
                  "Quick presets panel hides Level 1 workspace reset control")
        hostModel.quickPresetsVisible = false

        var editedLight = neutral
        editedLight.exposure = 0.75
        editedLight.saturation = 1.25
        hostModel.settings = editedLight
        hostModel.selectedGroup = .effects
        try await settle(host)

        let effectsOverview = try requirePresentation(
            hostModel.presentation,
            "Missing Level 1 editor.reset when viewing unmodified group with global edits"
        )
        try check(effectsOverview.isEnabled,
                  "Level 1 editor.reset enables when another group is modified so Reset All stays reachable")
        let effectsItems = try menuItems(of: effectsOverview)
        try check(effectsItems.count == 2 &&
                  effectsItems[0].id == "editor.reset.group" && !effectsItems[0].isEnabled &&
                  effectsItems[1].id == "editor.reset.all" && effectsItems[1].isEnabled && effectsItems[1].isDestructive,
                  "Unmodified group disables group reset while keeping destructive Reset All enabled")

        hostModel.selectedGroup = .light
        try await settle(host)
        let lightOverview = try requirePresentation(hostModel.presentation, "Missing Level 1 light group reset presentation")
        let lightItems = try menuItems(of: lightOverview)
        try check(lightOverview.isEnabled &&
                  lightItems[0].id == "editor.reset.group" &&
                  lightItems[0].title == L10n.format("重置%@组…", EditorAdjustmentGroup.light.title) &&
                  lightItems[0].scope == .group(.light) && lightItems[0].isEnabled,
                  "Level 1 overview exposes enabled Reset Current Group entry for modified group")
        try check(lightItems[1].id == "editor.reset.all" &&
                  lightItems[1].title == L10n.text("重置全部调整…") &&
                  lightItems[1].scope == .all && lightItems[1].isEnabled && lightItems[1].isDestructive,
                  "Level 1 overview exposes enabled destructive Reset All Adjustments entry")

        let noDraft = EditorDraftSnapshot(geometry: nil, lens: nil, tool: .film)
        let lightRev = UUID()
        guard case .prepared(let preparedGroup) = viewModel.prepareReset(.group(.light), settings: editedLight,
                                                                         revision: lightRev, draft: noDraft),
              preparedGroup.requiresConfirmation, !preparedGroup.updatesDraft,
              let afterGroup = viewModel.commitReset(preparedGroup, settings: editedLight,
                                                     revision: lightRev, draft: noDraft) else {
            throw Failure.assertion("Level 1 group reset failed to prepare and commit")
        }
        try check(afterGroup.settings.exposure == 0 && afterGroup.settings.saturation == 1.25 &&
                  viewModel.pendingResetMigrationClear == nil,
                  "Group reset clears only the selected group without touching other groups or migration state")

        let allRev = UUID()
        guard case .prepared(let preparedAll) = viewModel.prepareReset(.all, settings: afterGroup.settings,
                                                                       revision: allRev, draft: noDraft),
              preparedAll.requiresConfirmation, !preparedAll.updatesDraft,
              let afterAll = viewModel.commitReset(preparedAll, settings: afterGroup.settings,
                                                   revision: allRev, draft: noDraft) else {
            throw Failure.assertion("Level 1 full reset failed to prepare and commit")
        }
        try check(afterAll.settings.saturation == 1 && viewModel.pendingResetMigrationClear != nil,
                  "Reset All clears remaining adjustments and reaches pendingResetMigrationClear")

        // HDR 模式下仅显示映射改动时，「重置全部调整」仍可达且可用
        var hdrEdited = neutral
        var hdr = HDRSettings()
        hdr.mode = .hdr
        hdr.renditionSettings.peakLimitEV = 1.8
        hdrEdited.hdr = hdr
        hostModel.settings = hdrEdited
        hostModel.selectedGroup = .light
        try await settle(host)
        let hdrOverview = try requirePresentation(hostModel.presentation, "Missing Level 1 HDR reset presentation")
        let hdrItems = try menuItems(of: hdrOverview)
        try check(hdrOverview.isEnabled && !hdrItems[0].isEnabled && hdrItems[1].isEnabled,
                  "HDR rendition-only edits keep Level 1 Reset All enabled when group reset has no changes")

        // 2. 工具工作区打开（草稿态）：单工具重置可用；跨分组/全部重置被阻止并返回准确的草稿提示
        var draftBase = neutral
        draftBase.exposure = 0.5
        draftBase.saturation = 1.3
        var exposureDraft = EditorToolDraft(tool: .adjustment(.exposure), original: draftBase)
        var exposureEdited = draftBase
        exposureEdited.exposure = 1.2
        exposureDraft.update(exposureEdited)

        hostModel.settings = draftBase
        hostModel.toolWorkspaceOpen = true
        hostModel.currentTool = .adjustment(.exposure)
        hostModel.draft = exposureDraft
        hostModel.requestedScopes.removeAll()
        try await settle(host)

        let scalarPresentation = try requirePresentation(
            hostModel.presentation,
            "Missing Level 2 editor.draft.reset presentation for scalar tool"
        )
        try check(scalarPresentation.identifier == "editor.draft.reset" &&
                  scalarPresentation.label == L10n.text("重置调整") &&
                  scalarPresentation.isEnabled &&
                  scalarPresentation.style == .button(scope: .tool(.adjustment(.exposure)), isEnabled: true),
                  "Level 2 scalar tool exposes enabled editor.draft.reset button without cross-tool group/all items")
        try check(host.fittingSize.width >= 44 && host.fittingSize.height >= 44,
                  "Rendered SwiftUI Level 2 reset button meets 44x44 minimum hit target")
        if axTrusted {
            try check(findElement(appElement, identifier: "editor.reset") == nil,
                      "AX tree hides Level 1 editor.reset while Level 2 draft is open")
            guard let draftButton = findElement(appElement, identifier: "editor.draft.reset") else {
                throw Failure.assertion("Missing Level 2 editor.draft.reset AX button")
            }
            try perform(draftButton, kAXPressAction as CFString)
            try check(hostModel.requestedScopes == [.tool(.adjustment(.exposure))],
                      "AX press on editor.draft.reset triggers .tool(currentTool)")
        }

        let activeDraft = EditorDraftSnapshot(geometry: nil, lens: nil, tool: .adjustment(.exposure), workspace: exposureDraft)
        let draftRev = UUID()
        for forbidden in [
            EditorAdjustmentScope.group(.light),
            .group(.color),
            .group(.geometry),
            .all,
            .tool(.adjustment(.contrast)),
        ] {
            guard case .blocked(let reason) = viewModel.prepareReset(forbidden, settings: draftBase,
                                                                     revision: draftRev, draft: activeDraft) else {
                throw Failure.assertion("Expected \(forbidden) to be blocked while tool draft is active")
            }
            try check(reason == .draftConflict &&
                      reason.message == L10n.text("请先应用或放弃未完成的输入和几何草稿。") &&
                      reason.message != L10n.text("预览尚未就绪，请稍后重试。"),
                      "Active draft blocks \(forbidden) with accurate draft conflict message")
        }

        viewModel.hasImage = false
        if case .blocked(let notReady) = viewModel.prepareReset(.all, settings: draftBase, revision: draftRev, draft: noDraft) {
            try check(notReady == .sourceNotReady && notReady.message == L10n.text("预览尚未就绪，请稍后重试。"),
                      "Unready source retains the preview-not-ready message")
        } else {
            throw Failure.assertion("Expected unready source to block with .sourceNotReady")
        }
        viewModel.hasImage = true

        // 3. 非草稿态下 .group(.geometry) 可执行，且保留 .tool(.geometry)/.tool(.lens) 草稿态约束
        var geoEdited = neutral
        geoEdited.exposure = 0.4
        geoEdited.geometry.quarterTurns = 1
        geoEdited.geometry.cropWidth = 0.8
        geoEdited.lensCorrection = LensCorrectionSettings(distortion: true, tca: true, autoCrop: false)
        hostModel.toolWorkspaceOpen = false
        hostModel.draft = nil
        hostModel.settings = geoEdited
        hostModel.selectedGroup = .geometry
        try await settle(host)

        let geoOverview = try requirePresentation(hostModel.presentation, "Missing Level 1 geometry reset presentation")
        let geoItems = try menuItems(of: geoOverview)
        try check(geoOverview.isEnabled &&
                  geoItems[0].id == "editor.reset.group" &&
                  geoItems[0].scope == .group(.geometry) && geoItems[0].isEnabled &&
                  geoItems[0].title == L10n.format("重置%@组…", EditorAdjustmentGroup.geometry.title),
                  "Level 1 geometry group reset entry is enabled")

        for draftOnlyTool in [EditorAdjustmentScope.tool(.geometry), .tool(.lens)] {
            guard case .blocked(let reason) = viewModel.prepareReset(draftOnlyTool, settings: geoEdited,
                                                                     revision: UUID(), draft: noDraft),
                  reason == .draftConflict else {
                throw Failure.assertion("Expected non-draft \(draftOnlyTool) to stay blocked by draft constraint")
            }
        }
        let geoRev = UUID()
        guard case .prepared(let preparedGeo) = viewModel.prepareReset(.group(.geometry), settings: geoEdited,
                                                                       revision: geoRev, draft: noDraft),
              preparedGeo.requiresConfirmation, !preparedGeo.updatesDraft,
              let afterGeo = viewModel.commitReset(preparedGeo, settings: geoEdited,
                                                   revision: geoRev, draft: noDraft) else {
            throw Failure.assertion("Non-draft .group(.geometry) reset failed to prepare and commit")
        }
        try check(afterGeo.settings.geometry.isIdentity &&
                  afterGeo.settings.lensSettings == LensCorrectionSettings() &&
                  afterGeo.settings.exposure == 0.4,
                  "Non-draft .group(.geometry) resets both geometry and lens while preserving other groups")

        // 4. 二级工具态 HSL 与颜色分级：单色/单分区与全部 HSL/全部分级双项菜单可用且能正确执行
        var hslEdited = neutral
        hslEdited.hsl.set(.hue, channel: 0, value: 25)
        hslEdited.hsl.set(.saturation, channel: 4, value: -30)
        var hslDraft = EditorToolDraft(tool: .adjustment(.hsl), original: neutral)
        hslDraft.update(hslEdited)

        hostModel.settings = neutral
        hostModel.toolWorkspaceOpen = true
        hostModel.currentTool = .adjustment(.hsl)
        hostModel.hslChannel = 2
        hostModel.draft = hslDraft
        try await settle(host)

        let unmodifiedHSLMenu = try requirePresentation(hostModel.presentation, "Missing Level 2 HSL reset menu")
        let unmodifiedChannelItems = try menuItems(of: unmodifiedHSLMenu)
        try check(unmodifiedHSLMenu.identifier == "editor.draft.reset" &&
                  unmodifiedHSLMenu.isEnabled &&
                  host.fittingSize.width >= 44 && host.fittingSize.height >= 44 &&
                  unmodifiedChannelItems.count == 2 &&
                  unmodifiedChannelItems[0].id == "editor.draft.reset.hslChannel" && !unmodifiedChannelItems[0].isEnabled &&
                  unmodifiedChannelItems[1].id == "editor.draft.reset.allHSL" && unmodifiedChannelItems[1].isEnabled,
                  "Unmodified current HSL channel disables single-channel item while keeping Reset All HSL enabled")

        hostModel.hslChannel = 0
        try await settle(host)
        let modifiedHSLMenu = try requirePresentation(hostModel.presentation, "Missing Level 2 modified HSL reset menu")
        let modifiedChannelItems = try menuItems(of: modifiedHSLMenu)
        let redName = L10n.text(HSLSettings.channelNames[0])
        try check(modifiedChannelItems[0].title == L10n.format("重置当前颜色（%@）", redName) &&
                  modifiedChannelItems[0].scope == .hslChannel(0) && modifiedChannelItems[0].isEnabled &&
                  modifiedChannelItems[1].title == L10n.text("重置全部 HSL…") &&
                  modifiedChannelItems[1].scope == .allHSL && modifiedChannelItems[1].isEnabled,
                  "Modified HSL channel enables both single-channel and all-HSL menu items")

        let hslSnap = EditorDraftSnapshot(geometry: nil, lens: nil, tool: .adjustment(.hsl), workspace: hslDraft)
        let hslRev = UUID()
        guard case .prepared(let preparedChannel) = viewModel.prepareReset(.hslChannel(0), settings: neutral,
                                                                           revision: hslRev, draft: hslSnap),
              !preparedChannel.requiresConfirmation, preparedChannel.updatesDraft,
              let afterChannel = viewModel.commitReset(preparedChannel, settings: neutral,
                                                       revision: hslRev, draft: hslSnap) else {
            throw Failure.assertion("HSL single-channel reset failed")
        }
        try check(afterChannel.settings.hsl.value(.hue, channel: 0) == 0 &&
                  afterChannel.settings.hsl.value(.saturation, channel: 4) == -30,
                  "HSL single-channel reset clears only the selected color channel")

        hslDraft.update(afterChannel.settings)
        let hslSnap2 = EditorDraftSnapshot(geometry: nil, lens: nil, tool: .adjustment(.hsl), workspace: hslDraft)
        guard case .prepared(let preparedAllHSL) = viewModel.prepareReset(.allHSL, settings: neutral,
                                                                          revision: hslRev, draft: hslSnap2),
              preparedAllHSL.requiresConfirmation, preparedAllHSL.updatesDraft,
              let afterAllHSL = viewModel.commitReset(preparedAllHSL, settings: neutral,
                                                      revision: hslRev, draft: hslSnap2),
              afterAllHSL.settings.hsl.isIdentity else {
            throw Failure.assertion("HSL full reset failed")
        }
        print("PASS: All-HSL reset clears remaining modified channels in draft")

        var gradingEdited = neutral
        gradingEdited.gradingSettings.shadows = ColorGradingWheel(hue: 35, saturation: 40)
        gradingEdited.gradingSettings.midtones = ColorGradingWheel(hue: 210, saturation: 25)
        var gradingDraft = EditorToolDraft(tool: .adjustment(.colorGrading), original: neutral)
        gradingDraft.update(gradingEdited)

        hostModel.currentTool = .adjustment(.colorGrading)
        hostModel.gradingZone = .highlights
        hostModel.draft = gradingDraft
        try await settle(host)

        let unmodifiedGradingMenu = try requirePresentation(hostModel.presentation, "Missing Level 2 Color Grading reset menu")
        let unmodifiedZoneItems = try menuItems(of: unmodifiedGradingMenu)
        try check(unmodifiedGradingMenu.identifier == "editor.draft.reset" &&
                  unmodifiedGradingMenu.isEnabled &&
                  host.fittingSize.width >= 44 && host.fittingSize.height >= 44 &&
                  unmodifiedZoneItems.count == 2 &&
                  unmodifiedZoneItems[0].id == "editor.draft.reset.gradingZone" && !unmodifiedZoneItems[0].isEnabled &&
                  unmodifiedZoneItems[1].id == "editor.draft.reset.allGrading" && unmodifiedZoneItems[1].isEnabled,
                  "Unmodified Color Grading zone disables single-zone item while keeping Reset All Grading enabled")

        hostModel.gradingZone = .midtones
        try await settle(host)
        let modifiedGradingMenu = try requirePresentation(hostModel.presentation, "Missing Level 2 modified Color Grading reset menu")
        let modifiedZoneItems = try menuItems(of: modifiedGradingMenu)
        try check(modifiedZoneItems[0].title == L10n.text("重置当前分区") &&
                  modifiedZoneItems[0].scope == .gradingZone(.midtones) && modifiedZoneItems[0].isEnabled &&
                  modifiedZoneItems[1].title == L10n.text("重置颜色分级") &&
                  modifiedZoneItems[1].scope == .allGrading && modifiedZoneItems[1].isEnabled,
                  "Modified Color Grading zone enables both single-zone and all-grading menu items")

        let gradingSnap = EditorDraftSnapshot(geometry: nil, lens: nil, tool: .adjustment(.colorGrading), workspace: gradingDraft)
        let gradingRev = UUID()
        guard case .prepared(let preparedZone) = viewModel.prepareReset(.gradingZone(.midtones), settings: neutral,
                                                                        revision: gradingRev, draft: gradingSnap),
              !preparedZone.requiresConfirmation, preparedZone.updatesDraft,
              let afterZone = viewModel.commitReset(preparedZone, settings: neutral,
                                                    revision: gradingRev, draft: gradingSnap) else {
            throw Failure.assertion("Color Grading single-zone reset failed")
        }
        try check(afterZone.settings.gradingSettings.midtones.isDefault &&
                  !afterZone.settings.gradingSettings.shadows.isDefault,
                  "Color Grading single-zone reset clears only the active zone")

        gradingDraft.update(afterZone.settings)
        let gradingSnap2 = EditorDraftSnapshot(geometry: nil, lens: nil, tool: .adjustment(.colorGrading), workspace: gradingDraft)
        guard case .prepared(let preparedAllGrading) = viewModel.prepareReset(.allGrading, settings: neutral,
                                                                              revision: gradingRev, draft: gradingSnap2),
              preparedAllGrading.requiresConfirmation, preparedAllGrading.updatesDraft,
              let afterAllGrading = viewModel.commitReset(preparedAllGrading, settings: neutral,
                                                          revision: gradingRev, draft: gradingSnap2),
              afterAllGrading.settings.gradingSettings.isDefault else {
            throw Failure.assertion("Color Grading full reset failed")
        }
        print("PASS: All-Grading reset clears remaining modified zones in draft")
    }
}
