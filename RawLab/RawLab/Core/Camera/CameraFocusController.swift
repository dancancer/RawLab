import Foundation

protocol CameraFocusCancellable: AnyObject {
    func cancel()
}

@MainActor
protocol CameraFocusClock: AnyObject {
    var nowMillis: UInt64 { get }
    func schedule(afterMillis: UInt64, action: @escaping @MainActor () -> Void) -> any CameraFocusCancellable
}

@MainActor
final class SystemCameraFocusClock: CameraFocusClock {
    private final class TaskCancellable: CameraFocusCancellable {
        private var task: Task<Void, Never>?
        init(_ task: Task<Void, Never>) { self.task = task }
        func cancel() {
            task?.cancel()
            task = nil
        }
    }

    var nowMillis: UInt64 {
        let nanos = ProcessInfo.processInfo.systemUptime * 1000.0
        return nanos > 0 ? UInt64(nanos) : 0
    }

    func schedule(afterMillis: UInt64, action: @escaping @MainActor () -> Void) -> any CameraFocusCancellable {
        let task = Task { @MainActor in
            if afterMillis > 0 {
                try? await Task.sleep(nanoseconds: afterMillis * 1_000_000)
            }
            guard !Task.isCancelled else { return }
            action()
        }
        return TaskCancellable(task)
    }
}

@MainActor
final class VirtualCameraFocusClock: CameraFocusClock {
    private final class Entry: CameraFocusCancellable {
        let id: UInt64
        let deadlineMillis: UInt64
        var cancelled = false
        let action: @MainActor () -> Void

        init(id: UInt64, deadlineMillis: UInt64, action: @escaping @MainActor () -> Void) {
            self.id = id
            self.deadlineMillis = deadlineMillis
            self.action = action
        }

        func cancel() { cancelled = true }
    }

    private(set) var nowMillis: UInt64
    private var nextID: UInt64 = 1
    private var entries: [Entry] = []

    init(initialMillis: UInt64 = 0) {
        self.nowMillis = initialMillis
    }

    func schedule(afterMillis: UInt64, action: @escaping @MainActor () -> Void) -> any CameraFocusCancellable {
        let deadline = nowMillis &+ afterMillis
        let entry = Entry(id: nextID, deadlineMillis: deadline, action: action)
        nextID &+= 1
        entries.append(entry)
        return entry
    }

    func advance(byMillis delta: UInt64) {
        nowMillis &+= delta
        runDue()
    }

    func runDue() {
        while true {
            entries.removeAll { $0.cancelled }
            guard let nextIndex = entries.indices
                .filter({ entries[$0].deadlineMillis <= nowMillis })
                .min(by: {
                    if entries[$0].deadlineMillis != entries[$1].deadlineMillis {
                        return entries[$0].deadlineMillis < entries[$1].deadlineMillis
                    }
                    return entries[$0].id < entries[$1].id
                }) else {
                break
            }
            let entry = entries.remove(at: nextIndex)
            if !entry.cancelled {
                entry.action()
            }
        }
    }

    var pendingScheduledCount: Int {
        entries.filter { !$0.cancelled }.count
    }
}

struct CameraFocusOverlayRenderItem: Equatable {
    let box: CameraOverlayBox
    let focused: Bool
}

enum CameraFocusRenderContent: Equatable {
    case none
    case frames([CameraFocusOverlayRenderItem])
    case tapReticle(CameraOverlayBox, focused: Bool)
}

@MainActor
final class CameraFocusController {
    private let clock: any CameraFocusClock
    private(set) var state = sony2fuji_sony_focus_state()
    private(set) var tapID: UUID?
    private(set) var liveViewFrames: [CameraLiveViewFrame] = []
    private var pendingTimer: (any CameraFocusCancellable)?
    private var scheduledGeneration: UInt64?
    var onStateChanged: (() -> Void)?

    init(clock: (any CameraFocusClock)? = nil) {
        self.clock = clock ?? SystemCameraFocusClock()
        _ = sony2fuji_sony_focus_state_init(&state)
    }

    var focusBusy: Bool { state.focus_busy != 0 }
    var tapFocusLocked: Bool { state.tap_focus_locked != 0 }
    var tapFocusPoint: (id: UUID, u: Double, v: Double)? {
        guard state.tap_active != 0, let tapID else { return nil }
        return (tapID, state.tap_u, state.tap_v)
    }
    var lastFocusSquareRatio: Double? {
        state.has_last_square_ratio != 0 ? state.last_square_ratio : nil
    }

    func isCameraFocusLocked(propertiesFocusLocked: Bool) -> Bool {
        state.focus_busy == 0 && (state.tap_focus_locked != 0 || propertiesFocusLocked)
    }

    func reset(preserveLastRatio: Bool = false) {
        _ = sony2fuji_sony_focus_state_reset(&state, preserveLastRatio ? 1 : 0)
        tapID = nil
        liveViewFrames = []
        syncTimerAndNotify()
    }

    func beginTapFocus(id: UUID = UUID(), u: Double, v: Double, x: Int, y: Int) {
        let status = sony2fuji_sony_focus_state_on_tap(
            &state, u, v, Int32(x), Int32(y), clock.nowMillis)
        guard status == SONY2FUJI_STATUS_OK else { return }
        tapID = id
        liveViewFrames = []
        syncTimerAndNotify()
    }

    func beginCancelTouchFocus() {
        _ = sony2fuji_sony_focus_state_on_cancel_start(&state)
        tapID = nil
        liveViewFrames = []
        syncTimerAndNotify()
    }

    func onFocusFinished(succeeded: Bool, focusLocked: Bool) {
        _ = sony2fuji_sony_focus_state_on_focus_finished(
            &state, succeeded ? 1 : 0, focusLocked ? 1 : 0, clock.nowMillis)
        if state.tap_active == 0 { tapID = nil }
        syncTimerAndNotify()
    }

    func onLiveFrame(_ frames: [CameraLiveViewFrame], imageWidth: Double, imageHeight: Double) {
        let cFrames = frames.map { $0.cFrame }
        if cFrames.isEmpty {
            _ = sony2fuji_sony_focus_state_on_live_frame(&state, nil, 0, imageWidth, imageHeight)
        } else {
            cFrames.withUnsafeBufferPointer { buf in
                _ = sony2fuji_sony_focus_state_on_live_frame(
                    &state, buf.baseAddress, UInt32(buf.count), imageWidth, imageHeight)
            }
        }
        if state.focus_busy != 0 {
            liveViewFrames = []
        } else {
            liveViewFrames = frames
            if state.tap_active == 0 { tapID = nil }
        }
        syncTimerAndNotify()
    }

    func onProperties(canCancelTouchFocus: Bool, focusLocked: Bool, focusFailed: Bool) {
        _ = sony2fuji_sony_focus_state_on_properties(
            &state,
            canCancelTouchFocus ? 1 : 0,
            focusLocked ? 1 : 0,
            focusFailed ? 1 : 0
        )
        syncTimerAndNotify()
    }

    func onCaptureOrParameterStart() {
        _ = sony2fuji_sony_focus_state_on_capture_or_param_start(&state)
        syncTimerAndNotify()
    }

    func onLiveChanged(active: Bool) {
        _ = sony2fuji_sony_focus_state_on_live_changed(&state, active ? 1 : 0)
        if !active {
            tapID = nil
            liveViewFrames = []
        }
        syncTimerAndNotify()
    }

    func onFailure(keepLiveFrames: Bool) {
        _ = sony2fuji_sony_focus_state_on_focus_finished(&state, 0, 0, clock.nowMillis)
        if !keepLiveFrames {
            _ = sony2fuji_sony_focus_state_on_live_changed(&state, 0)
            liveViewFrames = []
        }
        if state.tap_active == 0 { tapID = nil }
        syncTimerAndNotify()
    }

    func tick() {
        _ = sony2fuji_sony_focus_state_on_tick(&state, clock.nowMillis)
        if state.tap_active == 0 { tapID = nil }
        syncTimerAndNotify()
    }

    func renderContent(
        left: Double,
        top: Double,
        fittedWidth: Double,
        fittedHeight: Double,
        propertiesFocusLocked: Bool
    ) -> CameraFocusRenderContent {
        var copy = state
        copy.props_focus_locked = propertiesFocusLocked ? 1 : 0
        var decision = sony2fuji_sony_focus_render_decision()
        let status = sony2fuji_sony_focus_state_resolve_render(
            &copy, left, top, fittedWidth, fittedHeight, 34.0, 52.0, 20.0, &decision)
        guard status == SONY2FUJI_STATUS_OK else { return .none }
        let locked = decision.effective_focus_locked != 0
        switch decision.mode {
        case SONY2FUJI_SONY_FOCUS_RENDER_LIVE_FRAMES:
            let items = liveViewFrames.map { overlay -> CameraFocusOverlayRenderItem in
                let box = CameraWire.focusOverlayBox(
                    frame: overlay, left: left, top: top,
                    fittedWidth: fittedWidth, fittedHeight: fittedHeight)
                let focused = overlay.focused || (locked && overlay.kind != .face)
                return CameraFocusOverlayRenderItem(box: box, focused: focused)
            }
            return items.isEmpty ? .none : .frames(items)
        case SONY2FUJI_SONY_FOCUS_RENDER_TAP_RETICLE:
            let box = CameraOverlayBox(
                x: decision.tap_box.x,
                y: decision.tap_box.y,
                width: decision.tap_box.width,
                height: decision.tap_box.height,
                isNormalizedSquare: decision.tap_box.is_normalized_square != 0
            )
            return .tapReticle(box, focused: decision.tap_box.focused != 0)
        default:
            return .none
        }
    }

    private func syncTimerAndNotify() {
        if state.has_pending_deadline != 0 {
            let gen = state.tap_generation
            if scheduledGeneration != gen || pendingTimer == nil {
                pendingTimer?.cancel()
                scheduledGeneration = gen
                let now = clock.nowMillis
                let delay = state.tap_deadline_ms > now ? state.tap_deadline_ms - now : 0
                pendingTimer = clock.schedule(afterMillis: delay) { [weak self] in
                    guard let self else { return }
                    _ = sony2fuji_sony_focus_state_on_timeout(&self.state, gen, self.clock.nowMillis)
                    if self.state.tap_active == 0 { self.tapID = nil }
                    self.pendingTimer = nil
                    self.scheduledGeneration = nil
                    self.onStateChanged?()
                }
            }
        } else {
            pendingTimer?.cancel()
            pendingTimer = nil
            scheduledGeneration = nil
        }
        onStateChanged?()
    }
}
