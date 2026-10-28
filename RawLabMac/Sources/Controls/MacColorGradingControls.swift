import SwiftUI

struct MacColorGradingControls: View {
    @Binding var settings: ColorGradingSettings
    @Binding var zone: ColorGradingZone
    let source: String
    let isCurrent: () -> Bool
    let onEditingChanged: (Bool) -> Void
    let onCancelled: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ColorGradingZone.allCases) { target in
                        Button {
                            onCancelled()
                            ParameterValueField.cancelPendingInputs()
                            zone = target
                        } label: {
                            HStack(spacing: 5) {
                                Text(target.title).fixedSize()
                                Circle().fill(settings[target].isDefault ? .clear : Color.yellow).frame(width: 3, height: 3)
                            }.padding(.horizontal, 10).frame(minHeight: 30)
                                .background(zone == target ? Color.yellow.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
                        }.buttonStyle(.plain).accessibilityIdentifier("grading.zone.\(target.rawValue)")
                            .accessibilityAddTraits(zone == target ? .isSelected : [])
                            .accessibilityValue(L10n.text(settings[target].isDefault ? "未调整" : "已调整"))
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                if !dynamicTypeSize.isAccessibilitySize {
                    HStack(spacing: 16) { wheel.frame(width: 156, height: 156); rows.frame(minWidth: 300) }
                }
                VStack(spacing: 8) { wheel.frame(width: 156, height: 156); rows }
            }
        }.frame(maxWidth: 720)
    }

    private var wheel: some View {
        let selected = zone
        return ColorGradingWheelControl(value: Binding(get: { settings[selected] }, set: { settings[selected] = $0 }),
            scope: "\(source).\(selected.rawValue)", title: L10n.text("颜色分级") + " · " + selected.title,
            isCurrent: { isCurrent() && zone == selected }, prepareEditing: ParameterValueField.commitPendingInputs,
            onEditingChanged: onEditingChanged, onCancelled: onCancelled)
    }
    private var rows: some View {
        let selected = zone
        return VStack(spacing: 6) {
            ParameterRow(title: L10n.text("色相"), value: Binding(get: { settings[selected].hue }, set: {
                if let hue = ColorGradingWheel.inputHue($0) { settings[selected].hue = hue }
            }), range: 0...360, defaultValue: 0, unit: "°", identifier: "grading.value.hue", onEditingChanged: onEditingChanged,
                accessibilityTitle: selected.title + " · " + L10n.text("色相"), inputScope: selected.rawValue)
            ParameterRow(title: L10n.text("饱和度"), value: Binding(get: { settings[selected].saturation }, set: {
                guard $0.isFinite, (0...100).contains($0) else { return }; settings[selected].saturation = $0
            }), range: 0...100, defaultValue: 0, unit: "%", identifier: "grading.value.saturation", onEditingChanged: onEditingChanged,
                accessibilityTitle: selected.title + " · " + L10n.text("饱和度"), inputScope: selected.rawValue)
        }.id("\(source).\(selected.rawValue)")
    }
}
