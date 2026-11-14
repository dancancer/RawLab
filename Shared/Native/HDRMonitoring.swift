#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import SwiftUI
import UniformTypeIdentifiers

struct HDRMonitoringControls: View {
    @ObservedObject var state: HDRDisplayState
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            Picker(L10n.text("预览方式"),selection:$state.mode) {
                Text(L10n.text("自动 HDR")).tag(HDRPreviewMode.automatic)
                Text(L10n.text("SDR 兼容预览")).tag(HDRPreviewMode.sdr)
            }.pickerStyle(.segmented).accessibilityIdentifier("hdr.previewMode")
            Toggle(L10n.text("HDR 假色"),isOn:$state.falseColor).accessibilityIdentifier("hdr.falseColor")
            Text(state.displayFailed ? L10n.text("HDR 显示不可用，当前显示 SDR。") :
                L10n.format("屏幕容量 %@ EV",String(format:"%.2f",log2(max(1,state.headroom)))))
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("hdr.displayStatus")
            if state.displayFailed {
                Button(L10n.text("重试")) { state.retry &+= 1 }.accessibilityIdentifier("hdr.retry")
            }
            if !state.displayFailed && (state.mode == .sdr || state.headroom <= 1) {
                Text(L10n.text("当前显示 SDR 兼容预览。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if state.falseColor {
                Text(L10n.text("假色：蓝色为暗部，琥珀色高于参考白，粉色超出屏幕容量。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            Text(L10n.text("预览方式不会改变编辑或导出。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
    }
}

struct HDRRenditionResetPresentation: Equatable {
    let identifier: String
    let title: String
    let isEnabled: Bool

    static func make(settings: HDRRenditionSettings) -> Self {
        Self(identifier: "hdr.rendition.reset",
             title: L10n.text("重置"),
             isEnabled: !settings.isDefault)
    }
}

struct HDRRenditionResetControl: View {
    let presentation: HDRRenditionResetPresentation
    let onReset: () -> Void

    var body: some View {
        Button(presentation.title, action: onReset)
            .buttonStyle(.borderless)
            .disabled(!presentation.isEnabled)
            .accessibilityIdentifier(presentation.identifier)
    }
}

private struct HDRRenditionDoubleTapResetModifier: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.onTapGesture(count: 2, perform: action) }
        else { content }
    }
}

struct HDRRenditionControls: View {
    @Binding var settings: HDRRenditionSettings
    let onEditingChanged: (Bool) -> Void
    let onCancelled: () -> Void
    var voiceOverOverride: Bool? = nil
    #if !os(macOS)
    @Environment(\.accessibilityVoiceOverEnabled) private var accessibilityVoiceOverEnabled
    #endif
    @State private var expanded: Bool
    @State private var editing = false

    init(settings: Binding<HDRRenditionSettings>,
         onEditingChanged: @escaping (Bool) -> Void,
         onCancelled: @escaping () -> Void,
         initiallyExpanded: Bool = false,
         voiceOverOverride: Bool? = nil) {
        self._settings = settings
        self.onEditingChanged = onEditingChanged
        self.onCancelled = onCancelled
        self._expanded = State(initialValue: initiallyExpanded)
        self.voiceOverOverride = voiceOverOverride
    }

    private var isVoiceOverEnabled: Bool {
        if let voiceOverOverride { return voiceOverOverride }
        #if os(macOS)
        return NSWorkspace.shared.isVoiceOverEnabled
        #else
        return accessibilityVoiceOverEnabled
        #endif
    }

    private var allowsDoubleTapReset: Bool {
        Self.allowsDoubleTapReset(voiceOverEnabled: isVoiceOverEnabled)
    }

    var resetPresentation: HDRRenditionResetPresentation {
        HDRRenditionResetPresentation.make(settings: settings)
    }

    static func allowsDoubleTapReset(voiceOverEnabled: Bool) -> Bool {
        !voiceOverEnabled
    }

    @discardableResult
    static func applySingleReset(_ keyPath: WritableKeyPath<HDRRenditionSettings, Double>,
                                 to settings: inout HDRRenditionSettings,
                                 isEditing: Bool) -> Bool {
        guard !isEditing else { return false }
        let baseline = HDRRenditionSettings()[keyPath: keyPath]
        guard settings[keyPath: keyPath] != baseline else { return false }
        settings[keyPath: keyPath] = baseline
        return true
    }

    func reset() {
        settings = HDRRenditionSettings()
    }

    @discardableResult
    func reset(_ keyPath: WritableKeyPath<HDRRenditionSettings, Double>, isEditing: Bool? = nil) -> Bool {
        var next = settings
        guard Self.applySingleReset(keyPath, to: &next, isEditing: isEditing ?? editing) else { return false }
        settings = next
        return true
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                slider("HDR 亮度上限", value: $settings.peakLimitEV, range: 0...6, step: 0.1, id: "peakLimit",
                       unit: "EV", keyPath: \.peakLimitEV, unlimitedAtZero: true)
                slider("SDR 底图曝光", value: $settings.sdrExposureEV, range: -4...4, step: 0.1, id: "sdrExposure",
                       unit: "EV", keyPath: \.sdrExposureEV)
                slider("SDR 底图对比度", value: $settings.sdrContrast, range: -100...100, step: 1, id: "sdrContrast",
                       unit: "%", keyPath: \.sdrContrast)
                slider("SDR 底图饱和度", value: $settings.sdrSaturation, range: -100...100, step: 1, id: "sdrSaturation",
                       unit: "%", keyPath: \.sdrSaturation)
            }.padding(.top, 6)
                .onDisappear { if editing { editing = false; onCancelled() } }
        } label: {
            HStack {
                Text(L10n.text("HDR 输出与 SDR 底图")).accessibilityIdentifier("hdr.rendition")
                Spacer()
                // 与滑杆共用同一绑定，一次写回四个显示映射参数，进入同一撤销记录。
                HDRRenditionResetControl(presentation: resetPresentation, onReset: reset)
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                        id: String, unit: String, keyPath: WritableKeyPath<HDRRenditionSettings, Double>,
                        unlimitedAtZero: Bool = false) -> some View {
        let current = value.wrappedValue
        let text = unlimitedAtZero && current == 0 ? L10n.text("不限") :
            String(format: unit == "EV" ? "%+.1f %@" : "%+.0f%@", locale: L10n.locale, current, unit)
        let doubleTapEnabled = allowsDoubleTapReset
        let resetField: () -> Void = { _ = reset(keyPath) }
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(L10n.text(title))
                Spacer()
                Text(text).monospacedDigit()
            }
            .font(.caption)
            .contentShape(Rectangle())
            .modifier(HDRRenditionDoubleTapResetModifier(enabled: doubleTapEnabled, action: resetField))
            HDRRenditionSlider(
                value: value,
                range: range,
                step: step,
                allowsDoubleTap: doubleTapEnabled,
                accessibilityTitle: L10n.text(title),
                accessibilityValueText: text,
                accessibilityHintText: doubleTapEnabled ? L10n.text("双击名称或轨道恢复默认值。") : "",
                accessibilityIdentifierText: "hdr.rendition.\(id)",
                resetLabel: L10n.text("重置"),
                onEditingChanged: { active in
                    editing = active
                    onEditingChanged(active)
                },
                onCancelled: {
                    editing = false
                    onCancelled()
                },
                onDoubleTapReset: resetField
            )
            .accessibilityLabel(L10n.text(title))
            .accessibilityValue(text)
            .accessibilityAction(named: L10n.text("重置"), resetField)
            .accessibilityHint(doubleTapEnabled ? L10n.text("双击名称或轨道恢复默认值。") : "")
            .accessibilityIdentifier("hdr.rendition.\(id)")
        }
    }
}

private enum HDRRenditionSliderMath {
    static func snap(_ raw: Double, to range: ClosedRange<Double>, step: Double) -> Double {
        let clamped = min(max(raw, range.lowerBound), range.upperBound)
        guard step > 0 else { return clamped }
        let steps = ((clamped - range.lowerBound) / step).rounded()
        let inverseStep = (1.0 / step).rounded()
        let stepped: Double
        if inverseStep > 0,
           abs(step * inverseStep - 1.0) < 1e-9,
           abs((range.lowerBound / step).rounded() - range.lowerBound / step) < 1e-9 {
            let baseSteps = (range.lowerBound / step).rounded()
            stepped = (baseSteps + steps) / inverseStep
        } else {
            stepped = range.lowerBound + steps * step
        }
        let result = min(max(stepped, range.lowerBound), range.upperBound)
        return result == 0 ? 0 : result
    }

    static func value(at fraction: CGFloat, in range: ClosedRange<Double>, step: Double) -> Double {
        let clamped = min(max(Double(fraction), 0), 1)
        return snap(range.lowerBound + clamped * (range.upperBound - range.lowerBound), to: range, step: step)
    }
}

#if os(macOS)
private struct HDRRenditionSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let allowsDoubleTap: Bool
    let accessibilityTitle: String
    let accessibilityValueText: String
    let accessibilityHintText: String
    let accessibilityIdentifierText: String
    let resetLabel: String
    let onEditingChanged: (Bool) -> Void
    let onCancelled: () -> Void
    let onDoubleTapReset: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> HDRRenditionAppKitSlider {
        let slider = HDRRenditionAppKitSlider()
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.valueChanged(_:))
        return slider
    }

    func updateNSView(_ slider: HDRRenditionAppKitSlider, context: Context) {
        context.coordinator.parent = self
        slider.range = range
        slider.step = step
        slider.allowsDoubleTap = allowsDoubleTap
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.onEditingChanged = { active in context.coordinator.parent.onEditingChanged(active) }
        slider.onCommitValue = { next in context.coordinator.commit(next) }
        slider.onCancelled = { context.coordinator.parent.onCancelled() }
        slider.onDoubleTapReset = { context.coordinator.parent.onDoubleTapReset() }
        slider.onStepDirection = { direction, fine in context.coordinator.stepBy(direction, fine: fine) }
        if !slider.isTrackingInteraction {
            slider.doubleValue = value
        }
        slider.setAccessibilityLabel(accessibilityTitle)
        slider.setAccessibilityValueDescription(accessibilityValueText)
        slider.setAccessibilityHelp(accessibilityHintText.isEmpty ? nil : accessibilityHintText)
        slider.setAccessibilityIdentifier(accessibilityIdentifierText)
        slider.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: resetLabel) {
                context.coordinator.parent.onDoubleTapReset()
                return true
            }
        ])
    }

    final class Coordinator: NSObject {
        var parent: HDRRenditionSlider
        init(_ parent: HDRRenditionSlider) { self.parent = parent }

        func commit(_ raw: Double) {
            let snapped = HDRRenditionSliderMath.snap(raw, to: parent.range, step: parent.step)
            if parent.value != snapped {
                parent.value = snapped
            }
        }

        func stepBy(_ direction: Int, fine: Bool) {
            let delta = fine ? parent.step : parent.step * 2
            let next = HDRRenditionSliderMath.snap(parent.value + Double(direction) * delta, to: parent.range, step: parent.step)
            guard next != parent.value else { return }
            parent.onEditingChanged(true)
            parent.value = next
            parent.onEditingChanged(false)
        }

        @objc func valueChanged(_ sender: NSSlider) {
            let next = HDRRenditionSliderMath.snap(sender.doubleValue, to: parent.range, step: parent.step)
            guard next != parent.value else { return }
            parent.onEditingChanged(true)
            parent.value = next
            parent.onEditingChanged(false)
        }
    }
}

/// Custom `NSSlider` subclass that swallows single-click track jumps on double-click and delegates resets directly.
private final class HDRRenditionAppKitSlider: NSSlider {
    private static let dragThreshold: CGFloat = 5

    var range: ClosedRange<Double> = 0...1
    var step: Double = 0.1
    var allowsDoubleTap = true
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onCommitValue: (Double) -> Void = { _ in }
    var onCancelled: () -> Void = {}
    var onDoubleTapReset: () -> Void = {}
    var onStepDirection: (Int, Bool) -> Void = { _, _ in }

    private var pendingClickWork: DispatchWorkItem?
    private var lastClickPoint: NSPoint?
    private var trackingPointer = false
    private var draggedDuringClick = false
    private var editingActive = false
    private var downPoint: NSPoint = .zero

    var isTrackingInteraction: Bool { trackingPointer }

    deinit {
        pendingClickWork?.cancel()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { cancelPendingInteraction() }
    }

    private func cancelPendingInteraction() {
        pendingClickWork?.cancel()
        pendingClickWork = nil
        lastClickPoint = nil
        trackingPointer = false
        draggedDuringClick = false
        finishEditingIfNeeded()
    }

    private func finishEditingIfNeeded() {
        if editingActive {
            editingActive = false
            onEditingChanged(false)
        }
    }

    private func valueForPoint(_ viewPoint: NSPoint) -> Double {
        let inset = min(knobThickness / 2, bounds.width / 4)
        let usable = max(1, bounds.width - 2 * inset)
        let fraction = (viewPoint.x - inset) / usable
        return HDRRenditionSliderMath.value(at: fraction, in: range, step: step)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let pt = convert(event.locationInWindow, from: nil)

        if !allowsDoubleTap {
            pendingClickWork?.cancel()
            pendingClickWork = nil
            lastClickPoint = nil
            trackingPointer = true
            draggedDuringClick = true
            editingActive = true
            onEditingChanged(true)
            let next = valueForPoint(pt)
            doubleValue = next
            onCommitValue(next)
            return
        }

        let isPairedSecondClick = pendingClickWork != nil
            && lastClickPoint.map { hypot(pt.x - $0.x, pt.y - $0.y) < Self.dragThreshold } == true
        if isPairedSecondClick {
            cancelPendingInteraction()
            onDoubleTapReset()
            return
        }

        pendingClickWork?.cancel()
        pendingClickWork = nil
        lastClickPoint = nil
        trackingPointer = true
        draggedDuringClick = false
        downPoint = pt
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, trackingPointer else { return }
        let pt = convert(event.locationInWindow, from: nil)
        if !draggedDuringClick {
            guard hypot(pt.x - downPoint.x, pt.y - downPoint.y) >= Self.dragThreshold else { return }
            draggedDuringClick = true
            editingActive = true
            onEditingChanged(true)
        }
        let next = valueForPoint(pt)
        doubleValue = next
        onCommitValue(next)
    }

    override func mouseUp(with event: NSEvent) {
        guard trackingPointer else { return }
        trackingPointer = false
        let pt = convert(event.locationInWindow, from: nil)

        if draggedDuringClick {
            draggedDuringClick = false
            let next = valueForPoint(pt)
            doubleValue = next
            onCommitValue(next)
            finishEditingIfNeeded()
            return
        }

        let target = valueForPoint(pt)
        lastClickPoint = pt
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingClickWork = nil
            self.lastClickPoint = nil
            self.onEditingChanged(true)
            self.doubleValue = target
            self.onCommitValue(target)
            self.onEditingChanged(false)
        }
        pendingClickWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { super.keyDown(with: event); return }
        if [123, 124, 125, 126].contains(event.keyCode) {
            onStepDirection([124, 126].contains(event.keyCode) ? 1 : -1, event.modifierFlags.contains(.shift))
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled else { return false }
        onStepDirection(1, true)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled else { return false }
        onStepDirection(-1, true)
        return true
    }
}
#elseif canImport(UIKit)
private struct HDRRenditionSlider: UIViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let allowsDoubleTap: Bool
    let accessibilityTitle: String
    let accessibilityValueText: String
    let accessibilityHintText: String
    let accessibilityIdentifierText: String
    let resetLabel: String
    let onEditingChanged: (Bool) -> Void
    let onCancelled: () -> Void
    let onDoubleTapReset: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> HDRRenditionUIKitSlider {
        let slider = HDRRenditionUIKitSlider()
        slider.isContinuous = true
        slider.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.touchFinished(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }

    func updateUIView(_ slider: HDRRenditionUIKitSlider, context: Context) {
        context.coordinator.parent = self
        slider.range = range
        slider.step = step
        slider.allowsDoubleTap = allowsDoubleTap
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        slider.onEditingChanged = { active in context.coordinator.parent.onEditingChanged(active) }
        slider.onCancelled = { context.coordinator.parent.onCancelled() }
        slider.onDoubleTapReset = { context.coordinator.parent.onDoubleTapReset() }
        slider.onStepDirection = { direction in context.coordinator.stepBy(direction, slider: slider) }
        if !slider.isTrackingInteraction {
            slider.value = Float(value)
        }
        slider.accessibilityLabel = accessibilityTitle
        slider.accessibilityValue = accessibilityValueText
        slider.accessibilityHint = accessibilityHintText.isEmpty ? nil : accessibilityHintText
        slider.accessibilityIdentifier = accessibilityIdentifierText
        slider.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: resetLabel) { _ in
                context.coordinator.parent.onDoubleTapReset()
                return true
            }
        ]
    }

    final class Coordinator: NSObject {
        var parent: HDRRenditionSlider
        init(_ parent: HDRRenditionSlider) { self.parent = parent }

        func stepBy(_ direction: Int, slider: HDRRenditionUIKitSlider) {
            let next = HDRRenditionSliderMath.snap(parent.value + Double(direction) * parent.step, to: parent.range, step: parent.step)
            slider.value = Float(next)
            guard next != parent.value else { return }
            parent.onEditingChanged(true)
            parent.value = next
            parent.onEditingChanged(false)
        }

        @objc func valueChanged(_ slider: HDRRenditionUIKitSlider) {
            guard !slider.suppressingFinishCallback else { return }
            if !slider.hasActivePointerInteraction {
                let snapped = HDRRenditionSliderMath.snap(Double(slider.value), to: parent.range, step: parent.step)
                slider.value = Float(snapped)
                guard snapped != parent.value else { return }
                parent.onEditingChanged(true)
                parent.value = snapped
                parent.onEditingChanged(false)
                return
            }
            if slider.allowsDoubleTap && !slider.isActivelyDragging {
                return
            }
            commitCurrentSliderValue(slider)
        }

        func commitCurrentSliderValue(_ slider: HDRRenditionUIKitSlider) {
            slider.beginEditingIfNeeded()
            slider.committedDragOnCurrentTouch = true
            let snapped = HDRRenditionSliderMath.snap(Double(slider.value), to: parent.range, step: parent.step)
            if parent.value != snapped {
                parent.value = snapped
            }
        }

        @objc func touchFinished(_ slider: HDRRenditionUIKitSlider) {
            guard !slider.suppressingFinishCallback else { return }
            if slider.isActivelyDragging {
                let snapped = HDRRenditionSliderMath.snap(Double(slider.value), to: parent.range, step: parent.step)
                if parent.value != snapped {
                    parent.value = snapped
                }
                slider.committedDragOnCurrentTouch = true
            } else {
                slider.value = Float(parent.value)
            }
            slider.finishTrackingInteraction()
        }
    }
}

private final class HDRRenditionDoubleTapDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var slider: UISlider?

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer.view === slider
    }
}

/// Custom `UISlider` subclass that prioritizes double-tap reset, suppresses stationary/micro-wobble tap-1 jitter, and closes non-touch `.valueChanged` / VoiceOver `.adjustable` edits cleanly.
private final class HDRRenditionUIKitSlider: UISlider {
    private static let dragThreshold: CGFloat = 10

    var range: ClosedRange<Double> = 0...1
    var step: Double = 0.1
    var allowsDoubleTap = true {
        didSet { syncGestureConfiguration() }
    }
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onCancelled: () -> Void = {}
    var onDoubleTapReset: () -> Void = {}
    var onStepDirection: (Int) -> Void = { _ in }

    private let doubleTapDelegate = HDRRenditionDoubleTapDelegate()
    private lazy var doubleTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        recognizer.numberOfTapsRequired = 2
        doubleTapDelegate.slider = self
        recognizer.delegate = doubleTapDelegate
        return recognizer
    }()

    private var downPoint: CGPoint?
    private var hasActiveTouch = false
    private var didMoveBeyondThreshold = false
    private var editingActive = false
    var committedDragOnCurrentTouch = false
    private var lastCompletedTouchCommittedDrag = false
    private var touchPrecededByDrag = false
    var suppressingFinishCallback = false

    var isTrackingInteraction: Bool { editingActive }

    private var hasActiveDragGesture: Bool {
        gestureRecognizers?.contains { recognizer in
            guard recognizer !== doubleTapRecognizer else { return false }
            return recognizer.state == .began || recognizer.state == .changed
        } ?? false
    }

    var hasActivePointerInteraction: Bool {
        isTracking || hasActiveTouch || downPoint != nil || hasActiveDragGesture
    }

    var isActivelyDragging: Bool {
        if didMoveBeyondThreshold { return true }
        return gestureRecognizers?.contains { recognizer in
            guard let pan = recognizer as? UIPanGestureRecognizer,
                  pan.state == .began || pan.state == .changed else { return false }
            let delta = pan.translation(in: self)
            return hypot(delta.x, delta.y) >= Self.dragThreshold
        } ?? false
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(doubleTapRecognizer)
        syncGestureConfiguration()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addGestureRecognizer(doubleTapRecognizer)
        syncGestureConfiguration()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncGestureConfiguration()
        if window == nil {
            resetTouchState()
        }
    }

    private func syncGestureConfiguration() {
        doubleTapRecognizer.isEnabled = allowsDoubleTap
    }

    private func resetTouchState() {
        downPoint = nil
        hasActiveTouch = false
        didMoveBeyondThreshold = false
        committedDragOnCurrentTouch = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchPrecededByDrag = lastCompletedTouchCommittedDrag
        hasActiveTouch = true
        committedDragOnCurrentTouch = !allowsDoubleTap
        if let touch = touches.first {
            downPoint = touch.location(in: self)
        }
        didMoveBeyondThreshold = !allowsDoubleTap
        if !allowsDoubleTap {
            beginEditingIfNeeded()
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first {
            markDraggedIfMoved(touch)
        }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        finishTrackingInteraction()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        if !hasActiveDragGesture {
            finishTrackingInteraction()
        }
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        markDraggedIfMoved(touch)
        return super.continueTracking(touch, with: event)
    }

    private func markDraggedIfMoved(_ touch: UITouch) {
        guard let start = downPoint, !didMoveBeyondThreshold else { return }
        let current = touch.location(in: self)
        if hypot(current.x - start.x, current.y - start.y) >= Self.dragThreshold {
            didMoveBeyondThreshold = true
            beginEditingIfNeeded()
        }
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        super.endTracking(touch, with: event)
        finishTrackingInteraction()
    }

    override func cancelTracking(with event: UIEvent?) {
        super.cancelTracking(with: event)
        if !suppressingFinishCallback {
            finishTrackingInteraction()
        }
    }

    override func accessibilityIncrement() {
        guard isEnabled else { return }
        onStepDirection(1)
    }

    override func accessibilityDecrement() {
        guard isEnabled else { return }
        onStepDirection(-1)
    }

    func beginEditingIfNeeded() {
        guard !editingActive else { return }
        editingActive = true
        onEditingChanged(true)
    }

    func finishTrackingInteraction() {
        let didFinishTouch = hasActiveTouch || downPoint != nil || editingActive
        let committedDrag = committedDragOnCurrentTouch
        resetTouchState()
        if didFinishTouch {
            lastCompletedTouchCommittedDrag = committedDrag
        }
        if editingActive {
            editingActive = false
            onEditingChanged(false)
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard isEnabled, allowsDoubleTap, recognizer.state == .ended else { return }
        if touchPrecededByDrag {
            return
        }
        let wasEditing = editingActive
        suppressingFinishCallback = true
        super.cancelTracking(with: nil)
        resetTouchState()
        suppressingFinishCallback = false
        lastCompletedTouchCommittedDrag = false
        touchPrecededByDrag = false
        if wasEditing {
            editingActive = false
            onCancelled()
        }
        onDoubleTapReset()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === doubleTapRecognizer {
            return isEnabled && allowsDoubleTap
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}
#endif

struct HDRLookControls: View {
    @Binding var settings: HDRSettings
    let onEditingChanged: (Bool) -> Void
    let onCancelled: () -> Void
    var onResourceRestored: () -> Void = {}
    @State private var choosingFile = false
    @State private var importing = false
    @State private var failed = false
    @State private var editing = false

    private static func bundledSilver(master: Bool, target: HDRSettings) throws -> HDRSettings {
        let look = try HDRLookAssetStore.installHDRSilver()
        if !master {
            var result = target
            result.lookSettings = look
            return result
        }
        guard let recipe = Bundle.main.url(forResource: "HDR Silver Master", withExtension: "json", subdirectory: "BundledLooks/HDR") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let payload = try JSONDecoder().decode(AdjustmentTransferPayload.self, from: Data(contentsOf: recipe))
        guard payload[.hdrLook]?.hdrLookSettings == look else { throw CocoaError(.fileReadCorruptFile) }
        return try HDRAdjustmentTransfer.prepare(payload: payload, target: target)
    }

    private func load(_ apply: @escaping (HDRSettings) throws -> HDRSettings) {
        let before = settings
        let restoring = before.lookSettings.asset().map { !FileManager.default.isReadableFile(atPath: $0.path) } == true
        importing = true; failed = false
        Task { @MainActor in
            defer { importing = false }
            do {
                let result = try await Task.detached { try apply(before) }.value
                if settings == before {
                    settings = result
                    if restoring && result == before { onResourceRestored() }
                }
            } catch { failed = true }
        }
    }

    var body: some View {
        let look = settings.lookSettings
        VStack(alignment: .leading, spacing: 6) {
            Text(look.name ?? "HDR LUT").font(.caption.weight(.medium)).lineLimit(2)
                .accessibilityIdentifier("hdr.look.name")
            HStack {
                Button(L10n.text("导入外观…")) { choosingFile = true }
                    .accessibilityIdentifier("hdr.look.import")
                if look.sha256 != nil {
                    Button(L10n.text("中性")) { settings.lookSettings = HDRLookSettings() }
                        .accessibilityIdentifier("hdr.look.clear")
                }
            }
            HStack {
                Button("HDR Silver") { load { try Self.bundledSilver(master: false, target: $0) } }
                    .accessibilityIdentifier("hdr.look.silver")
                Button("HDR Silver Master") { load { try Self.bundledSilver(master: true, target: $0) } }
                    .accessibilityIdentifier("hdr.look.silver-master")
            }
            if look.sha256 != nil {
                let percent = String(format: "%.0f%%", locale: L10n.locale, look.strength * 100)
                Text(L10n.text("外观强度") + " " + percent).font(.caption).monospacedDigit()
                Slider(value: $settings.lookSettings.strength, in: 0...2, step: 0.01, onEditingChanged: { active in
                    editing = active; onEditingChanged(active)
                }).accessibilityLabel(L10n.text("外观强度")).accessibilityValue(percent)
                    .accessibilityIdentifier("hdr.look.strength")
            }
            if let asset = look.asset(), !FileManager.default.isReadableFile(atPath: asset.path) {
                Text(L10n.text("上次使用的外观不可用，请重新选择或导入外观。"))
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("hdr.look.missing")
            }
            if failed {
                Text(L10n.text("无法读取外观文件。")).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("hdr.look.error")
            }
        }.disabled(importing)
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data]) { result in
                guard let url = try? result.get() else { return }
                load { target in
                    var result = target
                    result.lookSettings = try HDRLookAssetStore.install(url)
                    return result
                }
            }
            .onDisappear { if editing { editing = false; onCancelled() } }
    }
}

struct HDRCameraDevelopmentControls: View {
    let settings: HDRCameraDevelopmentSettings
    let supportsBayerDevelopment: Bool
    let apply: (HDRCameraDevelopmentSettings) -> Void
    let onResourceRestored: () -> Void
    @State private var draft: HDRCameraDevelopmentSettings
    @State private var choosingProfile = false
    @State private var importingProfile = false
    @State private var profileError: String?

    init(settings: HDRCameraDevelopmentSettings, supportsBayerDevelopment: Bool,
         apply: @escaping (HDRCameraDevelopmentSettings) -> Void,
         onResourceRestored: @escaping () -> Void = {}) {
        self.settings = settings
        self.supportsBayerDevelopment = supportsBayerDevelopment
        self.apply = apply
        self.onResourceRestored = onResourceRestored
        _draft = State(initialValue: settings)
    }

    var body: some View {
        DisclosureGroup("HDR RAW") {
            profileControls
            Picker(L10n.text("白平衡模式"), selection: Binding(get: { draft.whiteBalance }, set: { draft.selectWhiteBalance($0) })) {
                Text(L10n.text("相机白平衡（按目标照片）")).tag(HDRCameraDevelopmentSettings.WhiteBalance.asShot)
                Text(L10n.text("自定义")).tag(HDRCameraDevelopmentSettings.WhiteBalance.temperature)
            }
            .accessibilityIdentifier("hdr.camera.wb")
            if draft.whiteBalance == .temperature {
                cameraSlider("色温", value: $draft.temperature, range: 2000...50000, step: 50, unit: " K", id: "temperature")
                cameraSlider("色调", value: $draft.tint, range: -150...150, step: 1, unit: "", id: "tint")
            }
            Picker(L10n.text("曝光基准"), selection: $draft.exposureReference) {
                Text(L10n.text("场景")).tag(HDRCameraDevelopmentSettings.ExposureReference.metadata)
                Text(L10n.text("传感器基准")).tag(HDRCameraDevelopmentSettings.ExposureReference.sensor)
            }.accessibilityIdentifier("hdr.camera.exposure")
            if supportsBayerDevelopment {
                Picker(L10n.text("RAW 降噪"), selection: $draft.fbddLevel) {
                    Text(L10n.text("关闭")).tag(0)
                    Text("FBDD 1").tag(1)
                    Text("FBDD 2").tag(2)
                }.accessibilityIdentifier("hdr.camera.fbdd")
            }
            Toggle(L10n.text("畸变校正"), isOn: $draft.lensDistortion).accessibilityIdentifier("hdr.camera.distortion")
            Toggle(L10n.text("横向色差"), isOn: $draft.lensTCA).accessibilityIdentifier("hdr.camera.tca")
            Toggle(L10n.text("暗角校正"), isOn: $draft.lensVignetting).accessibilityIdentifier("hdr.camera.vignetting")
            Toggle(L10n.text("自动裁切"), isOn: $draft.lensAutoCrop).disabled(!draft.lensActive)
            HStack {
                Button(L10n.text("重置")) { draft = HDRCameraDevelopmentSettings() }.disabled(draft.isDefault)
                Button(L10n.text("应用")) {
                    if !draft.lensActive { draft.lensProfile = nil }
                    apply(draft)
                }.disabled(draft == settings).accessibilityIdentifier("hdr.camera.apply")
            }.buttonStyle(.borderless)
        }.disabled(importingProfile)
            .onChange(of: settings) { _, current in draft = current }
            .fileImporter(isPresented: $choosingProfile, allowedContentTypes: ["dcp", "rlook"].map {
                UTType(filenameExtension: $0, conformingTo: .data) ?? .data
            }) { result in
                guard let url = try? result.get() else { return }
                let restoring = draft == settings && draft.cameraProfile.map {
                    (try? HDRCameraProfileAssetStore.url(for: $0)) == nil
                } == true
                importingProfile = true
                profileError = nil
                Task { @MainActor in
                    defer { importingProfile = false }
                    do {
                        draft.cameraProfile = try await Task.detached { try HDRCameraProfileAssetStore.install(url) }.value
                        if restoring && draft.cameraProfile?.sha256 == settings.cameraProfile?.sha256 { onResourceRestored() }
                    } catch { profileError = error.localizedDescription }
                }
            }
    }

    @ViewBuilder private var profileControls: some View {
        if let profile = draft.cameraProfile {
            LabeledContent(L10n.text("HDR 相机配置"), value: profile.name)
                .accessibilityIdentifier("hdr.camera.profile.name")
        }
        HStack {
            Button(L10n.text("导入相机配置…")) { choosingProfile = true }
                .accessibilityIdentifier("hdr.camera.profile.import")
            if draft.cameraProfile != nil {
                Button(L10n.text("清除相机配置")) { draft.cameraProfile = nil; profileError = nil }
                    .accessibilityIdentifier("hdr.camera.profile.clear")
            }
        }.buttonStyle(.borderless)
        if let profile = draft.cameraProfile, (try? HDRCameraProfileAssetStore.url(for: profile)) == nil {
            Text(L10n.text("找不到 HDR 相机配置，请重新导入。"))
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("hdr.camera.profile.missing")
        }
        if let profileError { Text(profileError).font(.caption).foregroundStyle(.secondary) }
    }

    private func cameraSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                              step: Double, unit: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.text(title) + " " + String(Int(value.wrappedValue.rounded())) + unit).font(.caption)
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(L10n.text(title)).accessibilityIdentifier("hdr.camera.\(id)")
        }
    }
}

struct HDRLuminanceHistogram: View {
    let statistics: HDRStatistics
    let headroom: Double
    var body: some View {
        Canvas { context,size in
            let maximum=statistics.bins.max() ?? 1
            let width=size.width/256
            for (index,value) in statistics.bins.enumerated() {
                let height=maximum>0 ? size.height*log1p(value)/log1p(maximum) : 0
                context.fill(Path(CGRect(x:Double(index)*width,y:size.height-height,width:width+0.5,height:height)),
                    with:.color(.white.opacity(0.8)))
            }
            for (position,color,dash) in [(0.5,Color.white,[CGFloat]()),
                (HDRStatistics.position(headroom:headroom),Color.yellow,[CGFloat(3),2])] {
                var line=Path(); line.move(to:CGPoint(x:position*size.width,y:0))
                line.addLine(to:CGPoint(x:position*size.width,y:size.height))
                context.stroke(line,with:.color(.black.opacity(0.9)),style:StrokeStyle(lineWidth:3,dash:dash))
                context.stroke(line,with:.color(color),style:StrokeStyle(lineWidth:1,dash:dash))
            }
        }.accessibilityLabel(L10n.text("HDR 亮度直方图"))
    }
}
