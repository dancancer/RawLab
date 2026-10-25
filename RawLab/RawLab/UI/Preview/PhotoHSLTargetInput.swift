import UIKit

final class PhotoHSLTargetRecognizer: UIGestureRecognizer {
    var canBegin: ((CGPoint) -> Bool)?
    private(set) var point = CGPoint.zero
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let count = event.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled }.count ?? 0
        guard count == 1, let touch = touches.first else {
            state = state == .began || state == .changed ? .cancelled : .failed; return
        }
        point = touch.location(in: view)
        guard canBegin?(point) == true else { state = .failed; return }
        state = .began
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .began || state == .changed, let touch = touches.first else { return }
        point = touch.location(in: view); state = .changed
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .began || state == .changed else { state = .failed; return }
        if let touch = touches.first { point = touch.location(in: view) }
        state = .ended
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

final class PhotoSampleLoupe: UIView {
    var image: UIImage?
    var normalizedPoint = CGPoint.zero
    var displayWidth: CGFloat = 1
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; isAccessibilityElement = false
        backgroundColor = .black; clipsToBounds = true
        layer.cornerRadius = 44; layer.borderWidth = 2; layer.borderColor = UIColor.white.cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let image, image.size.width > 0 else { return }
        let scale = displayWidth / image.size.width * 3
        image.draw(in: CGRect(x: bounds.midX-normalizedPoint.x*image.size.width*scale,
                              y: bounds.midY-normalizedPoint.y*image.size.height*scale,
                              width: image.size.width*scale, height: image.size.height*scale))
        let center = CGRect(x: bounds.midX-6, y: bounds.midY-6, width: 12, height: 12)
        let path = UIBezierPath(ovalIn: center)
        UIColor.black.setStroke(); path.lineWidth = 4; path.stroke()
        UIColor.white.setStroke(); path.lineWidth = 2; path.stroke()
    }
}
