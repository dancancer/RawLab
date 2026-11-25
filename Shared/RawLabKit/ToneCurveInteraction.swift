import Foundation

public struct ToneCurveInputConfiguration {
    public let read: () -> ToneCurveSettings
    public let selected: Int
    public let scope: String
    public let fine: Bool
    public let enabled: Bool
    public let isCurrent: () -> Bool
    public let prepare: () -> Bool
    public let begin: () -> Bool
    public let select: (Int) -> Void
    public let change: (ToneCurveSettings) -> Void
    public let end: () -> Void
    public let cancel: () -> Void

    public init(read: @escaping () -> ToneCurveSettings, selected: Int, scope: String, fine: Bool, enabled: Bool,
                isCurrent: @escaping () -> Bool, prepare: @escaping () -> Bool, begin: @escaping () -> Bool,
                select: @escaping (Int) -> Void, change: @escaping (ToneCurveSettings) -> Void,
                end: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.read = read; self.selected = selected; self.scope = scope; self.fine = fine; self.enabled = enabled
        self.isCurrent = isCurrent; self.prepare = prepare; self.begin = begin
        self.select = select; self.change = change; self.end = end; self.cancel = cancel
    }
}

public final class ToneCurveInputSession {
    public static let dragOutDeleteMargin = 0.12
    public static let doubleTapDeleteInterval: TimeInterval = 0.35
    public static let significantMoveThreshold = 0.02

    public static func isOutsideDeleteBounds(x: Double, y: Double) -> Bool {
        let m = dragOutDeleteMargin
        return x < -m || x > 1.0 + m || y < -m || y > 1.0 + m
    }

    public var configuration: ToneCurveInputConfiguration?
    private let now: () -> TimeInterval
    private struct Drag {
        let config: ToneCurveInputConfiguration
        let initial: ToneCurveSettings
        let index: Int
        let x: Double, y: Double, scale: Double
        let hitExistingInterior: Bool
        let startTime: TimeInterval
        var latestPoint: ToneCurvePoint
        var movedSignificantly = false
        var removedByDragOut = false
    }
    private struct ArmedDelete {
        let scope: String
        let index: Int
        let point: ToneCurvePoint
        let time: TimeInterval
    }
    private var active: Drag?
    private var armedDelete: ArmedDelete?
    public init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }
    public var isActive: Bool { active != nil }
    public func configure(_ next: ToneCurveInputConfiguration) {
        if let old = configuration, old.scope != next.scope || old.fine != next.fine || !next.enabled {
            armedDelete = nil
            cancel(deferred: true)
        }
        configuration = next
    }
    @discardableResult public func begin(x: Double, y: Double, toleranceX: Double, toleranceY: Double, fine: Bool = false) -> Bool {
        guard active == nil, let config = configuration, config.enabled, config.isCurrent(),
              x.isFinite, y.isFinite, toleranceX > 0, toleranceY > 0,
              config.prepare() else { return false }
        let timestamp = now()
        let armed = armedDelete
        armedDelete = nil
        let original = config.read()
        guard original.mode == .custom else { return false }

        if let armed, armed.scope == config.scope,
           timestamp >= armed.time, timestamp - armed.time <= Self.doubleTapDeleteInterval,
           original.points.indices.contains(armed.index),
           original.isInterior(armed.index),
           original.points[armed.index] == armed.point,
           distance(armed.point, x, y, toleranceX, toleranceY) <= 1 {
            let removed = original.removing(index: armed.index)
            guard removed != original, config.begin() else { config.cancel(); return false }
            config.change(removed)
            config.select(min(armed.index, max(0, removed.points.count - 1)))
            config.end()
            return false
        }

        let nearest = original.points.enumerated().min { a, b in
            distance(a.element, x, y, toleranceX, toleranceY) < distance(b.element, x, y, toleranceX, toleranceY)
        }
        var initial = original
        let index: Int
        let hitExistingInterior: Bool
        if let nearest, distance(nearest.element, x, y, toleranceX, toleranceY) <= 1 {
            index = nearest.offset
            hitExistingInterior = original.isInterior(index)
        } else {
            initial = initial.inserting(x: x, y: y)
            guard initial != original, let inserted = initial.points.firstIndex(where: { $0.x == x }) else { return false }
            index = inserted
            hitExistingInterior = false
        }
        guard config.begin() else { config.cancel(); return false }
        config.select(index)
        active = Drag(
            config: config,
            initial: initial,
            index: index,
            x: x,
            y: y,
            scale: fine || config.fine ? 0.25 : 1,
            hitExistingInterior: hitExistingInterior,
            startTime: timestamp,
            latestPoint: initial.points[index]
        )
        if initial != original { config.change(initial) }
        return true
    }
    @discardableResult public func removePoint(x: Double, y: Double, toleranceX: Double, toleranceY: Double) -> Bool {
        cancel()
        armedDelete = nil
        guard let config = configuration, config.enabled, config.isCurrent(),
              x.isFinite, y.isFinite, toleranceX > 0, toleranceY > 0,
              config.prepare() else { return false }
        let original = config.read()
        guard original.mode == .custom,
              let nearest = original.points.enumerated().min(by: { a, b in
                  distance(a.element, x, y, toleranceX, toleranceY) < distance(b.element, x, y, toleranceX, toleranceY)
              }),
              distance(nearest.element, x, y, toleranceX, toleranceY) <= 1,
              original.isInterior(nearest.offset) else { return false }
        let removed = original.removing(index: nearest.offset)
        guard removed != original, config.begin() else { config.cancel(); return false }
        config.change(removed)
        config.select(min(nearest.offset, max(0, removed.points.count - 1)))
        config.end()
        return true
    }
    private func distance(_ point: ToneCurvePoint, _ x: Double, _ y: Double, _ tx: Double, _ ty: Double) -> Double {
        let dx = (point.x - x) / tx, dy = (point.y - y) / ty
        return dx * dx + dy * dy
    }
    public func move(x: Double, y: Double) {
        guard var drag = active else { return }
        guard drag.config.isCurrent() else { cancel(); return }
        if hypot(x - drag.x, y - drag.y) > Self.significantMoveThreshold {
            drag.movedSignificantly = true
        }
        if drag.initial.isInterior(drag.index) && Self.isOutsideDeleteBounds(x: x, y: y) {
            let removed = drag.initial.removing(index: drag.index)
            drag.removedByDragOut = true
            active = drag
            drag.config.select(min(drag.index, max(0, removed.points.count - 1)))
            drag.config.change(removed)
            return
        }
        let wasRemoved = drag.removedByDragOut
        drag.removedByDragOut = false
        let start = drag.initial.points[drag.index]
        let moved = drag.initial.moving(index: drag.index,
            x: start.x + (x - drag.x) * drag.scale, y: start.y + (y - drag.y) * drag.scale)
        drag.latestPoint = moved.points[drag.index]
        active = drag
        if wasRemoved { drag.config.select(drag.index) }
        drag.config.change(moved)
    }
    public func end() {
        guard let drag = active else { return }; active = nil
        if drag.hitExistingInterior && !drag.movedSignificantly && !drag.removedByDragOut {
            armedDelete = ArmedDelete(
                scope: drag.config.scope,
                index: drag.index,
                point: drag.latestPoint,
                time: drag.startTime
            )
        } else {
            armedDelete = nil
        }
        if drag.config.isCurrent() { drag.config.end() }
    }
    public func cancel(deferred: Bool = false) {
        armedDelete = nil
        guard let drag = active else { return }; active = nil
        if deferred { DispatchQueue.main.async { if drag.config.isCurrent() { drag.config.cancel() } } }
        else if drag.config.isCurrent() { drag.config.cancel() }
    }
    public func key(horizontal: Double = 0, vertical: Double = 0, fine: Bool = false, remove: Bool = false) {
        armedDelete = nil
        guard active == nil, let config = configuration, config.enabled, config.isCurrent(),
              config.prepare() else { return }
        let original = config.read()
        if remove {
            guard original.isInterior(config.selected) else { return }
        } else {
            guard (horizontal == 0 || original.canMoveX(config.selected)) &&
                  (vertical == 0 || original.canMoveY(config.selected)) else { return }
        }
        let point = original.points[config.selected], step = fine || config.fine ? 0.001 : 0.01
        let next = remove ? original.removing(index: config.selected) : original.moving(index: config.selected,
            x: point.x + horizontal * step, y: point.y + vertical * step)
        guard next != original, config.begin() else { return }
        config.change(next)
        if remove { config.select(min(config.selected, next.points.count - 1)) }
        config.end()
    }
}

public struct CurveTargetDrag {
    public let before: ToneCurveSettings
    public let channel: ToneCurveChannel
    public let initial: ToneCurveSettings
    public let pointIndex: Int
    public let sample: HSLTargetSample

    public static func targetValue(
        sample: HSLTargetSample,
        channel: ToneCurveChannel,
        isHDR: Bool
    ) -> Double? {
        guard (sample.availability == .available || sample.availability == .nearGray),
              sample.rgb.count == 3,
              sample.rgb.allSatisfy(\.isFinite) else { return nil }
        let raw: Double
        switch channel {
        case .rgb:
            raw = 0.2126 * sample.rgb[0] + 0.7152 * sample.rgb[1] + 0.0722 * sample.rgb[2]
        case .red:
            raw = sample.rgb[0]
        case .green:
            raw = sample.rgb[1]
        case .blue:
            raw = sample.rgb[2]
        }
        if isHDR {
            guard raw > 0 else { return 0.0 }
            let stops = log2(raw)
            return min(1.0, max(0.0, (stops + 8.0) / 16.0))
        }
        return min(1.0, max(0.0, raw))
    }

    public static func invertSampledCurve(_ yOut: Double, samples: [ToneCurvePoint]) -> Double {
        guard samples.count >= 2 else { return min(1.0, max(0.0, yOut)) }
        if yOut <= samples[0].y { return samples[0].x }
        if yOut >= samples[samples.count - 1].y { return samples[samples.count - 1].x }
        for i in 0..<(samples.count - 1) {
            let a = samples[i], b = samples[i + 1]
            if yOut >= a.y && yOut <= b.y {
                let spanY = b.y - a.y
                if spanY <= 1e-12 { return (a.x + b.x) * 0.5 }
                return a.x + (b.x - a.x) * ((yOut - a.y) / spanY)
            }
        }
        return min(1.0, max(0.0, yOut))
    }

    public init?(
        before: ToneCurveSettings,
        channel: ToneCurveChannel,
        sample: HSLTargetSample,
        sampledCurve: [ToneCurvePoint],
        isHDR: Bool = false,
        parametricEvaluator: ((Double) -> Double)? = nil,
        toleranceX: Double = 0.04
    ) {
        guard before.isValid,
              let yOut = Self.targetValue(sample: sample, channel: channel, isHDR: isHDR) else { return nil }
        self.before = before
        self.channel = channel
        self.sample = sample

        let existingShape = before.shape(channel)
        let workingShape = existingShape.mode == .legacy ? ToneCurveShape.identity : existingShape
        let xIn = Self.invertSampledCurve(yOut, samples: sampledCurve)
        let targetX: Double
        if channel == .rgb, !before.parametric.isIdentity, let eval = parametricEvaluator {
            targetX = min(1.0, max(0.0, eval(xIn)))
        } else {
            targetX = xIn
        }

        if let nearest = workingShape.points.enumerated().min(by: { abs($0.element.x - targetX) < abs($1.element.x - targetX) }),
           abs(nearest.element.x - targetX) <= toleranceX {
            self.pointIndex = nearest.offset
            self.initial = before.replacing(channel, with: workingShape)
        } else if targetX > 0.0 && targetX < 1.0 && workingShape.points.count < 33 {
            let yAtX = existingShape.mode == .legacy ? targetX : yOut
            let inserted = workingShape.inserting(x: targetX, y: yAtX)
            if let idx = inserted.points.firstIndex(where: { $0.x == targetX }) {
                self.pointIndex = idx
                self.initial = before.replacing(channel, with: inserted)
            } else if let nearest = workingShape.points.enumerated().min(by: { abs($0.element.x - targetX) < abs($1.element.x - targetX) }) {
                self.pointIndex = nearest.offset
                self.initial = before.replacing(channel, with: workingShape)
            } else {
                return nil
            }
        } else if let nearest = workingShape.points.enumerated().min(by: { abs($0.element.x - targetX) < abs($1.element.x - targetX) }) {
            self.pointIndex = nearest.offset
            self.initial = before.replacing(channel, with: workingShape)
        } else {
            return nil
        }
    }

    public func value(delta: Double) -> ToneCurveSettings {
        guard delta.isFinite else { return before }
        let shape = initial.shape(channel)
        guard shape.points.indices.contains(pointIndex) else { return before }
        let p = shape.points[pointIndex]
        let nextShape = shape.moving(index: pointIndex, x: p.x, y: p.y + delta / 200.0)
        return initial.replacing(channel, with: nextShape)
    }
}

public struct CurveTargetInteraction {
    private struct Pending {
        let token: UInt64
        let before: ToneCurveSettings
        let channel: ToneCurveChannel
        let revision: HSLTargetRevision
        let sampledCurve: [ToneCurvePoint]
        let isHDR: Bool
        let parametricEvaluator: ((Double) -> Double)?
        var delta = 0.0
        var released = false
        var drag: CurveTargetDrag?
    }
    private var generation: UInt64 = 0
    private var pending: Pending?
    public private(set) var selection: HSLTargetSample?
    public init() {}
    public var isDragging: Bool { pending?.released == false }
    public var isWaiting: Bool { pending != nil && pending?.drag == nil }
    public var selectedPointIndex: Int? { pending?.drag?.pointIndex }
    public func matches(_ token: UInt64) -> Bool { pending?.token == token }

    public mutating func accumulateReleased(delta: Double) {
        guard delta.isFinite, pending?.released == true, pending?.drag == nil,
              let amount = pending?.delta, (amount + delta).isFinite else { return }
        pending?.delta = amount + delta
    }

    @discardableResult
    public mutating func begin(
        before: ToneCurveSettings,
        channel: ToneCurveChannel,
        revision: HSLTargetRevision,
        sampledCurve: [ToneCurvePoint] = [],
        isHDR: Bool = false,
        parametricEvaluator: ((Double) -> Double)? = nil
    ) -> UInt64 {
        generation &+= 1
        selection = nil
        pending = Pending(
            token: generation,
            before: before,
            channel: channel,
            revision: revision,
            sampledCurve: sampledCurve,
            isHDR: isHDR,
            parametricEvaluator: parametricEvaluator
        )
        return generation
    }

    @discardableResult
    public mutating func move(delta: Double) -> ToneCurveSettings? {
        guard delta.isFinite, pending?.released == false else { return nil }
        pending?.delta = delta
        return pending?.drag?.value(delta: delta)
    }

    @discardableResult
    public mutating func accept(
        _ sample: HSLTargetSample,
        token: UInt64,
        currentRevision: HSLTargetRevision?
    ) -> ToneCurveSettings? {
        guard var active = pending, active.token == token else { return nil }
        guard active.revision == currentRevision, sample.revision == active.revision else {
            pending = nil; selection = nil; return nil
        }
        selection = sample
        guard let drag = CurveTargetDrag(
            before: active.before,
            channel: active.channel,
            sample: sample,
            sampledCurve: active.sampledCurve,
            isHDR: active.isHDR,
            parametricEvaluator: active.parametricEvaluator
        ) else {
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

    @discardableResult
    public mutating func cancel() -> ToneCurveSettings? {
        let before = pending?.drag == nil ? nil : pending?.before
        pending = nil; selection = nil
        return before
    }
}
