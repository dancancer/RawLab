import Foundation
import UIKit

@main
struct ViewingCanvasTests {
    static func main() {
        setbuf(stdout, nil)
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL"): \(name)")
            if !condition { failures += 1 }
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400), format: format).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        }
        let canvas = PhotoCanvasView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        var state = PhotoViewingState(); state.selectMode(.wipe)
        var received = state
        canvas.onViewingChange = { received = $0 }
        canvas.configure(image: image, reference: image, label: "After", state: state,
                         viewport: PhotoViewport(), displayScale: 1, isDraft: false, interactionEnabled: true)
        canvas.layoutIfNeeded()
        let split = canvas.subviews.compactMap { $0 as? PhotoSplitControl }.first!
        split.accessibilityIncrement()
        split.accessibilityIncrement()
        check(abs(received.split - 0.6) < 0.00001, "consecutive native AX increments compose without a SwiftUI configure roundtrip")
        split.onChange?(0.8)
        split.accessibilityDecrement()
        check(abs(received.split - 0.75) < 0.00001, "native drag callback followed by AX decrement starts from the dragged position")
        state = PhotoViewingState(); state.toggleComparison()
        canvas.configure(image: image, reference: nil, label: "After", state: state,
                         viewport: PhotoViewport(), displayScale: 1, isDraft: false, interactionEnabled: true)
        canvas.layoutIfNeeded()
        check(canvas.reference.isHidden && canvas.result.imageView.image === image,
              "missing neutral cannot open a blank comparison pane")
        state = PhotoViewingState(); state.beginHolding(isDraft: false)
        canvas.configure(image: image, reference: nil, label: "After", state: state,
                         viewport: PhotoViewport(), displayScale: 1, isDraft: false, interactionEnabled: true)
        canvas.layoutIfNeeded()
        check(canvas.result.imageView.image === image && canvas.result.accessibilityLabel == "After",
              "missing neutral keeps accepted after image and after label during attempted hold")
        check(!canvas.result.holdEnabled, "missing neutral disables native hold entry")
        state = PhotoViewingState()
        let desired = PhotoViewport(relativeScale: 1.5, focus: CGPoint(x: 0.5, y: 0.5))
        var lastViewport = desired
        canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 350)
        canvas.configure(image: image, reference: image, label: "After", state: state,
                         viewport: desired, displayScale: 1, isDraft: false, interactionEnabled: true)
        canvas.layoutIfNeeded()
        canvas.onViewportChange = { lastViewport = $0 }
        canvas.result.bounds.size.height = 700
        canvas.result.scrollViewDidScroll(canvas.result)
        check(lastViewport == desired, "native scroll delegate while resized bounds await geometry cannot publish a layout-derived center")
        lastViewport = desired
        canvas.frame.size.height = 700
        canvas.layoutIfNeeded()
        canvas.frame.size.height = 350
        canvas.layoutIfNeeded()
        check(lastViewport == desired, "pure-preview style bounds changes preserve shared normalized viewport without publishing a layout-derived center")
        exit(failures == 0 ? 0 : 1)
    }
}
