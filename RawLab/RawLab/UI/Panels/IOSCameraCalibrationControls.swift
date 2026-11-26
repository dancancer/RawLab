import RawLabKit
import SwiftUI

struct IOSCameraCalibrationControls: View {
    @Binding var settings: CameraCalibrationSettings
    let onEditingChanged: (Bool) -> Void

    private struct PrimaryDescriptor: Identifiable {
        let id: String
        let headerKey: String
        let hueKey: String
        let saturationKey: String
        let huePath: WritableKeyPath<CameraCalibrationSettings, Double>
        let saturationPath: WritableKeyPath<CameraCalibrationSettings, Double>
    }

    private static let primaries: [PrimaryDescriptor] = [
        PrimaryDescriptor(id: "red", headerKey: "红原色", hueKey: "红原色色相", saturationKey: "红原色饱和度",
                          huePath: \.redHue, saturationPath: \.redSaturation),
        PrimaryDescriptor(id: "green", headerKey: "绿原色", hueKey: "绿原色色相", saturationKey: "绿原色饱和度",
                          huePath: \.greenHue, saturationPath: \.greenSaturation),
        PrimaryDescriptor(id: "blue", headerKey: "蓝原色", hueKey: "蓝原色色相", saturationKey: "蓝原色饱和度",
                          huePath: \.blueHue, saturationPath: \.blueSaturation),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AdjustmentControl(
                title: L10n.text("阴影色调"),
                value: clampedBinding(\.shadowTint),
                range: CameraCalibrationSettings.axisRange,
                step: 1,
                defaultValue: 0,
                formatter: Self.formatValue,
                identifier: "calibration.shadowTint",
                compactNumber: false,
                compactDecimals: nil,
                onEditingChanged: onEditingChanged
            )
            ForEach(Self.primaries) { primary in
                primarySection(primary)
            }
        }
        .padding(.horizontal, 16)
    }

    private func primarySection(_ primary: PrimaryDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text(primary.headerKey))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            AdjustmentControl(
                title: L10n.text(primary.hueKey),
                value: clampedBinding(primary.huePath),
                range: CameraCalibrationSettings.axisRange,
                step: 1,
                defaultValue: 0,
                formatter: Self.formatValue,
                identifier: "calibration.\(primary.id)Hue",
                compactNumber: false,
                compactDecimals: nil,
                onEditingChanged: onEditingChanged
            )
            AdjustmentControl(
                title: L10n.text(primary.saturationKey),
                value: clampedBinding(primary.saturationPath),
                range: CameraCalibrationSettings.axisRange,
                step: 1,
                defaultValue: 0,
                formatter: Self.formatValue,
                identifier: "calibration.\(primary.id)Saturation",
                compactNumber: false,
                compactDecimals: nil,
                onEditingChanged: onEditingChanged
            )
        }
    }

    private func clampedBinding(_ keyPath: WritableKeyPath<CameraCalibrationSettings, Double>) -> Binding<Double> {
        let bounds = CameraCalibrationSettings.axisRange
        return Binding(
            get: { settings[keyPath: keyPath] },
            set: { newValue in
                guard newValue.isFinite else { return }
                settings[keyPath: keyPath] = min(max(newValue, bounds.lowerBound), bounds.upperBound)
            }
        )
    }

    private static func formatValue(_ value: Double) -> String {
        String(format: "%.0f", locale: L10n.locale, value)
    }
}
