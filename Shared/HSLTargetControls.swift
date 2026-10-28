import SwiftUI

struct HSLTargetControls: View {
    @Binding var enabled: Bool
    @Binding var axis: HSLAxis
    var sample: HSLTargetSample?
    var waiting = false
    var notice: HSLTargetAvailability?
    var onCancel: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    onCancel(); enabled.toggle()
                } label: { Label(L10n.text("目标调整"), systemImage: "scope") }
                    .buttonStyle(.bordered).tint(enabled ? .yellow : .secondary)
                    .accessibilityIdentifier("hsl.target")
                    .accessibilityValue(L10n.text(enabled ? "开启" : "关闭"))
                if enabled {
                    Picker(L10n.text("调整轴"), selection: Binding(get: { axis }, set: { onCancel(); axis = $0 })) {
                        ForEach(HSLAxis.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("hsl.target.axis")
                }
            }
            if enabled {
                Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("hsl.target.status")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var status: String {
        if waiting { return L10n.text("正在取色…") }
        switch notice ?? sample?.availability {
        case .nearGray: return L10n.text("颜色接近灰色，无法选择色域。")
        case .outside: return L10n.text("请在调整后的照片区域取色。")
        case .stale: return L10n.text("预览已变化，请重新取色。")
        case .nonfinite: return L10n.text("此像素不可取样。")
        case .failed: return L10n.text("取色失败，请重试。")
        default:
            if let sample, sample.isUsable {
                return L10n.format("受影响色域：%@", sample.channels.map { L10n.text(HSLSettings.channelNames[$0]) }.joined(separator: " · "))
            }
            #if canImport(UIKit)
            return L10n.text("在照片上取色并上下拖动")
            #else
            return L10n.text("上下拖动调整，方向键微调，Esc 取消")
            #endif
        }
    }
}

struct HSLTargetCanvasControls: View {
    let axis: HSLAxis
    let onExit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { title; exitButton }
                VStack(alignment: .leading, spacing: 4) { title; exitButton }
            }
            Text(L10n.text("拖动照片调整颜色；退出目标模式后可平移。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10).frame(maxWidth: 560, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain).accessibilityIdentifier("hsl.target.canvas")
    }
    private var title: some View {
        Label(L10n.format("目标调整：%@", axis.title), systemImage: "scope")
            .font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
    }
    private var exitButton: some View {
        Button(L10n.text("退出目标调整"), action: onExit)
            .buttonStyle(.bordered)
            #if canImport(UIKit)
            .frame(minHeight: 44)
            #endif
            .accessibilityIdentifier("hsl.target.exit")
    }
}
