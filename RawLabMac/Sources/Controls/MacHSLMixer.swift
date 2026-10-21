import SwiftUI
import AppKit

struct MacHSLMixer: View {
    @Environment(\.locale) private var localizationLocale
    @Binding var settings: HSLSettings
    var onEditingChanged: (Bool) -> Void = { _ in }
    @Binding var channel: Int
    var onReset: (EditorResetScope) -> Void = { _ in }
    @State private var resetRevision = 0
    private let colors: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink]

    init(settings: Binding<HSLSettings>, channel: Binding<Int> = .constant(0),
         onEditingChanged: @escaping (Bool) -> Void = { _ in }, onReset: @escaping (EditorResetScope) -> Void = { _ in }) {
        _settings = settings; _channel = channel
        self.onEditingChanged = onEditingChanged; self.onReset = onReset
    }

    var body: some View {
        let _ = localizationLocale
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    channels
                    Spacer(minLength: 0)
                    resetActions
                }
                VStack(spacing: 0) {
                    channels
                    resetActions.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }.padding(.bottom, 4)
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
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    channel = index
                } label: {
                    VStack(spacing: 2) {
                        Circle().fill(colors[index]).frame(width: 20, height: 20)
                            .padding(3)
                            .overlay { Circle().strokeBorder(channel == index ? Color.primary : Color.clear, lineWidth: 2) }
                        Text(L10n.text(HSLSettings.channelNames[index]))
                            .font(.system(size: 11)).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Circle().fill(HSLAxis.allCases.contains { settings.value($0, channel: index) != 0 } ? Color.yellow : Color.clear)
                            .frame(width: 3, height: 3)
                    }.frame(minWidth: 34, maxWidth: 48)
                }.buttonStyle(.plain)
                    .accessibilityLabel(L10n.text(HSLSettings.channelNames[index]))
                    .accessibilityValue(HSLAxis.allCases.contains { settings.value($0, channel: index) != 0 } ? L10n.text("已调整") : "")
                    .accessibilityAddTraits(channel == index ? .isSelected : [])
                    .accessibilityIdentifier("hsl.channel.\(index)")
            }
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var resetActions: some View {
        HStack(spacing: 12) {
            Button(L10n.text("重置当前颜色")) {
                NSApp.keyWindow?.makeFirstResponder(nil)
                onReset(.hslColor(channel))
                resetRevision += 1
            }
                .disabled(HSLAxis.allCases.allSatisfy { settings.value($0, channel: channel) == 0 })
                .accessibilityIdentifier("hsl.reset.current")
            Button(L10n.text("重置 HSL")) {
                NSApp.keyWindow?.makeFirstResponder(nil)
                onReset(.hslAll)
                resetRevision += 1
            }
                .disabled(settings.isIdentity)
                .accessibilityIdentifier("hsl.reset.all")
        }.buttonStyle(.borderless).font(.system(size: 11))
            .fixedSize(horizontal: true, vertical: false).frame(minHeight: 24)
    }

    private func parameterRow(_ axis: HSLAxis) -> some View {
        let targetChannel = channel
        return ParameterRow(title: axis.title, value: Binding(
            get: { settings.value(axis, channel: targetChannel) },
            set: { settings = MacHSLPrecision.setting($0, axis: axis, channel: targetChannel, in: settings) }
        ), range: -100...100, defaultValue: 0,
        identifier: "hsl.value.\(axis.rawValue)", onEditingChanged: onEditingChanged)
            .id("\(targetChannel).\(resetRevision)")
    }
}
