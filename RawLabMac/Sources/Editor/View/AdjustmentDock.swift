import SwiftUI
import AppKit

struct AdjustmentDock: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: EditorModel
    @Binding var selected: AdjustmentParameter?
    let resetVersion: Int
    var onPreferredHeight: (CGFloat) -> Void = { _ in }
    var headerAccessory = AnyView(EmptyView())
    private var navigation: EditorAdjustmentNavigation { model.adjustmentNavigation }

    var body: some View {
        let _ = localizationLocale
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                HorizontalPicker(selectedID: navigation.expandedGroup?.rawValue ?? "", name: L10n.text("调整工具"), showsScrollIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(EditorAdjustmentGroup.allCases) { group in groupButton(group) }
                    }.padding(.horizontal, 8)
                }
                headerAccessory.padding(.trailing, 12)
            }.frame(height: 36)
            if let group = navigation.expandedGroup {
                if model.geometryDraft != nil {
                    MacGeometryWorkspace(model: model)
                } else {
                    HorizontalPicker(selectedID: navigation.tool.rawValue, name: L10n.text("调整工具"), showsScrollIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(group.tools) { toolButton($0) }
                            if group == .looks {
                                Button { model.requestAdjustmentSheet(.presets) } label: {
                                    Label(L10n.text("我的预设"), systemImage: "bookmark")
                                        .font(.system(size: 12)).padding(.horizontal, 10).frame(height: 28)
                                }.buttonStyle(.plain).disabled(model.exporting || model.lookLibraryBusy)
                                    .accessibilityIdentifier("preset.library")
                            }
                        }
                            .scrollTargetLayout().padding(.horizontal, 12)
                    }.frame(height: 32).fixedSize(horizontal: false, vertical: true)
                    GeometryReader { editor in
                        ScrollView(.vertical) {
                            editorContent.frame(maxWidth: .infinity, minHeight: editor.size.height)
                                .disabled(model.settings.isHDREditing && !supportsHDR(navigation.tool))
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity)
            .environment(\.parameterInputScope, "\(model.file?.absoluteString ?? "").\(navigation.tool.rawValue)")
            .background(Color(nsColor: .windowBackgroundColor)).tint(.yellow)
    }

    private func groupButton(_ group: EditorAdjustmentGroup) -> some View {
        let active = navigation.expandedGroup == group
        let changed = model.isAdjustmentModified(.group(group))
        return Button { model.selectAdjustmentGroup(group) } label: {
            HStack(spacing: 5) {
                Text(group.title).font(.system(size: 12, weight: active ? .semibold : .regular))
                    .fixedSize()
                Circle().fill(changed ? Color.yellow : Color.clear).frame(width: 4, height: 4)
            }.padding(.horizontal, 10).frame(minHeight: 32)
                .background(active ? Color.yellow.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(active ? Color.yellow : Color.primary)
        }.buttonStyle(.plain).id(group.rawValue)
            .disabled(model.settings.isHDREditing && !group.tools.contains(where: supportsHDR))
            .accessibilityIdentifier("group.\(group.rawValue)")
            .accessibilityLabel(group.title)
            .accessibilityValue([active ? L10n.text("已展开") : L10n.text("已收起"), changed ? L10n.text("已调整") : ""].filter { !$0.isEmpty }.joined(separator: ", "))
            .accessibilityAddTraits(active ? .isSelected : [])
            .help(L10n.format(active ? "收起%@组" : "展开%@组", group.title))
    }

    private func toolButton(_ tool: EditorAdjustmentTool) -> some View {
        let active = navigation.tool == tool
        let changed = model.isAdjustmentModified(.tool(tool))
        return Button { model.selectAdjustmentTool(tool) } label: {
            HStack(spacing: 6) {
                Image(systemName: tool.symbol).font(.system(size: 13)).frame(width: 18)
                Text(tool.title).font(.system(size: 12)).fixedSize()
                Circle().fill(changed ? Color.yellow : Color.clear).frame(width: 3, height: 3)
            }.padding(.horizontal, 10).frame(height: 28)
                .background(active ? Color.yellow.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(active ? Color.yellow : Color.primary)
        }.buttonStyle(.plain).id(tool.rawValue)
            .accessibilityIdentifier("tool.\(tool.rawValue)")
            .accessibilityLabel(tool.title).accessibilityValue(changed ? L10n.text("已调整") : "")
            .accessibilityAddTraits(active ? .isSelected : [])
            .disabled((model.result == nil && !(tool == .denoise && model.file != nil && model.aiControlsVisible)) ||
                      (tool == .lens && RenderEngine.isRasterInput(model.file)) ||
                      (model.settings.isHDREditing && !supportsHDR(tool)))
            .contextMenu {
                Button(L10n.format("重置%@", tool.title)) { model.requestAdjustmentReset(.tool(tool)) }
                    .disabled(!changed)
            }
    }

    @ViewBuilder private var editorContent: some View {
        if navigation.tool == .toneCurve {
            let source = model.sourceRevision
            MacToneCurveControls(settings: Binding(get: { model.settings.curveSettings }, set: { model.settings.curveSettings = $0 }),
                legacy: $model.settings.toneCurve, source: String(describing: source),
                isCurrent: { model.sourceRevision == source && model.adjustmentNavigation.tool == .toneCurve && model.adjustmentNavigation.expandedGroup != nil },
                onEditingChanged: model.setInteracting, onCancelled: model.cancelAdjustmentInteraction)
                .padding(.horizontal, 16).disabled(model.result == nil)
        } else if navigation.tool == .colorGrading {
            let source = model.sourceRevision
            MacColorGradingControls(settings: Binding(get: { model.settings.gradingSettings }, set: { model.settings.gradingSettings = $0 }),
                zone: $model.adjustmentNavigation.selectedGradingZone, source: String(describing: source),
                isCurrent: { model.sourceRevision == source && model.adjustmentNavigation.tool == .colorGrading && model.adjustmentNavigation.expandedGroup != nil },
                onEditingChanged: model.setInteracting, onCancelled: model.cancelAdjustmentInteraction)
                .padding(.horizontal, 16).disabled(model.result == nil)
        } else if navigation.tool == .hsl {
            VStack(spacing: 10) {
                HSLTargetControls(enabled: $model.hslTargetEnabled, axis: $model.hslTargetAxis,
                    sample: model.hslTargetInteraction.selection, waiting: model.hslTargetInteraction.isWaiting,
                    notice: model.hslTargetNotice, onCancel: model.cancelHSLTarget)
                MacHSLMixer(settings: Binding(get: { model.settings.hslSettings }, set: { model.settings.hsl = $0.isIdentity ? nil : $0 }),
                    channel: $model.adjustmentNavigation.selectedHSLChannel,
                    onEditingChanged: { editing in
                        if editing { model.cancelHSLTarget() }
                        model.setInteracting(editing)
                    }, onCancelTarget: model.cancelHSLTarget)
            }.padding(.horizontal, 16).disabled(model.result == nil)
        } else if navigation.tool == .denoise {
            DenoiseControls(model: model, onReset: { model.requestAdjustmentReset(.tool(.denoise)) })
                .id(resetVersion).frame(maxWidth: 720).padding(.horizontal, 16)
        } else if let parameter = navigation.tool.parameter, parameter.isPhotoEffect {
            PhotoEffectsControls(model: model, tool: parameter, onReset: { model.requestAdjustmentReset(.tool(navigation.tool)) })
                .id("\(parameter.rawValue).\(resetVersion)").disabled(model.result == nil)
        } else if let parameter = navigation.tool.parameter {
            VStack(spacing: 0) {
                if parameter.isWhiteBalance {
                    if model.settings.isHDREditing {
                        Text(L10n.text("相对白平衡")).font(.caption).foregroundStyle(.secondary)
                    } else {
                    Picker(L10n.text("白平衡"), selection: Binding(get: { model.settings.whiteBalanceMode }, set: { mode in
                        if mode == .asShot { model.settings.resetWhiteBalance() }
                        else { model.settings.whiteBalanceMode = mode }
                    })) {
                        ForEach(WhiteBalanceMode.allCases) { Text($0.title).tag($0) }
                    }.fixedSize().controlSize(.small).padding(.bottom, 4).id(localizationLocale.identifier)
                    }
                    parameterRow(.temperature); parameterRow(.tint)
                } else { parameterRow(parameter) }
            }.frame(maxWidth: 720).padding(.horizontal, 16)
                .disabled(parameter == .strength && model.selectedFilm == nil && model.settings.masterRecipe == nil)
                .disabled(parameter.isWhiteBalance && !model.settings.isHDREditing && model.settings.asShotWhiteBalance == nil)
        } else if navigation.tool == .recipe {
            MasterRecipeDock(model: model).frame(height: AdjustmentPanelLayout.RecipeCard.dockHeight)
        } else {
            FilmDock(model: model).frame(height: 124)
        }
    }

    private func parameterRow(_ parameter: AdjustmentParameter) -> some View {
        AdjustmentRow(parameter: parameter, value: Binding(
            get: { parameter.value(from:model.settings) },
            set: { model.settings.set(parameter, to: $0) }
        ), showsTicks: true, specOverride: parameter.spec(for: model.settings),
        onEditingChanged: model.setInteracting,
        onAuto: parameter == .exposure && !model.settings.isHDREditing ? model.autoExposure : nil, autoBusy: model.autoExposing)
        .id("\(parameter.rawValue).\(resetVersion)")
    }

    private func supportsHDR(_ tool: EditorAdjustmentTool) -> Bool {
        tool == .geometry || tool == .whiteBalance || tool.parameter?.hdrKeyPath != nil
    }

}
