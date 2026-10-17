import SwiftUI
import AppKit

struct AdjustmentDock: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: EditorModel
    @Binding var selected: AdjustmentParameter?
    let resetVersion: Int
    var onPreferredHeight: (CGFloat) -> Void = { _ in }
    @State private var hslSelected = false
    private var lensSelected: Bool { model.geometryDraft != nil && model.geometryDraftTab == .lens }
    private var geometrySelected: Bool { model.geometryDraft != nil && model.geometryDraftTab != .lens }

    enum DockCategory: Equatable {
        case film
        case masterRecipe
    }

    @State private var dockCategory: DockCategory = .film

    var body: some View {
        let _ = localizationLocale
        VStack(spacing: 0) {
          if model.geometryDraft != nil {
            MacGeometryWorkspace(model: model)
          } else {
            HorizontalPicker(selectedID: activeToolID, name: L10n.text("调整工具"), showsScrollIndicators: false) {
                    HStack(spacing: 6) {
                        Button {
                            finishCurrentInput()
                            selected = nil
                            hslSelected = false
                            dockCategory = .film
                            onPreferredHeight(252)
                        } label: {
                            let active = selected == nil && !hslSelected && !lensSelected && !geometrySelected && dockCategory == .film
                            let changed = !model.selectedFilmID.isEmpty
                            VStack(spacing: 0) {
                                Image(systemName: "film").font(.system(size: 19))
                                    .frame(width: 40, height: 40)
                                    .background(active ? Color.yellow.opacity(0.12) : Color.white.opacity(0.04), in: Circle())
                                    .overlay { Circle().strokeBorder(active ? Color.yellow : Color.white.opacity(0.25), lineWidth: 1) }
                                toolCaption(L10n.text("胶片"))
                                Circle().fill(changed ? Color.yellow : Color.clear).frame(width: 3, height: 3)
                            }.frame(width: 72, height: 70)
                                .foregroundStyle(active ? Color.yellow : Color.primary)
                        }.buttonStyle(.plain).id("film").help(L10n.text("选择胶片模拟")).accessibilityLabel(L10n.text("胶片"))
                            .accessibilityValue(model.selectedFilm?.name ?? L10n.text("中性"))
                            .accessibilityAddTraits(selected == nil && !hslSelected && !lensSelected && !geometrySelected && dockCategory == .film ? .isSelected : [])

                        Button {
                            finishCurrentInput()
                            selected = nil
                            hslSelected = false
                            dockCategory = .masterRecipe
                            onPreferredHeight(252)
                        } label: {
                            let active = selected == nil && !hslSelected && !lensSelected && !geometrySelected && dockCategory == .masterRecipe
                            let changed = model.settings.masterRecipeID != nil
                            VStack(spacing: 0) {
                                Image(systemName: "photo.stack").font(.system(size: 19))
                                    .frame(width: 40, height: 40)
                                    .background(active ? Color.yellow.opacity(0.12) : Color.white.opacity(0.04), in: Circle())
                                    .overlay { Circle().strokeBorder(active ? Color.yellow : Color.white.opacity(0.25), lineWidth: 1) }
                                toolCaption(L10n.text("大师配方"))
                                Circle().fill(changed ? Color.yellow : Color.clear).frame(width: 3, height: 3)
                            }.frame(width: 72, height: 70)
                                .foregroundStyle(active ? Color.yellow : Color.primary)
                        }.buttonStyle(.plain).id("masterRecipe").help(L10n.text("选择大师配方")).accessibilityLabel(L10n.text("大师配方"))
                            .accessibilityValue(model.settings.masterRecipe?.title ?? L10n.text("无配方"))
                            .accessibilityAddTraits(selected == nil && !hslSelected && !lensSelected && !geometrySelected && dockCategory == .masterRecipe ? .isSelected : [])
                        ForEach([AdjustmentParameter.strength, .exposure, .highlights, .shadows, .contrast, .toneCurve, .saturation]) { tool($0) }
                        Button { finishCurrentInput(); hslSelected = true; onPreferredHeight(288) } label: {
                            VStack(spacing: 0) {
                                Image(systemName: "slider.horizontal.3").font(.system(size: 19))
                                    .frame(width: 40, height: 40)
                                    .background(hslSelected ? Color.yellow.opacity(0.12) : Color.white.opacity(0.04), in: Circle())
                                    .overlay { Circle().strokeBorder(hslSelected ? Color.yellow : Color.white.opacity(0.25), lineWidth: 1) }
                                toolCaption("HSL")
                                Circle().fill(model.settings.hslSettings.isIdentity ? Color.clear : Color.yellow).frame(width: 3, height: 3)
                            }.frame(width: 72, height: 70)
                        }.buttonStyle(.plain).id("hsl").accessibilityLabel("HSL").accessibilityIdentifier("tool.hsl")
                            .accessibilityAddTraits(hslSelected ? .isSelected : [])
                            .help(L10n.text("色相、饱和度和明度")).disabled(model.result == nil)
                        ForEach([AdjustmentParameter.temperature, .denoiseMode, .sharpening, .vignetteAmount, .grainAmount]) { tool($0) }
                        geometryTool
                        lensTool
                    }.scrollTargetLayout().padding(.horizontal, 12)
            }.frame(height: 72).fixedSize(horizontal: false, vertical: true)
            GeometryReader { editor in
              ScrollView(.vertical) {
                editorContent
                    .frame(maxWidth: .infinity, minHeight: editor.size.height)
              }
            }
          }
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor)).tint(.yellow)
    }

    private func finishCurrentInput() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private var activeToolID: String {
        if geometrySelected { return "geometry" }
        if lensSelected { return "lens" }
        if hslSelected { return "hsl" }
        if let selected { return selected.isWhiteBalance ? AdjustmentParameter.temperature.rawValue : selected.rawValue }
        return dockCategory == .film ? "film" : "masterRecipe"
    }

    private func toolCaption(_ title: String) -> some View {
        let caption = AdjustmentPanelLayout.ToolCaption.self
        return Text(title).font(.system(size: caption.size))
            .lineLimit(caption.lineLimit(for: title)).minimumScaleFactor(caption.minimumScale(for: title))
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .frame(height: 27, alignment: .top)
    }

    @ViewBuilder private var editorContent: some View {
            Group {
                if hslSelected {
                    MacHSLMixer(settings: Binding(get: { model.settings.hslSettings }, set: { model.settings.hsl = $0.isIdentity ? nil : $0 }),
                                onEditingChanged: model.setInteracting)
                        .disabled(model.result == nil)
                        .padding(.horizontal, 16)
                } else if selected == .denoiseMode {
                    DenoiseControls(model: model, onExpansionChanged: { onPreferredHeight($0 ? 288 : 252) })
                        .id(resetVersion)
                        .frame(maxWidth: 720).padding(.horizontal, 16)
                        .disabled(model.result == nil)
                } else if let parameter = selected, parameter.isPhotoEffect {
                    PhotoEffectsControls(model: model, tool: parameter, onPreferredHeight: onPreferredHeight)
                        .id("\(parameter.rawValue).\(resetVersion)")
                        .disabled(model.result == nil)
                } else if let parameter = selected {
                    VStack(spacing: 0) {
                        if parameter.isWhiteBalance {
                            Picker(L10n.text("白平衡"), selection: Binding(
                                get: { model.settings.whiteBalanceMode },
                                set: { mode in
                                    if mode == .asShot { model.settings.resetWhiteBalance() }
                                    else { model.settings.whiteBalanceMode = mode }
                                }
                            )) {
                                ForEach(WhiteBalanceMode.allCases) { Text($0.title).tag($0) }
                            }.frame(width: 240).controlSize(.small).padding(.bottom, 4)
                                .id(localizationLocale.identifier)
                            parameterRow(.temperature)
                            parameterRow(.tint)
                        } else {
                            parameterRow(parameter)
                        }
                    }.frame(maxWidth: 720).padding(.horizontal, 16)
                    .disabled(parameter == .strength && model.selectedFilm == nil && model.settings.masterRecipe == nil)
                    .disabled(parameter.isWhiteBalance && model.settings.asShotWhiteBalance == nil)
                } else if dockCategory == .masterRecipe {
                    MasterRecipeDock(model: model).frame(height: AdjustmentPanelLayout.RecipeCard.dockHeight)
                } else {
                    FilmDock(model: model).frame(height: 124)
                }
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

    private func tool(_ parameter: AdjustmentParameter) -> some View {
        let spec = parameter.spec(for: model.settings)
        let title = parameter.isWhiteBalance ? L10n.text("白平衡") : spec.title
        let value = model.settings[keyPath: spec.keyPath]
        let changed = parameter.isWhiteBalance ? !model.settings.isWhiteBalanceDefault :
            parameter.isPhotoEffect ? !model.settings.isEffectDefault(parameter) :
            (parameter == .denoiseMode ? model.settings.isDenoiseEnabled : value != spec.defaultValue)
        let active = (selected == parameter || (parameter.isWhiteBalance && selected?.isWhiteBalance == true)) &&
            !hslSelected && !lensSelected && !geometrySelected
        let progress = parameter.isWhiteBalance ? [AdjustmentParameter.temperature, .tint].map {
            $0.spec(for: model.settings).progress(for: model.settings[keyPath: $0.spec.keyPath])
        }.max(by: { abs($0) < abs($1) }) ?? 0 :
            parameter == .denoiseMode ? (changed ? 1.0 : 0.0) : spec.progress(for: value)
        let valueText = parameter.isWhiteBalance ?
            "\(L10n.text("色温")) \(AdjustmentParameter.temperature.spec.text(model.settings.temperature)) K, \(L10n.text("色调")) \(AdjustmentParameter.tint.spec.text(model.settings.tint))" :
            parameter == .denoiseMode ?
            model.settings.denoiseSummary : "\(spec.text(value)) \(spec.unit)"
        return Button {
            finishCurrentInput()
            // 换工具时先回到默认高度；降噪和效果面板出现后再按自身内容要高度，重复点同一工具不改高度
            if selected != parameter || hslSelected { onPreferredHeight(252) }
            selected = parameter; hslSelected = false
        } label: {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(active ? Color.yellow.opacity(0.12) : Color.white.opacity(0.04))
                    Circle().strokeBorder(active ? Color.yellow.opacity(0.5) : Color.white.opacity(0.25), lineWidth: 1)
                    if changed {
                        Circle().trim(from: 0, to: abs(progress)).rotation(.degrees(-90))
                            .scale(x: progress < 0 ? -1 : 1, y: 1)
                            .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                    Image(systemName: parameter.symbol).font(.system(size: 19, weight: .regular))
                        .foregroundStyle(active ? Color.yellow : Color.primary)
                }.frame(width: 40, height: 40)
                toolCaption(title)
                    .foregroundStyle(active ? Color.yellow : Color.primary)
                Circle().fill(changed ? Color.yellow : Color.clear).frame(width: 3, height: 3)
            }.frame(width: 72, height: 70).contentShape(Rectangle())
        }
        .buttonStyle(.plain).id(parameter.rawValue)
        .disabled(parameter.isWhiteBalance && model.settings.asShotWhiteBalance == nil)
        .disabled((parameter == .denoiseMode || parameter.isPhotoEffect) && model.result == nil)
        .accessibilityLabel(title).accessibilityValue(valueText)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("tool.\(parameter.rawValue)")
        .help(parameter == .denoiseMode ? noiseReductionHelp : L10n.format("%@：%@", title, valueText))
        .contextMenu {
            Button(L10n.format("重置%@", String(describing: title))) {
                if parameter.isWhiteBalance { model.settings.resetWhiteBalance() }
                else if parameter.isPhotoEffect { model.settings.resetEffect(parameter) }
                else { model.settings.set(parameter, to: spec.defaultValue) }
            }.disabled(!changed)
        }
    }

    private var lensTool: some View {
        let changed = !model.settings.isDefault(.lens)
        return Button { finishCurrentInput(); model.beginGeometryDraft(tab: .lens) } label: {
            VStack(spacing: 0) {
                Image(systemName: "viewfinder").font(.system(size: 19))
                    .frame(width: 40, height: 40)
                    .background(lensSelected ? Color.yellow.opacity(0.12) : Color.white.opacity(0.04), in: Circle())
                    .overlay { Circle().strokeBorder(lensSelected || changed ? Color.yellow : Color.white.opacity(0.25), lineWidth: changed ? 2 : 1) }
                toolCaption(L10n.text("镜头"))
                Circle().fill(changed ? Color.yellow : Color.clear).frame(width: 3, height: 3)
            }.frame(width: 72, height: 70).foregroundStyle(lensSelected ? Color.yellow : Color.primary)
        }.buttonStyle(.plain).id("lens").disabled(model.result == nil || RenderEngine.isRasterInput(model.file))
            .help(L10n.text("镜头畸变和横向色差校正")).accessibilityLabel(L10n.text("镜头校正"))
            .accessibilityIdentifier("tool.lens").accessibilityAddTraits(lensSelected ? .isSelected : [])
    }

    private var geometryTool: some View {
        let changed = !model.settings.isDefault(.geometry)
        return Button { finishCurrentInput(); model.beginGeometryDraft(tab: .crop) } label: {
            VStack(spacing: 0) {
                Image(systemName: "crop.rotate").font(.system(size: 19))
                    .frame(width: 40, height: 40)
                    .background(geometrySelected ? Color.yellow.opacity(0.12) : Color.white.opacity(0.04), in: Circle())
                    .overlay { Circle().strokeBorder(geometrySelected || changed ? Color.yellow : Color.white.opacity(0.25), lineWidth: changed ? 2 : 1) }
                toolCaption(L10n.text("几何"))
                Circle().fill(changed ? Color.yellow : Color.clear).frame(width: 3, height: 3)
            }.frame(width: 72, height: 70).foregroundStyle(geometrySelected ? Color.yellow : Color.primary)
        }.buttonStyle(.plain).id("geometry").disabled(model.result == nil)
            .help(L10n.text("裁切、旋转、翻转和拉直")).accessibilityLabel(L10n.text("几何编辑"))
            .accessibilityIdentifier("tool.geometry").accessibilityAddTraits(geometrySelected ? .isSelected : [])
    }

    private var noiseReductionHelp: String {
        model.result == nil ? L10n.text("载入照片后可用") :
            (model.settings.hasLegacyDenoise ? L10n.text("保留旧编辑记录的降噪算法") : L10n.text("调整亮度、色彩和粗色斑降噪"))
    }
}
