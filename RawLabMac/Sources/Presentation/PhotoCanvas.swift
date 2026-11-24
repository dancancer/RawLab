import RawLabKit
import SwiftUI

struct PhotoCanvas: View {
    let frame: RenderedImage
    @Binding var viewport: PhotoViewport
    let sourceWidth: Int
    let clipping: Bool
    var margins = true
    var beforeFrame: RenderedImage? = nil
    var split: Binding<Double>? = nil
    var comparisonLabel: String? = nil
    var hslTarget: HSLTargetCanvasInput? = nil
    var hslTargetPoint: CGPoint? = nil
    var canHold = false
    var onHold: (Bool) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    var onDoubleClickPoint: ((CGPoint?) -> Void)? = nil
    var sourceHeight: Int? = nil
    var onPreviewSizeChange: ((Int) -> Void)? = nil
    var cropSettings: GeometrySettings? = nil
    var pendingGeometry: GeometrySettings? = nil
    var cropAspectRatio: Double? = nil
    var cropGrid = true
    var onCropChange: ((GeometrySettings) -> Void)? = nil
    var onCropEditingChanged: ((Bool) -> Void)? = nil
    var prepareCropInteraction: (GeometrySettings) -> Bool = { _ in true }
    var hdrDisplay: HDRDisplayState? = nil
    var inspectionOverlay: InspectionOverlayMode = .none
    var inspectionAnchors: [(index: Int, point: CGPoint, selected: Bool)] = []
    var inspectionPinMode: Bool = false
    var onInspectionHover: ((CGPoint?) -> Void)? = nil
    var onInspectionPin: ((CGPoint) -> Void)? = nil
    @Environment(\.displayScale) private var displayScale
    @State private var dragOrigin: CGPoint?
    @State private var labelRects: [CGRect] = []
    @State private var hoveringWipe = false

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
            let margin: CGFloat = margins ? 12 : 0
            let fit = max(0.001, min((geometry.size.width - 2 * margin) / fitted.width,
                                     (geometry.size.height - 2 * margin) / fitted.height))
            let factor = viewport.factor(fit: fit, displayScale: displayScale,
                                         sourceWidth: CGFloat(sourceWidth), renderedWidth: CGFloat(frame.image.width))
            let previewEdge = viewport.previewLongEdge(canvas: geometry.size, displayScale: displayScale,
                source: CGSize(width: CGFloat(sourceWidth), height: sourceHeight.map(CGFloat.init) ??
                    CGFloat(sourceWidth) * CGFloat(frame.image.height) / CGFloat(frame.image.width)), margin: margin)
            let displayedSize = CGSize(width: safeRendered.width * factor, height: safeRendered.height * factor)
            let pan = viewport.pan(displayed: displayedSize)
            let displayPan = CGSize(width: pan.width + (safeRendered.width / 2 - (selection?.midX ?? safeRendered.width / 2)) * factor,
                                    height: pan.height + (safeRendered.height / 2 - (selection?.midY ?? safeRendered.height / 2)) * factor)
            let imageBounds = MacCropInteraction.imageBounds(canvasSize: geometry.size,
                renderedSize: safeRendered, factor: factor, pan: displayPan)
            let sourceBounds = MacCropInteraction.imageBounds(canvasSize: geometry.size,
                renderedSize: rendered, factor: factor, pan: displayPan)
            let visibleImage = sourceBounds.intersection(CGRect(origin: .zero, size: geometry.size))
            ZStack {
                Color.clear
                photo(frame)
                    .frame(width: CGFloat(frame.image.width) * factor, height: CGFloat(frame.image.height) * factor)
                    .overlay(alignment: .leading) {
                        if let beforeFrame, let split {
                            photo(beforeFrame)
                                .mask(alignment: .leading) { Rectangle().frame(width: rendered.width * factor * split.wrappedValue) }
                        }
                    }
                    .overlay {
                        if clipping, let mask = frame.clipping { Image(decorative: mask, scale: 1).resizable().interpolation(.none) }
                    }.rotationEffect(.degrees(straighten.angle)).offset(x: displayPan.width, y: displayPan.height)
                if let cropSettings {
                    MacCropOverlay(settings: cropSettings, imageBounds: imageBounds, canvasSize: straighten.safeCanvas,
                        previewIdentity: ObjectIdentifier(frame.image), aspectRatio: cropAspectRatio, showsGrid: cropGrid,
                        imageOutline: straighten.outline(in: sourceBounds),
                        onChange: onCropChange, onEditingChanged: onCropEditingChanged,
                        prepareInteraction: prepareCropInteraction)
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
                .overlay {
                    if onCropChange == nil {
                        MacCanvasInput(imageRect: sourceBounds,
                            excludedRects: labelRects + (beforeFrame != nil && split != nil ?
                                [CGRect(x: sourceBounds.minX, y: sourceBounds.minY,
                                    width: sourceBounds.width * (split?.wrappedValue ?? 0) + 12, height: sourceBounds.height)] : []),
                            target: hslTarget, pinMode: inspectionPinMode, canHold: canHold, onHold: onHold,
                            onPan: { translation in
                                if dragOrigin == nil { dragOrigin = viewport.focus }
                                viewport.moveFocus(from: dragOrigin ?? viewport.focus, translation: translation, displayed: displayedSize)
                            }, onPanEnd: { dragOrigin = nil }, onDoubleClick: onDoubleClick,
                            onDoubleClickPoint: onDoubleClickPoint,
                            onMagnify: { multiplier, location in
                                let anchor: CGPoint
                                if sourceBounds.width > 0 && sourceBounds.height > 0 {
                                    anchor = CGPoint(
                                        x: min(1, max(0, (location.x - sourceBounds.minX) / sourceBounds.width)),
                                        y: min(1, max(0, (location.y - sourceBounds.minY) / sourceBounds.height))
                                    )
                                } else {
                                    anchor = CGPoint(x: 0.5, y: 0.5)
                                }
                                viewport.zoom(by: multiplier, anchor: anchor)
                            },
                            onScrollPan: { delta in
                                if viewport.pixelMode || viewport.magnification > 1.001 {
                                    viewport.panBy(delta: delta, displayed: displayedSize)
                                }
                            },
                            onHover: onInspectionHover, onPin: onInspectionPin)
                    }
                }
                .overlay {
                    if let split, beforeFrame != nil, !visibleImage.isNull {
                        let x = sourceBounds.minX + sourceBounds.width * split.wrappedValue
                        Rectangle().fill(.black.opacity(0.65)).frame(width: 3, height: visibleImage.height)
                            .position(x: x, y: visibleImage.midY).allowsHitTesting(false)
                        Rectangle().fill(.white).frame(width: 1.5, height: visibleImage.height)
                            .position(x: x, y: visibleImage.midY).allowsHitTesting(false)
                        ZStack {
                            Circle()
                                .fill(.black.opacity(0.75))
                                .frame(width: 30, height: 30)
                            Circle()
                                .stroke(.white, lineWidth: 1.5)
                                .frame(width: 30, height: 30)
                            HStack(spacing: 3) {
                                Image(systemName: "chevron.left")
                                Image(systemName: "chevron.right")
                            }
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                        }
                        .position(x: x, y: visibleImage.midY)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        Color.clear.frame(width: 28, height: visibleImage.height).contentShape(Rectangle())
                            .position(x: x, y: visibleImage.midY)
                            .onHover { inside in
                                if inside && !hoveringWipe {
                                    hoveringWipe = true
                                    NSCursor.resizeLeftRight.push()
                                } else if !inside && hoveringWipe {
                                    hoveringWipe = false
                                    NSCursor.pop()
                                }
                            }
                            .onDisappear {
                                if hoveringWipe {
                                    hoveringWipe = false
                                    NSCursor.pop()
                                }
                            }
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("photoCanvas"))
                                .onChanged { hslTarget?.cancel(); split.wrappedValue = min(1, max(0, ($0.location.x - sourceBounds.minX) / max(1, sourceBounds.width))) })
                            .focusable().onKeyPress { key in
                                if key.key == .leftArrow { split.wrappedValue = max(0, split.wrappedValue - 0.01); return .handled }
                                if key.key == .rightArrow { split.wrappedValue = min(1, split.wrappedValue + 0.01); return .handled }
                                if key.key == .home { split.wrappedValue = 0.5; return .handled }
                                return .ignored
                            }
                            .accessibilityElement().accessibilityLabel(L10n.text("分割位置"))
                            .accessibilityValue(String(format: "%.0f%%", split.wrappedValue * 100))
                            .accessibilityAdjustableAction { direction in
                                split.wrappedValue = min(1, max(0, split.wrappedValue + (direction == .increment ? 0.01 : -0.01)))
                            }
                            .accessibilityAction(named: Text(L10n.text("重置分割线"))) { split.wrappedValue = 0.5 }
                            .accessibilityIdentifier("compare.split")
                    }
                }
                .overlay {
                    if !visibleImage.isNull {
                        HStack {
                            if let comparisonLabel { photoLabel(comparisonLabel) }
                            Spacer(minLength: 8)
                            if beforeFrame != nil { photoLabel(L10n.text("调整后")) }
                        }.padding(8).frame(width: visibleImage.width, height: visibleImage.height, alignment: .bottom)
                            .position(x: visibleImage.midX, y: visibleImage.midY).allowsHitTesting(false)
                    }
                }
                .overlay {
                    if hslTarget != nil, let point = hslTargetPoint {
                        Circle().stroke(.black, lineWidth: 4).overlay { Circle().stroke(.white, lineWidth: 2) }
                            .frame(width: 18, height: 18)
                            .position(x: sourceBounds.minX + point.x * sourceBounds.width,
                                      y: sourceBounds.minY + point.y * sourceBounds.height)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                    if cropSettings == nil, inspectionOverlay != .neutralGray50 {
                        ForEach(inspectionAnchors, id: \.index) { marker in
                            let x = sourceBounds.minX + marker.point.x * sourceBounds.width
                            let y = sourceBounds.minY + marker.point.y * sourceBounds.height
                            ZStack {
                                Circle()
                                    .fill(marker.selected ? Color.yellow : Color.black.opacity(0.75))
                                    .frame(width: 20, height: 20)
                                Circle()
                                    .stroke(marker.selected ? Color.black : Color.white, lineWidth: 1.5)
                                    .frame(width: 20, height: 20)
                                Text("\(marker.index)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(marker.selected ? Color.black : Color.white)
                            }
                            .position(x: x, y: y)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
                }
                .coordinateSpace(name: "photoCanvas")
                .onPreferenceChange(PhotoLabelBounds.self) { labelRects = $0 }
                .onChange(of: viewport) { _, _ in hslTarget?.cancel() }
                .onChange(of: previewEdge, initial: true) { _, edge in onPreviewSizeChange?(edge) }
        }
    }
    @ViewBuilder private func photo(_ frame: RenderedImage) -> some View {
        if inspectionOverlay == .neutralGray50 {
            Color(red: 128.0 / 255.0, green: 128.0 / 255.0, blue: 128.0 / 255.0)
        } else if inspectionOverlay != .none {
            InspectionOverlayPhotoView(base: frame.hdr?.sdrImage ?? frame.image, mode: inspectionOverlay)
        } else if let presentation = frame.hdr, let hdrDisplay {
            HDRCanvas(presentation: presentation, state: hdrDisplay)
        } else {
            Image(decorative: frame.image, scale: 1).resizable().interpolation(.high)
        }
    }
    private func photoLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 4)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
            .background { GeometryReader { geometry in
                Color.clear.preference(key: PhotoLabelBounds.self, value: [geometry.frame(in: .named("photoCanvas"))])
            } }
    }
}

private struct InspectionOverlayPhotoView: View {
    let base: CGImage
    let mode: InspectionOverlayMode
    @State private var rendered: (sourceID: ObjectIdentifier, mode: InspectionOverlayMode, image: CGImage)?

    private struct RenderKey: Equatable {
        let sourceID: ObjectIdentifier
        let mode: InspectionOverlayMode
    }

    var body: some View {
        let cached = InspectionOverlayRenderer.shared.cached(base, mode: mode)
        let display = cached
            ?? (rendered?.mode == mode ? rendered?.image : nil)
            ?? base
        Image(decorative: display, scale: 1)
            .resizable()
            .interpolation(.high)
            .task(id: RenderKey(sourceID: ObjectIdentifier(base), mode: mode)) {
                if let hit = InspectionOverlayRenderer.shared.cached(base, mode: mode) {
                    rendered = (ObjectIdentifier(base), mode, hit)
                    return
                }
                let result = await withCheckedContinuation { continuation in
                    InspectionOverlayRenderer.shared.renderAsync(base, mode: mode) { output in
                        continuation.resume(returning: output)
                    }
                }
                guard !Task.isCancelled, let result else { return }
                rendered = (ObjectIdentifier(base), mode, result)
            }
    }
}

private struct PhotoLabelBounds: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value.append(contentsOf: nextValue()) }
}

struct HistogramView: View {
    @Environment(\.locale) private var localizationLocale
    let bins: [[Double]]
    var luminanceCursor: Double? = nil

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
            if let cursor = luminanceCursor, cursor.isFinite {
                let x = min(1.0, max(0.0, cursor)) * size.width
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(.black.opacity(0.9)), lineWidth: 3)
                context.stroke(line, with: .color(.white), lineWidth: 1.2)
                var marker = Path()
                marker.move(to: CGPoint(x: x, y: 5))
                marker.addLine(to: CGPoint(x: x - 4, y: 0))
                marker.addLine(to: CGPoint(x: x + 4, y: 0))
                marker.closeSubpath()
                context.fill(marker, with: .color(.yellow))
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
