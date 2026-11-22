import RawLabKit
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
    private let nativePixelSize: CGSize?
    private let previewSourceSize: CGSize?
    private let previewLongEdgeLimit: Int
    private let detailOverlay: PhotoDetailOverlay?
    private let detailTiles: [PhotoDetailOverlay]
    private let detailBacking: PhotoDetailBacking?
    var onDetailRequest: ((PhotoDetailRequest?) -> Void)? = nil
    var hdr: HDRDisplayImage? = nil
    var referenceHDR: HDRDisplayImage? = nil
    var hdrDisplay: HDRDisplayState? = nil
    var inspectionOverlay: InspectionOverlayMode = .none
    var inspectionProbeEnabled: Bool = false
    var inspectionPoint: CGPoint? = nil
    var inspectionAnchors: [(index: Int, point: CGPoint, selected: Bool)] = []
    var onInspectionPointChange: ((CGPoint) -> Void)? = nil

    init(image: UIImage, referenceImage: UIImage?, label: String,
         viewing: Binding<PhotoViewingState>, viewport: Binding<PhotoViewport>,
         isDraft: Bool = false, interactionEnabled: Bool = true, overlayAvoidanceRect: CGRect = .zero,
         onPreviewSizeChange: ((Int) -> Void)? = nil, hslTarget: HSLTargetCanvasInput? = nil, hslTargetPoint: CGPoint? = nil,
         nativePixelSize: CGSize? = nil, previewSourceSize: CGSize? = nil,
         previewLongEdgeLimit: Int = PhotoZoomGeometry.defaultPreviewLongEdge,
         detailOverlay: PhotoDetailOverlay? = nil, detailTiles: [PhotoDetailOverlay] = [],
         detailBacking: PhotoDetailBacking? = nil,
         onDetailRequest: ((PhotoDetailRequest?) -> Void)? = nil,
         hdr: HDRDisplayImage? = nil, referenceHDR: HDRDisplayImage? = nil, hdrDisplay: HDRDisplayState? = nil,
         inspectionOverlay: InspectionOverlayMode = .none,
         inspectionProbeEnabled: Bool = false,
         inspectionPoint: CGPoint? = nil,
         inspectionAnchors: [(index: Int, point: CGPoint, selected: Bool)] = [],
         onInspectionPointChange: ((CGPoint) -> Void)? = nil) {
        self.image = image
        self.referenceImage = referenceImage
        self.label = label
        _viewing = viewing
        _viewport = viewport
        self.isDraft = isDraft
        self.interactionEnabled = interactionEnabled
        self.overlayAvoidanceRect = overlayAvoidanceRect
        self.onPreviewSizeChange = onPreviewSizeChange
        self.nativePixelSize = nativePixelSize
        self.previewSourceSize = previewSourceSize
        self.previewLongEdgeLimit = previewLongEdgeLimit
        self.detailOverlay = detailOverlay
        self.detailTiles = detailTiles
        self.detailBacking = detailBacking
        self.onDetailRequest = onDetailRequest
        self.hslTarget = hslTarget; self.hslTargetPoint = hslTargetPoint
        self.hdr = hdr; self.referenceHDR = referenceHDR; self.hdrDisplay = hdrDisplay
        self.inspectionOverlay = inspectionOverlay
        self.inspectionProbeEnabled = inspectionProbeEnabled
        self.inspectionPoint = inspectionPoint
        self.inspectionAnchors = inspectionAnchors
        self.onInspectionPointChange = onInspectionPointChange
    }

    // 批量结果查看沿用只读缩放接口，不启用编辑器的查看会话动作。
    init(image: UIImage, referenceImage: UIImage, label: String, onPreviewSizeChange: ((Int) -> Void)? = nil,
         hdr: HDRDisplayImage? = nil, referenceHDR: HDRDisplayImage? = nil, hdrDisplay: HDRDisplayState? = nil) {
        self.init(image: image, referenceImage: referenceImage, label: label,
                  viewing: .constant(PhotoViewingState()), viewport: .constant(PhotoViewport()),
                  interactionEnabled: false, onPreviewSizeChange: onPreviewSizeChange,
                  hdr: hdr, referenceHDR: referenceHDR, hdrDisplay: hdrDisplay)
    }

    func makeUIView(context: Context) -> PhotoCanvasView { PhotoCanvasView() }

    func updateUIView(_ view: PhotoCanvasView, context: Context) {
        let _ = localizationLocale
        view.onViewingChange = { viewing = $0 }
        view.onViewportChange = { viewport = $0 }
        view.onPreviewSizeChange = onPreviewSizeChange
        view.onDetailRequest = onDetailRequest
        view.onInspectionPointChange = onInspectionPointChange
        view.configure(image: image, reference: referenceImage, label: label, state: viewing,
                       viewport: viewport, displayScale: displayScale, overlayAvoidanceRect: overlayAvoidanceRect,
                       isDraft: isDraft, interactionEnabled: interactionEnabled, hslTarget: hslTarget, hslTargetPoint: hslTargetPoint,
                       nativePixelSize: nativePixelSize, previewSourceSize: previewSourceSize,
                       previewLongEdgeLimit: previewLongEdgeLimit, detailOverlay: detailOverlay, detailTiles: detailTiles,
                       detailBacking: detailBacking,
                       hdr: hdr, referenceHDR: referenceHDR, hdrDisplay: hdrDisplay,
                       inspectionOverlay: inspectionOverlay,
                       inspectionProbeEnabled: inspectionProbeEnabled,
                       inspectionPoint: inspectionPoint,
                       inspectionAnchors: inspectionAnchors)
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
    private var lastPublishedViewport: PhotoViewport?
    private var syncingViewport = false
    private var isDraft = false
    private var overlayAvoidanceRect = CGRect.zero
    private var interactionEnabled = true
    private var touchMonitor: PhotoTouchMonitor?
    private var hslTarget: HSLTargetCanvasInput?
    private var hslTargetPoint: CGPoint?
    private var targetOrigin: CGPoint?
    private var targetImage: UIImage?
    private var lastLayoutBounds = CGSize.zero
    private var lastLayoutSide: Bool?
    private var needsViewportApply = true
    private let targetRecognizer = PhotoHSLTargetRecognizer()
    private let inspectionRecognizer = PhotoHSLTargetRecognizer()
    private let sampleLoupe = PhotoSampleLoupe(frame: CGRect(x: 0, y: 0, width: 88, height: 88))
    private let sampleMarker = UIView()
    private let inspectionCrosshair = UIView()
    private var inspectionPinLabels: [UILabel] = []
    private var inspectionOverlay: InspectionOverlayMode = .none
    private var inspectionProbeEnabled = false
    private var inspectionPoint: CGPoint?
    private var inspectionAnchors: [(index: Int, point: CGPoint, selected: Bool)] = []
    private var unmaskedSampleImage: UIImage?
    private var inspectionDragging = false
    var onInspectionPointChange: ((CGPoint) -> Void)?
    var onViewingChange: ((PhotoViewingState) -> Void)?
    var onViewportChange: ((PhotoViewport) -> Void)?
    var onPreviewSizeChange: ((Int) -> Void)?
    var onDetailRequest: ((PhotoDetailRequest?) -> Void)?

    private static let neutralGray50UIImage: UIImage = {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        return renderer.image { ctx in
            UIColor(red: 128.0 / 255.0, green: 128.0 / 255.0, blue: 128.0 / 255.0, alpha: 1.0).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }()

    private static func displayImage(for image: UIImage?, hdr: HDRDisplayImage?, overlay: InspectionOverlayMode) -> UIImage? {
        guard overlay != .none else { return image }
        if overlay == .neutralGray50 { return neutralGray50UIImage }
        guard let cg = hdr?.sdrImage ?? image?.cgImage,
              let rendered = InspectionOverlayRenderer.shared.render(cg, mode: overlay) else { return image }
        return UIImage(cgImage: rendered, scale: 1, orientation: .up)
    }

    static func displayCGImage(for cgImage: CGImage?, overlay: InspectionOverlayMode) -> CGImage? {
        guard overlay != .none else { return cgImage }
        if overlay == .neutralGray50 { return neutralGray50UIImage.cgImage }
        guard let cgImage else { return nil }
        return InspectionOverlayRenderer.shared.render(cgImage, mode: overlay) ?? cgImage
    }

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
        inspectionRecognizer.addTarget(self, action: #selector(inspectionDragged(_:)))
        inspectionRecognizer.isEnabled = false
        inspectionRecognizer.canBegin = { [weak self] point in
            guard let self else { return false }
            return self.inspectionCoordinate(point) != nil
        }
        addGestureRecognizer(inspectionRecognizer)
        sampleLoupe.isHidden = true
        sampleMarker.isHidden = true; sampleMarker.isUserInteractionEnabled = false
        sampleMarker.layer.cornerRadius = 9; sampleMarker.layer.borderWidth = 2
        sampleMarker.layer.borderColor = UIColor.white.cgColor
        sampleMarker.layer.shadowColor = UIColor.black.cgColor; sampleMarker.layer.shadowOpacity = 1
        sampleMarker.layer.shadowRadius = 1; sampleMarker.layer.shadowOffset = .zero
        inspectionCrosshair.isHidden = true; inspectionCrosshair.isUserInteractionEnabled = false
        inspectionCrosshair.layer.cornerRadius = 11; inspectionCrosshair.layer.borderWidth = 2
        inspectionCrosshair.layer.borderColor = UIColor.systemYellow.cgColor
        inspectionCrosshair.layer.shadowColor = UIColor.black.cgColor; inspectionCrosshair.layer.shadowOpacity = 1
        inspectionCrosshair.layer.shadowRadius = 1.5; inspectionCrosshair.layer.shadowOffset = .zero
        inspectionCrosshair.accessibilityIdentifier = "inspection.crosshair"
        for idx in 1...InspectionAnchor.maxCount {
            let badge = UILabel(frame: CGRect(x: 0, y: 0, width: 22, height: 22))
            badge.font = .systemFont(ofSize: 10, weight: .bold)
            badge.textAlignment = .center
            badge.layer.cornerRadius = 11
            badge.layer.masksToBounds = true
            badge.layer.borderWidth = 1.5
            badge.text = "\(idx)"
            badge.isHidden = true
            badge.isUserInteractionEnabled = false
            inspectionPinLabels.append(badge)
        }
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
        addSubview(inspectionCrosshair)
        inspectionPinLabels.forEach { addSubview($0) }
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
        let handleScrollViewport: (PhotoScrollView, PhotoViewport, Bool) -> Void = { [weak self] scroll, value, commitToSwiftUI in
            guard let self, !self.syncingViewport else { return }
            self.cancelTargetInput()
            self.viewport = value
            self.needsViewportApply = false
            self.syncingViewport = true
            (scroll === self.result ? self.reference : self.result).applyViewport(value)
            self.syncingViewport = false
            self.layoutOverlays()
            if commitToSwiftUI {
                self.lastPublishedViewport = value
                self.onViewportChange?(value)
            }
        }
        for scroll in [result, reference] {
            scroll.onGestureCancel = { [weak self] in self?.cancelTargetInput() }
            scroll.onInteractiveViewportSync = { [weak scroll] value in
                guard let scroll else { return }
                handleScrollViewport(scroll, value, false)
            }
            scroll.onViewportChange = { [weak scroll] value in
                guard let scroll else { return }
                handleScrollViewport(scroll, value, true)
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
        }
        result.onPreviewSizeChange = { [weak self] edge in self?.onPreviewSizeChange?(edge) }
        result.onDetailRequest = { [weak self] request in self?.onDetailRequest?(request) }
        NotificationCenter.default.addObserver(self, selector: #selector(cancelTemporaryViewing),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(image: UIImage, reference imageBefore: UIImage?, label: String,
                   state: PhotoViewingState, viewport: PhotoViewport, displayScale: CGFloat, overlayAvoidanceRect: CGRect = .zero,
                   isDraft: Bool, interactionEnabled: Bool, hslTarget: HSLTargetCanvasInput? = nil,
                   hslTargetPoint: CGPoint? = nil, nativePixelSize: CGSize? = nil, previewSourceSize: CGSize? = nil,
                   previewLongEdgeLimit: Int = PhotoZoomGeometry.defaultPreviewLongEdge,
                   detailOverlay: PhotoDetailOverlay? = nil, detailTiles: [PhotoDetailOverlay] = [],
                   detailBacking: PhotoDetailBacking? = nil, hdr: HDRDisplayImage? = nil,
                   referenceHDR: HDRDisplayImage? = nil, hdrDisplay: HDRDisplayState? = nil,
                   inspectionOverlay: InspectionOverlayMode = .none,
                   inspectionProbeEnabled: Bool = false,
                   inspectionPoint: CGPoint? = nil,
                   inspectionAnchors: [(index: Int, point: CGPoint, selected: Bool)] = []) {
        let externalViewportChange = viewport != self.viewport && viewport != self.lastPublishedViewport
        if self.hslTarget?.scope != hslTarget?.scope || !interactionEnabled || isDraft || externalViewportChange {
            cancelTargetInput()
        }
        var displayState = state
        if interactionEnabled && !isDraft && hslTarget != nil { displayState.endTemporaryViewing() }
        if imageBefore == nil {
            displayState.enabled = false
            displayState.endTemporaryViewing()
        }
        let renderedPixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let pixels = nativePixelSize ?? renderedPixels
        let sideBySide = displayState.enabled && displayState.preferredMode == .sideBySide && !isDraft
        let wipeActive = displayState.enabled && displayState.preferredMode == .wipe && !isDraft
        let activeOverlay = isDraft ? .none : inspectionOverlay
        let rawResultImage = displayState.holdingBefore ? imageBefore : image
        unmaskedSampleImage = rawResultImage
        let nextResultImage = Self.displayImage(for: rawResultImage, hdr: displayState.holdingBefore ? referenceHDR : hdr, overlay: activeOverlay)
        let nextBeforeImage = Self.displayImage(for: imageBefore, hdr: referenceHDR, overlay: activeOverlay)
        let nextAvoidance = displayState.enabled && !displayState.previewOnly && !isDraft ? overlayAvoidanceRect : .zero
        let anchorsChanged = self.inspectionAnchors.count != inspectionAnchors.count ||
            zip(self.inspectionAnchors, inspectionAnchors).contains { $0.0 != $1.0 || $0.1 != $1.1 || $0.2 != $1.2 }
        let viewportInputsChanged = externalViewportChange
            || result.pixels != pixels
            || result.displayScale != displayScale
            || result.photoMargin != displayState.photoMargin
            || lastLayoutSide != sideBySide
        let layoutInputsChanged = viewportInputsChanged
            || self.state != displayState
            || self.isDraft != isDraft
            || self.overlayAvoidanceRect != nextAvoidance
            || self.hslTargetPoint != hslTargetPoint
            || self.inspectionOverlay != activeOverlay
            || self.inspectionProbeEnabled != inspectionProbeEnabled
            || self.inspectionPoint != inspectionPoint
            || anchorsChanged
            || result.imageView.image !== nextResultImage
            || reference.imageView.image !== nextBeforeImage
            || (wipeActive && result.comparisonImage !== nextBeforeImage)
            || (!wipeActive && result.comparisonImage != nil)
        if viewportInputsChanged {
            needsViewportApply = true
        }

        self.hslTarget = interactionEnabled && !isDraft ? hslTarget : nil
        self.hslTargetPoint = hslTargetPoint
        targetRecognizer.isEnabled = self.hslTarget != nil
        self.inspectionOverlay = activeOverlay
        self.inspectionProbeEnabled = inspectionProbeEnabled && interactionEnabled && !isDraft && self.hslTarget == nil
        self.inspectionPoint = inspectionPoint
        self.inspectionAnchors = inspectionAnchors
        inspectionRecognizer.isEnabled = self.inspectionProbeEnabled
        self.state = displayState
        self.overlayAvoidanceRect = nextAvoidance
        if externalViewportChange || self.lastPublishedViewport == nil {
            self.viewport = viewport
            self.lastPublishedViewport = viewport
        }
        self.isDraft = isDraft
        self.interactionEnabled = interactionEnabled
        result.previewNativeSize = previewSourceSize ?? (hdr == nil ? nil : nativePixelSize)
        result.previewLongEdgeLimit = previewLongEdgeLimit
        let activeBacking = (isDraft || hdr != nil) ? nil : detailBacking
        let backingEdge = activeBacking.map { Int(max($0.pixelSize.width, $0.pixelSize.height).rounded()) } ?? 0
        let beforeBackingEdge = (activeBacking?.beforeCGImage != nil) ? backingEdge : 0
        let afterBaseEdge = max(Int(max(renderedPixels.width, renderedPixels.height).rounded()), backingEdge)
        let beforeBaseEdge = imageBefore.map {
            max(Int(max($0.size.width * $0.scale, $0.size.height * $0.scale).rounded()), beforeBackingEdge)
        } ?? afterBaseEdge
        result.baseLongEdge = displayState.holdingBefore ? beforeBaseEdge : afterBaseEdge
        reference.baseLongEdge = beforeBaseEdge
        let maxDetailEdge = hdr == nil ? 2048 : 1280
        result.maxDetailLongEdge = maxDetailEdge
        reference.maxDetailLongEdge = maxDetailEdge
        for scroll in [result, reference] {
            scroll.pixels = pixels
            scroll.displayScale = displayScale
            scroll.photoMargin = displayState.photoMargin
            scroll.targetMode = self.hslTarget != nil || self.inspectionProbeEnabled
            scroll.canvasActionsEnabled = interactionEnabled && !isDraft && self.hslTarget == nil && !self.inspectionProbeEnabled
            scroll.holdEnabled = interactionEnabled && !isDraft && !displayState.enabled && imageBefore != nil && self.hslTarget == nil && !self.inspectionProbeEnabled
            scroll.previewOnly = displayState.previewOnly
            scroll.refreshAccessibilityActionsIfNeeded()
        }
        if result.imageView.image !== nextResultImage {
            result.imageView.image = nextResultImage
        }
        let nextComparison = wipeActive ? nextBeforeImage : nil
        if result.comparisonImage !== nextComparison {
            result.comparisonImage = nextComparison
        }
        if abs(result.wipePosition - displayState.split) > 1e-6 {
            result.wipePosition = displayState.split
        }
        result.setHDR(activeOverlay == .none ? (displayState.holdingBefore ? referenceHDR : hdr) : nil,
            before: activeOverlay == .none && wipeActive ? referenceHDR : nil, state: hdrDisplay)
        let activeTiles = isDraft ? [] : detailTiles
        let useTiledSDR = !activeTiles.isEmpty && hdr == nil
        let activeDetail = (isDraft || useTiledSDR) ? nil : detailOverlay
        let afterDetailImage = activeDetail?.cgImage.flatMap {
            Self.displayCGImage(for: $0, overlay: activeOverlay).map { UIImage(cgImage: $0, scale: 1, orientation: .up) }
        }
        let beforeDetailImage = activeDetail?.beforeCGImage.flatMap {
            Self.displayCGImage(for: $0, overlay: activeOverlay).map { UIImage(cgImage: $0, scale: 1, orientation: .up) }
        }
        result.setDetailBacking(activeBacking, showBefore: displayState.holdingBefore, wipeBefore: wipeActive, overlay: activeOverlay)
        result.setDetailTiles(useTiledSDR ? activeTiles : [], showBefore: displayState.holdingBefore, wipeBefore: wipeActive, overlay: activeOverlay)
        result.setDetail(
            image: displayState.holdingBefore ? beforeDetailImage : afterDetailImage,
            hdr: activeOverlay == .none ? (displayState.holdingBefore ? activeDetail?.beforeHDR : activeDetail?.hdr) : nil,
            beforeImage: wipeActive ? beforeDetailImage : nil,
            beforeHDR: activeOverlay == .none && wipeActive ? activeDetail?.beforeHDR : nil,
            normalizedRect: activeDetail?.normalizedRect,
            state: hdrDisplay
        )
        let nextResultLabel = displayState.holdingBefore ? L10n.text("调整前") : label
        if result.accessibilityLabel != nextResultLabel {
            result.accessibilityLabel = nextResultLabel
        }
        if reference.imageView.image !== nextBeforeImage {
            reference.imageView.image = nextBeforeImage
        }
        reference.setHDR(activeOverlay == .none ? referenceHDR : nil, before: nil, state: hdrDisplay)
        reference.setDetailBacking(sideBySide ? activeBacking : nil, showBefore: true, wipeBefore: false, overlay: activeOverlay)
        reference.setDetailTiles(useTiledSDR && sideBySide ? activeTiles : [], showBefore: true, wipeBefore: false, overlay: activeOverlay)
        reference.setDetail(
            image: sideBySide ? beforeDetailImage : nil,
            hdr: activeOverlay == .none && sideBySide ? activeDetail?.beforeHDR : nil,
            beforeImage: nil,
            beforeHDR: nil,
            normalizedRect: sideBySide ? activeDetail?.normalizedRect : nil,
            state: hdrDisplay
        )
        reference.accessibilityLabel = L10n.text("调整前")
        reference.accessibilityIdentifier = "editor.photo.before"
        reference.isHidden = !sideBySide
        beforeLabel.text = L10n.text("调整前")
        afterLabel.text = L10n.text("调整后")
        divider.accessibilityLabel = L10n.text("分割位置")
        divider.position = displayState.split
        if displayState.previewOnly && window != nil { becomeFirstResponder() }
        if layoutInputsChanged || bounds.size != lastLayoutBounds || lastLayoutSide != sideBySide {
            setNeedsLayout()
        }
        result.reportDetailRequestIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = state.enabled && state.preferredMode == .sideBySide && !isDraft
        let boundsChanged = lastLayoutBounds != bounds.size
        let sideChanged = lastLayoutSide != side
        lastLayoutBounds = bounds.size
        lastLayoutSide = side
        let layout = PhotoComparisonLayout(size: bounds.size, enabled: side)
        syncingViewport = true
        let refFrame = CGRect(origin: .zero, size: layout.paneSize)
        if reference.frame != refFrame {
            reference.frame = refFrame
        }
        let resFrame = side ? CGRect(origin: CGPoint(x: layout.horizontal ? layout.paneSize.width : 0,
                                                     y: layout.horizontal ? 0 : layout.paneSize.height), size: layout.paneSize) : bounds
        if result.frame != resFrame {
            result.frame = resFrame
        }
        for scroll in [result, reference] where !scroll.isHidden {
            if boundsChanged || sideChanged || needsViewportApply {
                scroll.setNeedsLayout()
                scroll.layoutIfNeeded()
            }
            let gestureActive = scroll.isTracking || scroll.isDragging || scroll.isZooming || scroll.isDecelerating
            if (boundsChanged || sideChanged || needsViewportApply) && !gestureActive {
                scroll.applyViewport(viewport)
            }
        }
        if !result.isTracking && !result.isDragging && !result.isZooming && !result.isDecelerating &&
           !reference.isTracking && !reference.isDragging && !reference.isZooming && !reference.isDecelerating {
            needsViewportApply = false
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
        let showCrosshair = inspectionProbeEnabled && !isDraft && hslTarget == nil && inspectionOverlay != .neutralGray50
        inspectionCrosshair.isHidden = !showCrosshair
        if showCrosshair {
            let pt = inspectionPoint ?? CGPoint(x: 0.5, y: 0.5)
            inspectionCrosshair.frame = CGRect(
                x: imageRect.minX + pt.x * imageRect.width - 11,
                y: imageRect.minY + pt.y * imageRect.height - 11,
                width: 22,
                height: 22
            )
        }
        let showPins = !isDraft && inspectionOverlay != .neutralGray50 && !imageRect.isEmpty
        for (slot, badge) in inspectionPinLabels.enumerated() {
            if showPins, let anchor = inspectionAnchors.first(where: { $0.index == slot + 1 }) {
                badge.isHidden = false
                badge.backgroundColor = anchor.selected ? UIColor.systemYellow : UIColor.black.withAlphaComponent(0.75)
                badge.textColor = anchor.selected ? .black : .white
                badge.layer.borderColor = (anchor.selected ? UIColor.black : UIColor.white).cgColor
                badge.center = CGPoint(
                    x: imageRect.minX + anchor.point.x * imageRect.width,
                    y: imageRect.minY + anchor.point.y * imageRect.height
                )
            } else {
                badge.isHidden = true
            }
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
        targetOrigin = nil; targetImage = nil
        if !inspectionDragging { sampleLoupe.isHidden = true }
        hslTarget?.cancel()
        if reset && (targetRecognizer.state == .began || targetRecognizer.state == .changed) {
            targetRecognizer.isEnabled = false; targetRecognizer.isEnabled = hslTarget != nil
        }
    }
    private func inspectionCoordinate(_ point: CGPoint) -> CGPoint? {
        guard inspectionProbeEnabled, interactionEnabled, !isDraft, !state.holdingBefore else { return nil }
        let imagePoint = result.imageView.convert(point, from: self)
        let rect = result.imageView.bounds
        guard rect.width > 0, rect.height > 0 else { return nil }
        if !inspectionDragging {
            guard result.visiblePhotoRect(in: self).contains(point), !overlayAvoidanceRect.contains(point),
                  rect.contains(imagePoint) else { return nil }
        }
        return CGPoint(
            x: min(1.0, max(0.0, (imagePoint.x - rect.minX) / rect.width)),
            y: min(1.0, max(0.0, (imagePoint.y - rect.minY) / rect.height))
        )
    }
    @objc private func inspectionDragged(_ recognizer: PhotoHSLTargetRecognizer) {
        switch recognizer.state {
        case .began:
            guard let pt = inspectionCoordinate(recognizer.point) else { return }
            inspectionDragging = true
            inspectionPoint = pt
            onInspectionPointChange?(pt)
            updateInspectionLoupe(at: recognizer.point, normalized: pt)
            layoutOverlays()
        case .changed:
            guard let pt = inspectionCoordinate(recognizer.point) else { return }
            inspectionPoint = pt
            onInspectionPointChange?(pt)
            updateInspectionLoupe(at: recognizer.point, normalized: pt)
            layoutOverlays()
        case .ended, .cancelled, .failed:
            inspectionDragging = false
            sampleLoupe.isHidden = true
        default:
            break
        }
    }
    private func updateInspectionLoupe(at point: CGPoint, normalized: CGPoint) {
        sampleLoupe.image = unmaskedSampleImage
        sampleLoupe.normalizedPoint = normalized
        sampleLoupe.displayWidth = result.imageView.convert(result.imageView.bounds, to: self).width
        let x = min(max(44, point.x), max(44, bounds.width - 44))
        let desiredY = point.y >= 110 ? point.y - 72 : point.y + 72
        sampleLoupe.center = CGPoint(x: x, y: min(max(44, desiredY), max(44, bounds.height - 44)))
        sampleLoupe.isHidden = unmaskedSampleImage == nil
        sampleLoupe.setNeedsDisplay()
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
    let detailBackingLayer = CALayer()
    let detailTileContainer = UIView()
    let detailImageView = UIImageView()
    private let beforeImageView = UIImageView()
    let beforeDetailBackingLayer = CALayer()
    let beforeDetailTileContainer = UIView()
    let beforeDetailImageView = UIImageView()
    private let wipeMaskLayer = CAShapeLayer()
    private var hdrHost: UIHostingController<HDRCanvas>?
    private var beforeHDRHost: UIHostingController<HDRCanvas>?
    private var detailHDRHost: UIHostingController<HDRCanvas>?
    private var beforeDetailHDRHost: UIHostingController<HDRCanvas>?
    private var afterBackingCGImage: CGImage?
    private var beforeBackingCGImage: CGImage?
    private var lastDetailInputs: (
        afterCG: CGImage?,
        beforeCG: CGImage?,
        hdrID: ObjectIdentifier?,
        beforeHDRID: ObjectIdentifier?,
        normalizedRect: CGRect?,
        state: HDRDisplayState?
    )?
    private var lastAccessibilitySignature: (Bool, Bool, Bool)?
    private var afterTileLayers: [PhotoDetailTileKey: (layer: CALayer, normalizedRect: CGRect, cgImage: CGImage)] = [:]
    private var beforeTileLayers: [PhotoDetailTileKey: (layer: CALayer, normalizedRect: CGRect, cgImage: CGImage)] = [:]

    var activeDetailTileCount: Int { afterTileLayers.count }
    var activeBeforeDetailTileCount: Int { beforeTileLayers.count }
    var currentWipeMaskLayer: CAShapeLayer { wipeMaskLayer }

    func detailTileLayer(for key: PhotoDetailTileKey) -> CALayer? { afterTileLayers[key]?.layer }

    private func updateHDRHost(_ host: inout UIHostingController<HDRCanvas>?, image: HDRDisplayImage?, state: HDRDisplayState?, container: UIImageView) {
        guard let image, let state else { host?.view.removeFromSuperview(); host = nil; return }
        if let host { host.rootView = HDRCanvas(presentation: image, state: state, boundedDrawable: true) }
        else {
            let next = UIHostingController(rootView: HDRCanvas(presentation: image, state: state, boundedDrawable: true))
            next.view.backgroundColor = .clear
            next.view.isUserInteractionEnabled = false
            next.view.frame = container.bounds
            next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.insertSubview(next.view, at: 0)
            host = next
        }
    }

    func setHDR(_ presentation: HDRDisplayImage?, before: HDRDisplayImage?, state: HDRDisplayState?) {
        updateHDRHost(&hdrHost, image: presentation, state: state, container: imageView)
        updateHDRHost(&beforeHDRHost, image: before, state: state, container: beforeImageView)
    }

    func setDetailBacking(_ backing: PhotoDetailBacking?, showBefore: Bool, wipeBefore: Bool, overlay: InspectionOverlayMode = .none) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let nextAfter = backing.flatMap {
            PhotoCanvasView.displayCGImage(for: showBefore ? ($0.beforeCGImage ?? $0.cgImage) : $0.cgImage, overlay: overlay)
        }
        let nextBefore = wipeBefore ? backing.flatMap {
            PhotoCanvasView.displayCGImage(for: $0.beforeCGImage ?? $0.cgImage, overlay: overlay)
        } : nil

        detailBackingLayer.frame = imageView.bounds
        if let nextAfter {
            let shouldFade = detailBackingLayer.isHidden || afterBackingCGImage !== nextAfter
            detailBackingLayer.isHidden = false
            if afterBackingCGImage !== nextAfter {
                detailBackingLayer.contents = nextAfter
                afterBackingCGImage = nextAfter
            }
            detailBackingLayer.opacity = 1
            if shouldFade && imageView.window != nil {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = 0.12
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                detailBackingLayer.add(fade, forKey: "rawlab.backing.fade")
            }
        } else {
            detailBackingLayer.isHidden = true
            if afterBackingCGImage != nil {
                detailBackingLayer.contents = nil
                afterBackingCGImage = nil
            }
        }

        beforeDetailBackingLayer.frame = beforeImageView.bounds
        if let nextBefore, !beforeImageView.isHidden {
            let shouldFade = beforeDetailBackingLayer.isHidden || beforeBackingCGImage !== nextBefore
            beforeDetailBackingLayer.isHidden = false
            if beforeBackingCGImage !== nextBefore {
                beforeDetailBackingLayer.contents = nextBefore
                beforeBackingCGImage = nextBefore
            }
            beforeDetailBackingLayer.opacity = 1
            if shouldFade && beforeImageView.window != nil {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = 0.12
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                beforeDetailBackingLayer.add(fade, forKey: "rawlab.backing.fade")
            }
        } else {
            beforeDetailBackingLayer.isHidden = true
            if beforeBackingCGImage != nil {
                beforeDetailBackingLayer.contents = nil
                beforeBackingCGImage = nil
            }
        }
    }

    func setDetail(
        image: UIImage?,
        hdr: HDRDisplayImage?,
        beforeImage: UIImage?,
        beforeHDR: HDRDisplayImage?,
        normalizedRect: CGRect?,
        state: HDRDisplayState?
    ) {
        let nextInputs = (
            afterCG: image?.cgImage,
            beforeCG: beforeImage?.cgImage,
            hdrID: hdr.map { ObjectIdentifier($0) },
            beforeHDRID: beforeHDR.map { ObjectIdentifier($0) },
            normalizedRect: normalizedRect,
            state: state
        )
        if let prev = lastDetailInputs,
           prev.afterCG === nextInputs.afterCG,
           prev.beforeCG === nextInputs.beforeCG,
           prev.hdrID == nextInputs.hdrID,
           prev.beforeHDRID == nextInputs.beforeHDRID,
           prev.normalizedRect == nextInputs.normalizedRect,
           prev.state === nextInputs.state {
            return
        }
        lastDetailInputs = nextInputs
        detailNormalizedRect = normalizedRect
        detailImageView.image = image
        beforeDetailImageView.image = beforeImage
        updateHDRHost(&detailHDRHost, image: hdr, state: state, container: detailImageView)
        updateHDRHost(&beforeDetailHDRHost, image: beforeHDR, state: state, container: beforeDetailImageView)
        updateDetailLayout()
    }

    func setDetailTiles(_ tiles: [PhotoDetailOverlay], showBefore: Bool, wipeBefore: Bool, overlay: InspectionOverlayMode = .none) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let bounds = imageView.bounds
        if detailTileContainer.frame != bounds {
            detailTileContainer.frame = bounds
        }
        if beforeDetailTileContainer.frame != beforeImageView.bounds {
            beforeDetailTileContainer.frame = beforeImageView.bounds
        }

        var desiredAfter: [PhotoDetailTileKey: (PhotoDetailOverlay, CGImage)] = [:]
        var desiredBefore: [PhotoDetailTileKey: (PhotoDetailOverlay, CGImage)] = [:]
        for tile in tiles {
            guard let key = tile.tileKey else { continue }
            if let afterRaw = showBefore ? (tile.beforeCGImage ?? tile.cgImage) : tile.cgImage,
               let afterCG = PhotoCanvasView.displayCGImage(for: afterRaw, overlay: overlay) {
                desiredAfter[key] = (tile, afterCG)
            }
            if wipeBefore,
               let beforeRaw = tile.beforeCGImage ?? tile.cgImage,
               let beforeCG = PhotoCanvasView.displayCGImage(for: beforeRaw, overlay: overlay) {
                desiredBefore[key] = (tile, beforeCG)
            }
        }

        syncTileLayers(&afterTileLayers, in: detailTileContainer, desired: desiredAfter, bounds: bounds)
        syncTileLayers(&beforeTileLayers, in: beforeDetailTileContainer, desired: desiredBefore, bounds: beforeImageView.bounds)
        detailTileContainer.isHidden = afterTileLayers.isEmpty
        beforeDetailTileContainer.isHidden = beforeImageView.isHidden || beforeTileLayers.isEmpty
    }

    private func syncTileLayers(
        _ pool: inout [PhotoDetailTileKey: (layer: CALayer, normalizedRect: CGRect, cgImage: CGImage)],
        in container: UIView,
        desired: [PhotoDetailTileKey: (PhotoDetailOverlay, CGImage)],
        bounds: CGRect
    ) {
        for key in Array(pool.keys) where desired[key] == nil {
            pool.removeValue(forKey: key)?.layer.removeFromSuperlayer()
        }
        guard bounds.width > 0, bounds.height > 0 else { return }
        let visibleInImage = container.window != nil ? convert(self.bounds, to: imageView) : .null
        for (key, (tile, cg)) in desired {
            let rect = tile.normalizedRect
            let frame = CGRect(
                x: rect.minX * bounds.width,
                y: rect.minY * bounds.height,
                width: rect.width * bounds.width,
                height: rect.height * bounds.height
            )
            if var entry = pool[key] {
                if entry.cgImage !== cg {
                    entry.layer.contents = cg
                    entry.cgImage = cg
                }
                if entry.layer.frame != frame {
                    entry.layer.frame = frame
                }
                entry.normalizedRect = rect
                pool[key] = entry
            } else {
                let layer = CALayer()
                layer.contentsGravity = .resize
                layer.minificationFilter = .trilinear
                layer.magnificationFilter = .linear
                layer.isOpaque = true
                layer.edgeAntialiasingMask = []
                layer.zPosition = CGFloat(100 - key.level)
                layer.contents = cg
                layer.frame = frame
                layer.opacity = 1
                container.layer.addSublayer(layer)
                if !visibleInImage.isNull && !visibleInImage.isEmpty && frame.intersects(visibleInImage) {
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 0
                    fade.toValue = 1
                    fade.duration = 0.10
                    fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    layer.add(fade, forKey: "rawlab.tile.fade")
                }
                pool[key] = (layer: layer, normalizedRect: rect, cgImage: cg)
            }
        }
    }

    var comparisonImage: UIImage? {
        didSet {
            if comparisonImage !== oldValue {
                beforeImageView.image = comparisonImage
                updateWipe()
            }
        }
    }
    var wipePosition: CGFloat = 0.5 {
        didSet {
            if abs(wipePosition - oldValue) > 1e-6 {
                updateWipe()
            }
        }
    }
    var pixels = CGSize.zero
    var previewNativeSize: CGSize?
    var previewLongEdgeLimit = PhotoZoomGeometry.defaultPreviewLongEdge
    var baseLongEdge = 0
    var maxDetailLongEdge = 2048
    var displayScale: CGFloat = 1
    var photoMargin = true
    var canvasActionsEnabled = true
    var holdEnabled = true
    var previewOnly = false
    private var detailNormalizedRect: CGRect?
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
    var onDetailRequest: ((PhotoDetailRequest?) -> Void)?
    var onInteractiveViewportSync: ((PhotoViewport) -> Void)?
    var onViewportChange: ((PhotoViewport) -> Void)?
    var onCanvasTap: (() -> Void)?
    var onHoldingChange: ((Bool) -> Void)?
    private var reportedEdge: Int?
    private var lastDetailRequest: PhotoDetailRequest?

    private var isGestureActive: Bool {
        isTracking || isDragging || isZooming || isDecelerating
    }

    init() {
        super.init(frame: .zero)
        delegate = self
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        bounces = false
        bouncesZoom = false
        imageView.contentMode = .scaleToFill
        imageView.layer.minificationFilter = .trilinear
        beforeImageView.contentMode = .scaleToFill
        beforeImageView.layer.minificationFilter = .trilinear
        for backingLayer in [detailBackingLayer, beforeDetailBackingLayer] {
            backingLayer.contentsGravity = .resize
            backingLayer.minificationFilter = .trilinear
            backingLayer.magnificationFilter = .linear
            backingLayer.isOpaque = true
            backingLayer.edgeAntialiasingMask = []
            backingLayer.isHidden = true
        }
        detailTileContainer.isUserInteractionEnabled = false
        detailTileContainer.clipsToBounds = true
        detailTileContainer.isHidden = true
        detailImageView.contentMode = .scaleToFill
        detailImageView.clipsToBounds = true
        detailImageView.isHidden = true
        beforeDetailTileContainer.isUserInteractionEnabled = false
        beforeDetailTileContainer.clipsToBounds = true
        beforeDetailTileContainer.isHidden = true
        beforeDetailImageView.contentMode = .scaleToFill
        beforeDetailImageView.clipsToBounds = true
        beforeDetailImageView.isHidden = true
        beforeImageView.layer.addSublayer(beforeDetailBackingLayer)
        beforeImageView.addSubview(beforeDetailTileContainer)
        beforeImageView.addSubview(beforeDetailImageView)
        imageView.layer.addSublayer(detailBackingLayer)
        imageView.addSubview(detailTileContainer)
        imageView.addSubview(detailImageView)
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
        refreshAccessibilityActionsIfNeeded()
    }

    func refreshAccessibilityActionsIfNeeded() {
        let signature = (canvasActionsEnabled, holdEnabled, previewOnly)
        if let prev = lastAccessibilitySignature, prev == signature {
            return
        }
        lastAccessibilitySignature = signature
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
        guard previousSize != bounds.size || previousPixels != pixels || previousDisplayScale != displayScale || previousMargin != photoMargin || geometry == nil else {
            if !isGestureActive {
                updateWipe()
            } else {
                updateDetailLayout()
            }
            return
        }
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
        reportDetailRequest()
    }

    func visiblePhotoRect(in view: UIView) -> CGRect { imageView.convert(imageView.bounds, to: view).intersection(convert(bounds, to: view)) }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        publishViewport()
        reportDetailRequest()
    }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        if !isZooming || UIAccessibility.isVoiceOverRunning {
            updateAccessibilityValue()
        }
        reportPreviewSize()
        publishViewport()
        reportDetailRequest()
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            publishViewport(forceCommit: true)
            updateAccessibilityValue()
        }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        publishViewport(forceCommit: true)
        updateAccessibilityValue()
    }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        if !isDragging && !isDecelerating {
            publishViewport(forceCommit: true)
        }
        updateAccessibilityValue()
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { cancelCanvasGestures() }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { cancelCanvasGestures() }

    private func publishViewport(forceCommit: Bool = false) {
        // 布局切换先改变 bounds，旧 geometry 此时不能反算新的查看中心。
        guard !updatingGeometry, previousSize == bounds.size, let geometry, geometry.fitScale > 0, zoomScale > 0 else { return }
        sharedViewport = PhotoViewport(relativeScale: zoomScale / geometry.fitScale,
                                      focus: CGPoint(x: (contentOffset.x + bounds.width / 2) / (geometry.imageSize.width * zoomScale),
                                                     y: (contentOffset.y + bounds.height / 2) / (geometry.imageSize.height * zoomScale)))
        if forceCommit || !isGestureActive {
            onViewportChange?(sharedViewport)
        } else {
            onInteractiveViewportSync?(sharedViewport)
        }
    }

    private func updateWipe() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if comparisonImage != nil {
            beforeImageView.frame = imageView.bounds
            beforeImageView.isHidden = false
            let maskRect = CGRect(x: 0, y: 0, width: imageView.bounds.width * wipePosition, height: imageView.bounds.height)
            if beforeImageView.layer.mask !== wipeMaskLayer {
                beforeImageView.layer.mask = wipeMaskLayer
            }
            wipeMaskLayer.frame = beforeImageView.bounds
            wipeMaskLayer.path = CGPath(rect: maskRect, transform: nil)
        } else {
            beforeImageView.isHidden = true
            if beforeImageView.layer.mask != nil {
                beforeImageView.layer.mask = nil
            }
        }
        updateDetailLayout()
    }

    private func updateDetailLayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let bounds = imageView.bounds
        detailBackingLayer.frame = bounds
        beforeDetailBackingLayer.frame = beforeImageView.bounds
        if detailTileContainer.frame != bounds {
            detailTileContainer.frame = bounds
        }
        if beforeDetailTileContainer.frame != beforeImageView.bounds {
            beforeDetailTileContainer.frame = beforeImageView.bounds
        }
        if bounds.width > 0, bounds.height > 0 {
            for (_, entry) in afterTileLayers {
                let rect = entry.normalizedRect
                let frame = CGRect(
                    x: rect.minX * bounds.width,
                    y: rect.minY * bounds.height,
                    width: rect.width * bounds.width,
                    height: rect.height * bounds.height
                )
                if entry.layer.frame != frame { entry.layer.frame = frame }
            }
            let bBounds = beforeImageView.bounds
            if bBounds.width > 0, bBounds.height > 0 {
                for (_, entry) in beforeTileLayers {
                    let rect = entry.normalizedRect
                    let frame = CGRect(
                        x: rect.minX * bBounds.width,
                        y: rect.minY * bBounds.height,
                        width: rect.width * bBounds.width,
                        height: rect.height * bBounds.height
                    )
                    if entry.layer.frame != frame { entry.layer.frame = frame }
                }
            }
        }
        detailTileContainer.isHidden = afterTileLayers.isEmpty
        beforeDetailTileContainer.isHidden = beforeImageView.isHidden || beforeTileLayers.isEmpty

        guard let rect = detailNormalizedRect,
              rect.width > 0, rect.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            detailImageView.isHidden = true
            beforeDetailImageView.isHidden = true
            return
        }
        let frame = CGRect(
            x: rect.minX * bounds.width,
            y: rect.minY * bounds.height,
            width: rect.width * bounds.width,
            height: rect.height * bounds.height
        )
        detailImageView.frame = frame
        detailHDRHost?.view.frame = detailImageView.bounds
        detailImageView.isHidden = detailImageView.image == nil && detailHDRHost == nil
        if !beforeImageView.isHidden {
            beforeDetailImageView.frame = frame
            beforeDetailHDRHost?.view.frame = beforeDetailImageView.bounds
            beforeDetailImageView.isHidden = beforeDetailImageView.image == nil && beforeDetailHDRHost == nil
        } else {
            beforeDetailImageView.isHidden = true
        }
    }

    func reportDetailRequestIfNeeded() {
        reportDetailRequest()
    }

    private func reportDetailRequest() {
        guard !updatingGeometry, previousSize == bounds.size, onDetailRequest != nil, let geometry else { return }
        let request = geometry.detailRegion(
            contentOffset: contentOffset,
            boundsSize: bounds.size,
            zoomScale: zoomScale,
            baseLongEdge: baseLongEdge,
            maxOutputLongEdge: maxDetailLongEdge,
            active: lastDetailRequest != nil
        ).map {
            PhotoDetailRequest(
                visibleRect: $0.visibleRect,
                overscanRect: $0.overscanRect,
                zoomScale: $0.zoomScale,
                baseScale: $0.baseScale,
                maxOutputLongEdge: $0.maxOutputLongEdge
            )
        }
        guard lastDetailRequest != request else { return }
        lastDetailRequest = request
        DispatchQueue.main.async { [weak self] in self?.onDetailRequest?(request) }
    }
    private func reportPreviewSize() {
        guard !updatingGeometry, onPreviewSizeChange != nil, let geometry else { return }
        if previewNativeSize == nil && onDetailRequest != nil && previewLongEdgeLimit <= PhotoZoomGeometry.defaultPreviewLongEdge {
            let edge = min(previewLongEdgeLimit, max(1, Int(geometry.pixelEdge.rounded())))
            guard reportedEdge != edge else { return }
            reportedEdge = edge
            DispatchQueue.main.async { [weak self] in self?.onPreviewSizeChange?(edge) }
            return
        }
        // HDR 渲染请求取整张源图的尺寸，查看缩放仍以交付像素为准。
        let edge = previewNativeSize.map { pixels in
            let native = PhotoZoomGeometry(pixels: pixels, viewport: bounds.size, displayScale: displayScale,
                                           margin: photoMargin ? PhotoZoomGeometry.defaultMargin : 0)
            // 100% 小于 Fit 时仍用 Fit 的请求，避免重渲染改变当前的像素比例。
            let relativeScale = max(1, zoomScale / geometry.fitScale)
            return native.previewLongEdge(scale: native.fitScale * relativeScale, limit: previewLongEdgeLimit)
        } ?? geometry.previewLongEdge(scale: zoomScale, limit: previewLongEdgeLimit)
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
