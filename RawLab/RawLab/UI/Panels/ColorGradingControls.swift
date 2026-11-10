import SwiftUI

struct IOSColorGradingControls: View {
    @Binding var settings: ColorGradingSettings
    @Binding var zone: ColorGradingZone
    let onEditingChanged: (Bool) -> Void
    let onCancelled: () -> Void
    @Environment(\.adjustmentInputContext) private var inputContext
    @Environment(\.adjustmentFine) private var fine
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                ForEach(ColorGradingZone.allCases) { target in
                    Button { onCancelled(); zone = target } label: {
                        Text(target.title).font(.subheadline).frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(zone == target ? Color.yellow : Color.secondary)
                    }.buttonStyle(.plain).accessibilityIdentifier("grading.zone.\(target.rawValue)")
                        .accessibilityAddTraits(zone == target ? .isSelected : [])
                        .accessibilityValue(L10n.text(settings[target].isDefault ? "未调整" : "已调整"))
                }
            }
            wheel.frame(width: 130, height: 130).frame(maxWidth: .infinity)
            rows.environment(\.compactAdjustmentRows, true)
        }.padding(.horizontal, 16)
    }

    private var wheel: some View {
        let selected = zone
        return ColorGradingWheelControl(value: Binding(get: { settings[selected] }, set: { settings[selected] = $0 }),
            scope: "\(inputContext.id).\(selected.rawValue)", title: L10n.text("颜色分级") + " · " + selected.title,
            fine: fine, isCurrent: { inputContext.isCurrent() && zone == selected }, canChange: inputContext.canChange,
            onEditingChanged: onEditingChanged, onCancelled: onCancelled)
    }
    private var rows: some View {
        let selected = zone
        return VStack(spacing: 4) {
            AdjustmentControl(title: L10n.text("色相"), value: Binding(get: { settings[selected].hue }, set: {
                if let hue = ColorGradingWheel.inputHue($0) { settings[selected].hue = hue }
            }), range: 0...360, step: 0.1, defaultValue: 0, unit: "°",
                formatter: { String(format: "%.1f", locale: L10n.locale, $0) }, identifier: "grading.hue", compactNumber: false, compactDecimals: nil, onEditingChanged: onEditingChanged)
            AdjustmentControl(title: L10n.text("饱和度"), value: Binding(get: { settings[selected].saturation }, set: {
                guard $0.isFinite, (0...100).contains($0) else { return }; settings[selected].saturation = $0
            }), range: 0...100, step: 0.1, defaultValue: 0, unit: "%",
                formatter: { String(format: "%.1f", locale: L10n.locale, $0) }, identifier: "grading.saturation", compactNumber: false, compactDecimals: nil, onEditingChanged: onEditingChanged)
        }.id("\(inputContext.id).\(selected.rawValue)")
    }
}
