import Foundation

struct PhotoZoomGeometry {
    static let defaultMargin: CGFloat = 16

    static func marginInset(viewport: CGSize, margin: CGFloat) -> CGFloat {
        max(0, min(margin, min(viewport.width, viewport.height) / 4))
    }

    let imageSize: CGSize
    let fitScale: CGFloat
    let pixelEdge: CGFloat

    init(pixels: CGSize, viewport: CGSize, displayScale: CGFloat, margin: CGFloat = PhotoZoomGeometry.defaultMargin) {
        imageSize = CGSize(width: pixels.width / displayScale, height: pixels.height / displayScale)
        let inset = Self.marginInset(viewport: viewport, margin: margin)
        fitScale = min(max(1, viewport.width - inset * 2) / imageSize.width,
                       max(1, viewport.height - inset * 2) / imageSize.height)
        pixelEdge = max(pixels.width, pixels.height)
    }

    func previewLongEdge(scale: CGFloat, limit: Int = 1280) -> Int {
        guard scale.isFinite, scale > 0, pixelEdge.isFinite, pixelEdge > 0 else { return limit }
        return min(limit, Int(pixelEdge), max(64, Int(ceil(pixelEdge * scale / 64)) * 64))
    }

    var minimumScale: CGFloat { min(fitScale, 1) }
    var maximumScale: CGFloat { max(fitScale * 8, 1) }

    func isFit(_ scale: CGFloat) -> Bool {
        abs(scale - fitScale) < fitScale * 0.001
    }

    func doubleTapScale(from scale: CGFloat) -> CGFloat {
        isFit(scale) ? 1 : fitScale
    }
}

struct PhotoViewport: Equatable {
    var relativeScale: CGFloat = 1
    var focus = CGPoint(x: 0.5, y: 0.5)

    func scale(in geometry: PhotoZoomGeometry) -> CGFloat {
        min(geometry.maximumScale, max(geometry.minimumScale, geometry.fitScale * relativeScale))
    }
}

struct PhotoComparisonLayout {
    let horizontal: Bool
    let paneSize: CGSize

    init(size: CGSize, enabled: Bool) {
        horizontal = size.width >= size.height
        paneSize = enabled ? CGSize(width: horizontal ? size.width / 2 : size.width,
                                    height: horizontal ? size.height : size.height / 2) : size
    }
}

enum PhotoComparisonMode: Equatable { case sideBySide, wipe }

struct PhotoViewingState: Equatable {
    var enabled = false
    var preferredMode = PhotoComparisonMode.sideBySide
    private(set) var split: CGFloat = 0.5
    private(set) var holdingBefore = false
    private(set) var previewOnly = false
    var photoMargin = true

    mutating func toggleComparison() {
        holdingBefore = false
        enabled.toggle()
    }

    mutating func selectMode(_ mode: PhotoComparisonMode) {
        holdingBefore = false
        preferredMode = mode
        enabled = true
    }

    mutating func setSplit(_ value: CGFloat) {
        guard value.isFinite else { return }
        split = min(1, max(0, value))
    }

    mutating func beginHolding(isDraft: Bool) {
        guard !isDraft, !enabled else { return }
        holdingBefore = true
    }

    mutating func endTemporaryViewing() { holdingBefore = false }

    mutating func togglePreview(isDraft: Bool) {
        guard !isDraft else { return }
        holdingBefore = false
        previewOnly.toggle()
    }

    mutating func sourceChanged() {
        enabled = false
        holdingBefore = false
        previewOnly = false
        split = 0.5
    }
}
