import Foundation

@main
struct CameraFocusControllerTests {
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CameraProtocolError.invalid(message) }
        print("PASS: \(message)")
    }

    @MainActor
    static func main() throws {
        let clock = VirtualCameraFocusClock(initialMillis: 1_000)
        let controller = CameraFocusController(clock: clock)
        var notifications = 0
        controller.onStateChanged = { notifications += 1 }

        // 1. Initial state
        try check(!controller.focusBusy && !controller.tapFocusLocked && controller.tapFocusPoint == nil &&
                  controller.renderContent(left: 0, top: 0, fittedWidth: 430, fittedHeight: 286, propertiesFocusLocked: false) == .none,
                  "Initial CameraFocusController state renders .none")

        // 2. Tap starts focusBusy and renders unlocked tapReticle without starting 1.8s timer
        let tap1 = UUID()
        controller.beginTapFocus(id: tap1, u: 0.5, v: 0.5, x: 320, y: 240)
        try check(controller.focusBusy && controller.tapFocusPoint?.id == tap1 && clock.pendingScheduledCount == 0,
                  "Tap sets focusBusy=true without scheduling timeout while busy")
        clock.advance(byMillis: 5_000)
        try check(controller.tapFocusPoint?.id == tap1 && controller.focusBusy,
                  "Advancing virtual clock while focusBusy does not expire tap reticle")

        // 3. Live frames arriving during focusBusy are suppressed
        let trackFrame = CameraLiveViewFrame(kind: .tracking, cx: 0.5, cy: 0.5, width: 0.10, height: 0.127, focused: true)
        controller.onLiveFrame([trackFrame], imageWidth: 430, imageHeight: 286)
        try check(controller.liveViewFrames.isEmpty && controller.tapFocusPoint?.id == tap1,
                  "Live frames suppressed while focusBusy=true")

        // 4. Focus succeeds & locks -> schedules 1800ms expiry; 1799ms stays visible, 1800ms clears
        controller.onFocusFinished(succeeded: true, focusLocked: true)
        try check(!controller.focusBusy && controller.tapFocusLocked && clock.pendingScheduledCount == 1,
                  "Focus finish schedules single 1800ms virtual-clock deadline")
        if case .tapReticle(_, let focused) = controller.renderContent(left: 0, top: 0, fittedWidth: 430, fittedHeight: 286, propertiesFocusLocked: false) {
            try check(focused, "Locked tap reticle renders green/focused")
        } else {
            try check(false, "Expected tapReticle after focus finished")
        }

        clock.advance(byMillis: 1_799)
        try check(controller.tapFocusPoint?.id == tap1, "Tap reticle remains visible at 1799ms")

        // 5. Re-tap supersedes previous generation so old 1800ms deadline cannot clear new tap
        let tap2 = UUID()
        controller.beginTapFocus(id: tap2, u: 0.25, v: 0.25, x: 160, y: 120)
        clock.advance(byMillis: 1)
        try check(controller.focusBusy && controller.tapFocusPoint?.id == tap2,
                  "New tap supersedes earlier generation before 1800ms")

        controller.onFocusFinished(succeeded: true, focusLocked: false)
        clock.advance(byMillis: 1_800)
        try check(controller.tapFocusPoint == nil &&
                  controller.renderContent(left: 0, top: 0, fittedWidth: 430, fittedHeight: 286, propertiesFocusLocked: false) == .none,
                  "Tap reticle expires cleanly at exact 1800ms virtual clock")

        // 6. Live frames replace tap reticle and learn normalized square ratio
        let tap3 = UUID()
        controller.beginTapFocus(id: tap3, u: 0.5, v: 0.5, x: 320, y: 240)
        controller.onFocusFinished(succeeded: true, focusLocked: true)
        controller.onLiveFrame([trackFrame], imageWidth: 430, imageHeight: 286)
        try check(controller.tapFocusPoint == nil && controller.lastFocusSquareRatio != nil,
                  "Live view frame clears tap reticle and learns square ratio")
        if case .frames(let items) = controller.renderContent(left: 0, top: 0, fittedWidth: 430, fittedHeight: 286, propertiesFocusLocked: false) {
            try check(items.count == 1 && items[0].box.isNormalizedSquare && items[0].focused,
                      "Renders normalized live frame box")
        } else {
            try check(false, "Expected .frames render content")
        }

        // 7. Subsequent tap uses learned square ratio; full reset clears learned ratio
        let tap4 = UUID()
        controller.beginTapFocus(id: tap4, u: 0.5, v: 0.5, x: 320, y: 240)
        controller.onFocusFinished(succeeded: true, focusLocked: false)
        let learnedRender = controller.renderContent(left: 0, top: 0, fittedWidth: 430, fittedHeight: 286, propertiesFocusLocked: false)
        if case .tapReticle(let learnedBox, _) = learnedRender {
            let expectedSide = CameraWire.tapFocusSide(fittedWidth: 430, fittedHeight: 286, lastSquareRatio: controller.lastFocusSquareRatio)
            try check(abs(learnedBox.width - expectedSide) < 0.001, "Tap reticle uses learned square ratio")
        } else {
            try check(false, "Expected learned tapReticle")
        }

        // 8. Properties & capture/param & failure & reset transitions
        controller.onProperties(canCancelTouchFocus: true, focusLocked: false, focusFailed: false)
        controller.onFocusFinished(succeeded: true, focusLocked: true)
        controller.onProperties(canCancelTouchFocus: false, focusLocked: false, focusFailed: false)
        try check(!controller.tapFocusLocked, "Dropping canCancelTouchFocus clears tapFocusLocked")

        controller.onFocusFinished(succeeded: true, focusLocked: true)
        controller.onCaptureOrParameterStart()
        try check(!controller.tapFocusLocked, "Capture/parameter start clears tapFocusLocked")

        controller.beginCancelTouchFocus()
        try check(controller.focusBusy && controller.tapFocusPoint == nil, "Cancel start sets focusBusy and clears overlays")
        controller.onFailure(keepLiveFrames: false)
        try check(!controller.focusBusy && controller.tapFocusPoint == nil && controller.liveViewFrames.isEmpty,
                  "Failure clears focusBusy and overlays")

        controller.onLiveChanged(active: false)
        try check(controller.lastFocusSquareRatio != nil, "Live off preserves learned ratio while connected")
        controller.reset(preserveLastRatio: false)
        try check(controller.lastFocusSquareRatio == nil && notifications > 0, "Full reset clears learned ratio")
    }
}
