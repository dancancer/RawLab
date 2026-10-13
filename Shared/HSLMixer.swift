import SwiftUI

struct HSLMixer: View {
    @Environment(\.locale) private var localizationLocale
    @Binding var settings: HSLSettings
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var channel = 0
    private let colors: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink]
    #if os(macOS)
    private let controlSize = 28.0
    private let rowHeight = 24.0
    #else
    private let controlSize = 44.0
    private let rowHeight = 44.0
    #endif

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(0..<8) { index in
                        Button { channel = index } label: {
                            Circle().fill(colors[index]).frame(width: 22, height: 22)
                                .overlay { Circle().strokeBorder(channel == index ? Color.primary : Color.clear, lineWidth: 3) }
                                .frame(width: controlSize, height: controlSize)
                        }.buttonStyle(.plain).accessibilityLabel(L10n.text(HSLSettings.channelNames[index]))
                            .accessibilityAddTraits(channel == index ? .isSelected : [])
                            .accessibilityIdentifier("hsl.channel.\(index)")
                    }
                }
            }.scrollIndicators(.hidden)
            ForEach(HSLAxis.allCases) { axis in
                HStack(spacing: 10) {
                    Text(axis.title).font(.caption).lineLimit(1).minimumScaleFactor(0.8).frame(width: 72, alignment: .leading)
                    Slider(value: Binding(get: { settings.value(axis, channel: channel) },
                        set: { settings.set(axis, channel: channel, value: $0) }),
                        in: -100...100, step: 1, onEditingChanged: onEditingChanged)
                        .accessibilityLabel("\(L10n.text(HSLSettings.channelNames[channel])) \(axis.title)")
                        .accessibilityIdentifier("hsl.\(axis.rawValue)")
                    Text(String(format: "%+.0f", settings.value(axis, channel: channel)))
                        .font(.caption.monospacedDigit()).frame(width: 38, alignment: .trailing)
                }.frame(minHeight: rowHeight)
            }
            HStack {
                Text(L10n.text(HSLSettings.channelNames[channel])).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { settings.reset(channel: channel) } label: { Image(systemName: "arrow.counterclockwise") }
                    .frame(minWidth: controlSize, minHeight: controlSize).accessibilityLabel(L10n.text("重置当前颜色"))
                    .disabled(HSLAxis.allCases.allSatisfy { settings.value($0, channel: channel) == 0 })
                Button { settings.reset() } label: { Image(systemName: "arrow.uturn.backward.circle") }
                    .frame(minWidth: controlSize, minHeight: controlSize).accessibilityLabel(L10n.text("重置 HSL"))
                    .disabled(settings.isIdentity)
            }
        }.padding(.horizontal, 16).tint(.yellow)
    }
}
