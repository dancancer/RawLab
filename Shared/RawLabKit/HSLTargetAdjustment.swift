import Foundation

public struct HSLTargetRevision: Equatable, Hashable {
    public let source: UInt64
    public let request: UInt64
    public init(source: UInt64, request: UInt64) {
        self.source = source
        self.request = request
    }
}

public enum HSLTargetAvailability: Int, Equatable {
    case available, nearGray, outside, stale, nonfinite, failed
}

public struct HSLTargetSample: Equatable {
    public let revision: HSLTargetRevision
    public let availability: HSLTargetAvailability
    public let rgb: [Double]
    public let weights: [Double]
    public let preview: Bool
    public init(revision: HSLTargetRevision, availability: HSLTargetAvailability, rgb: [Double], weights: [Double], preview: Bool) {
        self.revision = revision; self.availability = availability; self.rgb = rgb; self.weights = weights; self.preview = preview
    }
    public var isUsable: Bool {
        availability == .available && rgb.count == 3 && rgb.allSatisfy(\.isFinite) &&
        weights.count == 8 && weights.allSatisfy { $0.isFinite && (0...1).contains($0) } &&
        abs(weights.reduce(0, +) - 1) < 0.00001
    }
    public var channels: [Int] { isUsable ? weights.indices.filter { weights[$0] > 0 } : [] }
}

public struct HSLTargetDrag {
    public let before: HSLSettings
    public let axis: HSLAxis
    public let sample: HSLTargetSample
    public init?(before: HSLSettings, axis: HSLAxis, sample: HSLTargetSample) {
        guard before.isValid, sample.isUsable else { return nil }
        self.before = before; self.axis = axis; self.sample = sample
    }
    public func value(delta: Double) -> HSLSettings {
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
public struct HSLTargetInteraction {
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
    public private(set) var selection: HSLTargetSample?
    public init() {}
    public var isDragging: Bool { pending?.released == false }
    public var isWaiting: Bool { pending != nil && pending?.drag == nil }
    public func matches(_ token: UInt64) -> Bool { pending?.token == token }
    public mutating func accumulateReleased(delta: Double) {
        guard delta.isFinite, pending?.released == true, pending?.drag == nil,
              let amount = pending?.delta, (amount + delta).isFinite else { return }
        pending?.delta = amount + delta
    }
    @discardableResult public mutating func begin(before: HSLSettings, axis: HSLAxis, revision: HSLTargetRevision) -> UInt64 {
        generation &+= 1
        selection = nil
        pending = Pending(token: generation, before: before, axis: axis, revision: revision)
        return generation
    }
    @discardableResult public mutating func move(delta: Double) -> HSLSettings? {
        guard delta.isFinite, pending?.released == false else { return nil }
        pending?.delta = delta
        return pending?.drag?.value(delta: delta)
    }
    @discardableResult public mutating func accept(_ sample: HSLTargetSample, token: UInt64,
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
    public mutating func end() {
        if pending?.drag != nil { pending = nil }
        else { pending?.released = true }
    }
    @discardableResult public mutating func cancel() -> HSLSettings? {
        let before = pending?.drag == nil ? nil : pending?.before
        pending = nil; selection = nil
        return before
    }
}

public struct HSLTargetCanvasInput {
    public let scope: String
    public let begin: (CGPoint) -> Void
    public let change: (Double) -> Void
    public let end: () -> Void
    public let cancel: () -> Void
    public let key: (Double) -> Void
    public let reject: () -> Void
    public var exit: (() -> Void)? = nil
    public init(scope: String, begin: @escaping (CGPoint) -> Void, change: @escaping (Double) -> Void,
                end: @escaping () -> Void, cancel: @escaping () -> Void, key: @escaping (Double) -> Void,
                reject: @escaping () -> Void, exit: (() -> Void)? = nil) {
        self.scope = scope; self.begin = begin; self.change = change; self.end = end
        self.cancel = cancel; self.key = key; self.reject = reject; self.exit = exit
    }
}
