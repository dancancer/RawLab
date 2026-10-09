import SwiftUI

struct AdjustmentDock: View {
    @ObservedObject var model: EditorModel
    @Binding var selected: AdjustmentParameter?
    let resetVersion: Int

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        Button { selected = nil } label: {
                            VStack(spacing: 5) {
                                Image(systemName: "film").font(.system(size: 19))
                                    .frame(width: 40, height: 40)
                                    .background(selected == nil ? Color.yellow.opacity(0.12) : Color.white.opacity(0.04), in: Circle())
                                    .overlay { Circle().strokeBorder(selected == nil ? Color.yellow : Color.white.opacity(0.25), lineWidth: 1) }
                                Text("胶片").font(.system(size: 11))
                                Color.clear.frame(width: 3, height: 3)
                            }.frame(width: 56, height: 70)
                                .foregroundStyle(selected == nil ? Color.yellow : Color.primary)
                        }.buttonStyle(.plain).help("选择胶片模拟").accessibilityLabel("胶片")
                            .accessibilityValue(model.selectedFilm?.name ?? "中性")
                            .accessibilityAddTraits(selected == nil ? .isSelected : [])
                        ForEach([AdjustmentParameter.strength] + AdjustmentParameter.photoTools) { parameter in tool(parameter) }
                    }.padding(.horizontal, 12).padding(.top, 4)
                        .frame(minWidth: max(710, geometry.size.width))
                }.scrollIndicators(.hidden)
            }.frame(height: 76)
            Group {
                if selected == .denoiseMode {
                    DenoiseControls(model: model)
                        .id(resetVersion)
                        .frame(maxWidth: 560).padding(.horizontal, 16)
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
                    ) : nil, onEditingChanged: model.setInteracting)
                    .id("\(parameter.rawValue).\(resetVersion)")
                    .frame(maxWidth: 360).padding(.horizontal, 24)
                    .disabled(parameter == .strength && model.selectedFilm == nil)
                    .disabled(parameter.isWhiteBalance && model.settings.asShotWhiteBalance == nil)
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
        let changed = parameter == .denoiseMode ? model.settings.isDenoiseEnabled : value != spec.defaultValue
        let active = selected == parameter
        let progress = parameter == .denoiseMode ? (changed ? 1.0 : 0.0) : spec.progress(for: value)
        let valueText = parameter == .denoiseMode ?
            model.settings.denoiseSummary : "\(spec.text(value)) \(spec.unit)"
        return Button { selected = parameter } label: {
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
                    .foregroundStyle(active ? Color.yellow : Color.primary)
                Circle().fill(changed ? Color.yellow : Color.clear).frame(width: 3, height: 3)
            }.frame(width: 56, height: 70).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(parameter.isWhiteBalance && model.settings.asShotWhiteBalance == nil)
        .disabled(parameter == .denoiseMode && model.result == nil)
        .accessibilityLabel(spec.title).accessibilityValue(valueText)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("tool.\(parameter.rawValue)")
        .help(parameter == .denoiseMode ? noiseReductionHelp : "\(spec.title)：\(valueText)")
        .contextMenu {
            Button("重置\(spec.title)") { model.settings.set(parameter, to: spec.defaultValue) }.disabled(!changed)
        }
    }

    private var noiseReductionHelp: String {
        model.result == nil ? "载入照片后可用" :
            (model.settings.hasLegacyDenoise ? "保留旧编辑记录的降噪算法" : "调整亮度、色彩和粗色斑降噪")
    }
}
