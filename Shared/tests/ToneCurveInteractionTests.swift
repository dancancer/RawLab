import Foundation

@main struct ToneCurveInteractionTests {
    static func main() {
        let session = ToneCurveInputSession()
        var value = ToneCurveSettings.identity, before = value, selected = 0, begins = 0, ends = 0, cancels = 0
        var current = true
        func configure() {
            session.configure(.init(read: { value }, selected: selected, scope: "photo", fine: false, enabled: true,
                isCurrent: { current }, prepare: { true }, begin: { before = value; begins += 1; return true },
                select: { selected = $0 }, change: { value = $0 }, end: { ends += 1 }, cancel: { value = before; cancels += 1 }))
        }
        configure()
        precondition(session.begin(x: 0.4, y: 0.3, toleranceX: 0.05, toleranceY: 0.05))
        session.move(x: 0.5, y: 0.4); session.end()
        precondition(value.points.count == 3 && abs(value.points[1].x - 0.5) < 1e-12 && begins == 1 && ends == 1)
        configure(); let saved = value
        precondition(session.begin(x: 0.5, y: 0.4, toleranceX: 0.05, toleranceY: 0.05, fine: true))
        session.move(x: 0.9, y: 0.8)
        precondition(abs(value.points[1].x - 0.6) < 1e-12)
        session.cancel(); precondition(value == saved && cancels == 1)
        configure(); session.key(vertical: 1, fine: true)
        precondition(abs(value.points[1].y - 0.401) < 1e-12)
        configure(); session.key(remove: true); precondition(value == .identity)
        configure(); _ = session.begin(x: 0, y: 0, toleranceX: 0.05, toleranceY: 0.05)
        session.move(x: 0.2, y: 0.3); session.end(); precondition(value == .identity)
        configure(); current = false; precondition(!session.begin(x: 0.5, y: 0.5, toleranceX: 0.05, toleranceY: 0.05))
        current = true
        let pending = ToneCurveSettings.identity.inserting(x: 0.25, y: 0.2)
        session.configure(.init(read: { value }, selected: 0, scope: "photo", fine: false, enabled: true,
            isCurrent: { true }, prepare: { value = pending; return true }, begin: { true }, select: { selected = $0 },
            change: { value = $0 }, end: {}, cancel: {}))
        precondition(session.begin(x: 0.75, y: 0.8, toleranceX: 0.05, toleranceY: 0.05)); session.end()
        precondition(value.points.count == 4 && value.points[1] == pending.points[1], "pending coordinate commits before drag captures its initial curve")
        print("PASS: curve insert, drag, fixed endpoints, fine movement, keyboard, cancel and stale scope")
    }
}
