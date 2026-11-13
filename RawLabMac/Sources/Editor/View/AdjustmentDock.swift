import SwiftUI
import AppKit

struct AdjustmentDock: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: EditorModel
    let resetVersion: Int
    @State private var showsExposure = true
    @State private var showsTones = true
    @State private var collapsedTool: EditorAdjustmentTool?
    private var navigation: EditorAdjustmentNavigation {
        model.adjustmentNavigation.normalized(isHDREditing: model.settings.isHDREditing)
    }

    private var visibleGroups: [EditorAdjustmentGroup] {
        EditorAdjustmentGroup.visibleGroups(isHDREditing: model.settings.isHDREditing)
    }

    var body: some View {
        let _ = localizationLocale
        let groups = visibleGroups
        let split = (groups.count + 1) / 2
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                groupRow(groups)
                VStack(alignment: .leading, spacing: 2) {
                    groupRow(groups.prefix(split))
                    groupRow(groups.dropFirst(split))
                }
                VStack(alignment: .leading, spacing: 2) {
                    groupRow(groups.prefix(3))
                    groupRow(groups.dropFirst(3).prefix(3))
                    if groups.count > 6 { groupRow(groups.dropFirst(6)) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6).padding(.vertical, 2)
            Divider()
            if let group = navigation.expandedGroup, groups.contains(group) {
                if group == .looks && !model.settings.isHDREditing {
                    VStack(alignment: .leading, spacing: 3) {
                        parameterRow(.strength, title: L10n.text("外观强度"))
                            .disabled(model.selectedFilm == nil && model.settings.masterRecipe == nil)
                        Text(L10n.text(model.selectedFilm == nil && model.settings.masterRecipe == nil
                                      ? "请先选择外观或配方。" : "胶片、导入外观和大师配方共用"))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal, 10).padding(.vertical, 5)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("workspace.lookStrength")
                    Divider()
                }
                if model.geometryDraft != nil && !model.quickPresetsVisible {
                    MacGeometryWorkspace(model: model)
                } else if model.quickPresetsVisible {
                    if model.settings.isHDREditing {
                        let revision = model.sourceRevision
                        HDRLookControls(settings: Binding(
                            get: { model.settings.hdr ?? HDRSettings() },
                            set: { if model.sourceRevision == revision && model.settings.isHDREditing { model.settings.hdr = $0 } }
                        ), onEditingChanged: model.setInteracting, onCancelled: model.cancelAdjustmentInteraction,
                           onResourceRestored: { model.schedule(forceExact: true) })
                            .padding(.horizontal, 10).padding(.vertical, 6).id(revision).disabled(model.busy)
                        Divider()
                    }
                    QuickPresetView(model: model)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                Color.clear.frame(height: 0).id("adjustment.start").accessibilityHidden(true)
                                if group == .light { lightSections }
                                else { groupTools(group) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: group) { _, _ in proxy.scrollTo("adjustment.start", anchor: .top) }
                    }
                }
            } else { Spacer(minLength: 0) }
        }
        .onChange(of: navigation.tool) { _, _ in collapsedTool = nil }
        .frame(maxWidth: .infinity)
        .environment(\.parameterInputScope, "\(model.file?.absoluteString ?? "").\(navigation.tool.rawValue)")
        .background(Color(nsColor: .windowBackgroundColor)).tint(.yellow)
    }

    private func groupRow(_ groups: some RandomAccessCollection<EditorAdjustmentGroup>) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(groups)) { groupButton($0) }
        }.fixedSize(horizontal: true, vertical: false)
    }

    private func groupButton(_ group: EditorAdjustmentGroup) -> some View {
        let active = navigation.expandedGroup == group
        let changed = model.isAdjustmentModified(.group(group))
        return Button { model.selectAdjustmentGroup(group) } label: {
            HStack(spacing: 3) {
                Text(group.title).font(.system(size: 12, weight: .medium)).fixedSize()
                Circle().fill(.yellow).frame(width: 3, height: 3).opacity(changed ? 1 : 0).accessibilityHidden(true)
            }.padding(.horizontal, 5).frame(minHeight: 29)
                .background(active ? Color.yellow.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(active ? Color.yellow : Color.primary)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .disabled(model.settings.isHDREditing && group != .looks && !group.tools.contains(where: supportsHDR))
            .accessibilityIdentifier("group.\(group.rawValue)")
            .accessibilityLabel(group.title)
            .accessibilityValue([active ? L10n.text("已展开") : L10n.text("已收起"), changed ? L10n.text("已调整") : ""].filter { !$0.isEmpty }.joined(separator: ", "))
            .accessibilityAddTraits(active ? .isSelected : [])
            .help(L10n.format(active ? "收起%@组" : "展开%@组", group.title))
    }

    @ViewBuilder private var lightSections: some View {
        section(title: L10n.text("曝光"), id: "light.exposure", open: showsExposure, available: true,
                toggle: { showsExposure.toggle() }) {
            parameterRow(.exposure)
            parameterRow(.contrast)
        }
        section(title: L10n.text("明暗"), id: "light.tones", open: showsTones, available: true,
                toggle: { showsTones.toggle() }) {
            parameterRow(.highlights, showsTicks: true)
            parameterRow(.shadows)
            parameterRow(.whitePoint)
            parameterRow(.blackPoint)
        }
        toolSection(.toneCurve)
    }

    @ViewBuilder private func groupTools(_ group: EditorAdjustmentGroup) -> some View {
        ForEach(group.tools) { tool in
            if tool != .strength { toolSection(tool) }
        }
        if group == .looks {
            Button(action: model.showQuickPresets) {
                Label(L10n.text("我的预设"), systemImage: "bookmark")
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal, 10).disabled(model.lookLibraryBusy)
                .accessibilityIdentifier("preset.library")
        }
    }

    private func toolSection(_ tool: EditorAdjustmentTool) -> some View {
        let open = !tool.usesGeometryDraft && navigation.tool == tool && collapsedTool != tool
        let changed = model.isAdjustmentModified(.tool(tool))
        let reason = toolUnavailableReason(tool)
        return section(title: tool.title, id: "tool.\(tool.rawValue)", open: open,
                       available: reason == nil && (model.result != nil || (tool == .denoise && model.aiControlsVisible)),
                       changed: changed, reason: reason, toggle: {
            if tool.usesGeometryDraft {
                model.selectAdjustmentGeometryTab(tool == .lens ? .lens : .crop)
            } else if navigation.tool != tool {
                collapsedTool = nil
                model.selectAdjustmentTool(tool)
            } else if open {
                if tool == .colorGrading || tool == .toneCurve { model.cancelAdjustmentInteraction() }
                if tool == .hsl { model.cancelHSLTarget(); model.hslTargetEnabled = false }
                ParameterValueField.cancelPendingInputs()
                collapsedTool = tool
            } else {
                collapsedTool = nil
            }
        }) {
            if !tool.usesGeometryDraft { editorContent(tool) }
        }
        .contextMenu {
            Button(L10n.format("重置%@", tool.title)) { model.requestAdjustmentReset(.tool(tool)) }
                .disabled(!changed)
        }
    }

    private func section<Content: View>(title: String, id: String, open: Bool, available: Bool,
                                        changed: Bool = false, reason: String? = nil, toggle: @escaping () -> Void,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 7) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary).frame(width: 11)
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 4)
                    if changed { Circle().fill(.yellow).frame(width: 4, height: 4).accessibilityHidden(true) }
                }.frame(minHeight: 31).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal, 10).disabled(!available)
                .accessibilityIdentifier(id).accessibilityLabel(title)
                .accessibilityValue(L10n.text(open ? "已展开" : "已收起"))
                .accessibilityHint(reason ?? "").help(reason ?? title)
                .accessibilityAddTraits(open && id.hasPrefix("tool.") ? .isSelected : [])
            if open {
                if let reason {
                    Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10).padding(.bottom, 6)
                }
                VStack(spacing: 4) { content() }
                    .padding(.horizontal, 10).padding(.bottom, 8).disabled(!available)
            }
            Divider()
        }
    }

    private func toolUnavailableReason(_ tool: EditorAdjustmentTool) -> String? {
        if model.settings.isHDREditing && !supportsHDR(tool) { return L10n.text("HDR 模式暂不支持此工具。") }
        if tool == .lens && RenderEngine.isX3fInput(model.file) && model.settings.x3fMode == .normal { return L10n.text("此输入不支持镜头校正") }
        if tool == .lens && RenderEngine.isRasterInput(model.file) { return L10n.text("仅 RAW 照片支持镜头校正。") }
        if tool == .lens && !model.canUseLensCorrection { return L10n.text("此输入不支持镜头校正") }
        return nil
    }

    @ViewBuilder private func editorContent(_ tool: EditorAdjustmentTool) -> some View {
        if tool == .toneCurve {
            let source = model.sourceRevision
            let hdr = model.settings.isHDREditing
            MacToneCurveControls(settings: Binding(get: { model.settings.editingCurveSettings }, set: { model.settings.editingCurveSettings = $0 }),
                legacy: Binding(get: { AdjustmentParameter.toneCurve.value(from: model.settings) },
                                set: { model.settings.set(.toneCurve, to: $0) }),
                usesExposureStops: hdr, source: "\(source).\(hdr)",
                isCurrent: { model.sourceRevision == source && model.settings.isHDREditing == hdr &&
                    model.adjustmentNavigation.tool == .toneCurve && model.adjustmentNavigation.expandedGroup != nil },
                onEditingChanged: model.setInteracting, onCancelled: model.cancelAdjustmentInteraction)
        } else if tool == .colorGrading {
            let source = model.sourceRevision
            let hdr = model.settings.isHDREditing
            MacColorGradingControls(settings: Binding(get: { model.settings.editingGradingSettings }, set: { model.settings.editingGradingSettings = $0 }),
                zone: $model.adjustmentNavigation.selectedGradingZone, source: "\(source).\(hdr)",
                isCurrent: { model.sourceRevision == source && model.settings.isHDREditing == hdr &&
                    model.adjustmentNavigation.tool == .colorGrading && model.adjustmentNavigation.expandedGroup != nil },
                onEditingChanged: model.setInteracting, onCancelled: model.cancelAdjustmentInteraction, compact: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { gradingResets }
                VStack(alignment: .leading, spacing: 4) { gradingResets }
            }.controlSize(.small)
        } else if tool == .hsl {
            VStack(spacing: 8) {
                HSLTargetControls(enabled: $model.hslTargetEnabled, axis: $model.hslTargetAxis,
                    sample: model.hslTargetInteraction.selection, waiting: model.hslTargetInteraction.isWaiting,
                    notice: model.hslTargetNotice, onCancel: model.cancelHSLTarget)
                MacHSLMixer(settings: Binding(get: { model.settings.editingHSLSettings }, set: { model.settings.editingHSLSettings = $0 }),
                    channel: $model.adjustmentNavigation.selectedHSLChannel,
                    onEditingChanged: { editing in
                        if editing { model.cancelHSLTarget() }
                        model.setInteracting(editing)
                    }, onCancelTarget: model.cancelHSLTarget)
            }
        } else if tool == .denoise {
            if model.settings.isHDREditing {
                VStack(spacing: 8) {
                    parameterRow(.denoiseMode)
                    if model.aiControlsVisible { MacAIDenoiseControls(model: model) }
                }
            } else { DenoiseControls(model: model, onReset: { model.requestAdjustmentReset(.tool(.denoise)) }).id(resetVersion) }
        } else if let parameter = tool.parameter, parameter.isPhotoEffect {
            PhotoEffectsControls(model: model, tool: parameter, onReset: { model.requestAdjustmentReset(.tool(tool)) })
                .id("\(parameter.rawValue).\(resetVersion)")
        } else if let keyPath = tool.hdrRenditionKeyPath {
            hdrRenditionRow(tool, keyPath: keyPath)
        } else if let parameter = tool.parameter {
            if parameter.isWhiteBalance { whiteBalance }
            else { parameterRow(parameter) }
        } else if tool == .recipe {
            MasterRecipeDock(model: model).frame(height: AdjustmentPanelLayout.RecipeCard.dockHeight)
        } else if tool == .film {
            FilmDock(model: model)
        }
    }

    private func hdrRenditionRow(_ tool: EditorAdjustmentTool, keyPath: WritableKeyPath<HDRRenditionSettings, Double>) -> some View {
        let isEV = tool == .hdrPeakLimit || tool == .hdrSDRExposure
        let range: ClosedRange<Double> = tool == .hdrPeakLimit ? 0...6 : (isEV ? -4...4 : -100...100)
        return ParameterRow(
            title: tool.title,
            value: Binding(
                get: { model.settings.hdr?.renditionSettings[keyPath: keyPath] ?? 0 },
                set: { newValue in
                    guard model.settings.isHDREditing, var state = model.settings.hdr, newValue.isFinite else { return }
                    state.renditionSettings[keyPath: keyPath] = newValue
                    guard state.isValid else { return }
                    model.settings.hdr = state
                }
            ),
            range: range,
            defaultValue: 0,
            unit: isEV ? "EV" : "%",
            precision: isEV ? .exposure : .standard,
            identifier: "value.\(tool.rawValue)",
            onEditingChanged: model.setInteracting,
            compact: true
        )
        .id("\(tool.rawValue).\(resetVersion)")
        .disabled(model.result == nil)
    }

    private var whiteBalance: some View {
        VStack(spacing: 4) {
            if model.settings.isHDREditing {
                Text(L10n.text("相对白平衡")).font(.caption).foregroundStyle(.secondary)
            } else {
                Picker(L10n.text("白平衡"), selection: Binding(get: { model.settings.whiteBalanceMode }, set: { mode in
                    if mode == .asShot { model.settings.resetWhiteBalance() }
                    else { model.settings.whiteBalanceMode = mode }
                })) {
                    ForEach(WhiteBalanceMode.allCases) { Text($0.title).tag($0) }
                }.controlSize(.small).id(localizationLocale.identifier)
            }
            parameterRow(.temperature)
            parameterRow(.tint)
            if !model.settings.isHDREditing && model.settings.asShotWhiteBalance == nil {
                Text(L10n.text("此照片没有可用的相机白平衡校准。")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.disabled(!model.settings.isHDREditing && model.settings.asShotWhiteBalance == nil)
    }

    @ViewBuilder private var gradingResets: some View {
        gradingReset(.gradingZone(navigation.selectedGradingZone), "重置当前分区")
        gradingReset(.allGrading, "重置颜色分级")
    }

    private func gradingReset(_ scope: EditorResetScope, _ title: String) -> some View {
        Button(L10n.text(title)) { model.requestAdjustmentReset(scope) }
            .disabled(model.busy || !model.isAdjustmentModified(scope))
    }

    private func parameterRow(_ parameter: AdjustmentParameter, title: String? = nil, showsTicks: Bool = false) -> some View {
        AdjustmentRow(parameter: parameter, value: Binding(
            get: { parameter.value(from: model.settings) },
            set: { model.settings.set(parameter, to: $0) }
        ), showsTicks: showsTicks, specOverride: parameter.spec(for: model.settings), onEditingChanged: model.setInteracting,
        onAuto: parameter == .exposure ? model.autoExposure : nil,
        autoBusy: model.autoExposing, compact: true, titleOverride: title)
        .id("\(parameter.rawValue).\(resetVersion)")
        .disabled(model.result == nil)
    }

    private func supportsHDR(_ tool: EditorAdjustmentTool) -> Bool {
        tool == .geometry || tool == .whiteBalance || tool == .hsl || tool == .colorGrading ||
            tool == .vignette || tool == .grain || tool.hdrRenditionKeyPath != nil || tool.parameter?.hdrKeyPath != nil
    }
}
