import RawLabKit
import SwiftUI

struct IOSDenoiseControls: View {
    @Environment(\.locale) private var localizationLocale
    @Binding var settings: RawDenoiseSettings
    let onEditingChanged: (Bool) -> Void

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
                Spacer(minLength: 4)
                Picker(L10n.text("预设"), selection: Binding(get: { settings.preset }, set: { settings.apply($0) })) {
                    Text(RawDenoisePreset.detail.title).tag(RawDenoisePreset.detail)
                    Text(RawDenoisePreset.clean.title).tag(RawDenoisePreset.clean)
                    if settings.preset == .custom { Text(L10n.text("自定义")).tag(RawDenoisePreset.custom) }
                }
                .pickerStyle(.menu)
                .id(localizationLocale.identifier)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 44)
                .accessibilityIdentifier("denoise.preset")
            }
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
    @Environment(\.locale) private var localizationLocale
    let effect: AdjustmentKind
    let value: (PhotoEffectParameter) -> Binding<Double>
    let onEditingChanged: (Bool) -> Void
    var isHDREditing: Bool = false
    var grainToneCurve: Binding<GrainToneCurve> = .constant(.legacy)
    var grainFormatPreset: Binding<GrainFormatPreset> = .constant(.custom)
    var filmOptics: Binding<FilmOpticsSettings> = .constant(.init())
    @State private var advancedExpanded = false
    @State private var halationExpanded = false
    @State private var bloomExpanded = false

    private var parameters: [PhotoEffectParameter] {
        PhotoEffectParameter.allCases.filter { $0.isVignette == (effect == .vignette) }
    }

    var body: some View {
        let _ = localizationLocale
        VStack(alignment: .leading, spacing: 12) {
            if effect == .grain && !isHDREditing {
                IOSFilmGrainOptionsView(
                    toneCurve: grainToneCurve,
                    formatPreset: grainFormatPreset,
                    localeIdentifier: localizationLocale.identifier
                )
            }
            parameterControl(effect == .vignette ? .vignetteAmount : .grainAmount)
            DisclosureGroup(isExpanded: $advancedExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(parameters.dropFirst()) { parameter in
                        parameterControl(parameter)
                    }
                    if effect == .vignette && value(.vignetteAmount).wrappedValue >= 0 {
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
            if effect == .grain && !isHDREditing {
                IOSFilmOpticsGroupSection(
                    title: L10n.text("光晕"),
                    isHalation: true,
                    isExpanded: $halationExpanded,
                    filmOptics: filmOptics,
                    onEditingChanged: onEditingChanged
                )
                IOSFilmOpticsGroupSection(
                    title: L10n.text("柔光"),
                    isHalation: false,
                    isExpanded: $bloomExpanded,
                    filmOptics: filmOptics,
                    onEditingChanged: onEditingChanged
                )
            }
        }
        .id(effect.rawValue)
    }

    private func parameterControl(_ parameter: PhotoEffectParameter) -> some View {
        AdjustmentControl(title: parameter.title, value: value(parameter),
                          range: parameter.range, step: 1, defaultValue: parameter.defaultValue,
                          formatter: { String(format: $0 == 0 || parameter.range.lowerBound >= 0 ? "%.0f" : "%+.0f", locale: L10n.locale, $0) },
                          identifier: "effects.\(effect.rawValue).\(parameter.rawValue)",
                          onEditingChanged: onEditingChanged)
            .disabled(parameter == .vignetteHighlights && value(.vignetteAmount).wrappedValue >= 0)
    }
}

private struct IOSFilmGrainOptionsView: View {
    @Binding var toneCurve: GrainToneCurve
    @Binding var formatPreset: GrainFormatPreset
    let localeIdentifier: String

    var body: some View {
        HStack(spacing: 12) {
            Picker(L10n.text("颗粒曲线"), selection: $toneCurve) {
                ForEach(GrainToneCurve.allCases) { curve in
                    Text(curve.title).tag(curve)
                }
            }
            .pickerStyle(.menu)
            .id("curve.\(localeIdentifier)")
            .frame(minHeight: 44)
            .accessibilityIdentifier("effects.grain.toneCurve")

            Spacer(minLength: 4)

            Picker(L10n.text("颗粒画幅"), selection: $formatPreset) {
                ForEach(GrainFormatPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .id("preset.\(localeIdentifier)")
            .frame(minHeight: 44)
            .accessibilityIdentifier("effects.grain.formatPreset")
        }
    }
}

private struct IOSFilmOpticsGroupSection: View {
    let title: String
    let isHalation: Bool
    @Binding var isExpanded: Bool
    @Binding var filmOptics: FilmOpticsSettings
    let onEditingChanged: (Bool) -> Void

    private var parameters: [FilmOpticsParameter] {
        FilmOpticsParameter.allCases.filter { $0.isHalation == isHalation }
    }

    private var amountValue: Double {
        isHalation ? filmOptics.halationAmount : filmOptics.bloomAmount
    }

    private var isDefault: Bool {
        isHalation ? filmOptics.isHalationDefault : filmOptics.isBloomDefault
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        if isHalation { filmOptics.resetHalation() }
                        else { filmOptics.resetBloom() }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(isDefault)
                    .accessibilityLabel(L10n.format("重置%@", title))
                    .accessibilityIdentifier("effects.\(isHalation ? "halation" : "bloom").reset")
                }
                ForEach(parameters) { parameter in
                    AdjustmentControl(
                        title: parameter.title,
                        value: Binding(
                            get: { filmOptics[keyPath: parameter.keyPath] },
                            set: { newValue in
                                guard newValue.isFinite else { return }
                                let r = parameter.range
                                let quantized = min(r.upperBound, max(r.lowerBound, (newValue * 10).rounded() / 10))
                                filmOptics[keyPath: parameter.keyPath] = quantized
                            }
                        ),
                        range: parameter.range,
                        step: 1,
                        defaultValue: parameter.defaultValue,
                        formatter: { String(format: $0 == 0 || parameter.range.lowerBound >= 0 ? "%.0f" : "%+.0f", locale: L10n.locale, $0) },
                        identifier: "effects.\(isHalation ? "halation" : "bloom").\(parameter.rawValue)",
                        onEditingChanged: onEditingChanged
                    )
                    .disabled(parameter != .halationAmount && parameter != .bloomAmount && amountValue == 0)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.subheadline)
                if !isDefault {
                    Circle().fill(Color.yellow).frame(width: 5, height: 5).accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("effects.\(isHalation ? "halation" : "bloom").disclosure")
        }
    }
}

struct IOSHSLMixer: View {
    @Binding var settings: HSLSettings
    let onEditingChanged: (Bool) -> Void
    @Binding var channel: Int
    private let colors = [0xe65c5a, 0xe8a04f, 0xdfce51, 0x7bba64, 0x68c8c7, 0x5c89df, 0xa075d2, 0xcb6eaf].map {
        Color(red: Double(($0 >> 16) & 255) / 255, green: Double(($0 >> 8) & 255) / 255, blue: Double($0 & 255) / 255)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(colors.indices, id: \.self) { index in
                        Button { channel = index } label: {
                            VStack(spacing: 0) {
                                Circle().fill(colors[index]).frame(width: 19, height: 19)
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
                AdjustmentControl(title: axis.title, value: Binding(
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
