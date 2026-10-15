import SwiftUI

struct PhotoCanvas: View {
    let frame: RenderedImage
    let viewport: PhotoViewport
    let sourceWidth: Int
    @Binding var pan: CGSize
    let clipping: Bool
    var sourceHeight: Int? = nil
    var onPreviewSizeChange: ((Int) -> Void)? = nil
    var cropSettings: GeometrySettings? = nil
    var pendingGeometry: GeometrySettings? = nil
    var cropAspectRatio: Double? = nil
    var cropGrid = true
    var onCropChange: ((GeometrySettings) -> Void)? = nil
    var onCropEditingChanged: ((Bool) -> Void)? = nil
    @Environment(\.displayScale) private var displayScale
    @State private var dragOrigin: CGSize?

    var body: some View {
        GeometryReader { geometry in
            let rendered = CGSize(width: frame.image.width, height: frame.image.height)
            let native = CGSize(width: CGFloat(sourceWidth), height: sourceHeight.map(CGFloat.init) ??
                CGFloat(sourceWidth) * rendered.height / rendered.width)
            let displayedGeometry = cropSettings ?? pendingGeometry
            let straighten = MacStraightenPreview(source: native, degrees: displayedGeometry?.straightenDegrees ?? 0)
            let safeRendered = straighten.safeRenderedSize(rendered)
            let selection = pendingGeometry.map {
                MacCropInteraction.selectionBounds(crop: MacCropInteraction.rect(from: $0),
                    imageBounds: CGRect(origin: .zero, size: safeRendered))
            }
            let fitted = selection?.size ?? straighten.rotatedSize(rendered)
            let fit = max(0.001, min((geometry.size.width - 24) / fitted.width,
                                     (geometry.size.height - 24) / fitted.height))
            let factor = viewport.factor(fit: fit, displayScale: displayScale,
                                         sourceWidth: CGFloat(sourceWidth), renderedWidth: CGFloat(frame.image.width))
            let previewEdge = viewport.previewLongEdge(canvas: geometry.size, displayScale: displayScale,
                source: CGSize(width: CGFloat(sourceWidth), height: sourceHeight.map(CGFloat.init) ??
                    CGFloat(sourceWidth) * CGFloat(frame.image.height) / CGFloat(frame.image.width)))
            let displayPan = CGSize(width: pan.width + (safeRendered.width / 2 - (selection?.midX ?? safeRendered.width / 2)) * factor,
                                    height: pan.height + (safeRendered.height / 2 - (selection?.midY ?? safeRendered.height / 2)) * factor)
            let imageBounds = MacCropInteraction.imageBounds(canvasSize: geometry.size,
                renderedSize: safeRendered, factor: factor, pan: displayPan)
            let sourceBounds = MacCropInteraction.imageBounds(canvasSize: geometry.size,
                renderedSize: rendered, factor: factor, pan: displayPan)
            ZStack {
                Color.clear
                Image(decorative: frame.image, scale: 1).resizable().interpolation(.high)
                    .frame(width: CGFloat(frame.image.width) * factor, height: CGFloat(frame.image.height) * factor)
                    .overlay {
                        if clipping { Image(decorative: frame.clipping, scale: 1).resizable().interpolation(.none) }
                    }.rotationEffect(.degrees(straighten.angle)).offset(x: displayPan.width, y: displayPan.height)
                if let cropSettings {
                    MacCropOverlay(settings: cropSettings, imageBounds: imageBounds, canvasSize: straighten.safeCanvas,
                        previewIdentity: ObjectIdentifier(frame.image), aspectRatio: cropAspectRatio, showsGrid: cropGrid,
                        imageOutline: straighten.outline(in: sourceBounds),
                        onChange: onCropChange, onEditingChanged: onCropEditingChanged)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
                .mask {
                    if let selection {
                        Rectangle().frame(width: selection.width * factor, height: selection.height * factor)
                            .offset(x: pan.width, y: pan.height)
                    } else { Rectangle() }
                }
                .clipped().contentShape(Rectangle())
                .gesture(DragGesture().onChanged { value in
                    guard onCropChange == nil else { return }
                    if dragOrigin == nil { dragOrigin = pan }
                    pan = CGSize(width: dragOrigin!.width + value.translation.width,
                                 height: dragOrigin!.height + value.translation.height)
                }.onEnded { _ in dragOrigin = nil })
                .onChange(of: previewEdge, initial: true) { _, edge in onPreviewSizeChange?(edge) }
        }
    }
}

struct HistogramView: View {
    @Environment(\.locale) private var localizationLocale
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
        }.accessibilityLabel(L10n.text("RGB 输出直方图"))
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
