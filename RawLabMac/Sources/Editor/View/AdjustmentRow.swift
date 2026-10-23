import AppKit
import SwiftUI

struct RoundParameterSlider: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    let precision: ParameterPrecision
    let mapping: ParameterSliderMapping
    let colors: [Color]
    let onEditingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NativeParameterSlider {
        let slider = NativeParameterSlider()
        slider.cell = RoundParameterSliderCell()
        slider.minValue = 0; slider.maxValue = 1
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.onEditingChanged = { [weak coordinator = context.coordinator] in coordinator?.parent.onEditingChanged($0) }
        slider.onStep = { [weak coordinator = context.coordinator] direction, fine in
            coordinator?.step(direction, fine: fine)
        }
        return slider
    }
    func updateNSView(_ slider: NativeParameterSlider, context: Context) {
        context.coordinator.parent = self
        slider.isEnabled = isEnabled
        slider.doubleValue = mapping.position(for: value, in: range)
        if let cell = slider.cell as? RoundParameterSliderCell {
            cell.defaultPosition = mapping.position(for: defaultValue, in: range)
            cell.colors = colors.map { NSColor($0) }
        }
        slider.needsDisplay = true
    }
    final class Coordinator: NSObject {
        var parent: RoundParameterSlider
        init(_ parent: RoundParameterSlider) { self.parent = parent }
        @objc func changed(_ slider: NSSlider) {
            parent.value = parent.precision.snapped(parent.mapping.value(at: slider.doubleValue, in: parent.range), in: parent.range)
        }
        func step(_ direction: Int, fine: Bool) {
            guard ParameterValueField.commitPendingInputs() else { return }
            parent.value = parent.precision.stepped(parent.value, direction: direction, fine: fine, in: parent.range)
        }
    }
}

final class NativeParameterSlider: NSSlider {
    var onEditingChanged: ((Bool) -> Void)?
    var onStep: ((Int, Bool) -> Void)?
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, ParameterValueField.commitPendingInputs() else { return }
        onEditingChanged?(true)
        defer { onEditingChanged?(false) }
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if [123, 124, 125, 126].contains(event.keyCode), isEnabled {
            onStep?([124, 126].contains(event.keyCode) ? 1 : -1, event.modifierFlags.contains(.shift))
        } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled else { return false }; onStep?(1, true); return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled else { return false }; onStep?(-1, true); return true
    }
}

final class RoundParameterSliderCell: NSSliderCell {
    var defaultPosition = 0.0
    var colors: [NSColor] = []
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 1.5, width: rect.width, height: 3)
        let path = NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5)
        NSColor.separatorColor.setFill(); path.fill()
        if colors.count > 1 { NSGradient(colors: colors)?.draw(in: path, angle: 0) }
        let position = (doubleValue - minValue) / max(Double.ulpOfOne, maxValue - minValue)
        let start = min(defaultPosition, position)
        let fill = NSRect(x: track.minX + track.width * start, y: track.minY,
                          width: track.width * abs(position - defaultPosition), height: track.height)
        NSColor.systemYellow.setFill(); NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
        NSColor.labelColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: track.minX + track.width * defaultPosition - 1.5,
                                   y: track.midY - 1.5, width: 3, height: 3)).fill()
    }
    override func drawKnob(_ knobRect: NSRect) {
        let circle = NSBezierPath(ovalIn: NSRect(x: knobRect.midX - 7, y: knobRect.midY - 7, width: 14, height: 14))
        (isEnabled ? NSColor.white : NSColor.disabledControlTextColor).setFill(); circle.fill()
        NSColor.black.withAlphaComponent(0.2).setStroke(); circle.lineWidth = 0.5; circle.stroke()
    }
}

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
        RoundParameterSlider(value: $value, range: range, defaultValue: defaultValue,
                             precision: precision, mapping: sliderMapping, colors: trackColors,
                             onEditingChanged: onEditingChanged)
            .frame(minWidth: 160, minHeight: 26)
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
