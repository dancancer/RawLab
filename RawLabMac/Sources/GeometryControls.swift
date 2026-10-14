import SwiftUI

struct GeometryControls: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: EditorModel

    private var settings: GeometrySettings { model.settings.geometrySettings }

    var body: some View {
        let _ = localizationLocale
        ScrollView(.vertical) {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    rotationButton(clockwise: false)
                    rotationButton(clockwise: true)
                    Toggle(L10n.text("水平翻转"), isOn: flip(horizontal: true))
                        .accessibilityIdentifier("geometry.flipHorizontal")
                    Toggle(L10n.text("垂直翻转"), isOn: flip(horizontal: false))
                        .accessibilityIdentifier("geometry.flipVertical")
                    Spacer(minLength: 0)
                    Button { model.settings.reset(.geometry) } label: {
                        Image(systemName: "arrow.counterclockwise").frame(width: 20, height: 20)
                    }.buttonStyle(.borderless).disabled(model.settings.isDefault(.geometry))
                        .help(L10n.text("重置几何编辑")).accessibilityLabel(L10n.text("重置几何编辑"))
                        .accessibilityIdentifier("geometry.reset")
                }.controlSize(.small)
                HStack(spacing: 16) {
                    ForEach([GeometryParameter.cropX, .cropY, .cropWidth, .cropHeight]) { parameter in
                        GeometryValueField(parameter: parameter, value: value(parameter), range: parameter.range(for: settings))
                    }
                }
                HStack(spacing: 12) {
                    GeometryValueField(parameter: .straightenDegrees, value: value(.straightenDegrees), range: -45...45)
                        .frame(width: 150)
                    Slider(value: value(.straightenDegrees), in: -45...45, step: 0.1,
                           onEditingChanged: model.setInteracting)
                        .controlSize(.small).accessibilityLabel(L10n.text("拉直"))
                        .accessibilityValue(String(format: "%.1f°", settings.straightenDegrees))
                        .accessibilityIdentifier("geometry.straighten.slider")
                }
                Text(L10n.text("裁切位置和尺寸按旋转、翻转与拉直后的画布百分比设置。"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: 720).padding(.horizontal, 16).frame(maxWidth: .infinity)
        }
    }

    private func rotationButton(clockwise: Bool) -> some View {
        let title = L10n.text(clockwise ? "向右旋转 90°" : "向左旋转 90°")
        return Button { model.settings.rotateGeometry(clockwise: clockwise) } label: {
            Image(systemName: clockwise ? "rotate.right" : "rotate.left").frame(width: 24, height: 20)
        }.buttonStyle(.borderless).help(title).accessibilityLabel(title)
            .accessibilityIdentifier(clockwise ? "geometry.rotateRight" : "geometry.rotateLeft")
            .accessibilityValue(String(format: "%d°", settings.quarterTurns * 90))
    }

    private func value(_ parameter: GeometryParameter) -> Binding<Double> {
        Binding(get: { settings[keyPath: parameter.keyPath] },
                set: { model.settings.setGeometry(parameter, to: $0) })
    }

    private func flip(horizontal: Bool) -> Binding<Bool> {
        Binding(get: { horizontal ? settings.flipHorizontal : settings.flipVertical }, set: { enabled in
            let current = horizontal ? settings.flipHorizontal : settings.flipVertical
            if enabled != current { model.settings.flipGeometry(horizontal: horizontal) }
        })
    }
}

private struct GeometryValueField: View {
    let parameter: GeometryParameter
    @Binding var value: Double
    let range: ClosedRange<Double>
    @State private var draft = ""
    @State private var invalid = false
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(parameter.title).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            TextField(parameter.title, text: $draft)
                .textFieldStyle(.roundedBorder).controlSize(.small).monospacedDigit()
                .multilineTextAlignment(.trailing).frame(width: 52).focused($editing)
                .onSubmit(commit)
                .onChange(of: editing) { _, focused in if !focused { commit() } }
                .onExitCommand { draft = text(value); invalid = false; editing = false }
                .overlay { if invalid { RoundedRectangle(cornerRadius: 4).stroke(.red, lineWidth: 1) } }
                .accessibilityLabel(L10n.format("%@数值", parameter.title))
                .accessibilityValue("\(text(value)) \(parameter.unit)")
                .accessibilityIdentifier("geometry.value.\(parameter.rawValue)")
                .help(invalid ? L10n.text("请输入范围内的有效数字") :
                    L10n.format("%@ 至 %@", text(range.lowerBound), text(range.upperBound)))
            Text(parameter.unit).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
            .onAppear { draft = text(value) }
            .onChange(of: value) { _, current in draft = text(current); invalid = false }
    }

    private func text(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value * parameter.multiplier)
    }

    private func commit() {
        guard let number = Double(draft.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite else {
            invalid = true
            return
        }
        value = min(range.upperBound, max(range.lowerBound, number / parameter.multiplier))
        draft = text(value)
        invalid = false
    }
}
