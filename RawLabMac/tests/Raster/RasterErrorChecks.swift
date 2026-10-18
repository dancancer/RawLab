import Foundation

func assertMacFailureSemantics(_ context: RasterContext, raster: URL, engine: RenderEngine) throws {
    func message(input: URL, settings: Adjustments = Adjustments(), output: URL? = nil,
                 renderer: RenderEngine? = nil) throws -> String {
        do {
            _ = try (renderer ?? engine).render(input, settings: settings, lut: nil,
                                                edge: nil, output: output)
        } catch { return error.localizedDescription }
        throw fail("expected rendering to fail: \(input.lastPathComponent), output=\(output?.lastPathComponent ?? "buffer")")
    }

    let corrupt = context.root.appendingPathComponent("error-corrupt.png")
    let corruptData = try Data(contentsOf: raster).prefix(33)
    try corruptData.write(to: corrupt)
    let decode = try message(input: corrupt)
    try check(decode.hasPrefix("无法解码普通图片："),
              "corrupt raster reports decoding failure rather than an unsupported format: \(decode)")
    try check(RenderError.displayImage(SONY2FUJI_STATUS_IO_ERROR).localizedDescription == "无法读取照片，请检查文件和访问权限。",
              "decoder I/O errors name file access rather than format support")
    try check(RenderError.displayImage(SONY2FUJI_STATUS_OUT_OF_MEMORY).localizedDescription == "内存不足，无法解码普通图片。",
              "decoder allocation errors identify insufficient memory")

    let force = try RenderEngine(gpuMode: SONY2FUJI_GPU_FORCE)
    let unsupported = try message(input: raster, renderer: force)
    try check(unsupported == "不支持此照片、外观或处理方式。请检查文件兼容性和处理设置。",
              "unsupported processing does not incorrectly restrict input to RAW: \(unsupported)")

    var invalid = Adjustments()
    invalid.exposure = .nan
    let invalidMessage = try message(input: raster, settings: invalid)
    try check(invalidMessage == "参数或输出路径无效。",
              "invalid parameters do not claim an attempted source overwrite: \(invalidMessage)")

    for suffix in ["jpg", "png"] {
        let missing = context.root.appendingPathComponent("missing-source.ARW")
        let output = context.root.appendingPathComponent("missing-source-export.\(suffix)")
        let inputFailure = try message(input: missing, output: output)
        try check(inputFailure == "无法读取或写入文件，请检查路径和访问权限。",
                  "a missing RAW input is not misreported as an output storage error for \(suffix)")
    }

    let rawCopy = context.root.appendingPathComponent("protected-original.\(context.raw.pathExtension)")
    try FileManager.default.copyItem(at: context.raw, to: rawCopy)
    for input in [raster, rawCopy] {
        let original = try Data(contentsOf: input)
        let alias = context.root.appendingPathComponent("protected-alias-\(input.lastPathComponent)")
        try FileManager.default.linkItem(at: input, to: alias)
        defer { try? FileManager.default.removeItem(at: alias) }
        for output in [input, alias] {
            let protection = try message(input: input, output: output)
            try check(protection == "不能覆盖原始文件。",
                      "RAW and raster source aliases get a dedicated protection error: \(protection)")
            try check(try Data(contentsOf: input) == original,
                      "rejected output keeps the source bytes unchanged")
        }
    }
}
