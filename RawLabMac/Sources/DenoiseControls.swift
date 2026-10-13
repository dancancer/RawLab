import SwiftUI

struct DenoiseControls: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: EditorModel

    var body: some View {
        let _ = localizationLocale
        Group {
            if model.settings.hasLegacyDenoise {
                legacyControls
            } else {
                VStack(spacing: 4) {
                    HStack(spacing: 12) {
                        Toggle(L10n.text("降噪"), isOn: Binding(
                            get: { model.settings.waveletSettings.enabled },
                            set: { model.settings.setDenoiseEnabled($0) }
                        )).toggleStyle(.switch).controlSize(.mini)
                            .accessibilityIdentifier("denoise.enabled")
                        Spacer(minLength: 8)
                        Picker(L10n.text("预设"), selection: Binding(
                            get: { model.settings.waveletSettings.preset },
                            set: { model.settings.applyDenoisePreset($0) }
                        )) {
                            Text(DenoisePreset.detail.title).tag(DenoisePreset.detail)
                            Text(DenoisePreset.clean.title).tag(DenoisePreset.clean)
                            if model.settings.waveletSettings.preset == .custom {
                                Text(DenoisePreset.custom.title).tag(DenoisePreset.custom).disabled(true)
                            }
                        }.pickerStyle(.menu).controlSize(.small).fixedSize()
                            .id(localizationLocale.identifier)
                            .accessibilityIdentifier("denoise.preset")
                        Button { model.settings.set(.denoiseMode, to: 0) } label: {
                            Image(systemName: "arrow.counterclockwise").frame(width: 16, height: 18)
                        }.buttonStyle(.borderless).help(L10n.text("重置降噪"))
                            .accessibilityLabel(L10n.text("重置降噪"))
                            .disabled(model.settings.waveletNoiseReduction == nil)
                    }.frame(height: 22)
                    HStack(spacing: 16) {
                        ForEach(DenoiseParameter.allCases) { parameter in
                            DenoiseParameterControl(parameter: parameter, value: Binding(
                                get: { model.settings.waveletSettings[keyPath: parameter.keyPath] },
                                set: { model.settings.setDenoiseParameter(parameter, to: $0) }
                            ), onEditingChanged: model.setInteracting)
                        }
                    }.disabled(!model.settings.waveletSettings.enabled)
                }
            }
        }.font(.system(size: 12))
    }

    private var legacyControls: some View {
        VStack(spacing: 4) {
            Text(model.settings.denoiseMode == 3 ? L10n.text("旧版 FBDD") : L10n.text("旧版色度降噪"))
                .font(.caption).foregroundStyle(.secondary)
            if model.settings.denoiseMode == 3 {
                Picker(L10n.text("旧版 FBDD"), selection: $model.settings.rawNoiseReduction) {
                    ForEach(RawNoiseReductionLevel.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.segmented).frame(width: 300).id(localizationLocale.identifier)
            } else {
                Picker(L10n.text("旧版色度降噪"), selection: $model.settings.denoiseMode) {
                    ForEach(ChromaNoiseReductionMode.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.segmented).frame(width: 340).id(localizationLocale.identifier)
                    .accessibilityIdentifier("chromaNoiseReduction.mode")
            }
            Button(L10n.text("使用可调降噪")) { model.settings.applyDenoisePreset(.detail) }
                .buttonStyle(.link).accessibilityIdentifier("denoise.upgrade")
        }
    }
}

private struct DenoiseParameterControl: View {
    @Environment(\.locale) private var localizationLocale
    let parameter: DenoiseParameter
    @Binding var value: Double
    let onEditingChanged: (Bool) -> Void
    @State private var draft = ""
    @State private var invalid = false
    @FocusState private var editing: Bool

    var body: some View {
        let _ = localizationLocale
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Text(parameter.shortTitle).font(.system(size: 11)).lineLimit(1)
                    .minimumScaleFactor(0.85).help(parameter.title)
                Spacer(minLength: 2)
                TextField(parameter.title, text: $draft)
                    .textFieldStyle(.roundedBorder).controlSize(.mini)
                    .monospacedDigit().multilineTextAlignment(.trailing)
                    .frame(width: 38).focused($editing)
                    .onSubmit(commit)
                    .onChange(of: editing) { _, focused in if !focused { commit() } }
                    .onExitCommand { draft = text(value); invalid = false; editing = false }
                    .overlay { if invalid { RoundedRectangle(cornerRadius: 4).stroke(.red, lineWidth: 1) } }
                    .accessibilityLabel(L10n.format("%@数值", String(describing: parameter.title)))
                    .accessibilityIdentifier("denoise.value.\(parameter.rawValue)")
                    .help(invalid ? L10n.text("请输入 0 至 100 的有效数字") : L10n.text("0 至 100"))
                Button {
                    value = parameter.defaultValue; draft = text(value); invalid = false
                } label: { Image(systemName: "arrow.counterclockwise").frame(width: 14, height: 16) }
                    .buttonStyle(.borderless).disabled(value == parameter.defaultValue && !invalid)
                    .help(L10n.format("重置%@", String(describing: parameter.title))).accessibilityLabel(L10n.format("重置%@", String(describing: parameter.title)))
            }.frame(height: 20)
            Slider(value: $value, in: 0...100, step: 1, onEditingChanged: onEditingChanged)
                .controlSize(.small)
                .accessibilityLabel(parameter.title)
                .accessibilityValue(text(value))
                .accessibilityIdentifier("denoise.slider.\(parameter.rawValue)")
        }.frame(maxWidth: .infinity)
            .onAppear { draft = text(value) }
            .onChange(of: value) { _, current in draft = text(current); invalid = false }
    }

    private func text(_ value: Double) -> String { String(format: "%.0f", value) }
    private func commit() {
        if let number = Double(draft.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite {
            value = min(100, max(0, number.rounded())); invalid = false
        } else { invalid = true }
        draft = text(value)
    }
}
