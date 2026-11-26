import RawLabKit
import SwiftUI

struct MacBwMixerControls: View {
    @Environment(\.locale) private var localizationLocale
    @Binding var settings: BwMixerSettings
    let resetVersion: Int
    let onEditingChanged: (Bool) -> Void
    let onReset: () -> Void

    struct ChannelDescriptor: Identifiable {
        let id: String
        let titleKey: String
        let keyPath: WritableKeyPath<BwMixerChannelWeights, Double>
    }

    static let channels: [ChannelDescriptor] = [
        ChannelDescriptor(id: "red", titleKey: "红", keyPath: \.red),
        ChannelDescriptor(id: "orange", titleKey: "橙", keyPath: \.orange),
        ChannelDescriptor(id: "yellow", titleKey: "黄", keyPath: \.yellow),
        ChannelDescriptor(id: "green", titleKey: "绿", keyPath: \.green),
        ChannelDescriptor(id: "aqua", titleKey: "青", keyPath: \.aqua),
        ChannelDescriptor(id: "blue", titleKey: "蓝", keyPath: \.blue),
        ChannelDescriptor(id: "purple", titleKey: "紫", keyPath: \.purple),
        ChannelDescriptor(id: "magenta", titleKey: "洋红", keyPath: \.magenta),
    ]

    private static let spec = AdjustmentFieldSpec.SubFields.BwMixer.self

    var body: some View {
        let _ = localizationLocale
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(L10n.text("启用黑白"), isOn: Binding(
                    get: { settings.enabled },
                    set: { enabled in
                        ParameterValueField.cancelPendingInputs()
                        settings.enabled = enabled
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 12))
                .accessibilityIdentifier("bwMixer.enabled")
                Spacer(minLength: 0)
                Button(action: reset) {
                    Image(systemName: "arrow.counterclockwise").frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(L10n.text("重置"))
                .accessibilityLabel(L10n.text("重置"))
                .accessibilityIdentifier("bwMixer.reset")
                .disabled(settings.isDefault)
            }
            Text(L10n.text("黑白混合"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            ForEach(Self.channels) { channel in
                ParameterRow(
                    title: L10n.text(channel.titleKey),
                    value: channelBinding(channel.keyPath),
                    range: Self.spec.channelRange,
                    defaultValue: Self.spec.channelDefault,
                    identifier: "bwMixer.value.\(channel.id)",
                    onEditingChanged: onEditingChanged
                )
                .id("bwMixer.\(channel.id).\(resetVersion)")
            }
            .disabled(!settings.enabled)
        }
        .frame(maxWidth: 720)
    }

    private func channelBinding(_ keyPath: WritableKeyPath<BwMixerChannelWeights, Double>) -> Binding<Double> {
        let bounds = Self.spec.channelRange
        return Binding(
            get: { settings.mixer[keyPath: keyPath] },
            set: { value in
                guard value.isFinite else { return }
                settings.mixer[keyPath: keyPath] = min(max(value, bounds.lowerBound), bounds.upperBound)
            }
        )
    }

    private func reset() {
        ParameterValueField.cancelPendingInputs()
        onReset()
    }
}
