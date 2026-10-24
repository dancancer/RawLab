import Foundation

extension ToneCurveSettings {
    // 画布和渲染共用核心求值，四端不各自实现一份插值算法。
    func sampledPoints(count: Int = 257) -> [ToneCurvePoint] {
        guard isValid, mode == .custom, count >= 2, count <= 4097 else { return [] }
        var config = nativeConfig
        let xs = (0..<count).map { Double($0) / Double(count - 1) }
        var ys = [Double](repeating: 0, count: count)
        let status = xs.withUnsafeBufferPointer { x in
            ys.withUnsafeMutableBufferPointer { y in
                sony2fuji_sample_tone_curve(&config, x.baseAddress, y.baseAddress, UInt32(count))
            }
        }
        guard status == SONY2FUJI_STATUS_OK else { return [] }
        return zip(xs, ys).map { ToneCurvePoint(x: $0.0, y: $0.1) }
    }
}
