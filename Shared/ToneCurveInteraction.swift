import Foundation

struct ToneCurveInputConfiguration {
    let read: () -> ToneCurveSettings
    let selected: Int
    let scope: String
    let fine: Bool
    let enabled: Bool
    let isCurrent: () -> Bool
    let prepare: () -> Bool
    let begin: () -> Bool
    let select: (Int) -> Void
    let change: (ToneCurveSettings) -> Void
    let end: () -> Void
    let cancel: () -> Void
}

final class ToneCurveInputSession {
    var configuration: ToneCurveInputConfiguration?
    private struct Drag {
        let config: ToneCurveInputConfiguration
        let initial: ToneCurveSettings
        let index: Int
        let x: Double, y: Double, scale: Double
    }
    private var active: Drag?
    var isActive: Bool { active != nil }
    func configure(_ next: ToneCurveInputConfiguration) {
        if let old = configuration, old.scope != next.scope || old.fine != next.fine || !next.enabled {
            cancel(deferred: true)
        }
        configuration = next
    }
    @discardableResult func begin(x: Double, y: Double, toleranceX: Double, toleranceY: Double, fine: Bool = false) -> Bool {
        guard active == nil, let config = configuration, config.enabled, config.isCurrent(),
              x.isFinite, y.isFinite, toleranceX > 0, toleranceY > 0,
              config.prepare() else { return false }
        let original = config.read()
        guard original.mode == .custom else { return false }
        let nearest = original.points.enumerated().min { a, b in
            distance(a.element, x, y, toleranceX, toleranceY) < distance(b.element, x, y, toleranceX, toleranceY)
        }
        var initial = original
        let index: Int
        if let nearest, distance(nearest.element, x, y, toleranceX, toleranceY) <= 1 {
            index = nearest.offset
        } else {
            initial = initial.inserting(x: x, y: y)
            guard initial != original, let inserted = initial.points.firstIndex(where: { $0.x == x }) else { return false }
            index = inserted
        }
        guard config.begin() else { config.cancel(); return false }
        config.select(index)
        active = Drag(config: config, initial: initial, index: index, x: x, y: y, scale: fine || config.fine ? 0.25 : 1)
        if initial != original { config.change(initial) }
        return true
    }
    private func distance(_ point: ToneCurvePoint, _ x: Double, _ y: Double, _ tx: Double, _ ty: Double) -> Double {
        let dx = (point.x - x) / tx, dy = (point.y - y) / ty
        return dx * dx + dy * dy
    }
    func move(x: Double, y: Double) {
        guard let drag = active else { return }
        guard drag.config.isCurrent() else { cancel(); return }
        let start = drag.initial.points[drag.index]
        drag.config.change(drag.initial.moving(index: drag.index,
            x: start.x + (x - drag.x) * drag.scale, y: start.y + (y - drag.y) * drag.scale))
    }
    func end() {
        guard let drag = active else { return }; active = nil
        if drag.config.isCurrent() { drag.config.end() }
    }
    func cancel(deferred: Bool = false) {
        guard let drag = active else { return }; active = nil
        if deferred { DispatchQueue.main.async { if drag.config.isCurrent() { drag.config.cancel() } } }
        else if drag.config.isCurrent() { drag.config.cancel() }
    }
    func key(horizontal: Double = 0, vertical: Double = 0, fine: Bool = false, remove: Bool = false) {
        guard active == nil, let config = configuration, config.enabled, config.isCurrent(),
              config.prepare() else { return }
        let original = config.read()
        guard original.isInterior(config.selected) else { return }
        let point = original.points[config.selected], step = fine || config.fine ? 0.001 : 0.01
        let next = remove ? original.removing(index: config.selected) : original.moving(index: config.selected,
            x: point.x + horizontal * step, y: point.y + vertical * step)
        guard next != original, config.begin() else { return }
        config.change(next)
        if remove { config.select(min(config.selected, next.points.count - 1)) }
        config.end()
    }
}
