import SwiftUI

/// A drag owns its entry rectangle and coordinate system. Preview replacement,
/// aspect changes, and external edits invalidate it instead of replaying an old
/// translation against the new canvas.
struct MacCropDragSession {
    let handle: MacCropHandle
    let baseline: GeometrySettings
    let imageBounds: CGRect
    let canvasSize: CGSize
    let aspectRatio: Double?
    let previewIdentity: ObjectIdentifier
    private(set) var lastApplied: GeometrySettings
    private(set) var lastObserved: GeometrySettings

    init(handle: MacCropHandle, settings: GeometrySettings, imageBounds: CGRect,
         canvasSize: CGSize, aspectRatio: Double?, previewIdentity: ObjectIdentifier) {
        self.handle = handle
        baseline = settings
        lastApplied = settings
        lastObserved = settings
        self.imageBounds = imageBounds
        self.canvasSize = canvasSize
        self.aspectRatio = aspectRatio
        self.previewIdentity = previewIdentity
    }

    func canContinue(settings: GeometrySettings, imageBounds: CGRect, canvasSize: CGSize,
                     aspectRatio: Double?, previewIdentity: ObjectIdentifier,
                     allowingUnrefreshedSettings: Bool = false) -> Bool {
        (settings == lastApplied || (allowingUnrefreshedSettings && settings == lastObserved)) &&
            self.imageBounds == imageBounds && self.canvasSize == canvasSize &&
            self.aspectRatio == aspectRatio && self.previewIdentity == previewIdentity
    }

    mutating func observeAppliedSettings() { lastObserved = lastApplied }

    mutating func applying(translation: CGSize) -> GeometrySettings {
        guard let delta = MacCropInteraction.normalizedTranslation(translation, imageBounds: imageBounds) else {
            return lastApplied
        }
        let rect = MacCropInteraction.dragging(MacCropInteraction.rect(from: baseline), handle: handle,
            translation: delta, canvasSize: canvasSize, ratio: aspectRatio)
        lastApplied = MacCropInteraction.applying(rect: rect, to: baseline)
        return lastApplied
    }
}

/// A discrete edit interrupts the current pointer gesture without allowing its
/// remaining cumulative translations to create another baseline.
struct MacCropPointerState {
    var session: MacCropDragSession?
    private(set) var ignoresCurrentGesture = false

    mutating func begin(_ entry: MacCropDragSession) -> Bool {
        guard !ignoresCurrentGesture, session == nil else { return false }
        session = entry
        return true
    }

    mutating func applying(translation: CGSize) -> GeometrySettings? {
        guard !ignoresCurrentGesture, var current = session else { return nil }
        let result = current.applying(translation: translation)
        session = current
        return result
    }

    @discardableResult mutating func interrupt() -> Bool {
        let wasEditing = session != nil
        if wasEditing { ignoresCurrentGesture = true }
        session = nil
        return wasEditing
    }

    @discardableResult mutating func finish() -> Bool {
        let wasEditing = session != nil
        session = nil
        return wasEditing
    }

    mutating func endGesture() { session = nil; ignoresCurrentGesture = false }
}

struct MacCropOverlay: View {
    let settings: GeometrySettings
    let imageBounds: CGRect
    let canvasSize: CGSize
    let previewIdentity: ObjectIdentifier
    var aspectRatio: Double? = nil
    var showsGrid = true
    var onChange: ((GeometrySettings) -> Void)? = nil
    var onEditingChanged: ((Bool) -> Void)? = nil

    @Environment(\.locale) private var localizationLocale
    @State private var pointer = MacCropPointerState()
    @FocusState private var focusedHandle: MacCropHandle?

    private var crop: CGRect { MacCropInteraction.rect(from: settings) }
    private var selection: CGRect { MacCropInteraction.selectionBounds(crop: crop, imageBounds: imageBounds) }
    private var editable: Bool { onChange != nil && settings.isValid && imageBounds.width > 0 && imageBounds.height > 0 }
    private let focusColor = Color(red: 1, green: 0.82, blue: 0.22)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                var shade = Path(imageBounds)
                shade.addRect(selection)
                context.fill(shade, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
                context.stroke(Path(selection), with: .color(.black.opacity(0.75)), lineWidth: 3)
                context.stroke(Path(selection), with: .color(focusedHandle == .move ? focusColor : .white), lineWidth: 1)
                if showsGrid {
                    var grid = Path()
                    for index in 1...2 {
                        let fraction = CGFloat(index) / 3
                        grid.move(to: CGPoint(x: selection.minX + selection.width * fraction, y: selection.minY))
                        grid.addLine(to: CGPoint(x: selection.minX + selection.width * fraction, y: selection.maxY))
                        grid.move(to: CGPoint(x: selection.minX, y: selection.minY + selection.height * fraction))
                        grid.addLine(to: CGPoint(x: selection.maxX, y: selection.minY + selection.height * fraction))
                    }
                    context.stroke(grid, with: .color(.black.opacity(0.6)), lineWidth: 2)
                    context.stroke(grid, with: .color(.white.opacity(0.65)), lineWidth: 0.7)
                }
            }.allowsHitTesting(false).accessibilityHidden(true)

            if editable {
                interactive(Rectangle().fill(.clear).contentShape(Rectangle())
                    .frame(width: selection.width, height: selection.height), handle: .move)
                    .position(x: selection.midX, y: selection.midY)

                ForEach(MacCropHandle.allCases.filter { $0 != .move }, id: \.self) { handle in
                    interactive(MacCropHandleMark(handle: handle, color: focusedHandle == handle ? focusColor : .white)
                        .frame(width: 40, height: 40).contentShape(Rectangle()), handle: handle)
                        .position(position(for: handle))
                }
            }
        }
        .coordinateSpace(name: "mac.crop.canvas")
        .onChange(of: settings) { _, _ in invalidateIfNeeded() }
        .onChange(of: imageBounds) { _, _ in invalidateIfNeeded() }
        .onChange(of: canvasSize) { _, _ in invalidateIfNeeded() }
        .onChange(of: aspectRatio) { _, _ in invalidateIfNeeded() }
        .onChange(of: previewIdentity) { _, _ in invalidateIfNeeded() }
        .onChange(of: editable) { _, value in
            if !value { finishDrag() }
            // Removing the interactive layer cancels its recognizer. A newly
            // mounted layer must be allowed to begin a fresh gesture.
            pointer.endGesture()
        }
        .onDisappear { finishDrag(); pointer.endGesture() }
    }

    private func interactive<V: View>(_ view: V, handle: MacCropHandle) -> some View {
        view
            .highPriorityGesture(gesture(for: handle))
            .focusable(editable)
            .focused($focusedHandle, equals: handle)
            .focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                guard editable, !press.modifiers.contains(.command), !press.modifiers.contains(.control),
                      !press.modifiers.contains(.option) else { return .ignored }
                let direction: MacCropDirection
                switch press.key {
                case .leftArrow: direction = .left
                case .rightArrow: direction = .right
                case .upArrow: direction = .up
                case .downArrow: direction = .down
                default: return .ignored
                }
                adjust(handle, translation: MacCropInteraction.keyboardTranslation(for: handle,
                    direction: direction, fine: press.modifiers.contains(.shift), imageBounds: imageBounds))
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text(handle.titleKey))
            .accessibilityIdentifier("geometry.crop.\(String(describing: handle))")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(L10n.text("使用方向键移动，按住 Shift 精细调整。"))
            .accessibilityAdjustableAction { direction in
                guard editable else { return }
                let expanding: Bool
                switch direction {
                case .increment: expanding = true
                case .decrement: expanding = false
                @unknown default: return
                }
                let step: CGFloat = expanding ? 0.01 : -0.01
                let delta = accessibilityTranslation(for: handle, step: step)
                adjust(handle, translation: delta)
            }
            .help(L10n.text(handle.titleKey) + "\n" + L10n.text("使用方向键移动，按住 Shift 精细调整。"))
    }

    private var accessibilityValue: String {
        [ ("裁切左边", settings.cropX), ("裁切上边", settings.cropY),
          ("裁切宽度", settings.cropWidth), ("裁切高度", settings.cropHeight) ]
            .map { L10n.text($0.0) + " " + String(format: "%.1f%%", locale: L10n.locale, $0.1 * 100) }
            .joined(separator: ", ")
    }

    private func position(for handle: MacCropHandle) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: selection.minX, y: selection.minY)
        case .top: return CGPoint(x: selection.midX, y: selection.minY)
        case .topRight: return CGPoint(x: selection.maxX, y: selection.minY)
        case .right: return CGPoint(x: selection.maxX, y: selection.midY)
        case .bottomRight: return CGPoint(x: selection.maxX, y: selection.maxY)
        case .bottom: return CGPoint(x: selection.midX, y: selection.maxY)
        case .bottomLeft: return CGPoint(x: selection.minX, y: selection.maxY)
        case .left: return CGPoint(x: selection.minX, y: selection.midY)
        case .move: return CGPoint(x: selection.midX, y: selection.midY)
        }
    }

    private func accessibilityTranslation(for handle: MacCropHandle, step: CGFloat) -> CGSize {
        switch handle {
        case .topLeft: return CGSize(width: -step, height: -step)
        case .top: return CGSize(width: 0, height: -step)
        case .topRight: return CGSize(width: step, height: -step)
        case .right, .move: return CGSize(width: step, height: 0)
        case .bottomRight: return CGSize(width: step, height: step)
        case .bottom: return CGSize(width: 0, height: step)
        case .bottomLeft: return CGSize(width: -step, height: step)
        case .left: return CGSize(width: -step, height: 0)
        }
    }

    private func adjust(_ handle: MacCropHandle, translation: CGSize) {
        if pointer.interrupt() { onEditingChanged?(false) }
        let rect = MacCropInteraction.dragging(crop, handle: handle, translation: translation,
            canvasSize: canvasSize, ratio: aspectRatio)
        onChange?(MacCropInteraction.applying(rect: rect, to: settings))
        // Keyboard and accessibility adjustments are discrete exact edits.
        onEditingChanged?(false)
    }

    private func gesture(for handle: MacCropHandle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("mac.crop.canvas"))
            .onChanged { value in
                guard editable, !pointer.ignoresCurrentGesture else { return }
                focusedHandle = handle
                if pointer.begin(MacCropDragSession(handle: handle, settings: settings, imageBounds: imageBounds,
                    canvasSize: canvasSize, aspectRatio: aspectRatio, previewIdentity: previewIdentity)) {
                    onEditingChanged?(true)
                }
                updateDrag(handle: handle, translation: value.translation)
            }
            .onEnded { value in
                if !pointer.ignoresCurrentGesture { updateDrag(handle: handle, translation: value.translation) }
                finishDrag()
                pointer.endGesture()
            }
    }

    private func updateDrag(handle: MacCropHandle, translation: CGSize) {
        guard let current = pointer.session, current.handle == handle else { return }
        guard current.canContinue(settings: settings, imageBounds: imageBounds, canvasSize: canvasSize,
            aspectRatio: aspectRatio, previewIdentity: previewIdentity, allowingUnrefreshedSettings: true) else {
            if pointer.interrupt() { onEditingChanged?(false) }
            return
        }
        guard let result = pointer.applying(translation: translation) else { return }
        onChange?(result)
    }

    private func invalidateIfNeeded() {
        guard var current = pointer.session else { return }
        if current.canContinue(settings: settings, imageBounds: imageBounds, canvasSize: canvasSize,
            aspectRatio: aspectRatio, previewIdentity: previewIdentity) {
            current.observeAppliedSettings()
            pointer.session = current
            return
        }
        if pointer.interrupt() { onEditingChanged?(false) }
    }

    private func finishDrag() {
        if pointer.finish() { onEditingChanged?(false) }
    }
}

private extension MacCropHandle {
    var titleKey: String {
        switch self {
        case .topLeft: return "裁切左上角"
        case .top: return "裁切上边"
        case .topRight: return "裁切右上角"
        case .right: return "裁切右边"
        case .bottomRight: return "裁切右下角"
        case .bottom: return "裁切下边"
        case .bottomLeft: return "裁切左下角"
        case .left: return "裁切左边"
        case .move: return "裁切选区"
        }
    }
}

private struct MacCropHandleMark: View {
    let handle: MacCropHandle
    let color: Color

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            var path = Path()
            switch handle {
            case .topLeft, .topRight, .bottomLeft, .bottomRight:
                let left = handle == .topLeft || handle == .bottomLeft
                let top = handle == .topLeft || handle == .topRight
                path.move(to: CGPoint(x: center.x + (left ? 18 : -18), y: center.y))
                path.addLine(to: center)
                path.addLine(to: CGPoint(x: center.x, y: center.y + (top ? 18 : -18)))
            case .top, .bottom:
                path.move(to: CGPoint(x: center.x - 8, y: center.y))
                path.addLine(to: CGPoint(x: center.x + 8, y: center.y))
            case .left, .right:
                path.move(to: CGPoint(x: center.x, y: center.y - 8))
                path.addLine(to: CGPoint(x: center.x, y: center.y + 8))
            case .move: break
            }
            context.stroke(path, with: .color(.black.opacity(0.8)), style: StrokeStyle(lineWidth: 5, lineCap: .square))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .square))
        }.allowsHitTesting(false)
    }
}
