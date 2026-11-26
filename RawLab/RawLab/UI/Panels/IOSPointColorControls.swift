import RawLabKit
import RawLabNative
import SwiftUI

struct IOSPointColorControls: View {
    @Binding var settings: PointColorSettings
    @Binding var selectedIndex: Int
    @Binding var eyedropperEnabled: Bool
    let canSample: Bool
    let onEditingChanged: (Bool) -> Void

    private static let spec = AdjustmentFieldSpec.SubFields.PointColor.self

    private var activeIndex: Int? {
        guard !settings.swatches.isEmpty else { return nil }
        return min(max(selectedIndex, 0), settings.swatches.count - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            IOSPointColorActionBar(
                swatchCount: settings.swatches.count,
                maxSwatches: Self.spec.maxSwatches,
                eyedropperEnabled: $eyedropperEnabled,
                canSample: canSample,
                canDelete: activeIndex != nil,
                onAddSwatch: addNeutralSwatch,
                onDeleteSwatch: deleteSelectedSwatch
            )
            if !settings.swatches.isEmpty {
                IOSPointColorSwatchStrip(
                    swatches: settings.swatches,
                    selectedIndex: activeIndex ?? 0,
                    onSelect: { selectedIndex = $0 }
                )
            }
            if let index = activeIndex {
                IOSPointColorSwatchDetail(
                    swatch: bindingForSwatch(at: index),
                    onEditingChanged: onEditingChanged
                )
            }
        }
        .padding(.horizontal, 16)
    }

    private func addNeutralSwatch() {
        eyedropperEnabled = false
        guard settings.swatches.count < Self.spec.maxSwatches else { return }
        settings.swatches.append(PointColorSwatch(srcHue: 25, srcSaturation: 0.5, srcLuminance: 0.5))
        selectedIndex = settings.swatches.count - 1
    }

    private func deleteSelectedSwatch() {
        eyedropperEnabled = false
        guard let index = activeIndex else { return }
        settings.swatches.remove(at: index)
        selectedIndex = max(0, min(index, settings.swatches.count - 1))
    }

    private func bindingForSwatch(at index: Int) -> Binding<PointColorSwatch> {
        Binding(
            get: {
                guard settings.swatches.indices.contains(index) else {
                    return PointColorSwatch(srcHue: 0, srcSaturation: 0.5, srcLuminance: 0.5)
                }
                return settings.swatches[index]
            },
            set: { updated in
                guard settings.swatches.indices.contains(index) else { return }
                settings.swatches[index] = updated
            }
        )
    }
}

private struct IOSPointColorActionBar: View {
    let swatchCount: Int
    let maxSwatches: Int
    @Binding var eyedropperEnabled: Bool
    let canSample: Bool
    let canDelete: Bool
    let onAddSwatch: () -> Void
    let onDeleteSwatch: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                eyedropperEnabled.toggle()
            } label: {
                Label(L10n.text("吸管取样"), systemImage: "eyedropper")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .tint(eyedropperEnabled ? .yellow : .secondary)
            .disabled(!canSample)
            .accessibilityIdentifier("pointColor.eyedropper")
            Button(action: onAddSwatch) {
                Label(L10n.text("添加色板"), systemImage: "plus")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .disabled(swatchCount >= maxSwatches)
            .accessibilityIdentifier("pointColor.addSwatch")
            Spacer(minLength: 0)
            Text("\(swatchCount)/\(maxSwatches)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            if canDelete {
                Button(action: onDeleteSwatch) {
                    Image(systemName: "trash")
                        .frame(minWidth: 36, minHeight: 36)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pointColor.deleteSwatch")
            }
        }
    }
}

private struct IOSPointColorSwatchStrip: View {
    let swatches: [PointColorSwatch]
    let selectedIndex: Int
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(swatches.enumerated()), id: \.offset) { index, swatch in
                    let preview = PointColorSwatchPreview(swatch: swatch)
                    let color: Color = preview.map {
                        Color(red: Double($0.shiftedRed), green: Double($0.shiftedGreen), blue: Double($0.shiftedBlue))
                    } ?? .gray
                    Button {
                        onSelect(index)
                    } label: {
                        Circle()
                            .fill(color)
                            .opacity(swatch.enabled ? 1.0 : 0.35)
                            .frame(width: 28, height: 28)
                            .overlay {
                                Circle().strokeBorder(selectedIndex == index ? Color.yellow : Color.white.opacity(0.35),
                                                      lineWidth: selectedIndex == index ? 2 : 1)
                            }
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("色板"))
                    .accessibilityIdentifier("pointColor.swatch.\(index)")
                }
            }
        }
    }
}

private struct IOSPointColorSwatchDetail: View {
    @Binding var swatch: PointColorSwatch
    let onEditingChanged: (Bool) -> Void

    private static let spec = AdjustmentFieldSpec.SubFields.PointColor.self

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            previewHeader
            VStack(alignment: .leading, spacing: 6) {
                AdjustmentControl(title: L10n.text("色相偏移"), value: shiftBinding(\.hueShift),
                                  range: Self.spec.shiftRange, step: 1, defaultValue: 0,
                                  formatter: Self.formatValue, identifier: "pointColor.hueShift",
                                  compactNumber: false, compactDecimals: nil, onEditingChanged: onEditingChanged)
                AdjustmentControl(title: L10n.text("饱和度偏移"), value: shiftBinding(\.saturationShift),
                                  range: Self.spec.shiftRange, step: 1, defaultValue: 0,
                                  formatter: Self.formatValue, identifier: "pointColor.saturationShift",
                                  compactNumber: false, compactDecimals: nil, onEditingChanged: onEditingChanged)
                AdjustmentControl(title: L10n.text("明亮度偏移"), value: shiftBinding(\.luminanceShift),
                                  range: Self.spec.shiftRange, step: 1, defaultValue: 0,
                                  formatter: Self.formatValue, identifier: "pointColor.luminanceShift",
                                  compactNumber: false, compactDecimals: nil, onEditingChanged: onEditingChanged)
                AdjustmentControl(title: L10n.text("方差"), value: shiftBinding(\.variance),
                                  range: Self.spec.shiftRange, step: 1, defaultValue: 0,
                                  formatter: Self.formatValue, identifier: "pointColor.variance",
                                  compactNumber: false, compactDecimals: nil, onEditingChanged: onEditingChanged)
                AdjustmentControl(title: L10n.text("范围"), value: rangeBinding(\.range),
                                  range: Self.spec.rangeControlRange, step: 1, defaultValue: Self.spec.rangeControlDefault,
                                  formatter: Self.formatValue, identifier: "pointColor.range",
                                  compactNumber: false, compactDecimals: nil, onEditingChanged: onEditingChanged)
                AdjustmentControl(title: L10n.text("色相范围"), value: rangeBinding(\.hueRange),
                                  range: Self.spec.rangeControlRange, step: 1, defaultValue: Self.spec.rangeControlDefault,
                                  formatter: Self.formatValue, identifier: "pointColor.hueRange",
                                  compactNumber: false, compactDecimals: nil, onEditingChanged: onEditingChanged)
                AdjustmentControl(title: L10n.text("饱和度范围"), value: rangeBinding(\.satRange),
                                  range: Self.spec.rangeControlRange, step: 1, defaultValue: Self.spec.rangeControlDefault,
                                  formatter: Self.formatValue, identifier: "pointColor.satRange",
                                  compactNumber: false, compactDecimals: nil, onEditingChanged: onEditingChanged)
                AdjustmentControl(title: L10n.text("明亮度范围"), value: rangeBinding(\.lumRange),
                                  range: Self.spec.rangeControlRange, step: 1, defaultValue: Self.spec.rangeControlDefault,
                                  formatter: Self.formatValue, identifier: "pointColor.lumRange",
                                  compactNumber: false, compactDecimals: nil, onEditingChanged: onEditingChanged)
            }
            .disabled(!swatch.enabled)
        }
    }

    private var previewHeader: some View {
        let preview = PointColorSwatchPreview(swatch: swatch)
        let before = preview.map { Color(red: Double($0.srcRed), green: Double($0.srcGreen), blue: Double($0.srcBlue)) } ?? .gray
        let after = preview.map { Color(red: Double($0.shiftedRed), green: Double($0.shiftedGreen), blue: Double($0.shiftedBlue)) } ?? .gray
        return HStack(spacing: 10) {
            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 4).fill(before).frame(width: 32, height: 22)
                RoundedRectangle(cornerRadius: 4).fill(after).frame(width: 32, height: 22)
            }
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.25), lineWidth: 1) }
            .accessibilityIdentifier("pointColor.preview")
            Spacer(minLength: 0)
            Toggle(L10n.text("已启用"), isOn: $swatch.enabled)
                .labelsHidden()
                .accessibilityLabel(L10n.text("已启用"))
                .accessibilityIdentifier("pointColor.swatch.enabled")
        }
    }

    private func shiftBinding(_ path: WritableKeyPath<PointColorSwatch, Double>) -> Binding<Double> {
        clampedBinding(path, range: Self.spec.shiftRange)
    }

    private func rangeBinding(_ path: WritableKeyPath<PointColorSwatch, Double>) -> Binding<Double> {
        clampedBinding(path, range: Self.spec.rangeControlRange)
    }

    private func clampedBinding(_ path: WritableKeyPath<PointColorSwatch, Double>, range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { swatch[keyPath: path] },
            set: { value in
                guard value.isFinite else { return }
                swatch[keyPath: path] = min(max(value, range.lowerBound), range.upperBound)
            }
        )
    }

    private static func formatValue(_ value: Double) -> String {
        String(format: "%.0f", locale: L10n.locale, value)
    }
}
