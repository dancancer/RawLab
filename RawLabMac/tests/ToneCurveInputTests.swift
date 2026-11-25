import RawLabKit
import AppKit
import SwiftUI

@main enum ToneCurveInputTests {
    private static func findInputViews(_ root: NSView) -> [ToneCurveInputView] {
        (root as? ToneCurveInputView).map { [$0] } ?? root.subviews.flatMap(findInputViews)
    }

    @MainActor static func main() {
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
        var endpointCurve = ToneCurveSettings.identity
        input.session.configure(.init(read: { endpointCurve }, selected: 0, scope: "endpoint", fine: false, enabled: true,
            isCurrent: { true }, prepare: { true }, begin: { true },
            select: { _ in }, change: { endpointCurve = $0 }, end: { commits += 1 }, cancel: {}))
        input.keyDown(with: key)
        guard commits == 3 && endpointCurve.points[0].x == 0 && abs(endpointCurve.points[0].y - 0.01) < 1e-12 else {
            fatalError("Endpoint vertical nudge must move y while keeping x at 0")
        }
        let rightKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124)!
        input.keyDown(with: rightKey)
        guard commits == 4 && abs(endpointCurve.points[0].x - 0.01) < 1e-12 && abs(endpointCurve.points[0].y - 0.01) < 1e-12 else {
            fatalError("Endpoint horizontal nudge must move x while retaining y and focus")
        }

        // Verify double-click / double-tap, drag-out-of-bounds, and right-click / Control-click deletion semantics.
        var clock: TimeInterval = 10.0
        let session = ToneCurveInputSession(now: { clock })
        var sessionCurve = ToneCurveSettings.identity
        var selectedIdx = 0
        var sessionCommits = 0
        session.configure(.init(
            read: { sessionCurve },
            selected: selectedIdx,
            scope: "delete-checks",
            fine: false,
            enabled: true,
            isCurrent: { true },
            prepare: { true },
            begin: { true },
            select: { selectedIdx = $0 },
            change: { sessionCurve = $0 },
            end: { sessionCommits += 1 },
            cancel: {}
        ))

        // 1. Accidental double-click on empty curve space must insert once on Click 1 and NOT delete on Click 2.
        guard session.begin(x: 0.5, y: 0.55, toleranceX: 0.06, toleranceY: 0.06) else {
            fatalError("First click on empty curve space must start insertion gesture")
        }
        session.end()
        guard sessionCurve.points.count == 3 && sessionCommits == 1 else {
            fatalError("First click on empty curve space must insert one interior point")
        }
        clock += 0.12
        guard session.begin(x: 0.5, y: 0.55, toleranceX: 0.06, toleranceY: 0.06) else {
            fatalError("Immediate second click after insertion must NOT delete the newly inserted point")
        }
        session.end()
        guard sessionCurve.points.count == 3 && sessionCommits == 2 else {
            fatalError("Newly inserted point must survive accidental double-click on empty space")
        }

        // 2. Double-clicking an existing interior point deletes it cleanly.
        clock += 1.0
        guard session.begin(x: 0.5, y: 0.55, toleranceX: 0.06, toleranceY: 0.06) else {
            fatalError("First click on existing interior point must select and arm double-tap delete")
        }
        session.end()
        clock += 0.15
        let startedSecondDrag = session.begin(x: 0.5, y: 0.55, toleranceX: 0.06, toleranceY: 0.06)
        guard !startedSecondDrag && sessionCurve.points.count == 2 && sessionCommits == 4 else {
            fatalError("Second click within double-tap window on existing interior point must delete it")
        }

        // 3. Double-clicking endpoints must NEVER delete endpoints.
        clock += 1.0
        _ = session.begin(x: 0.0, y: 0.0, toleranceX: 0.06, toleranceY: 0.06)
        session.end()
        clock += 0.10
        _ = session.begin(x: 0.0, y: 0.0, toleranceX: 0.06, toleranceY: 0.06)
        session.end()
        guard sessionCurve.points.count == 2 else {
            fatalError("Endpoints must never be deleted by double-click")
        }

        // 4. Dragging an interior point significantly (> 0.02) disarms quick-second-click deletion.
        sessionCurve = ToneCurveSettings.identity.inserting(x: 0.4, y: 0.4)
        clock += 1.0
        _ = session.begin(x: 0.4, y: 0.4, toleranceX: 0.06, toleranceY: 0.06)
        session.move(x: 0.4, y: 0.65)
        session.end()
        clock += 0.10
        _ = session.begin(x: 0.4, y: 0.65, toleranceX: 0.06, toleranceY: 0.06)
        session.end()
        guard sessionCurve.points.count == 3 && abs(sessionCurve.points[1].y - 0.65) < 1e-12 else {
            fatalError("Quick click after significant drag must not delete moved point")
        }

        // 5. Drag-out-of-bounds previews deletion, dragging back in restores the point, releasing outside commits deletion.
        clock += 1.0
        _ = session.begin(x: 0.4, y: 0.65, toleranceX: 0.06, toleranceY: 0.06)
        session.move(x: 0.4, y: -0.20)
        guard sessionCurve.points.count == 2 else {
            fatalError("Dragging interior point outside bounds must preview point removal")
        }
        session.move(x: 0.45, y: 0.60)
        guard sessionCurve.points.count == 3 && abs(sessionCurve.points[1].x - 0.45) < 1e-12 && abs(sessionCurve.points[1].y - 0.60) < 1e-12 else {
            fatalError("Dragging back inside bounds before release must restore interior point")
        }
        session.move(x: 1.20, y: 0.60)
        session.end()
        guard sessionCurve.points.count == 2 else {
            fatalError("Releasing outside bounds must commit interior point deletion")
        }

        // 6. Dragging an endpoint outside bounds clamps without deleting.
        clock += 1.0
        _ = session.begin(x: 0.0, y: 0.0, toleranceX: 0.06, toleranceY: 0.06)
        session.move(x: -0.30, y: -0.30)
        session.end()
        guard sessionCurve.points.count == 2 && sessionCurve.points[0] == .init(x: 0, y: 0) else {
            fatalError("Dragging endpoint outside bounds must clamp to [0, 1] without deleting")
        }

        // 7. Right-click and Control-click on ToneCurveInputView delete interior points directly.
        var viewCurve = ToneCurveSettings.identity.inserting(x: 0.3, y: 0.3).inserting(x: 0.7, y: 0.7)
        var viewCommits = 0
        input.session.configure(.init(
            read: { viewCurve }, selected: 1, scope: "right-click", fine: false, enabled: true,
            isCurrent: { true }, prepare: { true }, begin: { true },
            select: { _ in }, change: { viewCurve = $0 }, end: { viewCommits += 1 }, cancel: {}
        ))
        func viewLocation(x: Double, y: Double) -> NSPoint {
            let local = NSPoint(x: 12 + x * (input.bounds.width - 24), y: 12 + (1 - y) * (input.bounds.height - 24))
            return input.convert(local, to: nil)
        }
        let rightDown = NSEvent.mouseEvent(
            with: .rightMouseDown, location: viewLocation(x: 0.3, y: 0.3), modifierFlags: [],
            timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        )!
        input.rightMouseDown(with: rightDown)
        guard viewCurve.points.count == 3 && viewCommits == 1 && abs(viewCurve.points[1].x - 0.7) < 1e-12 else {
            fatalError("Right-clicking interior point must delete it immediately")
        }
        let ctrlDown = NSEvent.mouseEvent(
            with: .leftMouseDown, location: viewLocation(x: 0.7, y: 0.7), modifierFlags: [.control],
            timestamp: 2, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1
        )!
        input.mouseDown(with: ctrlDown)
        guard viewCurve.points.count == 2 && viewCommits == 2 else {
            fatalError("Control-clicking interior point must delete it immediately")
        }

        // 8. SwiftUI ToneCurveCanvas UI hierarchy: point view mounts ToneCurveInputView, parametric view suppresses it.
        var hostedCurve = ToneCurveSettings(
            mode: .custom,
            points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.6), .init(x: 1, y: 1)],
            parametric: ToneCurveParametric(shadows: 35)
        )
        var hostedSelected = 1
        let pointHost = NSHostingView(rootView: ToneCurveCanvas(
            value: Binding(get: { hostedCurve }, set: { hostedCurve = $0 }),
            selected: Binding(get: { hostedSelected }, set: { hostedSelected = $0 }),
            scope: "hosted.rgb",
            channel: .rgb,
            showSplitMarkers: false,
            allowsPointEditing: true
        ).frame(width: 200, height: 200))
        pointHost.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        window.contentView = pointHost
        pointHost.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        guard !findInputViews(pointHost).isEmpty else {
            fatalError("Point-curve ToneCurveCanvas must mount interactive ToneCurveInputView")
        }

        let parametricHost = NSHostingView(rootView: ToneCurveCanvas(
            value: Binding(get: { hostedCurve }, set: { hostedCurve = $0 }),
            selected: Binding(get: { hostedSelected }, set: { hostedSelected = $0 }),
            scope: "hosted.rgb",
            channel: .rgb,
            showSplitMarkers: true,
            allowsPointEditing: true
        ).frame(width: 200, height: 200))
        parametricHost.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        window.contentView = parametricHost
        parametricHost.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        guard findInputViews(parametricHost).isEmpty else {
            fatalError("Parametric ToneCurveCanvas must suppress ToneCurveInputView even if allowsPointEditing is true")
        }

        print("PASS: curve keyboard preflight, endpoint nudges, double-click/drag-out/right-click deletion, accidental-delete guards, and canvas UI isolation")
    }
}
