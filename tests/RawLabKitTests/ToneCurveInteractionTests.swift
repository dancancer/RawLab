import Foundation
import XCTest
@testable import RawLabKit

final class ToneCurveInteractionTests: XCTestCase {
    func testToneCurveInputSessionDragFineKeyCancelAndStaleScope() {
        let session = ToneCurveInputSession()
        var value = ToneCurveSettings.identity
        var before = value
        var selected = 0
        var begins = 0
        var ends = 0
        var cancels = 0
        var current = true

        func configure() {
            session.configure(.init(
                read: { value },
                selected: selected,
                scope: "photo",
                fine: false,
                enabled: true,
                isCurrent: { current },
                prepare: { true },
                begin: { before = value; begins += 1; return true },
                select: { selected = $0 },
                change: { value = $0 },
                end: { ends += 1 },
                cancel: { value = before; cancels += 1 }
            ))
        }

        configure()
        XCTAssertTrue(session.begin(x: 0.4, y: 0.3, toleranceX: 0.05, toleranceY: 0.05))
        session.move(x: 0.5, y: 0.4)
        session.end()
        XCTAssertEqual(value.points.count, 3)
        XCTAssertEqual(value.points[1].x, 0.5, accuracy: 1e-12)
        XCTAssertEqual(begins, 1)
        XCTAssertEqual(ends, 1)

        configure()
        let saved = value
        XCTAssertTrue(session.begin(x: 0.5, y: 0.4, toleranceX: 0.05, toleranceY: 0.05, fine: true))
        session.move(x: 0.9, y: 0.8)
        XCTAssertEqual(value.points[1].x, 0.6, accuracy: 1e-12)
        session.cancel()
        XCTAssertEqual(value, saved)
        XCTAssertEqual(cancels, 1)

        configure()
        session.key(vertical: 1, fine: true)
        XCTAssertEqual(value.points[1].y, 0.401, accuracy: 1e-12)

        configure()
        session.key(remove: true)
        XCTAssertEqual(value, .identity)

        configure()
        _ = session.begin(x: 0, y: 0, toleranceX: 0.05, toleranceY: 0.05)
        session.move(x: 0.2, y: 0.3)
        session.end()
        XCTAssertEqual(value, .identity)

        configure()
        current = false
        XCTAssertFalse(session.begin(x: 0.5, y: 0.5, toleranceX: 0.05, toleranceY: 0.05))

        current = true
        let pending = ToneCurveSettings.identity.inserting(x: 0.25, y: 0.2)
        session.configure(.init(
            read: { value },
            selected: 0,
            scope: "photo",
            fine: false,
            enabled: true,
            isCurrent: { true },
            prepare: { value = pending; return true },
            begin: { true },
            select: { selected = $0 },
            change: { value = $0 },
            end: {},
            cancel: {}
        ))
        XCTAssertTrue(session.begin(x: 0.75, y: 0.8, toleranceX: 0.05, toleranceY: 0.05))
        session.end()
        XCTAssertEqual(value.points.count, 4)
        XCTAssertEqual(value.points[1], pending.points[1])
    }
}
