import CoreGraphics
import Foundation

struct PhotoZoomDetailRegion: Equatable {
    let visibleRect: CGRect
    let overscanRect: CGRect
    let zoomScale: CGFloat
    let baseScale: CGFloat
    let maxOutputLongEdge: Int
}

struct PhotoZoomGeometry {
    static let defaultMargin: CGFloat = 16
    static let defaultPreviewLongEdge = 1280

    static func detailOverlayCovers(
        normalizedRect: CGRect,
        pixelSize: CGSize,
        fullNativeSize: CGSize,
        visibleRect: CGRect,
        requiredZoomScale: CGFloat
    ) -> Bool {
        let tolerance: CGFloat = 0.0005
        guard normalizedRect.minX <= visibleRect.minX + tolerance,
              normalizedRect.minY <= visibleRect.minY + tolerance,
              normalizedRect.maxX >= visibleRect.maxX - tolerance,
              normalizedRect.maxY >= visibleRect.maxY - tolerance,
              normalizedRect.width > 0,
              fullNativeSize.width > 0 else {
            return false
        }
        let tileDensity = pixelSize.width / (normalizedRect.width * fullNativeSize.width)
        let neededDensity = min(1, requiredZoomScale)
        return tileDensity >= neededDensity * 0.9
    }

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

    func previewLongEdge(scale: CGFloat, limit: Int = PhotoZoomGeometry.defaultPreviewLongEdge) -> Int {
        guard scale.isFinite, scale > 0, pixelEdge.isFinite, pixelEdge > 0 else { return limit }
        return min(limit, Int(pixelEdge), max(64, Int(ceil(pixelEdge * scale / 64)) * 64))
    }

    var minimumScale: CGFloat { min(fitScale, 1) }
    var maximumScale: CGFloat { max(fitScale * 8, 4) }

    func isFit(_ scale: CGFloat) -> Bool {
        abs(scale - fitScale) < fitScale * 0.001
    }

    func doubleTapScale(from scale: CGFloat) -> CGFloat {
        isFit(scale) ? 1 : fitScale
    }

    func visibleNormalizedRect(contentOffset: CGPoint, boundsSize: CGSize, zoomScale: CGFloat) -> CGRect? {
        guard boundsSize.width > 0, boundsSize.height > 0, zoomScale.isFinite, zoomScale > 0,
              imageSize.width > 0, imageSize.height > 0 else {
            return nil
        }
        let scaledWidth = imageSize.width * zoomScale
        let scaledHeight = imageSize.height * zoomScale
        let x0 = max(0, min(1, contentOffset.x / scaledWidth))
        let y0 = max(0, min(1, contentOffset.y / scaledHeight))
        let x1 = max(x0, min(1, (contentOffset.x + boundsSize.width) / scaledWidth))
        let y1 = max(y0, min(1, (contentOffset.y + boundsSize.height) / scaledHeight))
        guard x1 > x0, y1 > y0 else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    func detailRegion(contentOffset: CGPoint, boundsSize: CGSize, zoomScale: CGFloat,
                      baseLongEdge: Int, maxOutputLongEdge: Int = 2048,
                      active: Bool = false) -> PhotoZoomDetailRegion? {
        guard baseLongEdge > 0, pixelEdge > CGFloat(baseLongEdge), maxOutputLongEdge > 0 else { return nil }
        let baseScale = min(1, CGFloat(baseLongEdge) / pixelEdge)
        let threshold = active ? baseScale * 0.85 : baseScale * 1.05
        guard min(1, zoomScale) > threshold else { return nil }
        guard let visible = visibleNormalizedRect(contentOffset: contentOffset, boundsSize: boundsSize, zoomScale: zoomScale) else {
            return nil
        }
        let padX = visible.width * 0.1
        let padY = visible.height * 0.1
        let x0 = max(0, visible.minX - padX)
        let y0 = max(0, visible.minY - padY)
        let x1 = min(1, visible.maxX + padX)
        let y1 = min(1, visible.maxY + padY)
        guard x1 > x0, y1 > y0 else { return nil }
        let overscan = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        return PhotoZoomDetailRegion(
            visibleRect: visible,
            overscanRect: overscan,
            zoomScale: zoomScale,
            baseScale: baseScale,
            maxOutputLongEdge: maxOutputLongEdge
        )
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
    var photoMargin = false

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
