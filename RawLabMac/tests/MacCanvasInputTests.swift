import AppKit
import SwiftUI

@main struct MacCanvasInputTests {
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var origin: CGFloat?, position: CGFloat = 0, moves = 0, ended = 0
        let input = MacCanvasInput.InputView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        input.owner = MacCanvasInput(imageRect: input.bounds, canHold: true, onHold: { _ in }, onPan: { translation in
            if origin == nil { origin = position }
            position = (origin ?? 0) + translation.width; moves += 1
        }, onPanEnd: { origin = nil; ended += 1 }, onDoubleClick: {})
        let window = NSWindow(contentRect: NSRect(x: -1000, y: -1000, width: 400, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = input; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        // Seed the owner callback exactly as an in-progress native pan does.
        // Real recognizer delivery is separately verified through the visible App/CUA fixture.
        input.owner?.onPan(CGSize(width: 50, height: 0))
        MacCanvasInput.dismantleNSView(input, coordinator: ())
        guard origin == nil && ended > 0 else { print("FAIL: native teardown ends the photo pan session before another gesture"); exit(1) }
        let first = position
        input.owner?.onPan(CGSize(width: 40, height: 0)); input.owner?.onPanEnd()
        guard position > first && origin == nil else { print("FAIL: next owner pan starts at the retained focus with a fresh origin"); exit(1) }
        input.owner?.onPan(CGSize(width: 10, height: 0))
        input.cancelOperation(nil)
        guard origin == nil else { print("FAIL: native Escape/cancel ends owner pan"); exit(1) }
        input.owner?.onPan(CGSize(width: 10, height: 0))
        window.makeKey(); window.resignKey()
        guard origin == nil else { print("FAIL: native key-window resignation ends owner pan"); exit(1) }
        input.owner?.onPan(CGSize(width: 10, height: 0))
        NotificationCenter.default.post(name: NSApplication.willResignActiveNotification, object: app)
        guard origin == nil else { print("FAIL: background lifecycle ends owner pan"); exit(1) }
        let endsBeforeDismantle = ended
        MacCanvasInput.dismantleNSView(input, coordinator: ())
        guard ended > endsBeforeDismantle else { print("FAIL: dismantle cancels both before and pan sessions"); exit(1) }
        print("PASS: native cancel, subsequent pan and dismantle lifecycle")
    }
}
