import SwiftUI
import AppKit

struct MacHSLMixer: View {
    @Environment(\.locale) private var localizationLocale
    @Binding var settings: HSLSettings
    var onEditingChanged: (Bool) -> Void = { _ in }
    @Binding var channel: Int
    var onCancelTarget: () -> Void = {}
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var channelFontSize: CGFloat { ParameterRow.textSize(for: dynamicTypeSize, base: 11) }
    private let colors: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink]

    init(settings: Binding<HSLSettings>, channel: Binding<Int> = .constant(0),
         onEditingChanged: @escaping (Bool) -> Void = { _ in }, onCancelTarget: @escaping () -> Void = {}) {
        _settings = settings; _channel = channel
        self.onEditingChanged = onEditingChanged; self.onCancelTarget = onCancelTarget
    }

    var body: some View {
        let _ = localizationLocale
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                channels.padding(.horizontal, 2)
            }.frame(height: 33 + ceil(channelFontSize * 1.25)).padding(.bottom, 4)
            ForEach(HSLAxis.allCases) { axis in
                parameterRow(axis)
            }
            Text(L10n.format("当前通道 %@，修改仅作用于该颜色。", L10n.text(HSLSettings.channelNames[channel])))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.top, 4)
                .accessibilityIdentifier("hsl.scope")
        }.frame(maxWidth: 720).tint(.yellow)
    }

    private var channels: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(0..<8) { index in
                Button {
                    onCancelTarget()
                    ParameterValueField.cancelPendingInputs()
                    channel = index
                } label: {
                    VStack(spacing: 2) {
                        Circle().fill(colors[index]).frame(width: 20, height: 20)
                            .padding(3)
                            .overlay { Circle().strokeBorder(channel == index ? Color.primary : Color.clear, lineWidth: 2) }
                        Text(L10n.text(HSLSettings.channelNames[index]))
                            .font(.system(size: channelFontSize)).multilineTextAlignment(.center)
                            .fixedSize()
                        Circle().fill(HSLAxis.allCases.contains { settings.value($0, channel: index) != 0 } ? Color.yellow : Color.clear)
                            .frame(width: 3, height: 3)
                    }.frame(minWidth: 40)
                }.buttonStyle(.plain)
                    .accessibilityLabel(L10n.text(HSLSettings.channelNames[index]))
                    .accessibilityValue(HSLAxis.allCases.contains { settings.value($0, channel: index) != 0 } ? L10n.text("已调整") : "")
                    .accessibilityAddTraits(channel == index ? .isSelected : [])
                    .accessibilityIdentifier("hsl.channel.\(index)")
            }
        }.fixedSize(horizontal: true, vertical: false)
    }

    private func directionHelp(_ axis: HSLAxis) -> String {
        switch axis {
        case .hue: return L10n.text("色相：向相邻颜色偏移。")
        case .saturation: return L10n.text("饱和度：从灰色到彩色。")
        case .lightness: return L10n.text("明度：从暗到亮。")
        }
    }

    private func trackColors(_ axis: HSLAxis, channel: Int) -> [Color] {
        let color = NSColor(colors[channel]).usingColorSpace(.deviceRGB) ?? .red
        switch axis {
        case .hue:
            let hue = color.hueComponent
            return [-1.0 / 12, 0, 1.0 / 12].map {
                Color(nsColor: NSColor(hue: (hue + $0 + 1).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.9, alpha: 1))
            }
        case .saturation: return [.gray, colors[channel]]
        case .lightness: return [.black, colors[channel], .white]
        }
    }

    private func parameterRow(_ axis: HSLAxis) -> some View {
        let targetChannel = channel
        return ParameterRow(title: axis.title, value: Binding(
            get: { settings.value(axis, channel: targetChannel) },
            set: { settings = MacHSLPrecision.setting($0, axis: axis, channel: targetChannel, in: settings) }
        ), range: -100...100, defaultValue: 0,
        identifier: "hsl.value.\(axis.rawValue)", onEditingChanged: onEditingChanged,
        trackColors: trackColors(axis, channel: targetChannel), directionHelp: directionHelp(axis),
        accessibilityTitle: L10n.format("%@ · %@", L10n.text(HSLSettings.channelNames[targetChannel]), axis.title), inputScope: String(targetChannel))
            .id(targetChannel)
    }
}
