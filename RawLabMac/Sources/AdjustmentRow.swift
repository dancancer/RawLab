import SwiftUI

/// A shared row using display units for both precise input and slider changes.
struct ParameterRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    var unit = ""
    var precision = ParameterPrecision.standard
    let identifier: String
    var onEditingChanged: (Bool) -> Void = { _ in }
    var invalidInputPolicy: ParameterInvalidInputPolicy = .restore
    var onValidityChange: (Bool) -> Void = { _ in }
    var externalResetRevision = 0
    var sliderMapping = ParameterSliderMapping.linear
    var showsReset = true
    @State private var resetRevision = 0

    private func controlIdentifier(_ control: String) -> String {
        if identifier.hasPrefix("value.") { return control + identifier.dropFirst(5) }
        if identifier.contains(".value.") { return identifier.replacingOccurrences(of: ".value.", with: ".\(control).") }
        return identifier + "." + control
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 120, alignment: .leading)
                .help(title)
            Slider(value: Binding(get: { sliderMapping.position(for: value, in: range) }, set: {
                value = precision.snapped(sliderMapping.value(at: $0, in: range), in: range)
            }), in: 0...1, onEditingChanged: onEditingChanged)
                .frame(minWidth: 160)
                .accessibilityLabel(title)
                .accessibilityIdentifier(controlIdentifier("slider"))
                .accessibilityValue("\(precision.text(value)) \(unit)")
                .help("\(precision.text(range.lowerBound)) – \(precision.text(range.upperBound)) \(unit)")
                .overlay(alignment: .bottomLeading) {
                    GeometryReader { proxy in
                        let origin = sliderMapping.position(for: defaultValue, in: range)
                        Circle().fill(.yellow).frame(width: 3, height: 3)
                            .offset(x: 7 + (proxy.size.width - 14) * origin - 1.5, y: proxy.size.height - 1)
                    }.allowsHitTesting(false).accessibilityHidden(true)
                }
            ParameterValueField(value: $value, range: range, precision: precision, title: title,
                                unit: unit, identifier: identifier, resetRevision: resetRevision &+ externalResetRevision,
                                onEditingChanged: onEditingChanged, invalidInputPolicy: invalidInputPolicy,
                                onValidityChange: onValidityChange)
                .frame(width: 72, height: 26)
            Text(unit).font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading).accessibilityHidden(true)
            if showsReset { Button {
                // Camera-derived white balance defaults deliberately bypass the editing grid.
                value = defaultValue
                resetRevision += 1
            } label: {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 12)).frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(controlIdentifier("reset"))
            .help(L10n.format("重置%@", title)).accessibilityLabel(L10n.format("重置%@", title))
            }
        }
        .frame(minHeight: 32)
        .frame(maxWidth: 720)
    }
}

struct AdjustmentRow: View {
    @Environment(\.locale) private var localizationLocale
    let parameter: AdjustmentParameter
    @Binding var value: Double
    var showsTicks = false
    var specOverride: AdjustmentSpec?
    var whiteBalanceMode: Binding<WhiteBalanceMode>?
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onAuto: (() -> Void)?
    var autoBusy = false
    private var spec: AdjustmentSpec { specOverride ?? parameter.spec }
    private var precision: ParameterPrecision {
        switch parameter {
        case .exposure: return .exposure
        case .temperature: return .temperature
        default: return .standard
        }
    }

    var body: some View {
        let _ = localizationLocale
        VStack(spacing: 2) {
            if let whiteBalanceMode {
                Picker(L10n.text("白平衡"), selection: whiteBalanceMode) {
                    ForEach(WhiteBalanceMode.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 160).id(localizationLocale.identifier)
                    .accessibilityLabel(L10n.text("白平衡"))
            }
            ParameterRow(title: spec.title,
                         value: Binding(get: { value * spec.multiplier }, set: { value = $0 / spec.multiplier }),
                         range: (spec.range.lowerBound * spec.multiplier)...(spec.range.upperBound * spec.multiplier),
                         defaultValue: spec.defaultValue * spec.multiplier, unit: spec.unit,
                         precision: precision, identifier: "value.\(parameter.rawValue)",
                         onEditingChanged: onEditingChanged,
                         sliderMapping: spec.reciprocalScale ? .reciprocalKelvin : .linear)
            if let onAuto {
                Button(action: onAuto) { Label(L10n.text("自动"), systemImage: "wand.and.stars") }
                    .controlSize(.small).disabled(autoBusy)
                    .accessibilityIdentifier("exposure.auto").help(L10n.text("自动调整曝光"))
            }
        }
        .frame(maxWidth: 720)
    }
}
