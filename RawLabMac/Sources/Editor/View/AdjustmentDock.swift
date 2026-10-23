import SwiftUI
import AppKit

struct AdjustmentDock: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: EditorModel
    @Binding var selected: AdjustmentParameter?
    let resetVersion: Int
    var onPreferredHeight: (CGFloat) -> Void = { _ in }
    private var navigation: EditorAdjustmentNavigation { model.adjustmentNavigation }

    var body: some View {
        let _ = localizationLocale
        VStack(spacing: 0) {
            HorizontalPicker(selectedID: navigation.expandedGroup?.rawValue ?? "", name: L10n.text("调整工具"), showsScrollIndicators: true) {
                HStack(spacing: 8) {
                    ForEach(EditorAdjustmentGroup.allCases) { group in groupButton(group) }
                }.padding(.horizontal, 12)
            }.frame(height: 42)
            if let group = navigation.expandedGroup {
                HorizontalPicker(selectedID: navigation.tool.rawValue, name: L10n.text("调整工具"), showsScrollIndicators: false) {
                    HStack(spacing: 6) { ForEach(group.tools) { toolButton($0) } }
                        .scrollTargetLayout().padding(.horizontal, 12)
                }.frame(height: 72).fixedSize(horizontal: false, vertical: true)
                if model.geometryDraft != nil {
                    MacGeometryWorkspace(model: model)
                } else {
                    GeometryReader { editor in
                        ScrollView(.vertical) {
                            editorContent.frame(maxWidth: .infinity, minHeight: editor.size.height)
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
            VStack(spacing: 0) {
                Image(systemName: tool.symbol).font(.system(size: 19))
                    .frame(width: 40, height: 40)
                    .background(active ? Color.yellow.opacity(0.12) : Color.white.opacity(0.04), in: Circle())
                    .overlay { Circle().strokeBorder(active ? Color.yellow : Color.white.opacity(0.25), lineWidth: 1) }
                Text(tool.title).font(.system(size: 11)).lineLimit(2)
                    .multilineTextAlignment(.center).frame(height: 27, alignment: .top)
                Circle().fill(changed ? Color.yellow : Color.clear).frame(width: 3, height: 3)
            }.frame(width: 80, height: 70)
                .foregroundStyle(active ? Color.yellow : Color.primary)
        }.buttonStyle(.plain).id(tool.rawValue)
            .accessibilityIdentifier("tool.\(tool.rawValue)")
            .accessibilityLabel(tool.title).accessibilityValue(changed ? L10n.text("已调整") : "")
            .accessibilityAddTraits(active ? .isSelected : [])
            .disabled((model.result == nil && !(tool == .denoise && model.file != nil && model.aiControlsVisible)) ||
                      (tool == .lens && RenderEngine.isRasterInput(model.file)))
            .contextMenu {
                Button(L10n.format("重置%@", tool.title)) { model.requestAdjustmentReset(.tool(tool)) }
                    .disabled(!changed)
            }
    }

    @ViewBuilder private var editorContent: some View {
        if navigation.tool == .hsl {
            MacHSLMixer(settings: Binding(get: { model.settings.hslSettings }, set: { model.settings.hsl = $0.isIdentity ? nil : $0 }),
                channel: $model.adjustmentNavigation.selectedHSLChannel,
                onEditingChanged: model.setInteracting)
                .padding(.horizontal, 16).disabled(model.result == nil)
        } else if navigation.tool == .denoise {
            DenoiseControls(model: model, onReset: { model.requestAdjustmentReset(.tool(.denoise)) })
                .id(resetVersion).frame(maxWidth: 720).padding(.horizontal, 16)
        } else if let parameter = navigation.tool.parameter, parameter.isPhotoEffect {
            PhotoEffectsControls(model: model, tool: parameter, onReset: { model.requestAdjustmentReset(.tool(navigation.tool)) })
                .id("\(parameter.rawValue).\(resetVersion)").disabled(model.result == nil)
        } else if let parameter = navigation.tool.parameter {
            VStack(spacing: 0) {
                if parameter.isWhiteBalance {
                    Picker(L10n.text("白平衡"), selection: Binding(get: { model.settings.whiteBalanceMode }, set: { mode in
                        if mode == .asShot { model.settings.resetWhiteBalance() }
                        else { model.settings.whiteBalanceMode = mode }
                    })) {
                        ForEach(WhiteBalanceMode.allCases) { Text($0.title).tag($0) }
                    }.fixedSize().controlSize(.small).padding(.bottom, 4).id(localizationLocale.identifier)
                    parameterRow(.temperature); parameterRow(.tint)
                } else { parameterRow(parameter) }
            }.frame(maxWidth: 720).padding(.horizontal, 16)
                .disabled(parameter == .strength && model.selectedFilm == nil && model.settings.masterRecipe == nil)
                .disabled(parameter.isWhiteBalance && model.settings.asShotWhiteBalance == nil)
        } else if navigation.tool == .recipe {
            MasterRecipeDock(model: model).frame(height: AdjustmentPanelLayout.RecipeCard.dockHeight)
        } else {
            FilmDock(model: model).frame(height: 124)
        }
    }

    private func parameterRow(_ parameter: AdjustmentParameter) -> some View {
        AdjustmentRow(parameter: parameter, value: Binding(
            get: { model.settings[keyPath: parameter.spec.keyPath] },
            set: { model.settings.set(parameter, to: $0) }
        ), showsTicks: true, specOverride: parameter.spec(for: model.settings),
        onEditingChanged: model.setInteracting,
        onAuto: parameter == .exposure ? model.autoExposure : nil, autoBusy: model.autoExposing)
        .id("\(parameter.rawValue).\(resetVersion)")
    }

}
