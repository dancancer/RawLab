import AppKit

@main enum ToneCurveInputTests {
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let input = ToneCurveInputView(frame: NSRect(x: 0, y: 0, width: 232, height: 164))
        let window = NSWindow(contentRect: input.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = input
        defer { window.contentView = nil; window.close() }
        var curve = ToneCurveSettings.identity.inserting(x: 0.5, y: 0.5)
        var commits = 0
        input.session.configure(.init(read: { curve }, selected: 1, scope: "source", fine: false, enabled: true,
            isCurrent: { true }, prepare: { window.makeFirstResponder(nil); return true }, begin: { true },
            select: { _ in }, change: { curve = $0 }, end: { commits += 1 }, cancel: {}))
        window.makeFirstResponder(input)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 126)!
        for _ in 0..<2 {
            input.keyDown(with: key)
            guard window.firstResponder === input else { fatalError("Curve nudge must retain keyboard focus after committing pending input") }
        }
        guard commits == 2 && abs(curve.points[1].y - 0.52) < 1e-12 else { fatalError("Consecutive curve nudges must remain independent commits") }
        print("PASS: curve keyboard preflight retains focus and consecutive history commits")
    }
}
