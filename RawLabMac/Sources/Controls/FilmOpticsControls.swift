import RawLabKit
import SwiftUI

struct MacFilmOpticsControls: View {
    enum Kind: String {
        case halation, bloom
        var isHalation: Bool { self == .halation }
        var title: String { L10n.text(isHalation ? "光晕" : "柔光") }
    }

    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: EditorModel
    let kind: Kind

    private var parameters: [FilmOpticsParameter] {
        FilmOpticsParameter.allCases.filter { $0.isHalation == kind.isHalation }
    }

    private var amountValue: Double {
        kind.isHalation ? model.settings.filmOpticsSettings.halationAmount : model.settings.filmOpticsSettings.bloomAmount
    }

    private var isDefault: Bool {
        kind.isHalation ? model.settings.filmOpticsSettings.isHalationDefault : model.settings.filmOpticsSettings.isBloomDefault
    }

    var body: some View {
        let _ = localizationLocale
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Button {
                    ParameterValueField.cancelPendingInputs()
                    if kind.isHalation { model.settings.filmOpticsSettings.resetHalation() }
                    else { model.settings.filmOpticsSettings.resetBloom() }
                } label: {
                    Image(systemName: "arrow.counterclockwise").frame(width: 28, height: 28)
                }.buttonStyle(.borderless)
                    .help(L10n.format("重置%@", kind.title))
                    .accessibilityLabel(L10n.format("重置%@", kind.title))
                    .accessibilityIdentifier("effects.resetGroup.\(kind.rawValue)")
                    .disabled(isDefault)
            }.frame(minHeight: 28)
            ForEach(parameters) { parameter in
                ParameterRow(title: parameter.title, value: Binding(
                    get: { model.settings.filmOpticsSettings[keyPath: parameter.keyPath] },
                    set: { model.settings.setFilmOptics(parameter, to: $0) }
                ), range: parameter.range, defaultValue: parameter.defaultValue,
                identifier: "effects.value.\(parameter.rawValue)",
                onEditingChanged: model.setInteracting, compact: true)
                    .disabled(isSecondary(parameter) && amountValue == 0)
            }
            if amountValue == 0 {
                Text(L10n.text("强度为 0，其他参数会保留。"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.top, 4)
                    .accessibilityIdentifier("effects.disabledReason.\(kind.rawValue)")
            }
        }.frame(maxWidth: 720)
    }

    private func isSecondary(_ parameter: FilmOpticsParameter) -> Bool {
        parameter != .halationAmount && parameter != .bloomAmount
    }
}
