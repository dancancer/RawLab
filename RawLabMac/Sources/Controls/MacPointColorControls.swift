import RawLabKit
import RawLabNative
import SwiftUI

struct MacPointColorControls: View {
    @Environment(\.locale) private var localizationLocale
    @Binding var settings: PointColorSettings
    @Binding var selectedIndex: Int
    @Binding var eyedropperEnabled: Bool
    let resetVersion: Int
    let canSample: Bool
    let onEditingChanged: (Bool) -> Void
    let onCancelEyedropper: () -> Void
    let onReset: () -> Void

    private static let spec = AdjustmentFieldSpec.SubFields.PointColor.self

    private var activeIndex: Int? {
        guard !settings.swatches.isEmpty else { return nil }
        return min(max(selectedIndex, 0), settings.swatches.count - 1)
    }

    var body: some View {
        let _ = localizationLocale
        VStack(alignment: .leading, spacing: 8) {
            MacPointColorActionBar(
                swatchCount: settings.swatches.count,
                maxSwatches: Self.spec.maxSwatches,
                eyedropperEnabled: eyedropperEnabled,
                canDelete: activeIndex != nil,
                canReset: !settings.isDefault,
                canSample: canSample,
                onToggleEyedropper: toggleEyedropper,
                onAddSwatch: addNeutralSwatch,
                onDeleteSwatch: deleteSelectedSwatch,
                onReset: resetAll
            )
            if !settings.swatches.isEmpty {
                MacPointColorSwatchStrip(
                    swatches: settings.swatches,
                    selectedIndex: activeIndex ?? 0,
                    onSelect: selectSwatch
                )
            }
            if let index = activeIndex {
                MacPointColorSwatchDetail(
                    swatch: bindingForSwatch(at: index),
                    swatchIndex: index,
                    resetVersion: resetVersion,
                    onEditingChanged: onEditingChanged
                )
            }
        }
        .frame(maxWidth: 720)
    }

    private func toggleEyedropper() {
        ParameterValueField.cancelPendingInputs()
        if eyedropperEnabled {
            onCancelEyedropper()
        } else {
            eyedropperEnabled = true
        }
    }

    private func addNeutralSwatch() {
        ParameterValueField.cancelPendingInputs()
        onCancelEyedropper()
        guard settings.swatches.count < Self.spec.maxSwatches else { return }
        settings.swatches.append(PointColorSwatch(srcHue: 25, srcSaturation: 0.5, srcLuminance: 0.5))
        selectedIndex = settings.swatches.count - 1
    }

    private func deleteSelectedSwatch() {
        ParameterValueField.cancelPendingInputs()
        onCancelEyedropper()
        guard let index = activeIndex else { return }
        settings.swatches.remove(at: index)
        selectedIndex = max(0, min(index, settings.swatches.count - 1))
    }

    private func selectSwatch(_ index: Int) {
        ParameterValueField.cancelPendingInputs()
        selectedIndex = index
    }

    private func resetAll() {
        ParameterValueField.cancelPendingInputs()
        onCancelEyedropper()
        onReset()
        selectedIndex = 0
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

private struct MacPointColorActionBar: View {
    let swatchCount: Int
    let maxSwatches: Int
    let eyedropperEnabled: Bool
    let canDelete: Bool
    let canReset: Bool
    let canSample: Bool
    let onToggleEyedropper: () -> Void
    let onAddSwatch: () -> Void
    let onDeleteSwatch: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggleEyedropper) {
                Label(L10n.text("吸管取样"), systemImage: "eyedropper")
                    .font(.system(size: 11, weight: eyedropperEnabled ? .semibold : .regular))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(eyedropperEnabled ? .yellow : .secondary)
            .disabled(!canSample)
            .accessibilityIdentifier("pointColor.eyedropper")
            Button(action: onAddSwatch) {
                Label(L10n.text("添加色板"), systemImage: "plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(swatchCount >= maxSwatches)
            .accessibilityIdentifier("pointColor.addSwatch")
            Spacer(minLength: 0)
            Text("\(swatchCount)/\(maxSwatches)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            if canDelete {
                Button(action: onDeleteSwatch) {
                    Image(systemName: "trash").frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("pointColor.deleteSwatch")
            }
            Button(action: onReset) {
                Image(systemName: "arrow.counterclockwise").frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help(L10n.text("重置"))
            .accessibilityLabel(L10n.text("重置"))
            .accessibilityIdentifier("pointColor.reset")
            .disabled(!canReset)
        }
    }
}

private struct MacPointColorSwatchStrip: View {
    let swatches: [PointColorSwatch]
    let selectedIndex: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
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
                        .frame(width: 22, height: 22)
                        .overlay {
                            Circle().strokeBorder(selectedIndex == index ? Color.yellow : Color.white.opacity(0.35),
                                                  lineWidth: selectedIndex == index ? 2 : 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("色板"))
                .accessibilityIdentifier("pointColor.swatch.\(index)")
            }
            Spacer(minLength: 0)
        }
    }
}

private struct MacPointColorSwatchDetail: View {
    @Binding var swatch: PointColorSwatch
    let swatchIndex: Int
    let resetVersion: Int
    let onEditingChanged: (Bool) -> Void

    private static let spec = AdjustmentFieldSpec.SubFields.PointColor.self

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            previewHeader
            ParameterRow(title: L10n.text("色相偏移"), value: shiftBinding(\.hueShift),
                         range: Self.spec.shiftRange, defaultValue: 0,
                         identifier: "pointColor.value.hueShift", onEditingChanged: onEditingChanged)
                .id("pointColor.\(swatchIndex).hueShift.\(resetVersion)")
            ParameterRow(title: L10n.text("饱和度偏移"), value: shiftBinding(\.saturationShift),
                         range: Self.spec.shiftRange, defaultValue: 0,
                         identifier: "pointColor.value.saturationShift", onEditingChanged: onEditingChanged)
                .id("pointColor.\(swatchIndex).satShift.\(resetVersion)")
            ParameterRow(title: L10n.text("明亮度偏移"), value: shiftBinding(\.luminanceShift),
                         range: Self.spec.shiftRange, defaultValue: 0,
                         identifier: "pointColor.value.luminanceShift", onEditingChanged: onEditingChanged)
                .id("pointColor.\(swatchIndex).lumShift.\(resetVersion)")
            ParameterRow(title: L10n.text("方差"), value: shiftBinding(\.variance),
                         range: Self.spec.shiftRange, defaultValue: 0,
                         identifier: "pointColor.value.variance", onEditingChanged: onEditingChanged)
                .id("pointColor.\(swatchIndex).variance.\(resetVersion)")
            ParameterRow(title: L10n.text("范围"), value: rangeBinding(\.range),
                         range: Self.spec.rangeControlRange, defaultValue: Self.spec.rangeControlDefault,
                         identifier: "pointColor.value.range", onEditingChanged: onEditingChanged)
                .id("pointColor.\(swatchIndex).range.\(resetVersion)")
            ParameterRow(title: L10n.text("色相范围"), value: rangeBinding(\.hueRange),
                         range: Self.spec.rangeControlRange, defaultValue: Self.spec.rangeControlDefault,
                         identifier: "pointColor.value.hueRange", onEditingChanged: onEditingChanged)
                .id("pointColor.\(swatchIndex).hueRange.\(resetVersion)")
            ParameterRow(title: L10n.text("饱和度范围"), value: rangeBinding(\.satRange),
                         range: Self.spec.rangeControlRange, defaultValue: Self.spec.rangeControlDefault,
                         identifier: "pointColor.value.satRange", onEditingChanged: onEditingChanged)
                .id("pointColor.\(swatchIndex).satRange.\(resetVersion)")
            ParameterRow(title: L10n.text("明亮度范围"), value: rangeBinding(\.lumRange),
                         range: Self.spec.rangeControlRange, defaultValue: Self.spec.rangeControlDefault,
                         identifier: "pointColor.value.lumRange", onEditingChanged: onEditingChanged)
                .id("pointColor.\(swatchIndex).lumRange.\(resetVersion)")
        }
        .disabled(!swatch.enabled)
    }

    private var previewHeader: some View {
        let preview = PointColorSwatchPreview(swatch: swatch)
        let before = preview.map { Color(red: Double($0.srcRed), green: Double($0.srcGreen), blue: Double($0.srcBlue)) } ?? .gray
        let after = preview.map { Color(red: Double($0.shiftedRed), green: Double($0.shiftedGreen), blue: Double($0.shiftedBlue)) } ?? .gray
        return HStack(spacing: 8) {
            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 4).fill(before).frame(width: 28, height: 18)
                RoundedRectangle(cornerRadius: 4).fill(after).frame(width: 28, height: 18)
            }
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.25), lineWidth: 1) }
            .accessibilityIdentifier("pointColor.preview")
            Spacer(minLength: 0)
            Toggle(L10n.text("已启用"), isOn: Binding(
                get: { swatch.enabled },
                set: { enabled in
                    ParameterValueField.cancelPendingInputs()
                    swatch.enabled = enabled
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
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
}
