import SwiftUI
import AppKit

struct MacHSLMixer: View {
    @Environment(\.locale) private var localizationLocale
    @Binding var settings: HSLSettings
    var onEditingChanged: (Bool) -> Void = { _ in }
    @Binding var channel: Int
    var onCancelTarget: () -> Void = {}
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var focusedChannel: Int?
    private let colors: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink]

    init(settings: Binding<HSLSettings>, channel: Binding<Int> = .constant(0),
         onEditingChanged: @escaping (Bool) -> Void = { _ in }, onCancelTarget: @escaping () -> Void = {}) {
        _settings = settings; _channel = channel
        self.onEditingChanged = onEditingChanged; self.onCancelTarget = onCancelTarget
    }

    var body: some View {
        let _ = localizationLocale
        VStack(spacing: 0) {
            channels
            Text(L10n.format("当前通道 %@，修改仅作用于该颜色。", L10n.text(HSLSettings.channelNames[channel])))
                .font(.system(size: ParameterRow.textSize(for: dynamicTypeSize, base: 11))).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                .accessibilityIdentifier("hsl.scope")
            ForEach(HSLAxis.allCases) { axis in
                parameterRow(axis)
            }
        }.frame(maxWidth: 720).tint(.yellow)
    }

    private var channels: some View {
        HStack(spacing: 2) {
            ForEach(colors.indices, id: \.self) { index in
                let title = L10n.text(HSLSettings.channelNames[index])
                let changed = HSLAxis.allCases.contains { settings.value($0, channel: index) != 0 }
                Button { selectChannel(index) } label: {
                    VStack(spacing: 2) {
                        Circle().fill(colors[index]).frame(width: 18, height: 18)
                            .padding(3)
                            .overlay { Circle().strokeBorder(channel == index ? Color.primary : Color.clear, lineWidth: 2) }
                        Circle().fill(changed ? Color.yellow : Color.clear).frame(width: 3, height: 3)
                    }
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).focusable().focused($focusedChannel, equals: index)
                    .onMoveCommand { direction in
                        switch direction {
                        case .left: selectChannel((index + colors.count - 1) % colors.count)
                        case .right: selectChannel((index + 1) % colors.count)
                        default: break
                        }
                    }
                    .help(title)
                    .accessibilityLabel(title)
                    .accessibilityValue(changed ? L10n.text("已调整") : "")
                    .accessibilityAddTraits(channel == index ? .isSelected : [])
                    .accessibilityIdentifier("hsl.channel.\(index)")
            }
        }
    }

    private func selectChannel(_ index: Int) {
        onCancelTarget()
        ParameterValueField.cancelPendingInputs()
        channel = index
        focusedChannel = index
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
