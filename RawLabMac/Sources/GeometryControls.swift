import SwiftUI

struct GeometryControls: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: EditorModel
    @State private var mode = Mode.crop
    @State private var preciseCrop = false

    private enum Mode: String, CaseIterable { case crop, correction }
    private var settings: GeometrySettings { model.geometryDraft }

    var body: some View {
        let _ = localizationLocale
        ScrollView(.vertical) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Picker(L10n.text("几何编辑"), selection: $mode) {
                        Text(L10n.text("裁切")).tag(Mode.crop)
                        Text(L10n.text("校正")).tag(Mode.correction)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
                        .accessibilityLabel(L10n.text("几何编辑"))
                        .accessibilityIdentifier("geometry.mode")
                    Spacer(minLength: 0)
                    Button { model.resetGeometryDraft() } label: {
                        Image(systemName: "arrow.counterclockwise").frame(width: 20, height: 20)
                    }.buttonStyle(.borderless).disabled(settings.isIdentity)
                        .help(L10n.text("重置几何草稿")).accessibilityLabel(L10n.text("重置几何草稿"))
                        .accessibilityIdentifier("geometry.reset")
                    Button(L10n.text("取消"), action: model.cancelGeometryEditing)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel(L10n.text("取消几何编辑"))
                        .accessibilityIdentifier("geometry.cancel")
                    Button(L10n.text("应用"), action: model.applyGeometryEditing)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(!model.geometryPreviewReady || model.busy)
                        .accessibilityLabel(L10n.text("应用几何编辑"))
                        .accessibilityIdentifier("geometry.apply")
                }.controlSize(.small)
                Group {
                    if mode == .crop { cropControls.disabled(!model.geometryPreviewReady) }
                    else {
                        VStack(spacing: 4) {
                            correctionControl(.straightenDegrees)
                            correctionControl(.perspectiveHorizontal)
                            correctionControl(.perspectiveVertical)
                        }
                    }
                }
            }.frame(maxWidth: 760).padding(.horizontal, 16).frame(maxWidth: .infinity)
        }.onChange(of: settings.isIdentity) { _, identity in
            if identity { preciseCrop = false }
        }
    }

    private var cropControls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Picker(L10n.text("裁切比例"), selection: Binding(
                    get: { model.geometryAspectPreset }, set: model.selectGeometryAspect)) {
                    ForEach(CropAspectPreset.allCases, id: \.self) { preset in
                        Text(L10n.text(preset.titleKey)).tag(preset)
                    }
                }.labelsHidden().frame(width: 180).controlSize(.small)
                    .help(L10n.text("裁切比例")).accessibilityLabel(L10n.text("裁切比例"))
                    .accessibilityIdentifier("geometry.aspect")
                Button(action: model.swapGeometryAspect) {
                    Image(systemName: "arrow.left.arrow.right").frame(width: 18, height: 18)
                }
                .disabled(model.geometryAspectRatio == nil || model.geometryAspectPreset == .square)
                .help(L10n.text("交换宽高")).accessibilityLabel(L10n.text("交换宽高"))
                .accessibilityIdentifier("geometry.aspectSwap")
                Divider().frame(height: 22)
                rotationButton(clockwise: false)
                rotationButton(clockwise: true)
                flipButton(horizontal: true)
                flipButton(horizontal: false)
                Spacer(minLength: 0)
                Toggle(isOn: $model.geometryShowsGrid) { Image(systemName: "square.grid.3x3").frame(width: 18, height: 18) }
                    .toggleStyle(.button).help(L10n.text("显示网格")).accessibilityLabel(L10n.text("显示网格"))
                    .accessibilityIdentifier("geometry.grid")
            }.buttonStyle(.bordered).controlSize(.small)
            HStack(spacing: 10) {
                Text(L10n.text("拖动边角裁切，拖动画面内移动选区。"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(cropDimensions).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.text("裁切尺寸"))
                    .accessibilityIdentifier("geometry.dimensions")
            }
            DisclosureGroup(L10n.text("精确裁切"), isExpanded: $preciseCrop) {
                HStack(spacing: 14) {
                    ForEach([GeometryParameter.cropX, .cropY, .cropWidth, .cropHeight]) { parameter in
                        GeometryValueField(parameter: parameter, value: value(parameter), range: parameter.range(for: settings))
                    }
                }.padding(.top, 5)
            }.font(.system(size: 11)).accessibilityIdentifier("geometry.preciseCrop")
        }
    }

    private var cropDimensions: String {
        guard let result = model.result else { return "" }
        let width = max(1, Int((Double(result.nativeWidth ?? result.image.width) * settings.cropWidth).rounded()))
        let height = max(1, Int((Double(result.nativeHeight ?? result.image.height) * settings.cropHeight).rounded()))
        return "\(width) × \(height)"
    }

    private func correctionControl(_ parameter: GeometryParameter) -> some View {
        HStack(spacing: 12) {
            GeometryValueField(parameter: parameter, value: value(parameter), range: parameter.range(for: settings))
                .frame(width: 185)
            Slider(value: value(parameter), in: parameter.range(for: settings),
                   step: parameter == .straightenDegrees ? 0.1 : 0.001,
                   onEditingChanged: model.setInteracting)
                .controlSize(.small).accessibilityLabel(parameter.title)
                .accessibilityValue(String(format: "%.1f%@", settings[keyPath: parameter.keyPath] * parameter.multiplier, parameter.unit))
                .accessibilityIdentifier("geometry.\(parameter.rawValue).slider")
            Button { model.setGeometryDraft(parameter, to: 0) } label: {
                Image(systemName: "arrow.counterclockwise").frame(width: 18, height: 18)
            }.buttonStyle(.borderless).disabled(settings[keyPath: parameter.keyPath] == 0)
                .help(L10n.format("重置%@", parameter.title)).accessibilityLabel(L10n.format("重置%@", parameter.title))
                .accessibilityIdentifier("geometry.\(parameter.rawValue).reset")
        }
    }

    private func flipButton(horizontal: Bool) -> some View {
        let title = L10n.text(horizontal ? "水平翻转" : "垂直翻转")
        let enabled = horizontal ? settings.flipHorizontal : settings.flipVertical
        return Button { model.flipGeometryDraft(horizontal: horizontal) } label: {
            Image(systemName: horizontal ? "arrow.left.and.right.righttriangle.left.righttriangle.right" :
                "arrow.up.and.down.righttriangle.up.righttriangle.down")
                .frame(width: 20, height: 18).foregroundStyle(enabled ? Color.yellow : Color.primary)
        }.help(title).accessibilityLabel(title)
            .accessibilityValue(enabled ? L10n.text("已开启") : L10n.text("已关闭"))
            .accessibilityIdentifier(horizontal ? "geometry.flipHorizontal" : "geometry.flipVertical")
    }

    private func rotationButton(clockwise: Bool) -> some View {
        let title = L10n.text(clockwise ? "向右旋转 90°" : "向左旋转 90°")
        return Button { model.rotateGeometryDraft(clockwise: clockwise) } label: {
            Image(systemName: clockwise ? "rotate.right" : "rotate.left").frame(width: 20, height: 18)
        }.help(title).accessibilityLabel(title)
            .accessibilityIdentifier(clockwise ? "geometry.rotateRight" : "geometry.rotateLeft")
            .accessibilityValue(String(format: "%d°", settings.quarterTurns * 90))
    }

    private func value(_ parameter: GeometryParameter) -> Binding<Double> {
        Binding(get: { settings[keyPath: parameter.keyPath] },
                set: { model.setGeometryDraft(parameter, to: $0) })
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
