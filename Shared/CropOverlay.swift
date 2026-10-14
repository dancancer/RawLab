import SwiftUI

// Coordinates are in the containing photo view; the crop stays normalized.
struct CropOverlay: View {
    @Binding var settings: GeometrySettings
    let imageBounds: CGRect
    var aspectRatio: Double? = nil
    var showsGrid = true
    var onEditingChanged: ((Bool) -> Void)? = nil
    var canvasSize: CGSize? = nil
    @State private var dragStart: CGRect?

    private var crop: CGRect { CropInteraction.rect(from: settings) }
    private var selection: CGRect {
        CGRect(x: imageBounds.minX + crop.minX * imageBounds.width,
               y: imageBounds.minY + crop.minY * imageBounds.height,
               width: crop.width * imageBounds.width, height: crop.height * imageBounds.height)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                let selected = selection
                var shade = Path(imageBounds)
                shade.addRect(selected)
                context.fill(shade, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
                context.stroke(Path(selected), with: .color(.black.opacity(0.7)), lineWidth: 3)
                context.stroke(Path(selected), with: .color(.white), lineWidth: 1)
                if showsGrid {
                    var grid = Path()
                    for index in 1...2 {
                        let fraction = CGFloat(index) / 3
                        grid.move(to: CGPoint(x: selected.minX + selected.width * fraction, y: selected.minY))
                        grid.addLine(to: CGPoint(x: selected.minX + selected.width * fraction, y: selected.maxY))
                        grid.move(to: CGPoint(x: selected.minX, y: selected.minY + selected.height * fraction))
                        grid.addLine(to: CGPoint(x: selected.maxX, y: selected.minY + selected.height * fraction))
                    }
                    context.stroke(grid, with: .color(.black.opacity(0.6)), lineWidth: 2)
                    context.stroke(grid, with: .color(.white.opacity(0.65)), lineWidth: 0.7)
                }
            }.allowsHitTesting(false).accessibilityHidden(true)

            Rectangle().fill(.clear).contentShape(Rectangle())
                .frame(width: selection.width, height: selection.height)
                .position(x: selection.midX, y: selection.midY)
                .gesture(gesture(for: .move))
                .accessibilityLabel(L10n.text("裁切选区"))
                .accessibilityIdentifier("geometry.crop.move")
                .accessibilityValue("\(Int(settings.cropWidth * 100))% × \(Int(settings.cropHeight * 100))%")
                .accessibilityHint(L10n.text("拖动边角裁切，拖动画面内移动选区。"))
                .accessibilityAdjustableAction { direction in
                    adjust(.move, expanding: direction == .increment)
                }

            ForEach([CropHandle.topLeft, .topRight, .bottomLeft, .bottomRight], id: \.self) { handle in
                let left = handle == .topLeft || handle == .bottomLeft
                let top = handle == .topLeft || handle == .topRight
                CornerHandle(left: left, top: top)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
                    .position(x: left ? selection.minX + 22 : selection.maxX - 22,
                              y: top ? selection.minY + 22 : selection.maxY - 22)
                    .highPriorityGesture(gesture(for: handle))
                    .accessibilityLabel(L10n.text("调整裁切边角"))
                    .accessibilityIdentifier("geometry.crop.\(String(describing: handle))")
                    .accessibilityValue("\(Int(settings.cropWidth * 100))% × \(Int(settings.cropHeight * 100))%")
                    .accessibilityAdjustableAction { direction in
                        adjust(handle, expanding: direction == .increment)
                    }
            }
        }
    }

    private func adjust(_ handle: CropHandle, expanding: Bool) {
        let step: CGFloat = expanding ? 0.01 : -0.01
        let left = handle == .topLeft || handle == .bottomLeft
        let top = handle == .topLeft || handle == .topRight
        let delta = handle == .move ? CGSize(width: step, height: 0) :
            CGSize(width: left ? -step : step, height: top ? -step : step)
        let rect = CropInteraction.dragging(crop, handle: handle, translation: delta,
                                            canvasSize: canvasSize ?? imageBounds.size, ratio: aspectRatio)
        settings = CropInteraction.applying(rect: rect, to: settings)
    }

    private func gesture(for handle: CropHandle) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard imageBounds.width > 0, imageBounds.height > 0 else { return }
                if dragStart == nil {
                    dragStart = crop
                    onEditingChanged?(true)
                }
                let translation = CGSize(width: value.translation.width / imageBounds.width,
                                         height: value.translation.height / imageBounds.height)
                let rect = CropInteraction.dragging(dragStart ?? crop, handle: handle, translation: translation,
                                                    canvasSize: canvasSize ?? imageBounds.size, ratio: aspectRatio)
                settings = CropInteraction.applying(rect: rect, to: settings)
            }
            .onEnded { _ in
                dragStart = nil
                onEditingChanged?(false)
            }
    }
}

private struct CornerHandle: View {
    let left: Bool
    let top: Bool
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: left ? 0 : size.width, y: top ? 0 : size.height)
            let dx: CGFloat = left ? 13 : -13
            let dy: CGFloat = top ? 13 : -13
            var path = Path()
            path.move(to: CGPoint(x: center.x + dx, y: center.y))
            path.addLine(to: center)
            path.addLine(to: CGPoint(x: center.x, y: center.y + dy))
            context.stroke(path, with: .color(.black.opacity(0.8)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }.allowsHitTesting(false)
    }
}
