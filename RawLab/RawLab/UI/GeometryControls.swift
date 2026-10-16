import SwiftUI

struct IOSGeometryControls: View {
    @Environment(\.locale) private var localizationLocale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var settings: GeometrySettings
    @Binding var aspectPreset: CropAspectPreset
    let onEditingChanged: (Bool) -> Void
    let canvasSize: CGSize

    init(settings: Binding<GeometrySettings>, onEditingChanged: @escaping (Bool) -> Void,
         canvasSize: CGSize = CGSize(width: 1, height: 1),
         aspectPreset: Binding<CropAspectPreset> = .constant(.free)) {
        _settings = settings
        self.onEditingChanged = onEditingChanged
        self.canvasSize = canvasSize
        _aspectPreset = aspectPreset
    }

    var body: some View {
        let _ = localizationLocale
        VStack(alignment: .leading, spacing: 16) {
            header
            rotationControls
            Toggle(L10n.text("水平翻转"), isOn: $settings.flipHorizontal)
                .frame(minHeight: 44)
                .accessibilityIdentifier("geometry.flipHorizontal")
            Toggle(L10n.text("垂直翻转"), isOn: $settings.flipVertical)
                .frame(minHeight: 44)
                .accessibilityIdentifier("geometry.flipVertical")
            AdjustmentControl(title: L10n.text("拉直"),
                              value: clampedBinding(\.straightenDegrees, range: -45...45),
                              range: -45...45, step: 0.1, defaultValue: 0, unit: "°",
                              formatter: decimalValue, identifier: "geometry.straighten",
                              onEditingChanged: onEditingChanged)
            perspectiveControl("水平透视", key: \.perspectiveHorizontal,
                               identifier: "geometry.perspectiveHorizontal")
            perspectiveControl("垂直透视", key: \.perspectiveVertical,
                               identifier: "geometry.perspectiveVertical")
            aspectMenu
                .disabled(canvasSize.width <= 0 || canvasSize.height <= 0)
            cropControl("裁切左侧", key: \.cropX, identifier: "geometry.cropX")
            cropControl("裁切顶部", key: \.cropY, identifier: "geometry.cropY")
            cropControl("裁切宽度", key: \.cropWidth, identifier: "geometry.cropWidth")
            cropControl("裁切高度", key: \.cropHeight, identifier: "geometry.cropHeight")
            if settings.cropX > 0 || settings.cropY > 0 {
                Text(L10n.text("此默认值不可达，请重置裁切组。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(L10n.text("裁切百分比基于旋转、翻转和拉直后的画面。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            Text(L10n.text("裁切与旋转"))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                settings = GeometrySettings()
                aspectPreset = .free
            } label: {
                Image(systemName: "arrow.counterclockwise").frame(width: 44, height: 44)
            }
            .accessibilityLabel(L10n.text("重置几何调整"))
            .accessibilityIdentifier("geometry.reset")
            .disabled(settings.isIdentity)
        }
    }

    @ViewBuilder
    private var rotationControls: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                rotationButton(clockwise: false)
                rotationButton(clockwise: true)
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                rotationButton(clockwise: false)
                rotationButton(clockwise: true)
            }
        }
    }

    private func rotationButton(clockwise: Bool) -> some View {
        Button {
            aspectPreset = .free
            settings.quarterTurns = (settings.quarterTurns + (clockwise ? 1 : 3)) % 4
        } label: {
            Label {
                Text(L10n.text(clockwise ? "顺时针 90°" : "逆时针 90°"))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: clockwise ? "rotate.right" : "rotate.left")
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(clockwise ? "geometry.rotateRight" : "geometry.rotateLeft")
    }

    private func perspectiveControl(_ title: String, key: WritableKeyPath<GeometrySettings, Double>,
                                    identifier: String) -> some View {
        AdjustmentControl(title: L10n.text(title), value: clampedBinding(key, range: -1...1, scale: 100),
                          range: -100...100, step: 1, defaultValue: 0,
                          formatter: { String(format: "%.0f", locale: L10n.locale, $0) },
                          identifier: identifier, onEditingChanged: onEditingChanged)
    }

    private func cropControl(_ title: String, key: WritableKeyPath<GeometrySettings, Double>,
                             identifier: String) -> some View {
        let isDimension = key == \.cropWidth || key == \.cropHeight
        return AdjustmentControl(title: L10n.text(title), value: cropBinding(key),
                                 range: cropRange(key), step: 0.1,
                                 defaultValue: isDimension ? 100 : 0, unit: "%",
                                 formatter: decimalValue, identifier: identifier,
                                 onEditingChanged: onEditingChanged)
    }

    private func cropRange(_ key: WritableKeyPath<GeometrySettings, Double>) -> ClosedRange<Double> {
        let limits: [WritableKeyPath<GeometrySettings, Double>: Double] = [
            \.cropX: 1 - settings.cropWidth, \.cropY: 1 - settings.cropHeight,
            \.cropWidth: 1 - settings.cropX, \.cropHeight: 1 - settings.cropY
        ]
        let maximum = min(1, max(0, limits[key] ?? 0))
        let upper = floor(maximum * 1000) / 10
        let minimum = key == \.cropWidth || key == \.cropHeight ? 1.0 : 0
        return min(minimum, upper)...upper
    }

    private func cropBinding(_ key: WritableKeyPath<GeometrySettings, Double>) -> Binding<Double> {
        Binding(get: { settings[keyPath: key] * 100 }, set: { value in
            guard value.isFinite else { return }
            let range = cropRange(key)
            if key == \.cropWidth || key == \.cropHeight { aspectPreset = .free }
            settings[keyPath: key] = min(range.upperBound, max(range.lowerBound, value)) / 100
        })
    }

    private func clampedBinding(_ key: WritableKeyPath<GeometrySettings, Double>,
                                range: ClosedRange<Double>, scale: Double = 1) -> Binding<Double> {
        Binding(get: { settings[keyPath: key] * scale }, set: { value in
            guard value.isFinite else { return }
            settings[keyPath: key] = min(range.upperBound, max(range.lowerBound, value / scale))
        })
    }

    private func decimalValue(_ value: Double) -> String {
        String(format: "%.1f", locale: L10n.locale, value)
    }

    private var orientedCanvasSize: CGSize {
        settings.quarterTurns % 2 == 0 ? canvasSize : CGSize(width: canvasSize.height, height: canvasSize.width)
    }

    private var activeAspectPreset: CropAspectPreset {
        guard let ratio = aspectPreset.ratio(for: orientedCanvasSize), settings.cropHeight > 0 else { return .free }
        let current = settings.cropWidth / settings.cropHeight * Double(orientedCanvasSize.width / orientedCanvasSize.height)
        return abs(current - ratio) < 0.000_001 ? aspectPreset : .free
    }

    private var aspectMenu: some View {
        Menu {
            ForEach(CropAspectPreset.allCases, id: \.self) { preset in
                Button { applyAspect(preset) } label: {
                    if activeAspectPreset == preset {
                        Label(L10n.text(preset.titleKey), systemImage: "checkmark")
                    } else {
                        Text(L10n.text(preset.titleKey))
                    }
                }
            }
        } label: {
            HStack {
                Text(L10n.text("画幅比例"))
                Spacer()
                Text(L10n.text(activeAspectPreset.titleKey))
                Image(systemName: "chevron.up.chevron.down")
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .accessibilityIdentifier("geometry.aspectRatio")
    }

    private func applyAspect(_ preset: CropAspectPreset) {
        aspectPreset = preset
        let rect = CropInteraction.fitting(ratio: preset.ratio(for: orientedCanvasSize),
                                           in: orientedCanvasSize, around: CropInteraction.rect(from: settings))
        settings = CropInteraction.applying(rect: rect, to: settings)
    }
}
