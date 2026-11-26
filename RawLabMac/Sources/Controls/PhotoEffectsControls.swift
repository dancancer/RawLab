import RawLabKit
import SwiftUI
import AppKit

struct PhotoEffectsControls: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: EditorModel
    let tool: AdjustmentParameter
    var horizontalPadding: CGFloat = 16
    var onPreferredHeight: (CGFloat) -> Void = { _ in }
    var onReset: () -> Void = {}
    @State private var advanced = false

    private var isVignette: Bool { tool == .vignetteAmount }
    private var parameters: [PhotoEffectParameter] {
        PhotoEffectParameter.allCases.filter { parameter in
            parameter.isVignette == isVignette && (!isVignette || advanced || parameter == .vignetteAmount)
        }
    }

    var body: some View {
        let _ = localizationLocale
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if isVignette {
                    Button(L10n.text(advanced ? "收起暗角参数" : "展开暗角参数")) {
                        ParameterValueField.cancelPendingInputs()
                        advanced.toggle()
                    }
                        .buttonStyle(.borderless).font(.system(size: 11))
                        .accessibilityIdentifier("effects.advanced.vignette")
                }
                Spacer(minLength: 0)
                Button {
                    ParameterValueField.cancelPendingInputs()
                    onReset()
                } label: {
                    Image(systemName: "arrow.counterclockwise").frame(width: 28, height: 28)
                }.buttonStyle(.borderless)
                    .help(L10n.format("重置%@", tool.spec.title))
                    .accessibilityLabel(L10n.format("重置%@", tool.spec.title))
                    .accessibilityIdentifier("effects.resetGroup.\(tool.rawValue)")
                    .disabled(model.settings.isEffectDefault(tool))
            }.frame(minHeight: 28)
            if !isVignette && !model.settings.isHDREditing {
                grainFilmPhysicsPickers
            }
            ForEach(parameters) { parameter in
                ParameterRow(title: parameter == .grainAmount ? L10n.text("颗粒强度") : parameter.title,
                             value: Binding(
                    get: { model.settings.editingEffectValue(parameter) },
                    set: { value in
                        if isVignette { model.settings.setEffect(parameter, to: value) }
                        else { model.settings.setGrainEffect(parameter, to: value) }
                    }
                ), range: parameter.range, defaultValue: parameter.defaultValue,
                identifier: "effects.value.\(parameter.rawValue)", onEditingChanged: model.setInteracting)
                    .disabled(isDisabled(parameter))
            }
            if let reason = disabledReason {
                Text(reason).font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.top, 4)
                    .accessibilityIdentifier("effects.disabledReason.\(tool.rawValue)")
            }
        }.frame(maxWidth: 720).padding(.horizontal, horizontalPadding)

    }

    private var grainFilmPhysicsPickers: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(L10n.text("颗粒曲线"), selection: Binding(
                get: { model.settings.effectSettings.grainToneCurve },
                set: { curve in
                    ParameterValueField.cancelPendingInputs()
                    model.settings.applyGrainToneCurve(curve)
                }
            )) {
                ForEach(GrainToneCurve.allCases) { curve in
                    Text(curve.title).tag(curve)
                }
            }.pickerStyle(.menu).controlSize(.small)
                .id(localizationLocale.identifier)
                .accessibilityIdentifier("effects.grain.toneCurve")
            Picker(L10n.text("颗粒画幅"), selection: Binding(
                get: { model.settings.effectSettings.grainFormatPreset },
                set: { preset in
                    ParameterValueField.cancelPendingInputs()
                    model.settings.applyGrainFormatPreset(preset)
                }
            )) {
                ForEach(GrainFormatPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }.pickerStyle(.menu).controlSize(.small)
                .id(localizationLocale.identifier)
                .accessibilityIdentifier("effects.grain.formatPreset")
        }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 4)
    }

    private var disabledReason: String? {
        if model.settings[keyPath: tool.spec.keyPath] == 0 {
            return L10n.text("强度为 0，其他参数会保留。")
        }
        if isVignette && advanced && model.settings.vignetteAmount >= 0 {
            return L10n.text("仅在暗角强度为负值时可用。")
        }
        return nil
    }

    private func isDisabled(_ parameter: PhotoEffectParameter) -> Bool {
        if parameter == .vignetteHighlights { return model.settings.vignetteAmount >= 0 }
        if parameter == .vignetteAmount || parameter == .grainAmount { return false }
        return model.settings[keyPath: tool.spec.keyPath] == 0
    }
}
