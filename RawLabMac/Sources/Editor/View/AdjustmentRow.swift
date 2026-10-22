import AppKit
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
    @State private var resetRevision = 0

    private func controlIdentifier(_ control: String) -> String {
        if identifier.hasPrefix("value.") { return control + identifier.dropFirst(5) }
        if identifier.contains(".value.") { return identifier.replacingOccurrences(of: ".value.", with: ".\(control).") }
        return identifier + "." + control
    }

    // ScaledMetric does not scale AppKit controls on macOS. Keep the native
    // preferred font and explicitly apply the SwiftUI accessibility size.
    static func textSize(for size: DynamicTypeSize, base: CGFloat = 13) -> CGFloat {
        let factor: CGFloat
        switch size {
        case .xSmall: factor = 0.9
        case .small: factor = 0.95
        case .medium, .large: factor = 1
        case .xLarge: factor = 1.1
        case .xxLarge: factor = 1.2
        case .xxxLarge: factor = 1.35
        case .accessibility1: factor = 1.5
        case .accessibility2: factor = 1.7
        case .accessibility3: factor = 1.9
        case .accessibility4: factor = 2.1
        case .accessibility5: factor = 2.3
        @unknown default: factor = 1
        }
        return max(base, NSFont.preferredFont(forTextStyle: .body).pointSize * base / 13) * factor
    }
    private var textSize: CGFloat { Self.textSize(for: dynamicTypeSize) }
    @State private var validationMessage: String?
    var trackColors: [Color] = []
    var directionHelp = ""
    var accessibilityTitle: String? = nil
    var inputScope = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var valueWidth: CGFloat {
        max(72, (precision.text(value, signed: range.lowerBound < 0) as NSString)
            .size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: textSize, weight: .regular)]).width + 24)
    }
    private var pointerHelp: String { NSWorkspace.shared.isVoiceOverEnabled ? "" : L10n.text("双击名称或轨道恢复默认值。") }
    private var metadata: String {
        L10n.format("默认值：%@；范围：%@ 至 %@；步进：%@。",
                    precision.text(defaultValue) + unit, precision.text(range.lowerBound) + unit,
                    precision.text(range.upperBound) + unit, precision.text(precision.fineStep) + unit)
    }
    private func reset() {
        ParameterValueField.cancelPendingInputs()
        // Camera-derived defaults deliberately bypass the editing grid.
        if value != defaultValue { value = defaultValue }
        resetRevision += 1
    }
    private var name: some View {
        Text(title).font(.system(size: textSize)).fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 100, alignment: .leading)
            .modifier(ParameterResetGesture(action: reset))
            .help(metadata + " " + pointerHelp)
    }
    private var number: some View {
        HStack(spacing: 6) {
            ParameterValueField(value: $value, range: range, precision: precision, title: accessibilityTitle ?? title,
                                unit: unit, identifier: identifier, defaultValue: defaultValue, fontSize: textSize, inputScope: identifier + inputScope,
                                onValidationMessage: { validationMessage = $0 },
                                resetRevision: resetRevision &+ externalResetRevision,
                                onEditingChanged: onEditingChanged, invalidInputPolicy: invalidInputPolicy,
                                onValidityChange: onValidityChange)
                .frame(width: valueWidth, height: max(26, textSize + 13))
                .help(metadata)
            Text(unit).font(.system(size: textSize)).foregroundStyle(.secondary)
                .frame(width: max(22, textSize * 1.7), alignment: .leading).accessibilityHidden(true)
        }.fixedSize()
    }
    private var track: some View {
        Slider(value: Binding(get: { sliderMapping.position(for: value, in: range) }, set: {
            value = precision.snapped(sliderMapping.value(at: $0, in: range), in: range)
        }), in: 0...1, onEditingChanged: onEditingChanged)
            .tint(.clear)
            .frame(minWidth: 160)
            .overlay {
                GeometryReader { proxy in
                    let fill = sliderMapping.fill(from: defaultValue, to: value, in: range)
                    let width = max(0, proxy.size.width - 14)
                    ZStack(alignment: .leading) {
                        if !trackColors.isEmpty {
                            Capsule().fill(LinearGradient(colors: trackColors, startPoint: .leading, endPoint: .trailing))
                                .frame(width: width, height: 3).offset(x: 7)
                        }
                        Capsule().fill(Color.yellow).frame(width: width * (fill.upperBound - fill.lowerBound), height: 3)
                            .offset(x: 7 + width * fill.lowerBound)
                        Circle().fill(Color.primary).frame(width: 3, height: 3)
                            .offset(x: 7 + width * sliderMapping.position(for: defaultValue, in: range) - 1.5)
                    }.frame(height: proxy.size.height)
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
            .modifier(ParameterResetGesture(action: reset))
            .accessibilityLabel(accessibilityTitle ?? title)
            .accessibilityIdentifier(controlIdentifier("slider"))
            .accessibilityValue(precision.text(value) + " " + unit + " · " + L10n.text(value == defaultValue ? "未调整" : "已调整"))
            .accessibilityAction(named: L10n.format("重置%@", title), reset)
            .help(metadata + " " + directionHelp + " " + pointerHelp)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ViewThatFits(in: .horizontal) {
                if !dynamicTypeSize.isAccessibilitySize { HStack(spacing: 10) { name.frame(width: 120, alignment: .leading); track; number } }
                VStack(spacing: 4) {
                    HStack(spacing: 10) { name; Spacer(minLength: 8); number }
                    track
                }
            }
            if let validationMessage {
                Text(validationMessage).font(.system(size: textSize)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(identifier + ".error")
            }
        }
        .frame(minHeight: max(32, textSize + 16)).frame(maxWidth: 720)
        .contextMenu { Button(L10n.format("重置%@", title), action: reset) }
    }
}

/// VoiceOver exposes the semantic action instead of competing with its activation gesture.
struct ParameterResetGesture: ViewModifier {
    let action: () -> Void
    @ViewBuilder func body(content: Content) -> some View {
        if NSWorkspace.shared.isVoiceOverEnabled { content }
        else { content.simultaneousGesture(TapGesture(count: 2).onEnded(action)) }
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
                    .controlSize(.small).tint(.secondary).disabled(autoBusy)
                    .accessibilityIdentifier("exposure.auto").help(L10n.text("自动调整曝光"))
            }
        }
        .frame(maxWidth: 720)
    }
}
