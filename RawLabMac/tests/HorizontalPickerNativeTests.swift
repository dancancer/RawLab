import AppKit
import Foundation
import SwiftUI

private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
    print("PASS: \(message)")
}

private func drainMainRunLoop(for duration: TimeInterval = 0.08) {
    let deadline = Date(timeIntervalSinceNow: duration)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
    }
}

private struct SelectionHarness: View {
    var body: some View {
        HorizontalPicker(selectedID: "item-8", name: "Probe", showsScrollIndicators: false) {
            HStack(spacing: 0) {
                ForEach(0..<12, id: \.self) { index in
                    Text("Item \(index)")
                        .frame(width: 100, height: 40)
                        .id("item-\(index)")
                }
            }
        }
        .frame(width: 600, height: 80)
    }
}

private func scrollView(in view: NSView) -> NSScrollView? {
    if let scrollView = view as? NSScrollView { return scrollView }
    return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
}

@main
struct HorizontalPickerNativeTests {
    static func main() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 80))
        let nativeScrollView = NSScrollView(frame: root.bounds)
        nativeScrollView.hasHorizontalScroller = false
        nativeScrollView.hasVerticalScroller = false
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 1800, height: 80))
        nativeScrollView.documentView = document
        root.addSubview(nativeScrollView)

        let bridgeView = HorizontalPickerScrollBridgeView(frame: .zero)
        document.addSubview(bridgeView)
        var states: [HorizontalPickerScrollState] = []
        let coordinator = HorizontalPickerScrollBridgeCoordinator { states.append($0) }
        coordinator.attach(to: bridgeView)
        drainMainRunLoop()

        guard let initial = states.last else {
            check(false, "Bridge reports initial document and viewport geometry")
            return
        }
        check(initial.contentWidth == 1800 && initial.viewportWidth == 600 && initial.offset == 0,
              "Bridge reports initial document and viewport geometry")

        coordinator.apply(HorizontalPickerScrollRequest(sequence: 1, offset: 510, animated: false))
        drainMainRunLoop()
        check(abs(nativeScrollView.contentView.bounds.origin.x - 510) < 0.01,
              "Pixel paging moves the clip view to the requested offset")

        nativeScrollView.contentView.scroll(to: NSPoint(x: 900, y: 0))
        nativeScrollView.reflectScrolledClipView(nativeScrollView.contentView)
        drainMainRunLoop()
        check(states.last?.offset == 900,
              "Selection-driven native scrolling is reflected in picker state")

        document.setFrameSize(NSSize(width: 900, height: 80))
        nativeScrollView.contentView.setFrameSize(NSSize(width: 700, height: 80))
        drainMainRunLoop()
        check(states.last?.contentWidth == 900 && states.last?.viewportWidth == 700,
              "Document and clip resize notifications refresh geometry")

        let replacement = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 80))
        bridgeView.removeFromSuperview()
        nativeScrollView.documentView = replacement
        replacement.addSubview(bridgeView)
        drainMainRunLoop()
        check(states.last?.contentWidth == 1200,
              "Replacing the document view rebinds the bridge")

        let replacementClip = NSClipView(frame: NSRect(x: 0, y: 0, width: 640, height: 80))
        nativeScrollView.contentView = replacementClip
        replacementClip.addSubview(replacement)
        replacementClip.setFrameSize(NSSize(width: 640, height: 80))
        drainMainRunLoop(for: 0.4)
        check(states.last?.viewportWidth == 640,
              "Replacing the clip view rebinds the bridge")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: SelectionHarness())
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        drainMainRunLoop(for: 0.4)
        guard let pickerScroll = scrollView(in: host), let pickerDocument = pickerScroll.documentView else {
            check(false, "Picker integration harness creates a native scroll view")
            return
        }
        let selectedCenter = 850.0
        let viewportCenter = pickerScroll.contentView.bounds.origin.x + pickerScroll.contentView.bounds.width / 2
        check(pickerDocument.bounds.width == 1200 && abs(viewportCenter - selectedCenter) < 1,
              "ScrollViewReader centers the selected ID after arrow lanes appear")
        window.orderOut(nil)

        let callbackCount = states.count
        let originalScrollFrameNotifications = nativeScrollView.postsFrameChangedNotifications
        let originalClipBoundsNotifications = nativeScrollView.contentView.postsBoundsChangedNotifications
        let originalClipFrameNotifications = nativeScrollView.contentView.postsFrameChangedNotifications
        let originalDocumentFrameNotifications = replacement.postsFrameChangedNotifications
        coordinator.teardown()
        check(nativeScrollView.postsFrameChangedNotifications == originalScrollFrameNotifications &&
              nativeScrollView.contentView.postsBoundsChangedNotifications == originalClipBoundsNotifications &&
              nativeScrollView.contentView.postsFrameChangedNotifications == originalClipFrameNotifications &&
              replacement.postsFrameChangedNotifications == originalDocumentFrameNotifications,
              "Bridge teardown restores native notification settings")

        nativeScrollView.contentView.scroll(to: NSPoint(x: 100, y: 0))
        nativeScrollView.reflectScrolledClipView(nativeScrollView.contentView)
        drainMainRunLoop()
        check(states.count == callbackCount, "Bridge teardown drops stale scroll callbacks")
    }
}
