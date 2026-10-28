import Foundation

@main enum ColorGradingInteractionTests {
    static func main() {
        let session = GradingWheelSession()
        var value = ColorGradingWheel(hue: 231.25, saturation: 0)
        var before = value
        var begins = 0, ends = 0, cancels = 0
        var current = true
        func configure(fine: Bool = false, enabled: Bool = true, scope: String = "photo.shadows") {
            session.configure(GradingWheelConfiguration(value: value, scope: scope, fine: fine, enabled: enabled,
                isCurrent: { current }, begin: { before = value; begins += 1; return true },
                change: { value = $0 }, end: { ends += 1 }, cancel: { value = before; cancels += 1 }))
        }
        configure(); precondition(session.begin(x: 0, y: 0))
        session.move(x: 0.3, y: 0.4); configure()
        let during = value
        session.key(horizontal: 1, vertical: 0, fine: false)
        precondition(value == during && begins == 1 && ends == 0 && session.isActive,
            "Arrow input during a pointer gesture cannot commit or replace its transaction")
        session.move(x: 0.5, y: 0); session.end()
        precondition(begins == 1 && ends == 1 && value.saturation == 50)
        configure(); session.begin(x: 0.2, y: 0.1); session.cancel()
        precondition(value == before && cancels == 1 && !session.isActive)
        configure(); session.begin(x: 0.7, y: 0.2); configure(fine: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        precondition(cancels == 2 && value == before && !session.isActive)
        configure(); session.begin(x: 0.7, y: 0.2)
        current = false; let replacement = ColorGradingWheel(hue: 20, saturation: 30); value = replacement
        configure(scope: "other-photo.midtones"); session.move(x: 1, y: 1); session.end()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        precondition(value == replacement && cancels == 2, "Stale cancellation cannot restore old photo into new source")
        current = true; configure(); session.key(horizontal: 1, vertical: 1, fine: true)
        precondition(abs(value.hue - 20.1) < 1e-10 && abs(value.saturation - 30.1) < 1e-10 && ends == 2)
        configure(enabled: false); precondition(!session.begin(x: 1, y: 1))
        print("PASS: grading pointer/key transaction, cancel, fine, stale source and disabled session")
    }
}
