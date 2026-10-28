import SwiftUI

struct IOSDenoiseControls: View {
    @Environment(\.locale) private var localizationLocale
    @Binding var settings: RawDenoiseSettings
    let onEditingChanged: (Bool) -> Void
    let onReset: () -> Void
    var resetEnabled: Bool = true
    @State private var advancedExpanded = false

    private var parameters: [(String, WritableKeyPath<RawDenoiseSettings, Double>, Double)] { [
        (L10n.text("亮度降噪"), \.luma, 0),
        (L10n.text("色彩降噪"), \.chroma, 46),
        (L10n.text("粗色斑抑制"), \.coarse, 50)
    ] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Toggle(L10n.text("降噪"), isOn: $settings.enabled)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("denoise.enabled")
                Button(action: onReset) {
                    Image(systemName: "arrow.counterclockwise").frame(width: 44, height: 44)
                }
                .accessibilityLabel(L10n.text("重置降噪"))
                .accessibilityIdentifier("denoise.reset")
                .disabled(!resetEnabled)
            }
            Picker(L10n.text("预设"), selection: Binding(get: { settings.preset }, set: { settings.apply($0) })) {
                Text(RawDenoisePreset.detail.title).tag(RawDenoisePreset.detail)
                Text(RawDenoisePreset.clean.title).tag(RawDenoisePreset.clean)
                if settings.preset == .custom { Text(L10n.text("自定义")).tag(RawDenoisePreset.custom) }
            }
            .pickerStyle(.menu)
            .id(localizationLocale.identifier)
            .frame(minHeight: 44)
            .accessibilityIdentifier("denoise.preset")
            DisclosureGroup(isExpanded: $advancedExpanded) {
                VStack(spacing: 12) {
                    ForEach(parameters.indices, id: \.self) { index in
                        let parameter = parameters[index]
                        AdjustmentControl(title: parameter.0, value: value(for: parameter.1),
                                          range: 0...100, step: 1, defaultValue: parameter.2,
                                          formatter: { String(format: "%.0f", locale: L10n.locale, $0) },
                                          identifier: "denoise.\(index)", onEditingChanged: onEditingChanged)
                            .disabled(!settings.enabled)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text(L10n.text("高级参数"))
                    .font(.subheadline)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("denoise.advanced")
            }
        }
    }

    private func value(for key: WritableKeyPath<RawDenoiseSettings, Double>) -> Binding<Double> {
        Binding(get: { settings[keyPath: key] }, set: { value in
            guard value.isFinite else { return }
            settings[keyPath: key] = min(100, max(0, value.rounded()))
        })
    }
}

struct IOSPhotoEffectsControls: View {
    let effect: AdjustmentKind
    @Binding var settings: PhotoEffectsSettings
    let onEditingChanged: (Bool) -> Void
    let onReset: () -> Void
    var resetEnabled: Bool = true
    @State private var advancedExpanded = false

    private var parameters: [PhotoEffectParameter] {
        PhotoEffectParameter.allCases.filter { $0.isVignette == (effect == .vignette) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(effect.title)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if effect != .vignette || advancedExpanded {
                    Button(action: onReset) {
                        Image(systemName: "arrow.counterclockwise").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(L10n.format("重置%@", effect.title))
                    .accessibilityIdentifier("effects.\(effect.rawValue).reset")
                    .disabled(!resetEnabled)
                }
            }
            parameterControl(effect == .vignette ? .vignetteAmount : .grainAmount)
            DisclosureGroup(isExpanded: $advancedExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(parameters.dropFirst()) { parameter in
                        parameterControl(parameter)
                    }
                    if effect == .vignette && settings.vignetteAmount >= 0 {
                        Text(L10n.text("仅在暗角强度为负值时可用。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("effects.vignette.highlightsUnavailable")
                    }
                }
                .padding(.top, 8)
            } label: {
                Text(L10n.text("高级参数"))
                    .font(.subheadline)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("effects.\(effect.rawValue).advanced")
            }
        }
        .id(effect.rawValue)
    }

    private func parameterControl(_ parameter: PhotoEffectParameter) -> some View {
        AdjustmentControl(title: parameter.title, value: binding(for: parameter),
                          range: parameter.range, step: 1, defaultValue: parameter.defaultValue,
                          formatter: { String(format: $0 == 0 || parameter.range.lowerBound >= 0 ? "%.0f" : "%+.0f", locale: L10n.locale, $0) },
                          identifier: "effects.\(effect.rawValue).\(parameter.rawValue)",
                          onEditingChanged: onEditingChanged)
            .disabled(parameter == .vignetteHighlights && settings.vignetteAmount >= 0)
    }

    private func binding(for parameter: PhotoEffectParameter) -> Binding<Double> {
        Binding(get: { settings[keyPath: parameter.keyPath] }, set: { value in
            guard value.isFinite else { return }
            settings[keyPath: parameter.keyPath] = min(parameter.range.upperBound,
                                                       max(parameter.range.lowerBound, value.rounded()))
        })
    }


}

struct IOSHSLMixer: View {
    @Binding var settings: HSLSettings
    let onEditingChanged: (Bool) -> Void
    @Binding var channel: Int
    private let colors: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(colors.indices, id: \.self) { index in
                        Button { channel = index } label: {
                            VStack(spacing: 0) {
                                Circle().fill(colors[index]).frame(width: 22, height: 22)
                                    .padding(4)
                                    .overlay { Circle().strokeBorder(channel == index ? Color.primary : .clear, lineWidth: 2) }
                                    .frame(width: 44, height: 40)
                                Circle().fill(HSLAxis.allCases.contains { settings.value($0, channel: index) != 0 } ? Color.yellow : .clear)
                                    .frame(width: 4, height: 4)
                            }
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text(HSLSettings.channelNames[index]))
                        .accessibilityAddTraits(channel == index ? .isSelected : [])
                        .accessibilityHint(L10n.text(HSLAxis.allCases.contains { settings.value($0, channel: index) != 0 } ? "已调整" : "未调整"))
                        .accessibilityIdentifier("hsl.channel.\(index)")
                    }
                }
            }
            ForEach(HSLAxis.allCases) { axis in
                let targetChannel = channel
                AdjustmentControl(title: L10n.format("%@ · %@", L10n.text(HSLSettings.channelNames[targetChannel]), axis.title), value: Binding(
                    get: { settings.value(axis, channel: targetChannel) },
                    set: { settings.set(axis, channel: targetChannel, value: $0) }
                ), range: -100...100, step: 1, defaultValue: 0,
                                  formatter: { String(format: $0 == 0 ? "%.0f" : "%+.0f", locale: L10n.locale, $0) },
                                  identifier: "hsl.\(axis.rawValue)", directionColors: trackColors(axis),
                                  directionHint: trackHint(axis), onEditingChanged: onEditingChanged)
                    .id("\(channel).\(axis.rawValue)")
            }

        }
        .padding(.horizontal, 16)
    }
    private func trackColors(_ axis: HSLAxis) -> [Color] {
        switch axis {
        case .hue: return [colors[(channel + 7) % 8], colors[channel], colors[(channel + 1) % 8]]
        case .saturation: return [.gray, colors[channel]]
        case .lightness: return [.black, colors[channel], .white]
        }
    }

    private func trackHint(_ axis: HSLAxis) -> String {
        switch axis {
        case .hue: return L10n.text("色相：向相邻颜色偏移。")
        case .saturation: return L10n.text("饱和度：从灰色到彩色。")
        case .lightness: return L10n.text("明度：从暗到亮。")
        }
    }

}
