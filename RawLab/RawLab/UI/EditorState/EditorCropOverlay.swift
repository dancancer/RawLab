import SwiftUI

struct CropDragSession {
    private(set) var startingRect: CGRect?
    private(set) var isCancelled = false
    private var sourceRevision: UUID?

    init() {}

    mutating func update(rect: CGRect, sourceRevision: UUID, isEnabled: Bool) -> CGRect? {
        guard isEnabled, !isCancelled else {
            cancel()
            return nil
        }
        if let previousRevision = self.sourceRevision, previousRevision != sourceRevision {
            cancel()
            return nil
        }
        if startingRect == nil {
            startingRect = rect
            self.sourceRevision = sourceRevision
        }
        return startingRect
    }

    @discardableResult
    mutating func cancel() -> Bool {
        let wasActive = startingRect != nil
        startingRect = nil
        isCancelled = true
        return wasActive
    }

    @discardableResult
    mutating func end() -> Bool {
        let wasActive = startingRect != nil
        self = Self()
        return wasActive
    }
}

struct EditorCropOverlay: View {
    @Binding var settings: GeometrySettings
    let imageSize: CGSize
    let aspectRatio: Double?
    let isEnabled: Bool
    let sourceRevision: UUID
    let onEditingChanged: (Bool) -> Void
    var showsGrid = true
    @State private var dragSession = CropDragSession()
    @GestureState private var gestureActive = false

    var body: some View {
        GeometryReader { geometry in
            let canvas = fittedCanvas(in: geometry.size)
            let crop = CropInteraction.rect(from: settings)
            let frame = CGRect(x: canvas.minX + crop.minX * canvas.width,
                               y: canvas.minY + crop.minY * canvas.height,
                               width: crop.width * canvas.width, height: crop.height * canvas.height)
            ZStack {
                Path { path in
                    path.addRect(canvas)
                    path.addRect(frame)
                }
                .fill(.black.opacity(0.35), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                Rectangle().stroke(.white, lineWidth: 1)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .allowsHitTesting(false)
                if showsGrid {
                    Path { path in
                        for index in 1...2 {
                            let fraction = CGFloat(index) / 3
                            path.move(to: CGPoint(x: frame.minX + frame.width * fraction, y: frame.minY))
                            path.addLine(to: CGPoint(x: frame.minX + frame.width * fraction, y: frame.maxY))
                            path.move(to: CGPoint(x: frame.minX, y: frame.minY + frame.height * fraction))
                            path.addLine(to: CGPoint(x: frame.maxX, y: frame.minY + frame.height * fraction))
                        }
                    }.stroke(.white.opacity(0.65), lineWidth: 0.7).allowsHitTesting(false)
                }
                if frame.width >= 88 && frame.height >= 88 {
                    Color.clear.contentShape(Rectangle())
                        .frame(width: frame.width - 44, height: frame.height - 44)
                        .position(x: frame.midX, y: frame.midY)
                        .gesture(drag(.move, canvas: canvas))
                        .accessibilityLabel(L10n.text("裁切选区"))
                        .accessibilityIdentifier("geometry.crop.move")
                }
                ForEach(handles(for: frame), id: \.self) { handle in
                    let point = position(handle, frame: frame)
                    ZStack {
                        Color.clear
                        RoundedRectangle(cornerRadius: 1).fill(.yellow).frame(width: 12, height: 12)
                    }
                    .frame(width: 44, height: 44).contentShape(Rectangle())
                    .position(point)
                    .gesture(drag(handle, canvas: canvas))
                    .accessibilityLabel(handleTitle(handle))
                    .accessibilityIdentifier("geometry.crop.\(handle)")
                }
            }
        }
        .allowsHitTesting(isEnabled)
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { cancelDrag() }
        }
        .onChange(of: sourceRevision) { _, _ in cancelDrag() }
        .onChange(of: gestureActive) { _, active in
            if !active { endDrag() }
        }
        .onDisappear { endDrag() }
    }

    private func fittedCanvas(in size: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        let width = imageSize.width * scale, height = imageSize.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                      width: width, height: height)
    }

    private func handles(for frame: CGRect) -> [CropHandle] {
        frame.width >= 88 && frame.height >= 88
            ? [.topLeft, .topRight, .bottomLeft, .bottomRight] : [.bottomRight]
    }

    private func position(_ handle: CropHandle, frame: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: frame.minX, y: frame.minY)
        case .topRight: return CGPoint(x: frame.maxX, y: frame.minY)
        case .bottomLeft: return CGPoint(x: frame.minX, y: frame.maxY)
        case .bottomRight: return CGPoint(x: frame.maxX, y: frame.maxY)
        case .move: return CGPoint(x: frame.midX, y: frame.midY)
        }
    }

    private func handleTitle(_ handle: CropHandle) -> String {
        switch handle {
        case .topLeft: return L10n.text("裁切左上角")
        case .topRight: return L10n.text("裁切右上角")
        case .bottomLeft: return L10n.text("裁切左下角")
        case .bottomRight: return L10n.text("裁切右下角")
        case .move: return L10n.text("裁切选区")
        }
    }

    private func drag(_ handle: CropHandle, canvas: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($gestureActive) { _, active, _ in active = true }
            .onChanged { event in
                guard isEnabled, canvas.width > 0, canvas.height > 0 else {
                    if dragSession.cancel() { onEditingChanged(false) }
                    return
                }
                let wasActive = dragSession.startingRect != nil
                guard let startingRect = dragSession.update(rect: CropInteraction.rect(from: settings),
                                                           sourceRevision: sourceRevision, isEnabled: isEnabled) else {
                    if wasActive { onEditingChanged(false) }
                    return
                }
                if !wasActive { onEditingChanged(true) }
                let translation = CGSize(width: event.translation.width / canvas.width,
                                         height: event.translation.height / canvas.height)
                let moved = CropInteraction.dragging(startingRect, handle: handle, translation: translation,
                                                     canvasSize: canvas.size, ratio: aspectRatio)
                settings = CropInteraction.applying(rect: moved, to: settings)
            }
            .onEnded { _ in endDrag() }
    }

    private func cancelDrag() {
        guard gestureActive || dragSession.startingRect != nil else { return }
        if dragSession.cancel() { onEditingChanged(false) }
    }

    private func endDrag() {
        if dragSession.end() { onEditingChanged(false) }
    }
}
