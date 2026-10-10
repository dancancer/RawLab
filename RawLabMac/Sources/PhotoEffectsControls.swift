import SwiftUI

struct PhotoEffectsControls: View {
    @ObservedObject var model: EditorModel
    let tool: AdjustmentParameter

    private var parameters: [PhotoEffectParameter] {
        PhotoEffectParameter.allCases.filter { $0.isVignette == (tool == .vignetteAmount) }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(tool.spec.title).font(.system(size: 12, weight: .medium))
                Spacer()
                Button { model.settings.resetEffect(tool) } label: {
                    Image(systemName: "arrow.counterclockwise").frame(width: 20, height: 20)
                }.buttonStyle(.borderless)
                    .help("重置\(tool.spec.title)").accessibilityLabel("重置\(tool.spec.title)")
                    .accessibilityIdentifier("effects.reset.\(tool.rawValue)")
                    .disabled(model.settings.isEffectDefault(tool))
            }
            HStack(spacing: 14) {
                ForEach(parameters) { parameter in
                    PhotoEffectControl(parameter: parameter, value: Binding(
                        get: { model.settings.effectSettings[keyPath: parameter.keyPath] },
                        set: { model.settings.setEffect(parameter, to: $0) }
                    ), onEditingChanged: model.setInteracting)
                    .disabled(isDisabled(parameter))
                }
            }
        }.frame(maxWidth: tool == .vignetteAmount ? 820 : 560)
            .padding(.horizontal, 16)
    }

    private func isDisabled(_ parameter: PhotoEffectParameter) -> Bool {
        if parameter == .vignetteHighlights { return model.settings.vignetteAmount >= 0 }
        if parameter == .vignetteAmount || parameter == .grainAmount { return false }
        return model.settings[keyPath: tool.spec.keyPath] == 0
    }
}

private struct PhotoEffectControl: View {
    let parameter: PhotoEffectParameter
    @Binding var value: Double
    let onEditingChanged: (Bool) -> Void
    @State private var draft = ""
    @State private var invalid = false
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                Text(parameter.title).font(.system(size: 11)).lineLimit(1)
                Spacer(minLength: 0)
                TextField(parameter.title, text: $draft)
                    .textFieldStyle(.roundedBorder).controlSize(.mini)
                    .monospacedDigit().multilineTextAlignment(.trailing)
                    .frame(width: 38).focused($editing)
                    .onSubmit(commit)
                    .onChange(of: editing) { _, focused in if !focused { commit() } }
                    .onExitCommand { draft = text(value); invalid = false; editing = false }
                    .overlay { if invalid { RoundedRectangle(cornerRadius: 4).stroke(.red, lineWidth: 1) } }
                    .accessibilityLabel("\(parameter.title)数值")
                    .accessibilityIdentifier("effects.value.\(parameter.rawValue)")
                    .help(invalid ? "请输入范围内的有效数字" : "\(text(parameter.range.lowerBound)) 至 \(text(parameter.range.upperBound))")
                Button {
                    value = parameter.defaultValue; draft = text(value); invalid = false
                } label: { Image(systemName: "arrow.counterclockwise").frame(width: 14, height: 18) }
                    .buttonStyle(.borderless).disabled(value == parameter.defaultValue && !invalid)
                    .help("重置\(parameter.title)").accessibilityLabel("重置\(parameter.title)")
            }.frame(height: 20)
            Slider(value: $value, in: parameter.range, step: 1, onEditingChanged: onEditingChanged)
                .controlSize(.small)
                .accessibilityLabel(parameter.title).accessibilityValue(text(value))
                .accessibilityIdentifier("effects.slider.\(parameter.rawValue)")
        }.frame(maxWidth: .infinity)
            .onAppear { draft = text(value) }
            .onChange(of: value) { _, current in draft = text(current); invalid = false }
    }

    private func text(_ value: Double) -> String { String(format: "%.0f", value) }
    private func commit() {
        if let number = Double(draft.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite {
            value = min(parameter.range.upperBound, max(parameter.range.lowerBound, number.rounded()))
            invalid = false
        } else { invalid = true }
        draft = text(value)
    }
}
