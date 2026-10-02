import SwiftUI
import UIKit

struct AdjustmentToolLabel: View {
    @ScaledMetric(relativeTo: .title3) private var diameter = 44.0
    let title: String
    let symbol: String
    let selected: Bool
    let progress: Double
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().fill(selected ? Color.yellow.opacity(0.12) : Color.white.opacity(0.04))
                Circle().strokeBorder(selected ? Color.yellow.opacity(0.5) : Color.white.opacity(0.25), lineWidth: 1)
                if progress != 0 {
                    Circle().trim(from: 0, to: abs(progress))
                        .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .scaleEffect(x: progress < 0 ? -1 : 1, y: 1)
                }
                Image(systemName: symbol).font(.title3)
            }
            .frame(width: diameter, height: diameter)
            Text(title).font(.caption).lineLimit(1)
            Circle().fill(progress != 0 ? Color.yellow : Color.clear).frame(width: 3, height: 3)
        }
        .foregroundStyle(selected ? Color.yellow : Color.primary)
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

struct FilmLabel: View {
    @ScaledMetric(relativeTo: .caption) private var labelHeight = 30.0
    @ScaledMetric(relativeTo: .caption) private var minimumWidth = 82.0
    let name: String
    let artworkName: String?
    let neutral: Bool
    let selected: Bool
    let imageSize: CGFloat

    var body: some View {
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
                .frame(width: max(minimumWidth, imageSize + 18) - 12)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: labelHeight)
        }
        .padding(6)
        .frame(width: max(minimumWidth, imageSize + 18))
        .foregroundStyle(selected ? Color.yellow : Color.primary)
        .background(selected ? Color.yellow.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.yellow : .clear, lineWidth: 1) }
        .accessibilityHidden(true)
    }

    private static let artwork: [String: UIImage] = {
        var images: [String: UIImage] = [:]
        for name in FilmPresentation.artworkNames.values {
            if let url = Bundle.main.url(forResource: name, withExtension: "png"),
               let image = UIImage(contentsOfFile: url.path) {
                images[name] = image
            }
        }
        return images
    }()
}

struct DefaultValueMarker: View {
    let range: ClosedRange<Double>
    let value: Double

    var body: some View {
        GeometryReader { geometry in
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            Circle().fill(.yellow).frame(width: 3, height: 3)
                .position(x: 14 + (geometry.size.width - 28) * fraction, y: 2)
        }
        .accessibilityHidden(true)
    }
}

struct FloatingHistogram: View {
    let values: [CGFloat]
    @Binding var expanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chart.bar.xaxis")
                    if expanded { Spacer(minLength: 0) }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .font(.caption)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("亮度直方图")
            .accessibilityValue(expanded ? "已展开" : "已收起")
            .accessibilityIdentifier("editor.histogram")
            if expanded {
                HistogramView(values: values)
                    .frame(height: 54)
                    .padding(.horizontal, 12).padding(.bottom, 12)
                    .accessibilityLabel("当前预览的亮度分布")
            }
        }
        .frame(width: expanded ? nil : 76)
        .foregroundStyle(.white)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.12), lineWidth: 1) }
    }
}

struct HistogramView: View {
    let values: [CGFloat]

    var body: some View {
        Canvas { context, size in
            guard let peak = values.max(), peak > 0 else { return }
            let barWidth = size.width / CGFloat(values.count)
            var path = Path()
            for (index, value) in values.enumerated() {
                let height = (value / peak) * size.height
                path.addRect(CGRect(x: CGFloat(index) * barWidth, y: size.height - height,
                                    width: barWidth, height: height))
            }
            context.fill(path, with: .color(.white.opacity(0.75)))
        }
    }
}
