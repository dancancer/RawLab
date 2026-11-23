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
        selected = 0
        _ = session.begin(x: 0, y: 0, toleranceX: 0.05, toleranceY: 0.05)
        session.move(x: 0.2, y: 0.3)
        session.end()
        XCTAssertEqual(value.points[0], ToneCurvePoint(x: 0, y: 0.3))
        configure()
        session.key(horizontal: 1, vertical: 1, fine: true)
        XCTAssertEqual(value.points[0].x, 0, accuracy: 1e-12)
        XCTAssertEqual(value.points[0].y, 0.301, accuracy: 1e-12)
        value = .identity
        selected = 0

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

    func testCurveTargetInteractionNearGrayLegacySwitchDragCancelAndStaleRevision() {
        let rev = HSLTargetRevision(source: 3, request: 9)
        var target = CurveTargetInteraction()
        let graySample = HSLTargetSample(revision: rev, availability: .nearGray, rgb: [0.4, 0.4, 0.4], weights: [Double](repeating: 0, count: 8), preview: false)
        let samples = (0...100).map { ToneCurvePoint(x: Double($0) / 100.0, y: Double($0) / 100.0) }

        let token = target.begin(before: ToneCurveSettings(), channel: .rgb, revision: rev, sampledCurve: samples)
        XCTAssertTrue(target.isWaiting)
        guard let started = target.accept(graySample, token: token, currentRevision: rev) else {
            return XCTFail("Near-gray sample should start curve target interaction")
        }
        XCTAssertEqual(started.mode, .custom)
        XCTAssertEqual(started.points.count, 3)
        XCTAssertEqual(started.points[1].x, 0.4, accuracy: 1e-12)
        XCTAssertEqual(started.points[1].y, 0.4, accuracy: 1e-12)

        guard let moved = target.move(delta: 50) else {
            return XCTFail("Move should return updated curve")
        }
        XCTAssertEqual(moved.points[1].y, 0.65, accuracy: 1e-12)
        let cancelled = target.cancel()
        XCTAssertEqual(cancelled, ToneCurveSettings())
        XCTAssertFalse(target.isDragging)

        let staleToken = target.begin(before: .identity, channel: .red, revision: rev, sampledCurve: samples)
        XCTAssertNil(target.accept(graySample, token: staleToken, currentRevision: HSLTargetRevision(source: 3, request: 10)))
    }
}
