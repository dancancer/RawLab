import Foundation
import XCTest
@testable import RawLabKit

final class ToneCurveModelTests: XCTestCase {
    func testToneCurveEditingEncodingValidationAndScaling() throws {
        XCTAssertTrue(ToneCurveSettings().isDefault)
        var curve = ToneCurveSettings.identity
        XCTAssertFalse(curve.isDefault)
        XCTAssertTrue(curve.isIdentity)
        XCTAssertTrue(curve.isValid)

        curve = curve.inserting(x: 0.25, y: 0.12)
        curve = curve.inserting(x: 0.75, y: 0.88)
        XCTAssertEqual(curve.points.count, 4)
        XCTAssertEqual(curve.points[1], ToneCurvePoint(x: 0.25, y: 0.12))

        let moved = curve.moving(index: 1, x: 0.9, y: 1)
        XCTAssertTrue(moved.isValid)
        XCTAssertLessThan(moved.points[1].x, moved.points[2].x)
        XCTAssertEqual(moved.points[1].y, moved.points[2].y)

        XCTAssertTrue(curve.isEndpoint(0))
        XCTAssertTrue(curve.isEndpoint(3))
        XCTAssertFalse(curve.isInterior(0))
        XCTAssertTrue(curve.canMoveY(0))
        XCTAssertTrue(curve.canMoveY(3))

        let liftBlack = curve.moving(index: 0, x: 0.1, y: 0.08)
        XCTAssertEqual(liftBlack.points[0], ToneCurvePoint(x: 0.0, y: 0.08))
        XCTAssertEqual(curve.moving(index: 0, x: 0.1, y: 0.5).points[0], ToneCurvePoint(x: 0.0, y: curve.points[1].y))
        let dropWhite = curve.moving(index: 3, x: 0.9, y: 0.92)
        XCTAssertEqual(dropWhite.points[3], ToneCurvePoint(x: 1.0, y: 0.92))
        XCTAssertEqual(curve.moving(index: 3, x: 0.9, y: 0.2).points[3], ToneCurvePoint(x: 1.0, y: curve.points[2].y))
        XCTAssertEqual(curve.removing(index: 3), curve)
        XCTAssertEqual(curve.removing(index: 1).points.count, 3)
        XCTAssertEqual(curve.inserting(x: 0.25, y: 0.5), curve)
        XCTAssertEqual(curve.moving(index: 1, x: .nan, y: 0), curve)

        let bytes = try JSONEncoder().encode(curve)
        XCTAssertEqual(try JSONDecoder().decode(ToneCurveSettings.self, from: bytes), curve)

        for invalid in [
            #"{"mode":"custom","points":[[0.1,0],[1,1]]}"#,
            #"{"mode":"custom","points":[[0,0],[0.5,0.7],[0.6,0.5],[1,1]]}"#,
            #"{"mode":"custom","points":[[0,0],[0.5,0.2],[0.5,0.7],[1,1]]}"#,
            #"{"mode":"legacy","points":[[0,0],[1,1]]}"#,
            #"{"mode":"future","points":[]}"#,
            #"{"mode":"legacy","points":[],"future":0}"#,
            #"{"mode":"custom","points":[[0,0],[1,1,1]]}"#
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(ToneCurveSettings.self, from: Data(invalid.utf8)))
        }

        var full = ToneCurveSettings.identity
        for i in 1...31 {
            full = full.inserting(x: Double(i) / 32, y: Double(i) / 32)
        }
        XCTAssertEqual(full.points.count, 33)
        XCTAssertEqual(full.inserting(x: 0.01, y: 0.01), full)

        let tiny = ToneCurveSettings(mode: .custom, points: [.init(x: 0, y: 0), .init(x: 2e-320, y: 4e-320), .init(x: 1, y: 1)])
        XCTAssertTrue(tiny.isValid)

        let flat = ToneCurveSettings(mode: .custom, points: [.init(x: 0, y: 0), .init(x: 0.2, y: 0.8), .init(x: 0.4, y: 0.8), .init(x: 1, y: 1)])
        for original in [curve, flat, tiny, full] {
            for strength in [0.0, 0.1, 0.5, 1, 1.5, 2] {
                let scaled = original.scaled(by: strength)
                XCTAssertTrue(scaled.isValid)
                if strength == 0 { XCTAssertTrue(scaled.isIdentity) }
                if strength == 1 { XCTAssertEqual(scaled, original) }
            }
        }

        let doubled = flat.scaled(by: 2)
        XCTAssertEqual(doubled.points.map(\.x), flat.points.map(\.x))
        XCTAssertEqual(doubled.points.map(\.y), [0, 1, 1, 1])

        let unpinned = ToneCurveSettings(
            mode: .custom,
            points: [.init(x: 0, y: 0.125), .init(x: 0.5, y: 0.55), .init(x: 1, y: 0.875)],
            applyToLuminosity: true,
            parametric: ToneCurveParametric(highlights: -10, lights: 15, darks: -5, shadows: 20, splitShadow: 0.2, splitMidtone: 0.5, splitHighlight: 0.8)
        )
        XCTAssertTrue(unpinned.isValid)
        XCTAssertTrue(unpinned.hasV2Extensions)
        XCTAssertFalse(curve.hasV2Extensions)
        XCTAssertTrue(ToneCurveSettings(mode: .custom, points: [.init(x: 0, y: 0.2), .init(x: 1, y: 1)]).hasV2Extensions)
        XCTAssertTrue(ToneCurveSettings(channels: ToneCurveChannels(
            red: ToneCurveShape(mode: .custom, points: [.init(x: 0, y: 0), .init(x: 1, y: 0.9)])
        )).hasV2Extensions)
        let encodedUnpinned = try JSONEncoder().encode(unpinned)
        XCTAssertEqual(try JSONDecoder().decode(ToneCurveSettings.self, from: encodedUnpinned), unpinned)
        XCTAssertFalse(ToneCurveParametric(splitShadow: 0.4, splitMidtone: 0.41, splitHighlight: 0.75).isValid)

        let unpinnedZero = unpinned.scaled(by: 0)
        XCTAssertTrue(unpinnedZero.isIdentity)
        let unpinnedHalf = unpinned.scaled(by: 0.5)
        XCTAssertEqual(unpinnedHalf.points[0].y, 0.0625, accuracy: 1e-12)
        XCTAssertEqual(unpinnedHalf.points[2].y, 0.9375, accuracy: 1e-12)
        XCTAssertEqual(unpinnedHalf.parametric.shadows, 10, accuracy: 1e-12)
        let unpinnedDouble = unpinned.scaled(by: 2.0)
        XCTAssertEqual(unpinnedDouble.points[0].y, 0.25, accuracy: 1e-12)
        XCTAssertEqual(unpinnedDouble.points[2].y, 0.75, accuracy: 1e-12)
        XCTAssertEqual(unpinnedDouble.parametric.shadows, 40, accuracy: 1e-12)

        let scaledParam = try AdjustmentTransferRefinement.scaled(unpinned.parametric.transferValue, field: .curveParametric, by: 0.5)
        let invertedParam = try AdjustmentTransferRefinement.logical(scaledParam, field: .curveParametric, strength: 0.5, preserving: ToneCurveParametric().transferValue)
        XCTAssertTrue(AdjustmentTransferRefinement.equivalent(invertedParam, unpinned.parametric.transferValue, field: .curveParametric))
    }
}
