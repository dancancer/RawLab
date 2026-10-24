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
        var samples: [CGPoint] = [], changes: [Double] = [], targetEnds = 0, targetCancels = 0, keys: [Double] = []
        let target = HSLTargetCanvasInput(scope: "photo-a:hue", begin: { point in
            samples.append(point)
            // 数值输入预检会结束字段焦点，画布须在预检后才接管本次拖动。
            window.makeFirstResponder(nil)
        }, change: { changes.append($0) },
            end: { targetEnds += 1 }, cancel: { targetCancels += 1 }, key: { keys.append($0); window.makeFirstResponder(nil) }, reject: {})
        input.configure(MacCanvasInput(imageRect: CGRect(x: -100, y: 20, width: 500, height: 200),
            excludedRects: [CGRect(x: 0, y: 20, width: 40, height: 40)], target: target,
            canHold: false, onHold: { _ in }, onPan: { _ in }, onPanEnd: {}, onDoubleClick: {}))
        func pointer(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: input.convert(point, to: nil), modifierFlags: .shift,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        let arrow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124)!
        input.mouseDown(with: pointer(.leftMouseDown, CGPoint(x: 10, y: 30)))
        guard samples.isEmpty else { fatalError("Label overlay was sampled") }
        input.mouseDown(with: pointer(.leftMouseDown, CGPoint(x: 150, y: 120)))
        input.mouseDragged(with: pointer(.leftMouseDragged, CGPoint(x: 150, y: 80))); input.keyDown(with: arrow)
        guard samples == [CGPoint(x: 0.5, y: 0.5)] && changes == [5] && keys.isEmpty else { fatalError("Frozen normalized sample, fine drag or pointer/key ownership failed") }
        input.mouseUp(with: pointer(.leftMouseUp, CGPoint(x: 150, y: 80))); input.keyDown(with: arrow)
        guard targetEnds == 1 && keys == [0.1] && window.firstResponder === input else { fatalError("Target release and keyboard fine step failed") }
        let changesBeforeRelease = changes.count
        input.mouseDown(with: pointer(.leftMouseDown, CGPoint(x: 150, y: 120)))
        input.mouseUp(with: pointer(.leftMouseUp, CGPoint(x: 150, y: 80)))
        guard changes.count == changesBeforeRelease + 1 && changes.last == 5 else {
            fatalError("Target release dropped the final pointer position without a delivered drag event")
        }
        input.mouseDown(with: pointer(.leftMouseDown, CGPoint(x: 150, y: 120)))
        let previousCancels = targetCancels; input.cancelOperation(nil); input.mouseUp(with: pointer(.leftMouseUp, CGPoint(x: 150, y: 80)))
        guard targetCancels > previousCancels && targetEnds == 2 else { fatalError("Cancelled target accepted a late mouse-up") }
        print("PASS: native cancel, subsequent pan and dismantle lifecycle")
    }
}
