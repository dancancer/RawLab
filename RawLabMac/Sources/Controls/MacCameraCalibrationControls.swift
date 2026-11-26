import RawLabKit
import SwiftUI

struct MacCameraCalibrationControls: View {
    @Environment(\.locale) private var localizationLocale
    @Binding var settings: CameraCalibrationSettings
    let resetVersion: Int
    let onEditingChanged: (Bool) -> Void
    let onReset: () -> Void

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
        let _ = localizationLocale
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer(minLength: 0)
                Button(action: reset) {
                    Image(systemName: "arrow.counterclockwise").frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(L10n.text("重置"))
                .accessibilityLabel(L10n.text("重置"))
                .accessibilityIdentifier("calibration.reset")
                .disabled(settings.isDefault)
            }
            ParameterRow(
                title: L10n.text("阴影色调"),
                value: clampedBinding(\.shadowTint),
                range: CameraCalibrationSettings.axisRange,
                defaultValue: 0,
                identifier: "calibration.value.shadowTint",
                onEditingChanged: onEditingChanged
            )
            .id("calibration.shadowTint.\(resetVersion)")
            ForEach(Self.primaries) { primary in
                primarySection(primary)
            }
        }
        .frame(maxWidth: 720)
    }

    private func primarySection(_ primary: PrimaryDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text(primary.headerKey))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            ParameterRow(
                title: L10n.text(primary.hueKey),
                value: clampedBinding(primary.huePath),
                range: CameraCalibrationSettings.axisRange,
                defaultValue: 0,
                identifier: "calibration.value.\(primary.id)Hue",
                onEditingChanged: onEditingChanged
            )
            .id("calibration.\(primary.id)Hue.\(resetVersion)")
            ParameterRow(
                title: L10n.text(primary.saturationKey),
                value: clampedBinding(primary.saturationPath),
                range: CameraCalibrationSettings.axisRange,
                defaultValue: 0,
                identifier: "calibration.value.\(primary.id)Saturation",
                onEditingChanged: onEditingChanged
            )
            .id("calibration.\(primary.id)Saturation.\(resetVersion)")
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

    private func reset() {
        ParameterValueField.cancelPendingInputs()
        onReset()
    }
}
