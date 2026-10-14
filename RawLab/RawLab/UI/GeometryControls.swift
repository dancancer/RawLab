import SwiftUI

struct IOSGeometryControls: View {
    @Environment(\.locale) private var localizationLocale
    @Binding var settings: GeometrySettings
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        let _ = localizationLocale
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text("裁切与旋转")).font(.subheadline)
                Spacer()
                Button { settings = GeometrySettings() } label: {
                    Image(systemName: "arrow.counterclockwise").frame(width: 44, height: 44)
                }
                .accessibilityLabel(L10n.text("重置几何调整"))
                .accessibilityIdentifier("geometry.reset")
                .disabled(settings.isIdentity)
            }
            HStack {
                rotationButton(clockwise: false)
                rotationButton(clockwise: true)
            }
            Toggle(L10n.text("水平翻转"), isOn: $settings.flipHorizontal)
                .accessibilityIdentifier("geometry.flipHorizontal")
            Toggle(L10n.text("垂直翻转"), isOn: $settings.flipVertical)
                .accessibilityIdentifier("geometry.flipVertical")
            HStack {
                Text(L10n.text("拉直"))
                Spacer()
                numberField("拉直", value: Binding(get: { settings.straightenDegrees }, set: {
                    guard $0.isFinite else { return }
                    settings.straightenDegrees = min(45, max(-45, $0))
                }), identifier: "geometry.straighten")
                Text("°")
            }
            Slider(value: $settings.straightenDegrees, in: -45...45, step: 0.1,
                   onEditingChanged: onEditingChanged)
                .frame(minHeight: 44)
                .accessibilityLabel(L10n.text("拉直"))
                .accessibilityValue(String(format: "%.1f°", locale: L10n.locale, settings.straightenDegrees))
                .accessibilityIdentifier("geometry.straightenSlider")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                cropRow("裁切左侧", key: \.cropX, maximum: 1 - settings.cropWidth, identifier: "geometry.cropX")
                cropRow("裁切顶部", key: \.cropY, maximum: 1 - settings.cropHeight, identifier: "geometry.cropY")
                cropRow("裁切宽度", key: \.cropWidth, maximum: 1 - settings.cropX, identifier: "geometry.cropWidth")
                cropRow("裁切高度", key: \.cropHeight, maximum: 1 - settings.cropY, identifier: "geometry.cropHeight")
            }
            Text(L10n.text("裁切百分比基于旋转、翻转和拉直后的画面。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func rotationButton(clockwise: Bool) -> some View {
        Button {
            settings.quarterTurns = (settings.quarterTurns + (clockwise ? 1 : 3)) % 4
        } label: {
            Label(L10n.text(clockwise ? "顺时针 90°" : "逆时针 90°"),
                  systemImage: clockwise ? "rotate.right" : "rotate.left")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(clockwise ? "geometry.rotateRight" : "geometry.rotateLeft")
    }

    private func cropRow(_ title: String, key: WritableKeyPath<GeometrySettings, Double>,
                         maximum: Double, identifier: String) -> some View {
        GridRow {
            Text(L10n.text(title))
            numberField(title, value: Binding(get: { settings[keyPath: key] * 100 }, set: { value in
                guard value.isFinite else { return }
                let minimum = key == \.cropWidth || key == \.cropHeight ? 0.01 : 0
                settings[keyPath: key] = min(maximum, max(minimum, value / 100))
            }), identifier: identifier)
            Text("%")
        }
    }

    private func numberField(_ title: String, value: Binding<Double>, identifier: String) -> some View {
        TextField(L10n.text(title), value: value, format: .number.precision(.fractionLength(0...1)))
            .keyboardType(.numbersAndPunctuation)
            .multilineTextAlignment(.trailing)
            .frame(width: 88, height: 44)
            .padding(.horizontal, 8)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(L10n.text(title))
            .accessibilityIdentifier(identifier)
    }
}
