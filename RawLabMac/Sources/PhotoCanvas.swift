import SwiftUI

struct PhotoCanvas: View {
    let frame: RenderedImage
    let viewport: PhotoViewport
    let sourceWidth: Int
    @Binding var pan: CGSize
    let clipping: Bool
    @Environment(\.displayScale) private var displayScale
    @State private var dragOrigin: CGSize?

    var body: some View {
        GeometryReader { geometry in
            let fit = max(0.001, min((geometry.size.width - 24) / CGFloat(frame.image.width),
                                     (geometry.size.height - 24) / CGFloat(frame.image.height)))
            let factor = viewport.factor(fit: fit, displayScale: displayScale,
                                         sourceWidth: CGFloat(sourceWidth), renderedWidth: CGFloat(frame.image.width))
            ZStack {
                Color.clear
                Image(decorative: frame.image, scale: 1).resizable().interpolation(.high)
                    .frame(width: CGFloat(frame.image.width) * factor, height: CGFloat(frame.image.height) * factor)
                    .overlay {
                        if clipping { Image(decorative: frame.clipping, scale: 1).resizable().interpolation(.none) }
                    }.offset(x: pan.width, y: pan.height)
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped().contentShape(Rectangle())
                .gesture(DragGesture().onChanged { value in
                    if dragOrigin == nil { dragOrigin = pan }
                    pan = CGSize(width: dragOrigin!.width + value.translation.width,
                                 height: dragOrigin!.height + value.translation.height)
                }.onEnded { _ in dragOrigin = nil })
        }
    }
}

struct HistogramView: View {
    let bins: [[Double]]

    var body: some View {
        let presentation = HistogramPresentation(bins: bins)
        Canvas { context, size in
            var grid = Path()
            for index in 1...3 {
                let x = size.width * Double(index) / 4
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(grid, with: .color(.white.opacity(0.1)), lineWidth: 1)
            let barWidth = size.width / CGFloat(HistogramPresentation.binCount)
            for index in 0..<HistogramPresentation.binCount {
                let x = CGFloat(index) * barWidth
                for segment in presentation.segments(at: index) {
                    let height = CGFloat(segment.upper - segment.lower) * size.height
                    guard height > 0 else { continue }
                    let y = size.height - CGFloat(segment.upper) * size.height
                    let rect = CGRect(x: x, y: y, width: barWidth + 0.5, height: height)
                    context.fill(Path(rect), with: .color(color(for: segment.fill).opacity(0.82)))
                }
            }
        }.accessibilityLabel("RGB 输出直方图")
    }

    private func color(for fill: HistogramFill) -> Color {
        switch fill {
        case .red: return .red
        case .green: return .green
        case .blue: return .blue
        case .cyan: return .cyan
        case .magenta: return Color(red: 1, green: 0, blue: 1)
        case .yellow: return .yellow
        case .neutralGray: return .gray
        }
    }
}
