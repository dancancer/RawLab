import RawLabKit
import SwiftUI

struct IOSBwMixerControls: View {
    @Binding var settings: BwMixerSettings
    let onEditingChanged: (Bool) -> Void

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
        VStack(alignment: .leading, spacing: 6) {
            Toggle(L10n.text("启用黑白"), isOn: $settings.enabled)
                .font(.subheadline)
                .frame(minHeight: 44)
                .accessibilityIdentifier("bwMixer.enabled")
            Text(L10n.text("黑白混合"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Self.channels) { channel in
                AdjustmentControl(
                    title: L10n.text(channel.titleKey),
                    value: channelBinding(channel.keyPath),
                    range: Self.spec.channelRange,
                    step: 1,
                    defaultValue: Self.spec.channelDefault,
                    formatter: Self.formatValue,
                    identifier: "bwMixer.\(channel.id)",
                    compactNumber: false,
                    compactDecimals: nil,
                    onEditingChanged: onEditingChanged
                )
            }
            .disabled(!settings.enabled)
        }
        .padding(.horizontal, 16)
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

    private static func formatValue(_ value: Double) -> String {
        String(format: "%.0f", locale: L10n.locale, value)
    }
}
