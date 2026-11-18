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

        XCTAssertEqual(curve.moving(index: 0, x: 0.1, y: 0.2), curve)
        XCTAssertEqual(curve.removing(index: 3), curve)
        XCTAssertEqual(curve.removing(index: 1).points.count, 3)
        XCTAssertEqual(curve.inserting(x: 0.25, y: 0.5), curve)
        XCTAssertEqual(curve.moving(index: 1, x: .nan, y: 0), curve)

        let bytes = try JSONEncoder().encode(curve)
        XCTAssertEqual(try JSONDecoder().decode(ToneCurveSettings.self, from: bytes), curve)

        for invalid in [
            #"{"mode":"custom","points":[[0,0],[1,0.9]]}"#,
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
    }
}
