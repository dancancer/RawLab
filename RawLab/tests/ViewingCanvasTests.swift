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
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
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
        canvas.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        state.selectMode(.wipe)
        let menuRect = CGRect(x: 544, y: 344, width: 44, height: 44)
        canvas.configure(image: image, reference: image, label: "After", state: state,
                         viewport: PhotoViewport(), displayScale: 1, overlayAvoidanceRect: menuRect,
                         isDraft: false, interactionEnabled: true)
        canvas.layoutIfNeeded()
        let after = canvas.subviews.first { $0.accessibilityIdentifier == "editor.compare.after" }!
        check(!after.frame.intersects(menuRect), "wipe after label must avoid the actual floating comparison control rectangle")
        canvas.configure(image: image, reference: image, label: "After", state: state,
                         viewport: PhotoViewport(), displayScale: 1, isDraft: false, interactionEnabled: true)
        canvas.layoutIfNeeded()
        let unchanged = after.frame
        canvas.configure(image: image, reference: image, label: "After", state: state,
                         viewport: PhotoViewport(), displayScale: 1, overlayAvoidanceRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                         isDraft: false, interactionEnabled: true)
        canvas.layoutIfNeeded()
        check(after.frame == unchanged, "nonintersecting overlay must not change the original label position")
        canvas.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        canvas.frame = CGRect(x: 0, y: 0, width: 402, height: 96)
        let tinyPhoto = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 749), format: format).image { _ in }
        state.selectMode(.sideBySide)
        canvas.configure(image: tinyPhoto, reference: tinyPhoto, label: "Nachher", state: state,
                         viewport: PhotoViewport(), displayScale: 1, overlayAvoidanceRect: CGRect(x: 346, y: 40, width: 44, height: 44),
                         isDraft: false, interactionEnabled: true)
        let caption = after as! UILabel
        caption.text = "Nachher"
        canvas.setNeedsLayout(); canvas.layoutIfNeeded()
        let fullWidth = "Nachher".size(withAttributes: [.font: caption.font!]).width
        check(caption.frame.width >= fullWidth + 8 && caption.font.pointSize >= 13 && caption.font.pointSize <= 17,
              "XXXL tiny-photo annotation keeps complete German text at a caption size between13 and17pt")
        state.selectMode(.wipe)
        canvas.configure(image: tinyPhoto, reference: tinyPhoto, label: "Nachher", state: state,
                         viewport: PhotoViewport(), displayScale: 1, isDraft: false, interactionEnabled: true)
        let beforeCaption = canvas.subviews.first { $0.accessibilityIdentifier == "editor.compare.before" } as! UILabel
        beforeCaption.text = "Vorher"; caption.text = "Nachher"
        canvas.setNeedsLayout(); canvas.layoutIfNeeded()
        check(!beforeCaption.frame.intersects(caption.frame), "tiny wipe keeps both complete annotation labels mutually visible")
        let beforeInSplit = beforeCaption.convert(beforeCaption.bounds, to: split)
        let afterInSplit = caption.convert(caption.bounds, to: split)
        let lineImage = UIGraphicsImageRenderer(size: split.bounds.size, format: format).image { context in
            UIColor.black.setFill(); context.fill(split.bounds)
            split.draw(split.bounds)
        }.cgImage!
        let lineBytes = CFDataGetBytePtr(lineImage.dataProvider!.data!)!
        func whiteLine(at y: CGFloat) -> Bool {
            let offset = Int(y) * lineImage.bytesPerRow + Int(split.lineX) * 4
            return lineBytes[offset] > 240 && lineBytes[offset + 1] > 240 && lineBytes[offset + 2] > 240
        }
        check(!whiteLine(at: beforeInSplit.midY) && !whiteLine(at: afterInSplit.midY)
              && whiteLine(at: (beforeInSplit.maxY + afterInSplit.minY) / 2),
              "wipe line skips actual label rectangles while preserving the visible gap")
        check(split.bounds.width == 44 && split.bounds.height == canvas.result.visiblePhotoRect(in: canvas).height,
              "label paint exclusions preserve the full-height44pt split input target")
        exit(failures == 0 ? 0 : 1)
    }
}
