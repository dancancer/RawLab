import RawLabKit
import SwiftUI

struct IOSSelectiveColorControls: View {
    @Binding var settings: SelectiveColorSettings
    @Binding var selectedBandIndex: Int
    let onEditingChanged: (Bool) -> Void

    struct BandDescriptor: Identifiable {
        let id: String
        let titleKey: String
        let color: Color
        let keyPath: WritableKeyPath<SelectiveColorBands, SelectiveColorBand>
    }

    static let bandDescriptors: [BandDescriptor] = [
        BandDescriptor(id: "reds", titleKey: "红色", color: .red, keyPath: \.reds),
        BandDescriptor(id: "yellows", titleKey: "黄色", color: .yellow, keyPath: \.yellows),
        BandDescriptor(id: "greens", titleKey: "绿色", color: .green, keyPath: \.greens),
        BandDescriptor(id: "cyans", titleKey: "青色", color: .cyan, keyPath: \.cyans),
        BandDescriptor(id: "blues", titleKey: "蓝色", color: .blue, keyPath: \.blues),
        BandDescriptor(id: "magentas", titleKey: "洋红色", color: Color(red: 0.9, green: 0.2, blue: 0.7), keyPath: \.magentas),
        BandDescriptor(id: "whites", titleKey: "白色", color: .white, keyPath: \.whites),
        BandDescriptor(id: "neutrals", titleKey: "中性色", color: .gray, keyPath: \.neutrals),
        BandDescriptor(id: "blacks", titleKey: "黑色", color: Color(white: 0.15), keyPath: \.blacks),
    ]

    private static let spec = AdjustmentFieldSpec.SubFields.SelectiveColor.self

    private var activeBand: BandDescriptor {
        let safeIndex = min(max(selectedBandIndex, 0), Self.bandDescriptors.count - 1)
        return Self.bandDescriptors[safeIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $settings.method) {
                Text(L10n.text("相对")).tag(SelectiveColorMethod.relative)
                Text(L10n.text("绝对")).tag(SelectiveColorMethod.absolute)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityIdentifier("selectiveColor.method")
            bandStrip
            bandSliders
        }
        .padding(.horizontal, 16)
    }

    private var bandStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(Self.bandDescriptors.enumerated()), id: \.element.id) { index, descriptor in
                    let bandValue = settings.bands[keyPath: descriptor.keyPath]
                    let selected = index == min(max(selectedBandIndex, 0), Self.bandDescriptors.count - 1)
                    Button {
                        selectedBandIndex = index
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(descriptor.color)
                                .overlay { Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 0.8) }
                                .frame(width: 9, height: 9)
                            Text(L10n.text(descriptor.titleKey))
                                .font(.caption.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Color.yellow : Color.primary)
                            if !bandValue.isDefault {
                                Circle().fill(Color.yellow).frame(width: 4, height: 4)
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .background(selected ? Color.yellow.opacity(0.16) : Color.secondary.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("selectiveColor.band.\(descriptor.id)")
                }
            }
        }
    }

    private var bandSliders: some View {
        let band = activeBand
        return VStack(spacing: 4) {
            AdjustmentControl(title: L10n.text("青色 (C)"), value: componentBinding(band.keyPath, \.cyan),
                              range: Self.spec.componentRange, step: 1, defaultValue: 0,
                              formatter: Self.formatValue, identifier: "selectiveColor.cyan",
                              compactNumber: false, compactDecimals: nil, onEditingChanged: onEditingChanged)
            AdjustmentControl(title: L10n.text("洋红 (M)"), value: componentBinding(band.keyPath, \.magenta),
                              range: Self.spec.componentRange, step: 1, defaultValue: 0,
                              formatter: Self.formatValue, identifier: "selectiveColor.magenta",
                              compactNumber: false, compactDecimals: nil, onEditingChanged: onEditingChanged)
            AdjustmentControl(title: L10n.text("黄色 (Y)"), value: componentBinding(band.keyPath, \.yellow),
                              range: Self.spec.componentRange, step: 1, defaultValue: 0,
                              formatter: Self.formatValue, identifier: "selectiveColor.yellow",
                              compactNumber: false, compactDecimals: nil, onEditingChanged: onEditingChanged)
            AdjustmentControl(title: L10n.text("黑色 (K)"), value: componentBinding(band.keyPath, \.black),
                              range: Self.spec.componentRange, step: 1, defaultValue: 0,
                              formatter: Self.formatValue, identifier: "selectiveColor.black",
                              compactNumber: false, compactDecimals: nil, onEditingChanged: onEditingChanged)
        }
    }

    private func componentBinding(
        _ bandPath: WritableKeyPath<SelectiveColorBands, SelectiveColorBand>,
        _ compPath: WritableKeyPath<SelectiveColorBand, Double>
    ) -> Binding<Double> {
        let bounds = Self.spec.componentRange
        return Binding(
            get: { settings.bands[keyPath: bandPath][keyPath: compPath] },
            set: { value in
                guard value.isFinite else { return }
                settings.bands[keyPath: bandPath][keyPath: compPath] = min(max(value, bounds.lowerBound), bounds.upperBound)
            }
        )
    }

    private static func formatValue(_ value: Double) -> String {
        String(format: "%.0f", locale: L10n.locale, value)
    }
}
