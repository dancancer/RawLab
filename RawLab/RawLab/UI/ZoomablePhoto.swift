import SwiftUI
import UIKit

struct ZoomablePhoto: UIViewRepresentable {
    @Environment(\.displayScale) private var displayScale
    let image: UIImage
    let referenceImage: UIImage
    let label: String

    func makeUIView(context: Context) -> PhotoScrollView { PhotoScrollView() }

    func updateUIView(_ view: PhotoScrollView, context: Context) {
        view.imageView.image = image
        view.pixels = CGSize(width: referenceImage.size.width * referenceImage.scale,
                             height: referenceImage.size.height * referenceImage.scale)
        view.displayScale = displayScale
        view.accessibilityLabel = label
        view.setNeedsLayout()
    }
}

final class PhotoScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var pixels = CGSize.zero
    var displayScale: CGFloat = 1
    private var previousSize = CGSize.zero
    private var geometry: PhotoZoomGeometry?

    init() {
        super.init(frame: .zero)
        delegate = self
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        bounces = false
        bouncesZoom = false
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        isAccessibilityElement = true
        accessibilityIdentifier = "editor.photo"
        accessibilityTraits = [.image, .adjustable]
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "100%", target: self, selector: #selector(showActualPixels)),
            UIAccessibilityCustomAction(name: "适应画面", target: self, selector: #selector(showFit))
        ]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, pixels.width > 0, pixels.height > 0 else { return }
        guard previousSize != bounds.size || geometry == nil else { return }
        let wasFit = geometry?.isFit(zoomScale) ?? true
        let center = CGPoint(x: (contentOffset.x + previousSize.width / 2) / zoomScale,
                             y: (contentOffset.y + previousSize.height / 2) / zoomScale)
        let next = PhotoZoomGeometry(pixels: pixels, viewport: bounds.size, displayScale: displayScale)
        let initial = geometry == nil
        geometry = next
        previousSize = bounds.size
        if initial {
            imageView.frame = CGRect(origin: .zero, size: next.imageSize)
            contentSize = next.imageSize
        }
        maximumZoomScale = next.maximumScale
        minimumZoomScale = next.minimumScale
        setZoomScale(wasFit ? next.fitScale : zoomScale, animated: false)
        centerImage()
        let offset = wasFit ? CGPoint(x: -contentInset.left, y: -contentInset.top)
            : CGPoint(x: center.x * zoomScale - bounds.width / 2, y: center.y * zoomScale - bounds.height / 2)
        setContentOffset(constrainedOffset(offset), animated: false)
        updateAccessibilityValue()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        updateAccessibilityValue()
    }

    private func centerImage() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    private func constrainedOffset(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, -contentInset.left), max(-contentInset.left, contentSize.width - bounds.width + contentInset.right)),
                y: min(max(point.y, -contentInset.top), max(-contentInset.top, contentSize.height - bounds.height + contentInset.bottom)))
    }

    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        guard let geometry else { return }
        let imagePoint = gesture.location(in: imageView)
        let point = gesture.location(in: self)
        let viewportPoint = CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
        let target = geometry.doubleTapScale(from: zoomScale)
        setZoomScale(target, animated: false)
        centerImage()
        setContentOffset(constrainedOffset(CGPoint(x: imagePoint.x * target - viewportPoint.x,
                                                   y: imagePoint.y * target - viewportPoint.y)), animated: false)
    }

    @objc private func showActualPixels() -> Bool {
        setZoomScale(1, animated: false)
        return true
    }

    @objc private func showFit() -> Bool {
        guard let geometry else { return false }
        setZoomScale(geometry.fitScale, animated: false)
        return true
    }

    override func accessibilityIncrement() { setZoomScale(min(maximumZoomScale, zoomScale * 1.5), animated: false) }
    override func accessibilityDecrement() { setZoomScale(max(minimumZoomScale, zoomScale / 1.5), animated: false) }

    private func updateAccessibilityValue() {
        let percent = "\(Int((zoomScale * 100).rounded()))%"
        accessibilityValue = geometry?.isFit(zoomScale) == true ? "Fit \(percent)" : percent
    }
}
