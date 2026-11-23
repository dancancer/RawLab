import RawLabKit
import Foundation

extension ToneCurveSettings {
    // 画布和渲染共用核心求值，四端不各自实现一份插值算法。
    func sampledPoints(channel: ToneCurveChannel = .rgb, includeParametric: Bool? = nil, count: Int = 257) -> [ToneCurvePoint] {
        guard isValid, count >= 2, count <= 4097 else { return [] }
        let useParametric = includeParametric ?? (channel == .rgb)
        let targetShape = shape(channel)
        let evalShape = targetShape.mode == .custom ? targetShape : ToneCurveShape.identity
        var config = evalShape.nativeConfig
        var param = parametric.nativeConfig
        let xs = (0..<count).map { Double($0) / Double(count - 1) }
        var ys = [Double](repeating: 0, count: count)
        let status = xs.withUnsafeBufferPointer { x in
            ys.withUnsafeMutableBufferPointer { y in
                if useParametric {
                    return withUnsafePointer(to: &param) { paramPtr in
                        sony2fuji_sample_tone_curve_v2(&config, paramPtr, x.baseAddress, y.baseAddress, UInt32(count))
                    }
                }
                return sony2fuji_sample_tone_curve_v2(&config, nil, x.baseAddress, y.baseAddress, UInt32(count))
            }
        }
        guard status == SONY2FUJI_STATUS_OK else { return [] }
        return zip(xs, ys).map { ToneCurvePoint(x: $0.0, y: $0.1) }
    }

    func sampledParametricValue(at x: Double) -> Double {
        guard isValid, x.isFinite else { return x }
        var config = ToneCurveShape.identity.nativeConfig
        var param = parametric.nativeConfig
        var input = x
        var output = x
        let status = withUnsafePointer(to: &param) { paramPtr in
            sony2fuji_sample_tone_curve_v2(&config, paramPtr, &input, &output, 1)
        }
        return status == SONY2FUJI_STATUS_OK ? output : x
    }

    func applyToSession(_ session: OpaquePointer) -> sony2fuji_status {
        var config = nativeSetV2Config
        return sony2fuji_session_set_tone_curves_v2(session, &config)
    }
}
