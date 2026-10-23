import SwiftUI
import UIKit

struct AdjustmentToolLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let symbol: String
    let selected: Bool
    let progress: Double
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.body).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            Text(title).font(dynamicTypeSize.isAccessibilitySize ? .body : .subheadline)
                .fixedSize(horizontal: true, vertical: false)
            Circle().fill(progress != 0 ? Color.yellow : .clear).frame(width: 3, height: 3)
        }
        .padding(.horizontal, 8).frame(minWidth: 44, minHeight: max(44, height))
        .foregroundStyle(selected ? Color.yellow : Color.primary)
        .background(selected ? Color.yellow.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle()).accessibilityElement(children: .ignore).accessibilityLabel(title)
    }
}

struct FilmLabel: View {
    @Environment(\.locale) private var localizationLocale
    @ScaledMetric(relativeTo: .caption) private var labelHeight = 30.0
    @ScaledMetric(relativeTo: .caption) private var minimumWidth = 82.0
    @ScaledMetric(relativeTo: .caption) private var bundledLookWidth = 138.0
    @ScaledMetric(relativeTo: .caption) private var bundledLookLabelHeight = 34.0
    let name: String
    let artworkName: String?
    let neutral: Bool
    let selected: Bool
    let imageSize: CGFloat

    var body: some View {
        let _ = localizationLocale
        let isBundledLook = BundledLook.all.contains(where: { $0.name == name })
        let itemWidth = max(minimumWidth, imageSize + 18,
                            isBundledLook ? bundledLookWidth : 0)
        VStack(spacing: 6) {
            Group {
                if let artworkName, let image = Self.artwork[artworkName] {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: neutral ? "circle.lefthalf.filled" : "camera.filters")
                        .font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(width: imageSize, height: imageSize)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(name).font(.caption)
                .lineLimit(2).multilineTextAlignment(.center)
                .frame(width: itemWidth - 12)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: isBundledLook ? bundledLookLabelHeight : labelHeight)
        }
        .padding(6)
        .frame(width: itemWidth)
        .foregroundStyle(selected ? Color.yellow : Color.primary)
        .background(selected ? Color.yellow.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.yellow : .clear, lineWidth: 1) }
        .accessibilityHidden(true)
    }

    private static let artwork: [String: UIImage] = {
        var images: [String: UIImage] = [:]
        for name in FilmPresentation.artworkNames.values {
            if let url = Bundle.main.url(forResource: name, withExtension: "png")
                ?? Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "BundledLooks/Artwork"),
               let image = UIImage(contentsOfFile: url.path) {
                images[name] = image
            }
        }
        return images
    }()
}

struct DefaultValueMarker: View {
    @Environment(\.locale) private var localizationLocale
    let range: ClosedRange<Double>
    let value: Double

    var body: some View {
        let _ = localizationLocale
        GeometryReader { geometry in
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            Circle().fill(.yellow).frame(width: 3, height: 3)
                .position(x: 14 + (geometry.size.width - 28) * fraction, y: 2)
        }
        .accessibilityHidden(true)
    }
}

struct FloatingHistogram: View {
    @Environment(\.locale) private var localizationLocale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let histogram: Sony2FujiProcessor.RGBHistogram?
    let showingBefore: Bool
    let availableSize: CGSize
    @Binding var expanded: Bool

    private var source: String { L10n.text(showingBefore ? "调整前" : "调整后") }
    private var usesPopover: Bool { dynamicTypeSize.isAccessibilitySize || availableSize.height < 160 }
    private var inlineExpanded: Bool { expanded && !usesPopover }

    var body: some View {
        let _ = localizationLocale
        VStack(spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chart.bar.xaxis")
                    if inlineExpanded { Spacer(minLength: 0) }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .font(.caption)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("RGB 直方图"))
            .accessibilityValue(([expanded ? L10n.text("已展开") : L10n.text("已收起"), source]
                + (histogram == nil ? [L10n.text("统计不可用")] : [])).joined(separator: ", "))
            .accessibilityHint(L10n.text(expanded ? "收起直方图" : "展开直方图"))
            .accessibilityIdentifier("editor.histogram")
            if inlineExpanded {
                contents(graphHeight: 54).padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .frame(width: inlineExpanded ? nil : 76)
        .foregroundStyle(.white)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.12), lineWidth: 1) }
        // 短画布或辅助字号无法容纳图表时，完整内容在原生浮层中展开。
        .popover(isPresented: Binding(get: { expanded && usesPopover }, set: { expanded = $0 }),
                 attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            VStack(spacing: 12) {
                Button { expanded = false } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel(L10n.text("收起直方图"))
                .accessibilityIdentifier("editor.histogram.close")
                ScrollView {
                    VStack(spacing: 12) {
                        Text(L10n.text("RGB 直方图")).font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        contents(graphHeight: 80)
                    }
                }
                .accessibilityIdentifier("editor.histogram.scroll")
            }
            .padding(16)
            .frame(width: min(320, availableSize.width - 24), height: 300)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("editor.histogram.popover")
            .presentationCompactAdaptation(.popover)
        }
    }

    private func contents(graphHeight: CGFloat) -> some View {
        VStack(spacing: 6) {
            Text(source).font(.caption).fixedSize(horizontal: false, vertical: true)
            Group {
                if let histogram {
                    HistogramView(histogram: histogram).frame(height: graphHeight)
                } else {
                    Text(L10n.text("统计不可用")).font(.caption)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: graphHeight)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(source)
            .accessibilityValue(histogram == nil ? L10n.text("统计不可用") : "R, G, B")
            .accessibilityIdentifier("editor.histogram.plot")
        }
    }
}

struct HistogramView: View {
    let histogram: Sony2FujiProcessor.RGBHistogram

    var body: some View {
        Canvas { context, size in
            let barWidth = size.width / 256
            for bin in 0..<256 {
                for segment in histogram.segments(at: bin) {
                    let channels = segment.channels
                    let color = channels == 7 ? Color(white: 0.75) : Color(
                        red: channels & 1 == 0 ? 0 : 1,
                        green: channels & 2 == 0 ? 0 : 1,
                        blue: channels & 4 == 0 ? 0 : 1)
                    let rect = CGRect(x: CGFloat(bin) * barWidth, y: (1 - segment.upper) * size.height,
                                      width: barWidth, height: (segment.upper - segment.lower) * size.height)
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
    }
}
