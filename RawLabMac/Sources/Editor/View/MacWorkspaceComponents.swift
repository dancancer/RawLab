import SwiftUI
import AppKit

struct MacWorkspaceDivider: View {
    let width: CGFloat
    let limits: ClosedRange<CGFloat>
    let leading: Bool
    let onResize: (CGFloat, Bool) -> Void
    @State private var startWidth: CGFloat?

    var body: some View {
        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
            .frame(width: 6).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    let initial = startWidth ?? width
                    startWidth = initial
                    onResize(clamped(initial + value.translation.width * (leading ? 1 : -1)), false)
                }
                .onEnded { value in
                    let initial = startWidth ?? width
                    startWidth = nil
                    onResize(clamped(initial + value.translation.width * (leading ? 1 : -1)), true)
                })
            .onHover { (inside: Bool) in
                if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .accessibilityLabel(L10n.text(leading ? "浏览栏宽度" : "调整栏宽度"))
            .accessibilityValue(String(Int(width.rounded())))
            .accessibilityIdentifier(leading ? "workspace.library.resize" : "workspace.inspector.resize")
            .accessibilityAdjustableAction { direction in
                if direction == .increment { onResize(clamped(width + 12), true) }
                else if direction == .decrement { onResize(clamped(width - 12), true) }
            }
    }

    private func clamped(_ value: CGFloat) -> CGFloat { min(limits.upperBound, max(limits.lowerBound, value)) }
}

struct WorkspaceHistogram: View {
    let frame: RenderedImage?
    let before: Bool
    @Binding var clipping: Bool
    @Binding var expanded: Bool
    var hdrDisplay: HDRDisplayState?
    var collapsible = true
    var clippingEnabled = true
    @Environment(\.locale) private var localizationLocale
    private var source: String { L10n.text(before ? "调整前" : "调整后") }
    private var title: String { L10n.text(frame?.hdr == nil ? "RGB 直方图" : "HDR 亮度直方图") }

    var body: some View {
        let _ = localizationLocale
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if collapsible {
                    Button { expanded.toggle() } label: {
                        Label(title, systemImage: expanded ? "chevron.down" : "chevron.right")
                            .frame(minHeight: 24)
                    }.buttonStyle(.plain).font(.caption.weight(.semibold))
                        .help(L10n.text(expanded ? "收起直方图" : "展开直方图"))
                        .accessibilityIdentifier("histogram.toggle")
                        .accessibilityValue(L10n.text(expanded ? "已展开" : "已收起"))
                } else {
                    Text(title).font(.caption.weight(.semibold))
                }
                Spacer(minLength: 4)
                Text(source).font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel(title + " · " + source).accessibilityIdentifier("histogram.source")
                Toggle(isOn: $clipping) { Image(systemName: "exclamationmark.triangle") }
                    .toggleStyle(.button).buttonStyle(.borderless).tint(.yellow)
                    .help(L10n.text("显示输出高光与黑位裁切"))
                    .accessibilityLabel(L10n.text("显示裁切提示"))
                    .disabled(!clippingEnabled || frame?.clipping == nil)
            }
            if expanded || !collapsible {
                Group {
                    if let hdr = frame?.hdr {
                        HDRLuminanceHistogram(statistics: hdr.statistics, headroom: hdrDisplay?.headroom ?? 1)
                    } else {
                        HistogramView(bins: frame?.histogram ?? [])
                    }
                }.frame(height: 68)
                    .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
                    .accessibilityLabel(title + " · " + source).accessibilityIdentifier("histogram.plot")
                statistics
            }
        }.padding(.horizontal, 12).padding(.vertical, 5)
    }

    @ViewBuilder private var statistics: some View {
        if let hdr = frame?.hdr {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.format("参考白以上 %@", percent(Double(hdr.statistics.aboveWhite) / Double(hdr.statistics.pixels))))
                Text(L10n.format("内容容量 %@ EV", String(format: "%.2f", log2(Double(hdr.statistics.headroom)))))
            }.font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        } else if frame?.histogram.isEmpty == false {
            ViewThatFits(in: .horizontal) {
                HStack { clippingStatistics }
                VStack(alignment: .leading) { clippingStatistics }
            }.font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        } else {
            Text(L10n.text("统计不可用")).font(.caption2).foregroundStyle(.secondary)
                .accessibilityIdentifier("histogram.unavailable")
        }
    }

    @ViewBuilder private var clippingStatistics: some View {
        Text(L10n.format("高光 %@", percent(frame?.highlights)))
        Text(L10n.format("黑位 %@", percent(frame?.shadows)))
    }

    private func percent(_ value: Double?) -> String { value.map { String(format: "%.2f%%", $0 * 100) } ?? "--" }
}
