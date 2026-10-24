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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(ColorGradingZone.allCases) { target in
                        Button { onCancelled(); zone = target } label: {
                            HStack(spacing: 5) {
                                Text(target.title).fixedSize()
                                Circle().fill(settings[target].isDefault ? .clear : Color.yellow).frame(width: 4, height: 4)
                            }.padding(.horizontal, 10).frame(minHeight: 44)
                                .background(zone == target ? Color.yellow.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain).accessibilityIdentifier("grading.zone.\(target.rawValue)")
                            .accessibilityAddTraits(zone == target ? .isSelected : [])
                            .accessibilityValue(L10n.text(settings[target].isDefault ? "未调整" : "已调整"))
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                if !dynamicTypeSize.isAccessibilitySize {
                    HStack(spacing: 10) { wheel.frame(width: 140, height: 140); rows.frame(minWidth: 160) }
                }
                VStack(spacing: 4) { wheel.frame(width: 156, height: 156); rows }
            }
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
                formatter: { String(format: "%.1f", locale: L10n.locale, $0) }, identifier: "grading.hue", compactNumber: true, compactDecimals: nil, onEditingChanged: onEditingChanged)
            AdjustmentControl(title: L10n.text("饱和度"), value: Binding(get: { settings[selected].saturation }, set: {
                guard $0.isFinite, (0...100).contains($0) else { return }; settings[selected].saturation = $0
            }), range: 0...100, step: 0.1, defaultValue: 0, unit: "%",
                formatter: { String(format: "%.1f", locale: L10n.locale, $0) }, identifier: "grading.saturation", compactNumber: true, compactDecimals: nil, onEditingChanged: onEditingChanged)
        }.id("\(inputContext.id).\(selected.rawValue)")
    }
}
