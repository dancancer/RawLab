import Foundation

struct HSLTargetRevision: Equatable, Hashable {
    let source: UInt64
    let request: UInt64
}

enum HSLTargetAvailability: Int, Equatable {
    case available, nearGray, outside, stale, nonfinite, failed
}

struct HSLTargetSample: Equatable {
    let revision: HSLTargetRevision
    let availability: HSLTargetAvailability
    let rgb: [Double]
    let weights: [Double]
    let preview: Bool
    var isUsable: Bool {
        availability == .available && rgb.count == 3 && rgb.allSatisfy(\.isFinite) &&
        weights.count == 8 && weights.allSatisfy { $0.isFinite && (0...1).contains($0) } &&
        abs(weights.reduce(0, +) - 1) < 0.00001
    }
    var channels: [Int] { isUsable ? weights.indices.filter { weights[$0] > 0 } : [] }
}

struct HSLTargetDrag {
    let before: HSLSettings
    let axis: HSLAxis
    let sample: HSLTargetSample
    init?(before: HSLSettings, axis: HSLAxis, sample: HSLTargetSample) {
        guard before.isValid, sample.isUsable else { return nil }
        self.before = before; self.axis = axis; self.sample = sample
    }
    func value(delta: Double) -> HSLSettings {
        guard delta.isFinite else { return before }
        var next = before
        for channel in sample.channels {
            next.setExact(axis, channel: channel,
                          value: min(100, max(-100, before.value(axis, channel: channel) + delta * sample.weights[channel])))
        }
        return next
    }
}

// 取色在串行渲染队列中完成；等待期间保留最后位移，迟到结果不能恢复已取消的输入。
struct HSLTargetInteraction {
    private struct Pending {
        let token: UInt64
        let before: HSLSettings
        let axis: HSLAxis
        let revision: HSLTargetRevision
        var delta = 0.0
        var released = false
        var drag: HSLTargetDrag?
    }
    private var generation: UInt64 = 0
    private var pending: Pending?
    private(set) var selection: HSLTargetSample?
    var isDragging: Bool { pending?.released == false }
    var isWaiting: Bool { pending != nil && pending?.drag == nil }
    func matches(_ token: UInt64) -> Bool { pending?.token == token }
    mutating func accumulateReleased(delta: Double) {
        guard delta.isFinite, pending?.released == true, pending?.drag == nil,
              let amount = pending?.delta, (amount + delta).isFinite else { return }
        pending?.delta = amount + delta
    }
    @discardableResult mutating func begin(before: HSLSettings, axis: HSLAxis, revision: HSLTargetRevision) -> UInt64 {
        generation &+= 1
        selection = nil
        pending = Pending(token: generation, before: before, axis: axis, revision: revision)
        return generation
    }
    @discardableResult mutating func move(delta: Double) -> HSLSettings? {
        guard delta.isFinite, pending?.released == false else { return nil }
        pending?.delta = delta
        return pending?.drag?.value(delta: delta)
    }
    @discardableResult mutating func accept(_ sample: HSLTargetSample, token: UInt64,
                                            currentRevision: HSLTargetRevision?) -> HSLSettings? {
        guard var active = pending, active.token == token else { return nil }
        guard active.revision == currentRevision, sample.revision == active.revision else {
            pending = nil; selection = nil; return nil
        }
        selection = sample
        guard let drag = HSLTargetDrag(before: active.before, axis: active.axis, sample: sample) else {
            pending = nil; return nil
        }
        active.drag = drag
        pending = active.released ? nil : active
        return drag.value(delta: active.delta)
    }
    mutating func end() {
        if pending?.drag != nil { pending = nil }
        else { pending?.released = true }
    }
    @discardableResult mutating func cancel() -> HSLSettings? {
        let before = pending?.drag == nil ? nil : pending?.before
        pending = nil; selection = nil
        return before
    }
}

struct HSLTargetCanvasInput {
    let scope: String
    let begin: (CGPoint) -> Void
    let change: (Double) -> Void
    let end: () -> Void
    let cancel: () -> Void
    let key: (Double) -> Void
    let reject: () -> Void
    var exit: (() -> Void)? = nil
}
