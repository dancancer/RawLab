import Foundation

@main struct ToneCurveModelTests {
    static func main() throws {
        func check(_ value: Bool, _ message: String) { precondition(value, message) }
        check(ToneCurveSettings().isDefault, "legacy default")
        var curve = ToneCurveSettings.identity
        check(!curve.isDefault && curve.isIdentity && curve.isValid, "custom identity keeps mode")
        curve = curve.inserting(x: 0.25, y: 0.12)
        curve = curve.inserting(x: 0.75, y: 0.88)
        check(curve.points.count == 4 && curve.points[1] == ToneCurvePoint(x: 0.25, y: 0.12), "point insertion")
        let moved = curve.moving(index: 1, x: 0.9, y: 1)
        check(moved.isValid && moved.points[1].x < moved.points[2].x && moved.points[1].y == moved.points[2].y, "drag cannot cross neighbors")
        check(curve.moving(index: 0, x: 0.1, y: 0.2) == curve, "fixed first endpoint")
        check(curve.removing(index: 3) == curve, "fixed final endpoint")
        check(curve.removing(index: 1).points.count == 3, "remove selected interior point")
        check(curve.inserting(x: 0.25, y: 0.5) == curve, "duplicate x rejected")
        check(curve.moving(index: 1, x: .nan, y: 0) == curve, "nonfinite move ignored")
        let bytes = try JSONEncoder().encode(curve)
        check(try JSONDecoder().decode(ToneCurveSettings.self, from: bytes) == curve, "mode and precise points roundtrip")
        for invalid in [
            #"{"mode":"custom","points":[[0,0],[1,0.9]]}"#,
            #"{"mode":"custom","points":[[0,0],[0.5,0.7],[0.6,0.5],[1,1]]}"#,
            #"{"mode":"custom","points":[[0,0],[0.5,0.2],[0.5,0.7],[1,1]]}"#,
            #"{"mode":"legacy","points":[[0,0],[1,1]]}"#,
            #"{"mode":"future","points":[]}"#,
            #"{"mode":"legacy","points":[],"future":0}"#,
            #"{"mode":"custom","points":[[0,0],[1,1,1]]}"#
        ] {
            do { _ = try JSONDecoder().decode(ToneCurveSettings.self, from: Data(invalid.utf8)); fatalError("invalid curve accepted") }
            catch { }
        }
        var full = ToneCurveSettings.identity
        for i in 1...31 { full = full.inserting(x: Double(i) / 32, y: Double(i) / 32) }
        check(full.points.count == 33 && full.inserting(x: 0.01, y: 0.01) == full, "33 point limit")
        let tiny = ToneCurveSettings(mode: .custom, points: [.init(x: 0, y: 0), .init(x: 2e-320, y: 4e-320), .init(x: 1, y: 1)])
        check(tiny.isValid, "binary64 close points kept")
        print("Tone curve model checks passed")
    }
}
