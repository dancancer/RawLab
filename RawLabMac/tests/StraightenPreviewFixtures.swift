import Foundation

enum StraightenPreviewFixtures {
    static func make(from raw: URL, engine: RenderEngine, in directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let source = try engine.render(raw, settings: Adjustments(), lut: nil, edge: 32) else {
            throw RenderError.failed("Missing fixture source")
        }
        let ratio = Double(source.nativeWidth ?? source.image.width) / Double(source.nativeHeight ?? source.image.height)
        /* 从同一 RAW 生成横竖夹具，避免方图漏掉视口裁剪，也不依赖系统的扩展名类型注册。 */
        return try [("landscape", 1.5), ("portrait", 2.0 / 3)].map { name, targetRatio in
            var geometry = GeometrySettings()
            geometry.cropWidth = min(1, targetRatio / ratio)
            geometry.cropHeight = min(1, ratio / targetRatio)
            geometry.cropX = (1 - geometry.cropWidth) / 2
            geometry.cropY = (1 - geometry.cropHeight) / 2
            var settings = Adjustments()
            settings.geometry = geometry
            let url = directory.appendingPathComponent("fixture-\(name).dng")
            _ = try engine.render(raw, settings: settings, lut: nil, edge: nil, output: url, exportLongEdge: 900)
            return url
        }
    }
}
