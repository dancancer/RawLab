import SwiftUI

struct AdjustmentDock: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: EditorModel
    @Binding var selected: AdjustmentParameter?
    let resetVersion: Int
    @State private var hslSelected = false
    @State private var lensSelected = false

    enum DockCategory: Equatable {
        case film
        case masterRecipe
    }

    @State private var dockCategory: DockCategory = .film

    var body: some View {
        let _ = localizationLocale
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        Button {
                            selected = nil
                            hslSelected = false
                            lensSelected = false
                            dockCategory = .film
                        } label: {
                            let active = selected == nil && !hslSelected && !lensSelected && dockCategory == .film
                            let changed = !model.selectedFilmID.isEmpty
                            VStack(spacing: 5) {
                                Image(systemName: "film").font(.system(size: 19))
                                    .frame(width: 40, height: 40)
                                    .background(active ? Color.yellow.opacity(0.12) : Color.white.opacity(0.04), in: Circle())
                                    .overlay { Circle().strokeBorder(active ? Color.yellow : Color.white.opacity(0.25), lineWidth: 1) }
                                Text(L10n.text("胶片")).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.8)
                                Circle().fill(changed ? Color.yellow : Color.clear).frame(width: 3, height: 3)
                            }.frame(width: 72, height: 70)
                                .foregroundStyle(active ? Color.yellow : Color.primary)
                        }.buttonStyle(.plain).help(L10n.text("选择胶片模拟")).accessibilityLabel(L10n.text("胶片"))
                            .accessibilityValue(model.selectedFilm?.name ?? L10n.text("中性"))
                            .accessibilityAddTraits(selected == nil && !hslSelected && !lensSelected && dockCategory == .film ? .isSelected : [])

                        Button {
                            selected = nil
                            hslSelected = false
                            dockCategory = .masterRecipe
                            lensSelected = false
                        } label: {
                            let active = selected == nil && !hslSelected && !lensSelected && dockCategory == .masterRecipe
                            let changed = model.settings.masterRecipeID != nil
                            VStack(spacing: 5) {
                                Image(systemName: "photo.stack").font(.system(size: 19))
                                    .frame(width: 40, height: 40)
                                    .background(active ? Color.yellow.opacity(0.12) : Color.white.opacity(0.04), in: Circle())
                                    .overlay { Circle().strokeBorder(active ? Color.yellow : Color.white.opacity(0.25), lineWidth: 1) }
                                Text(L10n.text("大师配方")).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.8)
                                Circle().fill(changed ? Color.yellow : Color.clear).frame(width: 3, height: 3)
                            }.frame(width: 72, height: 70)
                                .foregroundStyle(active ? Color.yellow : Color.primary)
                        }.buttonStyle(.plain).help(L10n.text("选择大师配方")).accessibilityLabel(L10n.text("大师配方"))
                            .accessibilityValue(model.settings.masterRecipe?.name ?? L10n.text("无配方"))
                            .accessibilityAddTraits(selected == nil && !hslSelected && !lensSelected && dockCategory == .masterRecipe ? .isSelected : [])
                        ForEach([AdjustmentParameter.strength] + AdjustmentParameter.photoTools) { parameter in tool(parameter) }
                        Button { hslSelected = true; lensSelected = false } label: {
                            VStack(spacing: 5) {
                                Image(systemName: "slider.horizontal.3").font(.system(size: 19))
                                    .frame(width: 40, height: 40)
                                    .background(hslSelected ? Color.yellow.opacity(0.12) : Color.white.opacity(0.04), in: Circle())
                                    .overlay { Circle().strokeBorder(hslSelected ? Color.yellow : Color.white.opacity(0.25), lineWidth: 1) }
                                Text("HSL").font(.system(size: 11))
                                Circle().fill(model.settings.hslSettings.isIdentity ? Color.clear : Color.yellow).frame(width: 3, height: 3)
                            }.frame(width: 72, height: 70)
                        }.buttonStyle(.plain).accessibilityLabel("HSL").accessibilityIdentifier("tool.hsl")
                            .accessibilityAddTraits(hslSelected ? .isSelected : [])
                            .help(L10n.text("色相、饱和度和明度")).disabled(model.result == nil)
                        lensTool
                    }.padding(.horizontal, 12).padding(.top, 4)
                        .frame(minWidth: max(780, geometry.size.width))
                }.scrollIndicators(.hidden)
            }.frame(height: 76)
            Group {
                if lensSelected {
                    LensControls(model: model).id(resetVersion).disabled(model.result == nil)
                } else if hslSelected {
                    ScrollView(.vertical) {
                        HSLMixer(settings: Binding(get: { model.settings.hslSettings }, set: { model.settings.hsl = $0.isIdentity ? nil : $0 }),
                                 onEditingChanged: model.setInteracting)
                            .frame(maxWidth: 540).disabled(model.result == nil)
                            .frame(maxWidth: .infinity)
                    }
                } else if selected == .denoiseMode {
                    DenoiseControls(model: model)
                        .id(resetVersion)
                        .frame(maxWidth: 560).padding(.horizontal, 16)
                        .disabled(model.result == nil)
                } else if let parameter = selected, parameter.isPhotoEffect {
                    PhotoEffectsControls(model: model, tool: parameter)
                        .id("\(parameter.rawValue).\(resetVersion)")
                        .disabled(model.result == nil)
                } else if let parameter = selected {
                    AdjustmentRow(parameter: parameter, value: Binding(
                        get: { model.settings[keyPath: parameter.spec.keyPath] },
                        set: { model.settings.set(parameter, to: $0) }
                    ), showsTicks: true, specOverride: parameter.spec(for: model.settings),
                    whiteBalanceMode: parameter.isWhiteBalance ? Binding(
                        get: { model.settings.whiteBalanceMode },
                        set: { mode in
                            if mode == .asShot { model.settings.resetWhiteBalance() }
                            else { model.settings.whiteBalanceMode = mode }
                        }
                    ) : nil, onEditingChanged: model.setInteracting,
                    onAuto: parameter == .exposure ? model.autoExposure : nil, autoBusy: model.autoExposing)
                    .id("\(parameter.rawValue).\(resetVersion)")
                    .frame(maxWidth: 360).padding(.horizontal, 24)
                    .disabled(parameter == .strength && model.selectedFilm == nil && model.settings.masterRecipe == nil)
                    .disabled(parameter.isWhiteBalance && model.settings.asShotWhiteBalance == nil)
                } else if dockCategory == .masterRecipe {
                    MasterRecipeDock(model: model)
                } else {
                    FilmDock(model: model)
                }
            }.frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity).padding(.top, 6).padding(.bottom, 6)
        .background(Color(nsColor: .windowBackgroundColor)).tint(.yellow)
    }

    private func tool(_ parameter: AdjustmentParameter) -> some View {
        let spec = parameter.spec(for: model.settings)
        let value = model.settings[keyPath: spec.keyPath]
        let changed = parameter.isPhotoEffect ? !model.settings.isEffectDefault(parameter) :
            (parameter == .denoiseMode ? model.settings.isDenoiseEnabled : value != spec.defaultValue)
        let active = selected == parameter && !hslSelected && !lensSelected
        let progress = parameter == .denoiseMode ? (changed ? 1.0 : 0.0) : spec.progress(for: value)
        let valueText = parameter == .denoiseMode ?
            model.settings.denoiseSummary : "\(spec.text(value)) \(spec.unit)"
        return Button { selected = parameter; hslSelected = false; lensSelected = false } label: {
            VStack(spacing: 5) {
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
                Text(spec.title).font(.system(size: 11)).lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(active ? Color.yellow : Color.primary)
                Circle().fill(changed ? Color.yellow : Color.clear).frame(width: 3, height: 3)
            }.frame(width: 72, height: 70).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(parameter.isWhiteBalance && model.settings.asShotWhiteBalance == nil)
        .disabled((parameter == .denoiseMode || parameter.isPhotoEffect) && model.result == nil)
        .accessibilityLabel(spec.title).accessibilityValue(valueText)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("tool.\(parameter.rawValue)")
        .help(parameter == .denoiseMode ? noiseReductionHelp : "\(spec.title)：\(valueText)")
        .contextMenu {
            Button(L10n.format("重置%@", String(describing: spec.title))) {
                if parameter.isPhotoEffect { model.settings.resetEffect(parameter) }
                else { model.settings.set(parameter, to: spec.defaultValue) }
            }.disabled(!changed)
        }
    }

    private var lensTool: some View {
        let changed = !model.settings.isDefault(.lens)
        return Button { selected = nil; lensSelected = true; hslSelected = false } label: {
            VStack(spacing: 5) {
                Image(systemName: "viewfinder").font(.system(size: 19))
                    .frame(width: 40, height: 40)
                    .background(lensSelected ? Color.yellow.opacity(0.12) : Color.white.opacity(0.04), in: Circle())
                    .overlay { Circle().strokeBorder(lensSelected || changed ? Color.yellow : Color.white.opacity(0.25), lineWidth: changed ? 2 : 1) }
                Text(L10n.text("镜头")).font(.system(size: 11))
                Circle().fill(changed ? Color.yellow : Color.clear).frame(width: 3, height: 3)
            }.frame(width: 56, height: 70).foregroundStyle(lensSelected ? Color.yellow : Color.primary)
        }.buttonStyle(.plain).disabled(model.result == nil)
            .help(L10n.text("镜头畸变和横向色差校正")).accessibilityLabel(L10n.text("镜头校正"))
            .accessibilityIdentifier("tool.lens").accessibilityAddTraits(lensSelected ? .isSelected : [])
    }

    private var noiseReductionHelp: String {
        model.result == nil ? L10n.text("载入照片后可用") :
            (model.settings.hasLegacyDenoise ? L10n.text("保留旧编辑记录的降噪算法") : L10n.text("调整亮度、色彩和粗色斑降噪"))
    }
}
