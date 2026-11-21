import Foundation
import RawLabKit
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
        canvas.frame = CGRect(x: 0, y: 0, width: 402, height: 96)
        let tinyPhoto = UIGraphicsImageRenderer(size: CGSize(width: 700, height: 749), format: format).image { _ in }
        let caption = after as! UILabel
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

        let base1280 = UIGraphicsImageRenderer(size: CGSize(width: 1280, height: 853), format: format).image { _ in }
        let tileAfter = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400), format: format).image { _ in }
        let tileBefore = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400), format: format).image { _ in }
        let tileRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let overlay = PhotoDetailOverlay(
            cgImage: tileAfter.cgImage, beforeCGImage: tileBefore.cgImage,
            hdr: nil, beforeHDR: nil,
            normalizedRect: tileRect,
            pixelSize: CGSize(width: 600, height: 400),
            fullNativeSize: CGSize(width: 6000, height: 4000),
            renderID: UUID()
        )
        canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        var zoomState = PhotoViewingState()
        zoomState.selectMode(.wipe)
        canvas.configure(image: base1280, reference: base1280, label: "After", state: zoomState,
                         viewport: PhotoViewport(), displayScale: 3, isDraft: false, interactionEnabled: true,
                         nativePixelSize: CGSize(width: 6000, height: 4000), detailOverlay: overlay)
        canvas.layoutIfNeeded()
        check(canvas.result.pixels == CGSize(width: 6000, height: 4000) && canvas.result.maximumZoomScale == 4,
              "SDR canvas configures native pixel coordinates and allows >= 400% zoom")
        check(!canvas.result.detailImageView.isHidden && canvas.result.detailImageView.image?.cgImage === tileAfter.cgImage,
              "active detail overlay displays after tile")
        check(!canvas.result.beforeDetailImageView.isHidden && canvas.result.beforeDetailImageView.image?.cgImage === tileBefore.cgImage,
              "wipe comparison displays before detail tile")
        let expectedTileFrame = CGRect(x: 500, y: 1000.0 / 3, width: 1000, height: 2000.0 / 3)
        check(abs(canvas.result.detailImageView.frame.minX - expectedTileFrame.minX) < 0.5 &&
              abs(canvas.result.detailImageView.frame.width - expectedTileFrame.width) < 0.5,
              "detail overlay frame aligns cleanly inside imageView bounds")

        zoomState.selectMode(.sideBySide)
        canvas.configure(image: base1280, reference: base1280, label: "After", state: zoomState,
                         viewport: PhotoViewport(), displayScale: 3, isDraft: false, interactionEnabled: true,
                         nativePixelSize: CGSize(width: 6000, height: 4000), detailOverlay: overlay)
        canvas.layoutIfNeeded()
        check(!canvas.reference.detailImageView.isHidden && canvas.reference.detailImageView.image?.cgImage === tileBefore.cgImage,
              "side-by-side comparison renders before detail tile on reference pane")

        var holdState = PhotoViewingState(); holdState.beginHolding(isDraft: false)
        canvas.configure(image: base1280, reference: base1280, label: "After", state: holdState,
                         viewport: PhotoViewport(), displayScale: 3, isDraft: false, interactionEnabled: true,
                         nativePixelSize: CGSize(width: 6000, height: 4000), detailOverlay: overlay)
        canvas.layoutIfNeeded()
        check(!canvas.result.detailImageView.isHidden && canvas.result.detailImageView.image?.cgImage === tileBefore.cgImage,
              "holding before displays before detail tile")

        canvas.configure(image: base1280, reference: base1280, label: "After", state: PhotoViewingState(),
                         viewport: PhotoViewport(), displayScale: 3, isDraft: true, interactionEnabled: true,
                         nativePixelSize: CGSize(width: 6000, height: 4000), detailOverlay: overlay)
        canvas.layoutIfNeeded()
        check(canvas.result.detailImageView.isHidden, "draft mode suppresses detail overlay")

        var emittedDetail: PhotoDetailRequest?
        canvas.onDetailRequest = { emittedDetail = $0 }
        canvas.configure(image: base1280, reference: base1280, label: "After", state: PhotoViewingState(),
                         viewport: PhotoViewport(relativeScale: 5.0, focus: CGPoint(x: 0.5, y: 0.5)),
                         displayScale: 3, isDraft: false, interactionEnabled: true,
                         nativePixelSize: CGSize(width: 6000, height: 4000))
        canvas.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check(emittedDetail != nil && emittedDetail!.maxOutputLongEdge == 2048,
              "zooming SDR canvas past base density emits 2048px detail request")

        let keyA = PhotoDetailTileKey(level: 0, col: 0, row: 0)
        let keyB = PhotoDetailTileKey(level: 0, col: 1, row: 0)
        let tile0 = PhotoDetailOverlay(
            cgImage: tileAfter.cgImage, beforeCGImage: tileBefore.cgImage,
            hdr: nil, beforeHDR: nil,
            normalizedRect: CGRect(x: 0, y: 0, width: 1024.0 / 6000.0, height: 1024.0 / 4000.0),
            pixelSize: CGSize(width: 1024, height: 1024),
            fullNativeSize: CGSize(width: 6000, height: 4000),
            renderID: UUID(),
            tileKey: keyA
        )
        let tile1 = PhotoDetailOverlay(
            cgImage: tileAfter.cgImage, beforeCGImage: tileBefore.cgImage,
            hdr: nil, beforeHDR: nil,
            normalizedRect: CGRect(x: 1024.0 / 6000.0, y: 0, width: 1024.0 / 6000.0, height: 1024.0 / 4000.0),
            pixelSize: CGSize(width: 1024, height: 1024),
            fullNativeSize: CGSize(width: 6000, height: 4000),
            renderID: tile0.renderID,
            tileKey: keyB
        )
        var wipeState = PhotoViewingState(); wipeState.selectMode(.wipe)
        let steadyViewport = PhotoViewport(relativeScale: 5.0, focus: CGPoint(x: 0.5, y: 0.5))
        canvas.configure(image: base1280, reference: base1280, label: "After", state: wipeState,
                         viewport: steadyViewport, displayScale: 3, isDraft: false, interactionEnabled: true,
                         nativePixelSize: CGSize(width: 6000, height: 4000),
                         detailOverlay: tile1, detailTiles: [tile0, tile1])
        canvas.layoutIfNeeded()
        check(!canvas.result.detailTileContainer.isHidden && canvas.result.activeDetailTileCount == 2,
              "tiled SDR overlays mount one layer per cached tile")
        check(canvas.result.detailImageView.isHidden, "tiled SDR path avoids duplicate single-overlay imageView")
        check(!canvas.result.beforeDetailTileContainer.isHidden && canvas.result.activeBeforeDetailTileCount == 2,
              "wipe comparison displays before detail tiles")
        let initialLayerA = canvas.result.detailTileLayer(for: keyA)
        let offsetBeforeTileAppend = canvas.result.contentOffset
        // Appending/updating detail tiles with unchanged viewport must keep scroll position and reuse existing CALayers.
        canvas.configure(image: base1280, reference: base1280, label: "After", state: wipeState,
                         viewport: steadyViewport, displayScale: 3, isDraft: false, interactionEnabled: true,
                         nativePixelSize: CGSize(width: 6000, height: 4000),
                         detailOverlay: tile0, detailTiles: [tile0, tile1])
        check(canvas.result.detailTileLayer(for: keyA) === initialLayerA,
              "reconfiguring cached tiles reuses existing CALayer instances")
        check(canvas.result.contentOffset == offsetBeforeTileAppend,
              "detail tile updates do not reset UIScrollView contentOffset")
        canvas.configure(image: base1280, reference: base1280, label: "After", state: wipeState,
                         viewport: steadyViewport, displayScale: 3, isDraft: true, interactionEnabled: true,
                         nativePixelSize: CGSize(width: 6000, height: 4000),
                         detailOverlay: tile0, detailTiles: [tile0, tile1])
        check(canvas.result.detailTileContainer.isHidden && canvas.result.activeDetailTileCount == 0,
              "draft mode clears and hides detail tiles")

        let backingCG = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1600), format: format).image { _ in }.cgImage!
        let beforeBackingCG = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1600), format: format).image { _ in }.cgImage!
        let backing = PhotoDetailBacking(
            cgImage: backingCG,
            beforeCGImage: beforeBackingCG,
            pixelSize: CGSize(width: 2400, height: 1600),
            fullNativeSize: CGSize(width: 6000, height: 4000),
            renderID: UUID()
        )
        var backingWipe = PhotoViewingState(); backingWipe.selectMode(.wipe)
        let offsetBeforeBacking = canvas.result.contentOffset
        canvas.configure(image: base1280, reference: base1280, label: "After", state: backingWipe,
                         viewport: steadyViewport, displayScale: 3, isDraft: false, interactionEnabled: true,
                         nativePixelSize: CGSize(width: 6000, height: 4000),
                         detailTiles: [tile0], detailBacking: backing)
        canvas.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check(!canvas.result.detailBackingLayer.isHidden &&
              canvas.result.baseLongEdge == 2400 &&
              canvas.result.contentOffset == offsetBeforeBacking,
              "detail backing layer mounts cleanly, raises baseLongEdge, and preserves contentOffset")

        let initialMask = canvas.result.currentWipeMaskLayer
        backingWipe.setSplit(0.25)
        canvas.configure(image: base1280, reference: base1280, label: "After", state: backingWipe,
                         viewport: steadyViewport, displayScale: 3, isDraft: false, interactionEnabled: true,
                         nativePixelSize: CGSize(width: 6000, height: 4000),
                         detailTiles: [tile0], detailBacking: backing)
        check(canvas.result.currentWipeMaskLayer === initialMask &&
              canvas.result.beforeDetailBackingLayer.isHidden == false,
              "wipe updates reuse CAShapeLayer mask and drive beforeDetailBackingLayer")

        let sizeCanvas = PhotoCanvasView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        var reportedPreviewEdges: [Int] = []
        sizeCanvas.onPreviewSizeChange = { reportedPreviewEdges.append($0) }
        sizeCanvas.onDetailRequest = { _ in }
        sizeCanvas.configure(image: base1280, reference: base1280, label: "After", state: PhotoViewingState(),
                             viewport: PhotoViewport(), displayScale: 3, isDraft: false, interactionEnabled: true,
                             nativePixelSize: CGSize(width: 6000, height: 4000),
                             detailTiles: [], detailBacking: nil)
        sizeCanvas.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        sizeCanvas.configure(image: base1280, reference: base1280, label: "After", state: PhotoViewingState(),
                             viewport: steadyViewport, displayScale: 3, isDraft: false, interactionEnabled: true,
                             nativePixelSize: CGSize(width: 6000, height: 4000),
                             detailTiles: [], detailBacking: backing)
        sizeCanvas.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check(reportedPreviewEdges == [1280],
              "SDR zoom changes keep previewLongEdge constant at 1280 without triggering mid-zoom cache clears")

        canvas.configure(image: base1280, reference: base1280, label: "After", state: backingWipe,
                         viewport: steadyViewport, displayScale: 3, isDraft: true, interactionEnabled: true,
                         nativePixelSize: CGSize(width: 6000, height: 4000),
                         detailTiles: [tile0], detailBacking: backing)
        check(canvas.result.detailBackingLayer.isHidden && canvas.result.beforeDetailBackingLayer.isHidden,
              "draft mode hides after and before detailBackingLayers")

        exit(failures == 0 ? 0 : 1)
    }
}
