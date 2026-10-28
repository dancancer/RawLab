import SwiftUI
import UIKit

struct ZoomablePhoto: UIViewRepresentable {
    @Environment(\.locale) private var localizationLocale
    @Environment(\.displayScale) private var displayScale
    let image: UIImage
    let referenceImage: UIImage?
    let label: String
    @Binding var viewing: PhotoViewingState
    @Binding var viewport: PhotoViewport
    var hslTarget: HSLTargetCanvasInput? = nil
    var hslTargetPoint: CGPoint? = nil
    var isDraft = false
    var overlayAvoidanceRect = CGRect.zero
    var interactionEnabled = true
    var onPreviewSizeChange: ((Int) -> Void)? = nil

    init(image: UIImage, referenceImage: UIImage?, label: String,
         viewing: Binding<PhotoViewingState>, viewport: Binding<PhotoViewport>,
         isDraft: Bool = false, interactionEnabled: Bool = true, overlayAvoidanceRect: CGRect = .zero,
         onPreviewSizeChange: ((Int) -> Void)? = nil, hslTarget: HSLTargetCanvasInput? = nil, hslTargetPoint: CGPoint? = nil) {
        self.image = image
        self.referenceImage = referenceImage
        self.label = label
        _viewing = viewing
        _viewport = viewport
        self.isDraft = isDraft
        self.interactionEnabled = interactionEnabled
        self.overlayAvoidanceRect = overlayAvoidanceRect
        self.onPreviewSizeChange = onPreviewSizeChange
        self.hslTarget = hslTarget; self.hslTargetPoint = hslTargetPoint
    }

    // 批量结果查看沿用只读缩放接口，不启用编辑器的查看会话动作。
    init(image: UIImage, referenceImage: UIImage, label: String, onPreviewSizeChange: ((Int) -> Void)? = nil) {
        self.init(image: image, referenceImage: referenceImage, label: label,
                  viewing: .constant(PhotoViewingState()), viewport: .constant(PhotoViewport()),
                  interactionEnabled: false, onPreviewSizeChange: onPreviewSizeChange)
    }

    func makeUIView(context: Context) -> PhotoCanvasView { PhotoCanvasView() }

    func updateUIView(_ view: PhotoCanvasView, context: Context) {
        let _ = localizationLocale
        view.onViewingChange = { viewing = $0 }
        view.onViewportChange = { viewport = $0 }
        view.onPreviewSizeChange = onPreviewSizeChange
        view.configure(image: image, reference: referenceImage, label: label, state: viewing,
                       viewport: viewport, displayScale: displayScale, overlayAvoidanceRect: overlayAvoidanceRect,
                       isDraft: isDraft, interactionEnabled: interactionEnabled, hslTarget: hslTarget, hslTargetPoint: hslTargetPoint)
    }
}

final class PhotoCanvasView: UIView {
    let result = PhotoScrollView()
    let reference = PhotoScrollView()
    private let beforeLabel = UILabel()
    private let afterLabel = UILabel()
    private let divider = PhotoSplitControl()
    private var state = PhotoViewingState()
    private var viewport = PhotoViewport()
    private var syncingViewport = false
    private var isDraft = false
    private var overlayAvoidanceRect = CGRect.zero
    private var interactionEnabled = true
    private var touchMonitor: PhotoTouchMonitor?
    private var hslTarget: HSLTargetCanvasInput?
    private var hslTargetPoint: CGPoint?
    private var targetOrigin: CGPoint?
    private var targetImage: UIImage?
    private let targetRecognizer = PhotoHSLTargetRecognizer()
    private let sampleLoupe = PhotoSampleLoupe(frame: CGRect(x: 0, y: 0, width: 88, height: 88))
    private let sampleMarker = UIView()
    var onViewingChange: ((PhotoViewingState) -> Void)?
    var onViewportChange: ((PhotoViewport) -> Void)?
    var onPreviewSizeChange: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addSubview(reference)
        addSubview(result)
        targetRecognizer.addTarget(self, action: #selector(targeted(_:)))
        targetRecognizer.isEnabled = false
        targetRecognizer.canBegin = { [weak self] point in
            guard let self else { return false }
            guard self.targetCoordinate(point) != nil else { self.hslTarget?.reject(); return false }
            return true
        }
        addGestureRecognizer(targetRecognizer)
        sampleLoupe.isHidden = true
        sampleMarker.isHidden = true; sampleMarker.isUserInteractionEnabled = false
        sampleMarker.layer.cornerRadius = 9; sampleMarker.layer.borderWidth = 2
        sampleMarker.layer.borderColor = UIColor.white.cgColor
        sampleMarker.layer.shadowColor = UIColor.black.cgColor; sampleMarker.layer.shadowOpacity = 1
        sampleMarker.layer.shadowRadius = 1; sampleMarker.layer.shadowOffset = .zero
        for label in [beforeLabel, afterLabel] {
            label.font = .preferredFont(forTextStyle: .caption1)
            label.adjustsFontForContentSizeCategory = false
            label.textColor = .white
            label.backgroundColor = UIColor.black.withAlphaComponent(0.65)
            label.isUserInteractionEnabled = false
            addSubview(label)
        }
        beforeLabel.accessibilityIdentifier = "editor.compare.before"
        afterLabel.accessibilityIdentifier = "editor.compare.after"
        addSubview(divider)
        addSubview(sampleMarker); addSubview(sampleLoupe)
        divider.onChange = { [weak self] value in
            guard let self, self.state.enabled, self.state.preferredMode == .wipe else { return }
            self.cancelTargetInput()
            self.state.setSplit(value)
            self.divider.position = self.state.split
            self.result.wipePosition = self.state.split
            self.onViewingChange?(self.state)
            self.layoutOverlays()
        }
        for scroll in [result, reference] {
            scroll.onGestureCancel = { [weak self] in self?.cancelTargetInput() }
            scroll.onViewportChange = { [weak self, weak scroll] value in
                guard let self, let scroll, !self.syncingViewport else { return }
                self.cancelTargetInput()
                self.viewport = value
                self.syncingViewport = true
                (scroll === self.result ? self.reference : self.result).applyViewport(value)
                self.syncingViewport = false
                self.layoutOverlays()
                self.onViewportChange?(value)
            }
            scroll.onCanvasTap = { [weak self] in
                guard let self, self.interactionEnabled else { return }
                self.state.togglePreview(isDraft: self.isDraft)
                self.onViewingChange?(self.state)
            }
            scroll.onHoldingChange = { [weak self] holding in
                guard let self else { return }
                if holding && self.interactionEnabled { self.state.beginHolding(isDraft: self.isDraft) }
                else { self.state.endTemporaryViewing() }
                self.onViewingChange?(self.state)
            }
            scroll.onPreviewSizeChange = { [weak self] edge in self?.onPreviewSizeChange?(edge) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(cancelTemporaryViewing),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(image: UIImage, reference imageBefore: UIImage?, label: String,
                   state: PhotoViewingState, viewport: PhotoViewport, displayScale: CGFloat, overlayAvoidanceRect: CGRect = .zero,
                   isDraft: Bool, interactionEnabled: Bool, hslTarget: HSLTargetCanvasInput? = nil,
                   hslTargetPoint: CGPoint? = nil) {
        if self.hslTarget?.scope != hslTarget?.scope || !interactionEnabled || isDraft || self.viewport != viewport {
            cancelTargetInput()
        }
        self.hslTarget = interactionEnabled && !isDraft ? hslTarget : nil
        self.hslTargetPoint = hslTargetPoint
        targetRecognizer.isEnabled = self.hslTarget != nil
        var displayState = state
        if self.hslTarget != nil { displayState.endTemporaryViewing() }
        if imageBefore == nil {
            displayState.enabled = false
            displayState.endTemporaryViewing()
        }
        self.state = displayState
        self.overlayAvoidanceRect = displayState.enabled && !displayState.previewOnly && !isDraft ? overlayAvoidanceRect : .zero
        self.viewport = viewport
        self.isDraft = isDraft
        self.interactionEnabled = interactionEnabled
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let sideBySide = displayState.enabled && displayState.preferredMode == .sideBySide && !isDraft
        for scroll in [result, reference] {
            scroll.pixels = pixels
            scroll.displayScale = displayScale
            scroll.photoMargin = displayState.photoMargin
            scroll.targetMode = self.hslTarget != nil
            scroll.canvasActionsEnabled = interactionEnabled && !isDraft && self.hslTarget == nil
            scroll.holdEnabled = interactionEnabled && !isDraft && !displayState.enabled && imageBefore != nil && self.hslTarget == nil
            scroll.previewOnly = displayState.previewOnly
            scroll.refreshAccessibilityActions()
        }
        result.imageView.image = displayState.holdingBefore ? imageBefore : image
        result.comparisonImage = displayState.enabled && displayState.preferredMode == .wipe && !isDraft ? imageBefore : nil
        result.wipePosition = displayState.split
        result.accessibilityLabel = displayState.holdingBefore ? L10n.text("调整前") : label
        reference.imageView.image = imageBefore
        reference.accessibilityLabel = L10n.text("调整前")
        reference.accessibilityIdentifier = "editor.photo.before"
        reference.isHidden = !sideBySide
        beforeLabel.text = L10n.text("调整前")
        afterLabel.text = L10n.text("调整后")
        divider.accessibilityLabel = L10n.text("分割位置")
        divider.position = displayState.split
        if displayState.previewOnly && window != nil { becomeFirstResponder() }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = state.enabled && state.preferredMode == .sideBySide && !isDraft
        let layout = PhotoComparisonLayout(size: bounds.size, enabled: side)
        syncingViewport = true
        reference.frame = CGRect(origin: .zero, size: layout.paneSize)
        result.frame = side ? CGRect(origin: CGPoint(x: layout.horizontal ? layout.paneSize.width : 0,
                                                    y: layout.horizontal ? 0 : layout.paneSize.height), size: layout.paneSize) : bounds
        for scroll in [result, reference] where !scroll.isHidden {
            scroll.setNeedsLayout()
            scroll.layoutIfNeeded()
            if !scroll.isTracking && !scroll.isDragging && !scroll.isZooming { scroll.applyViewport(viewport) }
        }
        syncingViewport = false
        layoutOverlays()
    }

    private func layoutOverlays() {
        let comparing = state.enabled && !isDraft
        let side = comparing && state.preferredMode == .sideBySide
        beforeLabel.isHidden = !comparing
        afterLabel.isHidden = !comparing
        let resultRect = result.visiblePhotoRect(in: self)
        let referenceRect = side ? reference.visiblePhotoRect(in: self) : resultRect
        place(beforeLabel, in: referenceRect, trailing: false)
        place(afterLabel, in: resultRect, trailing: !side, avoiding: overlayAvoidanceRect)
        if comparing && !side && beforeLabel.frame.intersects(afterLabel.frame) {
            var above = beforeLabel.frame
            above.origin.y = referenceRect.minY
            if referenceRect.contains(above) && !above.intersects(afterLabel.frame) && !above.intersects(overlayAvoidanceRect) {
                beforeLabel.frame = above
            }
        }
        let imageRect = result.imageView.convert(result.imageView.bounds, to: self)
        let x = imageRect.minX + imageRect.width * state.split
        divider.isHidden = !comparing || state.preferredMode != .wipe || resultRect.isEmpty || x < resultRect.minX || x > resultRect.maxX
        divider.imageRect = imageRect
        divider.frame = CGRect(x: max(resultRect.minX, min(x - 22, resultRect.maxX - min(44, resultRect.width))),
                               y: resultRect.minY, width: min(44, resultRect.width), height: resultRect.height)
        divider.lineX = x - divider.frame.minX
        divider.lineExclusionRects = [beforeLabel, afterLabel].filter { !$0.isHidden }
            .map { $0.convert($0.bounds, to: divider) }
        divider.setNeedsDisplay()
        sampleMarker.isHidden = hslTarget == nil || hslTargetPoint == nil
        if let point = hslTargetPoint {
            sampleMarker.frame = CGRect(x: imageRect.minX+point.x*imageRect.width-9,
                                        y: imageRect.minY+point.y*imageRect.height-9, width: 18, height: 18)
        }
    }

    private func place(_ label: UILabel, in rect: CGRect, trailing: Bool, avoiding exclusion: CGRect = .zero) {
        guard !rect.isEmpty else { label.frame = .zero; return }
        // 照片注释保留完整名称，字号随 caption 增长至 17pt；小照片不低于 13pt。
        let preferred = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traitCollection)
        let pointSize = min(17, max(13, preferred.pointSize))
        var font = preferred.withSize(pointSize)
        let text = label.text ?? ""
        let naturalWidth = text.size(withAttributes: [.font: font]).width
        if naturalWidth > max(0, rect.width - 8), naturalWidth > 0 {
            font = font.withSize(max(13, pointSize * max(0, rect.width - 8) / naturalWidth))
        }
        label.font = font
        let size = text.size(withAttributes: [.font: font])
        let width = min(rect.width, ceil(size.width) + 8)
        let height = min(rect.height, ceil(font.lineHeight) + 4)
        label.frame = CGRect(x: trailing ? rect.maxX - width : rect.minX,
                             y: rect.maxY - height, width: width, height: height)
        if !exclusion.isEmpty && label.frame.intersects(exclusion) {
            let above = label.frame.offsetBy(dx: 0, dy: exclusion.minY - label.frame.maxY)
            let leading = label.frame.offsetBy(dx: exclusion.minX - label.frame.maxX, dy: 0)
            if rect.contains(above) { label.frame = above }
            else if rect.contains(leading) { label.frame = leading }
        }
        label.textAlignment = .center
        label.clipsToBounds = true
    }

    @objc private func cancelTemporaryViewing() {
        cancelTargetInput()
        result.cancelCanvasGestures()
        reference.cancelCanvasGestures()
        state.endTemporaryViewing()
        onViewingChange?(state)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let touchMonitor { touchMonitor.view?.removeGestureRecognizer(touchMonitor) }
        touchMonitor = nil
        if let window {
            let monitor = PhotoTouchMonitor()
            monitor.onMultipleTouches = { [weak self] in self?.cancelTemporaryViewing() }
            window.addGestureRecognizer(monitor)
            touchMonitor = monitor
        } else { cancelTemporaryViewing() }
    }

    private func targetCoordinate(_ point: CGPoint) -> CGPoint? {
        guard hslTarget != nil, interactionEnabled, !isDraft, !state.holdingBefore,
              result.visiblePhotoRect(in: self).contains(point), !overlayAvoidanceRect.contains(point),
              ![beforeLabel, afterLabel].contains(where: { !$0.isHidden && $0.frame.contains(point) }),
              divider.isHidden || !divider.frame.contains(point) else { return nil }
        let imagePoint = result.imageView.convert(point, from: self)
        let rect = result.imageView.bounds
        guard rect.width > 0, rect.height > 0, rect.contains(imagePoint) else { return nil }
        let normalized = CGPoint(x: (imagePoint.x-rect.minX)/rect.width, y: (imagePoint.y-rect.minY)/rect.height)
        if state.enabled && state.preferredMode == .wipe && normalized.x <= state.split { return nil }
        return normalized
    }
    private func cancelTargetInput(reset: Bool = true) {
        targetOrigin = nil; targetImage = nil; sampleLoupe.isHidden = true
        hslTarget?.cancel()
        if reset && (targetRecognizer.state == .began || targetRecognizer.state == .changed) {
            targetRecognizer.isEnabled = false; targetRecognizer.isEnabled = hslTarget != nil
        }
    }
    @objc private func targeted(_ recognizer: PhotoHSLTargetRecognizer) {
        switch recognizer.state {
        case .began:
            guard let point = targetCoordinate(recognizer.point) else { hslTarget?.reject(); return }
            targetOrigin = recognizer.point; hslTargetPoint = point; targetImage = result.imageView.image
            hslTarget?.begin(point); becomeFirstResponder(); updateLoupe(at: recognizer.point)
        case .changed:
            if let origin = targetOrigin { hslTarget?.change(Double(origin.y-recognizer.point.y)*0.5) }
            updateLoupe(at: recognizer.point)
        case .ended:
            if let origin = targetOrigin { hslTarget?.change(Double(origin.y-recognizer.point.y)*0.5) }
            targetOrigin = nil; targetImage = nil; sampleLoupe.isHidden = true; hslTarget?.end()
        case .cancelled: cancelTargetInput(reset: false)
        case .failed: if targetOrigin != nil { cancelTargetInput(reset: false) }
        default: break
        }
    }
    private func updateLoupe(at point: CGPoint) {
        guard let target = hslTargetPoint, targetOrigin != nil else { return }
        sampleLoupe.image = targetImage; sampleLoupe.normalizedPoint = target
        sampleLoupe.displayWidth = result.imageView.convert(result.imageView.bounds, to: self).width
        let x = min(max(44, point.x), max(44, bounds.width-44))
        let desiredY = point.y >= 110 ? point.y-72 : point.y+72
        sampleLoupe.center = CGPoint(x: x, y: min(max(44, desiredY), max(44, bounds.height-44)))
        sampleLoupe.isHidden = false; sampleLoupe.setNeedsDisplay(); layoutOverlays()
    }

    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        if hslTarget != nil {
            return [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelTargetKey)),
                    UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(increaseTargetKey)),
                    UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(decreaseTargetKey))]
        }
        return state.previewOnly ? [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(exitPreview))] : nil
    }
    @objc private func cancelTargetKey() { cancelTargetInput() }
    @objc private func increaseTargetKey() { if targetOrigin == nil { hslTarget?.key(1) } }
    @objc private func decreaseTargetKey() { if targetOrigin == nil { hslTarget?.key(-1) } }
    @objc private func exitPreview() {
        if state.previewOnly { state.togglePreview(isDraft: false); onViewingChange?(state) }
    }
}

final class PhotoSplitControl: UIControl {
    var position: CGFloat = 0.5 { didSet { accessibilityValue = "\(Int((position * 100).rounded()))%" } }
    var imageRect = CGRect.zero
    var lineX: CGFloat = 22
    var lineExclusionRects: [CGRect] = []
    var onChange: ((CGFloat) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityIdentifier = "editor.compare.split"
        accessibilityTraits = [.adjustable]
        backgroundColor = .clear
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: L10n.text("重置分割线"), target: self, selector: #selector(resetSplit))]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func drag(_ recognizer: UIPanGestureRecognizer) {
        guard imageRect.width > 0 else { return }
        if recognizer.state == .began { becomeFirstResponder() }
        let x = recognizer.location(in: superview).x
        onChange?((x - imageRect.minX) / imageRect.width)
    }
    @objc private func resetSplit() -> Bool { onChange?(0.5); return true }
    override func accessibilityIncrement() { onChange?(position + 0.05) }
    override func accessibilityDecrement() { onChange?(position - 0.05) }
    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(stepLeft)),
         UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(stepRight)),
         UIKeyCommand(input: UIKeyCommand.inputHome, modifierFlags: [], action: #selector(home))]
    }
    @objc private func stepLeft() { accessibilityDecrement() }
    @objc private func stepRight() { accessibilityIncrement() }
    @objc private func home() { _ = resetSplit() }
    override func draw(_ rect: CGRect) {
        UIColor.white.setFill()
        let line = CGRect(x: lineX - 1, y: 0, width: 2, height: bounds.height)
        let exclusions = lineExclusionRects.map { $0.intersection(line) }
            .filter { !$0.isNull && !$0.isEmpty }.sorted { $0.minY < $1.minY }
        var start: CGFloat = 0
        for exclusion in exclusions {
            if exclusion.minY > start {
                UIBezierPath(rect: CGRect(x: line.minX, y: start, width: line.width, height: exclusion.minY - start)).fill()
            }
            start = max(start, exclusion.maxY)
        }
        if start < line.maxY {
            UIBezierPath(rect: CGRect(x: line.minX, y: start, width: line.width, height: line.maxY - start)).fill()
        }
    }
}

final class PhotoScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let imageView = UIImageView()
    private let beforeImageView = UIImageView()
    var comparisonImage: UIImage? { didSet { beforeImageView.image = comparisonImage; updateWipe() } }
    var wipePosition: CGFloat = 0.5 { didSet { updateWipe() } }
    var pixels = CGSize.zero
    var displayScale: CGFloat = 1
    var photoMargin = true
    var canvasActionsEnabled = true
    var holdEnabled = true
    var previewOnly = false
    private var previousSize = CGSize.zero
    private var previousPixels = CGSize.zero
    private var previousDisplayScale: CGFloat = 0
    private var previousMargin = true
    private var updatingGeometry = false
    private var geometry: PhotoZoomGeometry?
    private var sharedViewport = PhotoViewport()
    private let doubleTap = UITapGestureRecognizer()
    var targetMode = false { didSet {
        panGestureRecognizer.minimumNumberOfTouches = targetMode ? 2 : 1
        doubleTap.isEnabled = !targetMode
    } }
    var onGestureCancel: (() -> Void)?
    private let singleTap = UITapGestureRecognizer()
    private let holding = PhotoHoldRecognizer()
    var onPreviewSizeChange: ((Int) -> Void)?
    var onViewportChange: ((PhotoViewport) -> Void)?
    var onCanvasTap: (() -> Void)?
    var onHoldingChange: ((Bool) -> Void)?
    private var reportedEdge: Int?

    init() {
        super.init(frame: .zero)
        delegate = self
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        bounces = false
        bouncesZoom = false
        imageView.contentMode = .scaleAspectFit
        beforeImageView.contentMode = .scaleToFill
        imageView.addSubview(beforeImageView)
        addSubview(imageView)
        doubleTap.addTarget(self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        singleTap.addTarget(self, action: #selector(tapCanvas))
        singleTap.require(toFail: doubleTap)
        singleTap.require(toFail: holding)
        singleTap.require(toFail: panGestureRecognizer)
        addGestureRecognizer(singleTap)
        holding.addTarget(self, action: #selector(holdCanvas(_:)))
        holding.delegate = self
        holding.numberOfTouchesRequired = 1
        addGestureRecognizer(holding)
        isAccessibilityElement = true
        accessibilityIdentifier = "editor.photo"
        accessibilityTraits = [.image, .adjustable]
        refreshAccessibilityActions()
    }

    func refreshAccessibilityActions() {
        var actions = [UIAccessibilityCustomAction(name: "100%", target: self, selector: #selector(showActualPixels)),
                       UIAccessibilityCustomAction(name: L10n.text("适合窗口"), target: self, selector: #selector(showFit))]
        if canvasActionsEnabled {
            actions.append(UIAccessibilityCustomAction(name: L10n.text(previewOnly ? "退出纯预览" : "进入纯预览"), target: self, selector: #selector(accessibilityPreview)))
        }
        if holdEnabled {
            actions.append(UIAccessibilityCustomAction(name: L10n.text("查看调整前"), target: self, selector: #selector(accessibilityBefore)))
            actions.append(UIAccessibilityCustomAction(name: L10n.text("返回调整后"), target: self, selector: #selector(accessibilityAfter)))
        }
        accessibilityCustomActions = actions
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, pixels.width > 0, pixels.height > 0 else { return }
        guard previousSize != bounds.size || previousPixels != pixels || previousDisplayScale != displayScale || previousMargin != photoMargin || geometry == nil else { updateWipe(); return }
        let saved = sharedViewport
        updatingGeometry = true
        let next = PhotoZoomGeometry(pixels: pixels, viewport: bounds.size, displayScale: displayScale, margin: photoMargin ? PhotoZoomGeometry.defaultMargin : 0)
        geometry = next
        previousSize = bounds.size
        previousPixels = pixels
        previousDisplayScale = displayScale
        previousMargin = photoMargin
        setZoomScale(1, animated: false)
        imageView.frame = CGRect(origin: .zero, size: next.imageSize)
        contentSize = next.imageSize
        maximumZoomScale = next.maximumScale
        minimumZoomScale = next.minimumScale
        updatingGeometry = false
        applyViewport(saved)
    }

    func applyViewport(_ viewport: PhotoViewport) {
        guard let geometry else { sharedViewport = viewport; return }
        updatingGeometry = true
        sharedViewport = viewport
        let scale = viewport.scale(in: geometry)
        setZoomScale(scale, animated: false)
        centerImage()
        let offset = CGPoint(x: viewport.focus.x * geometry.imageSize.width * scale - bounds.width / 2,
                             y: viewport.focus.y * geometry.imageSize.height * scale - bounds.height / 2)
        setContentOffset(constrainedOffset(offset), animated: false)
        updateWipe()
        updateAccessibilityValue()
        updatingGeometry = false
        reportPreviewSize()
    }

    func visiblePhotoRect(in view: UIView) -> CGRect { imageView.convert(imageView.bounds, to: view).intersection(convert(bounds, to: view)) }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { publishViewport() }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        updateAccessibilityValue()
        reportPreviewSize()
        publishViewport()
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { cancelCanvasGestures() }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { cancelCanvasGestures() }

    private func publishViewport() {
        // 布局切换先改变 bounds，旧 geometry 此时不能反算新的查看中心。
        guard !updatingGeometry, previousSize == bounds.size, let geometry, geometry.fitScale > 0, zoomScale > 0 else { return }
        sharedViewport = PhotoViewport(relativeScale: zoomScale / geometry.fitScale,
                                      focus: CGPoint(x: (contentOffset.x + bounds.width / 2) / (geometry.imageSize.width * zoomScale),
                                                     y: (contentOffset.y + bounds.height / 2) / (geometry.imageSize.height * zoomScale)))
        onViewportChange?(sharedViewport)
    }

    private func updateWipe() {
        beforeImageView.frame = imageView.bounds
        beforeImageView.isHidden = comparisonImage == nil
        let mask = CAShapeLayer()
        mask.path = UIBezierPath(rect: CGRect(x: 0, y: 0, width: imageView.bounds.width * wipePosition, height: imageView.bounds.height)).cgPath
        beforeImageView.layer.mask = mask
    }
    private func reportPreviewSize() {
        guard !updatingGeometry, let geometry else { return }
        let edge = geometry.previewLongEdge(scale: zoomScale)
        guard reportedEdge != edge else { return }
        reportedEdge = edge
        DispatchQueue.main.async { [weak self] in self?.onPreviewSizeChange?(edge) }
    }
    private func centerImage() {
        contentInset = UIEdgeInsets(top: max(0, (bounds.height - contentSize.height) / 2),
                                   left: max(0, (bounds.width - contentSize.width) / 2),
                                   bottom: max(0, (bounds.height - contentSize.height) / 2),
                                   right: max(0, (bounds.width - contentSize.width) / 2))
    }
    private func constrainedOffset(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, -contentInset.left), max(-contentInset.left, contentSize.width - bounds.width + contentInset.right)),
                y: min(max(point.y, -contentInset.top), max(-contentInset.top, contentSize.height - bounds.height + contentInset.bottom)))
    }
    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        guard let geometry else { return }
        cancelCanvasGestures()
        let imagePoint = gesture.location(in: imageView)
        let point = gesture.location(in: self)
        let viewportPoint = CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
        let target = geometry.doubleTapScale(from: zoomScale)
        setZoomScale(target, animated: false)
        centerImage()
        setContentOffset(constrainedOffset(CGPoint(x: imagePoint.x * target - viewportPoint.x,
                                                   y: imagePoint.y * target - viewportPoint.y)), animated: false)
    }
    @objc private func tapCanvas() { if canvasActionsEnabled { onCanvasTap?() } }
    @objc private func holdCanvas(_ gesture: UILongPressGestureRecognizer) {
        onHoldingChange?(holdEnabled && (gesture.state == .began || gesture.state == .changed))
    }
    func cancelCanvasGestures() {
        onGestureCancel?()
        onHoldingChange?(false)
        holding.isEnabled = false
        holding.isEnabled = true
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer !== holding || (holdEnabled && panGestureRecognizer.numberOfTouches <= 1 && !isDragging && !isZooming)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === holding && (other === panGestureRecognizer || other === pinchGestureRecognizer)
    }
    @objc private func accessibilityPreview() -> Bool { onCanvasTap?(); return true }
    @objc private func accessibilityBefore() -> Bool { onHoldingChange?(true); return true }
    @objc private func accessibilityAfter() -> Bool { onHoldingChange?(false); return true }
    @objc private func showActualPixels() -> Bool { setZoomScale(1, animated: false); return true }
    @objc private func showFit() -> Bool {
        guard let geometry else { return false }
        setZoomScale(geometry.fitScale, animated: false)
        return true
    }
    override func accessibilityIncrement() { setZoomScale(min(maximumZoomScale, zoomScale * 1.5), animated: false) }
    override func accessibilityDecrement() { setZoomScale(max(minimumZoomScale, zoomScale / 1.5), animated: false) }
    private func updateAccessibilityValue() {
        let percent = "\(Int((zoomScale * 100).rounded()))%"
        accessibilityValue = geometry?.isFit(zoomScale) == true ? L10n.format("Fit %@", percent) : percent
    }
}

// 第二触点和长按后的位移也终止临时查看，不将完成的长按降级成单击。
private final class PhotoHoldRecognizer: UILongPressGestureRecognizer {
    private var origin: CGPoint?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if (event.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled }.count ?? 0) > 1 {
            state = state == .began || state == .changed ? .cancelled : .failed
            return
        }
        origin = touches.first?.location(in: view)
        super.touchesBegan(touches, with: event)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let origin, let point = touches.first?.location(in: view),
           hypot(point.x - origin.x, point.y - origin.y) > allowableMovement {
            state = state == .began || state == .changed ? .cancelled : .failed
            return
        }
        super.touchesMoved(touches, with: event)
    }
    override func reset() { origin = nil; super.reset() }
}

// 只观察窗口内触点，不识别或抢占控件；第二触点即使落在 toolbar 也结束 hold。
private final class PhotoTouchMonitor: UIGestureRecognizer {
    var onMultipleTouches: (() -> Void)?
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }
    convenience init() { self.init(target: nil, action: nil) }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if (event.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled }.count ?? 0) > 1 { onMultipleTouches?() }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if (event.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled }.count ?? 0) == 0 { state = .failed }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        onMultipleTouches?()
        state = .failed
    }
}
