import SwiftUI
import UIKit

struct AdjustmentRuler: UIViewRepresentable {
    @Binding var value: Double
    let scale: AdjustmentScale
    let defaultValue: Double?
    let title: String
    let formatter: (Double) -> String
    let identifier: String
    let fine: Bool
    let haptics: Bool
    let reduceMotion: Bool
    let onEditingChanged: (Bool) -> Void

    func makeUIView(context: Context) -> AdjustmentRulerView { AdjustmentRulerView() }

    func updateUIView(_ view: AdjustmentRulerView, context: Context) {
        view.configure(scale: scale, value: value, defaultValue: defaultValue, fine: fine,
                       haptics: haptics, reduceMotion: reduceMotion, title: title,
                       formatter: formatter, identifier: identifier,
                       onChange: { value = $0 }, onEditingChanged: onEditingChanged)
    }

    static func dismantleUIView(_ view: AdjustmentRulerView, coordinator: Void) { view.cancel() }
}

// MARK: - Continuous tape, discrete values

final class AdjustmentRulerView: UIView, UIGestureRecognizerDelegate {
    private var scale = AdjustmentScale(range: 0...1, step: 0.01)
    private var ticks: [AdjustmentTick] = []
    private var value = 0.0
    private var defaultValue: Double?
    private var position = 0.0
    private var lastTranslation = 0.0
    private var editing = false
    private var gestureActive = false
    private var gestureValueEchoes: Set<Double> = []
    private var fine = false
    private var haptics = true
    private var reduceMotion = false
    private var formatter: (Double) -> String = { String($0) }
    private var onChange: (Double) -> Void = { _ in }
    private var onEditingChanged: (Bool) -> Void = { _ in }
    private var motion = AdjustmentTickMotion()
    private var displayLink: CADisplayLink?
    private var settlement: (start: Double, end: Double, time: Double)?
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
    private lazy var linkTarget = RulerDisplayLinkTarget(view: self)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        tintColor = .systemYellow
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        pan.delegate = self
        addGestureRecognizer(pan)
        NotificationCenter.default.addObserver(self, selector: #selector(cancel),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { displayLink?.invalidate(); NotificationCenter.default.removeObserver(self) }

    func configure(scale: AdjustmentScale, value: Double, defaultValue: Double?, fine: Bool,
                   haptics: Bool, reduceMotion: Bool, title: String, formatter: @escaping (Double) -> String,
                   identifier: String, onChange: @escaping (Double) -> Void,
                   onEditingChanged: @escaping (Bool) -> Void) {
        let gestureEcho = gestureActive && self.scale == scale && gestureValueEchoes.contains(value)
        let replaced = self.scale != scale || (!gestureEcho && abs(self.value - value) > scale.step * 1e-8)
        let endedEditing = replaced && editing
        if replaced { cancelState(notify: false) }
        if self.scale != scale || ticks.isEmpty { ticks = scale.ticks }
        self.scale = scale
        if !gestureEcho { self.value = value }
        self.defaultValue = defaultValue
        self.fine = fine
        self.haptics = haptics
        self.reduceMotion = reduceMotion
        self.formatter = formatter
        self.onChange = onChange
        self.onEditingChanged = onEditingChanged
        accessibilityLabel = title
        accessibilityIdentifier = identifier
        accessibilityValue = formatter(self.value)
        accessibilityHint = "\(L10n.text("范围")) \(formatter(scale.range.lowerBound)) – \(formatter(scale.range.upperBound))"
        accessibilityCustomActions = defaultValue.map { _ in
            [UIAccessibilityCustomAction(name: L10n.text("恢复默认"), target: self, selector: #selector(resetDefault))]
        }
        if !editing && settlement == nil { position = scale.position(for: value) }
        if reduceMotion { motion.clear(); settlement = nil; stopDisplayLink() }
        if endedEditing {
            DispatchQueue.main.async { [weak self] in self?.onEditingChanged(false) }
        }
        setNeedsDisplay()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancel() }
    }

    override var isHidden: Bool { didSet { if isHidden { cancel() } } }
    override var canBecomeFirstResponder: Bool { true }
    override func resignFirstResponder() -> Bool { cancel(); return super.resignFirstResponder() }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        let translation = pan.translation(in: self)
        let direction = translation == .zero ? pan.velocity(in: self) : translation
        return abs(direction.x) > abs(direction.y) * 1.4
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, let scroll = other.view as? UIScrollView else { return false }
        return other === scroll.panGestureRecognizer && isDescendant(of: scroll)
    }

    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            if gesture.state == .began {
                becomeFirstResponder()
                gestureActive = true
                gestureValueEchoes = [value]
            }
            guard gestureActive else { return }
            let translation = gesture.translation(in: self)
            if !editing {
                guard AdjustmentScale.hasHorizontalIntent(x: translation.x, y: translation.y) else { return }
                settlement = nil
                motion.clear()
                lastTranslation = 0
                editing = true
                onEditingChanged(true)
            }
            guard gestureActive else { return }
            moveTape(translation: translation.x)
        case .ended:
            gestureActive = false
            finishDrag()
        case .cancelled, .failed:
            cancel()
        default:
            break
        }
    }

    private func moveTape(translation: Double) {
        guard editing else { return }
        let delta = translation - lastTranslation
        lastTranslation = translation
        let next = min(max(position - delta / scale.tapeLength * (fine ? 0.25 : 1), 0), 1)
        guard next != position else { return }
        position = next
        let now = CACurrentMediaTime()
        if !reduceMotion {
            for tick in ticks {
                motion.excite(id: tick.id, distance: (tick.position - position) * scale.tapeLength, at: now)
            }
            startDisplayLink()
        }
        commit(scale.rounded(scale.value(at: next)), feedback: true)
        setNeedsDisplay()
    }

    private func commit(_ newValue: Double, feedback: Bool) {
        guard newValue != value else { return }
        let old = value
        value = newValue
        if gestureActive { gestureValueEchoes.insert(newValue) }
        accessibilityValue = formatter(newValue)
        onChange(newValue)
        if feedback { AdjustmentFeedback.change(from: old, to: newValue, scale: scale, defaultValue: defaultValue, enabled: haptics) }
    }

    private func finishDrag() {
        guard editing else { return }
        editing = false
        gestureValueEchoes.removeAll(keepingCapacity: true)
        onEditingChanged(false)
        let target = scale.position(for: value)
        if !reduceMotion && abs(target - position) > 1e-8 {
            settlement = (position, target, CACurrentMediaTime())
            startDisplayLink()
        } else { position = target }
        setNeedsDisplay()
    }

    @objc func cancel() {
        cancelState(notify: true)
    }

    private func cancelState(notify: Bool) {
        gestureActive = false
        gestureValueEchoes.removeAll(keepingCapacity: true)
        if editing {
            editing = false
            if notify { onEditingChanged(false) }
        }
        settlement = nil
        motion.clear()
        stopDisplayLink()
        position = scale.position(for: value)
        setNeedsDisplay()
    }

    private func startDisplayLink() {
        guard displayLink == nil, window != nil, !isHidden else { return }
        displayLink = CADisplayLink(target: linkTarget, selector: #selector(RulerDisplayLinkTarget.frame(_:)))
        displayLink?.add(to: .main, forMode: .common)
    }

    private func stopDisplayLink() { displayLink?.invalidate(); displayLink = nil }

    fileprivate func frame(at time: Double) {
        if let settlement {
            let progress = min(max((time - settlement.time) / 0.12, 0), 1)
            let eased = 1 - pow(1 - progress, 2)
            position = settlement.start + (settlement.end - settlement.start) * eased
            if progress == 1 { self.settlement = nil }
        }
        motion.prune(at: time)
        if motion.isEmpty && settlement == nil { stopDisplayLink() }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let center = bounds.midX, baseline = 34.0, now = CACurrentMediaTime()
        let font = UIFont.preferredFont(forTextStyle: .caption2)
        var lastLabelRight = -Double.infinity
        context.setLineWidth(1)
        for tick in ticks {
            let x = center + (tick.position - position) * scale.tapeLength
            guard x >= -1 && x <= bounds.width + 1 else { continue }
            let height = motion.height(for: tick, at: now, reduceMotion: reduceMotion)
            context.setStrokeColor(UIColor.secondaryLabel.cgColor)
            context.move(to: CGPoint(x: x, y: baseline - height))
            context.addLine(to: CGPoint(x: x, y: baseline))
            context.strokePath()
            if tick.major {
                let text = formatter(tick.value) as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.secondaryLabel]
                let width = text.size(withAttributes: attributes).width
                if x - width / 2 > lastLabelRight + 12 {
                    text.draw(at: CGPoint(x: x - width / 2, y: baseline + 13), withAttributes: attributes)
                    lastLabelRight = x + width / 2
                }
            }
        }
        if let defaultValue {
            let x = center + (scale.position(for: defaultValue) - position) * scale.tapeLength
            context.setFillColor(UIColor.secondaryLabel.cgColor)
            context.fillEllipse(in: CGRect(x: x - 2.5, y: baseline + 5, width: 5, height: 5))
        }
        context.setStrokeColor(tintColor.cgColor)
        context.setLineWidth(2)
        context.move(to: CGPoint(x: center, y: 6))
        context.addLine(to: CGPoint(x: center, y: baseline))
        context.strokePath()
    }

    override func accessibilityIncrement() { discreteChange(direction: 1) }
    override func accessibilityDecrement() { discreteChange(direction: -1) }

    private func discreteChange(direction: Int) {
        cancel()
        onEditingChanged(true)
        commit(scale.increment(value, direction: direction), feedback: false)
        position = scale.position(for: value)
        onEditingChanged(false)
        setNeedsDisplay()
    }

    @objc private func resetDefault() -> Bool {
        guard let defaultValue else { return false }
        cancel()
        onEditingChanged(true)
        commit(defaultValue, feedback: false)
        position = scale.position(for: value)
        onEditingChanged(false)
        return true
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(decrease)),
         UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(increase))]
    }

    @objc private func decrease() { discreteChange(direction: -1) }
    @objc private func increase() { discreteChange(direction: 1) }
}

private final class RulerDisplayLinkTarget {
    weak var view: AdjustmentRulerView?
    init(view: AdjustmentRulerView) { self.view = view }
    @objc func frame(_ link: CADisplayLink) { view?.frame(at: link.timestamp) }
}
