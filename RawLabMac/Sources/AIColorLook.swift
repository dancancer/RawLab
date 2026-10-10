import Foundation

final class AITemporaryDirectory {
    let url: URL
    init(parent: URL = FileManager.default.temporaryDirectory) throws {
        url = parent.appendingPathComponent(".rawlab-ai-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

struct AIColorLook {
    struct Report: Codable {
        let gridSize: UInt32
        let maxError: Float
        let meanError: Float
        let p99Error: Float
    }
    private struct Metadata: Codable {
        var version = 1
        let recipe: AIColorRecipe
        let regions: AIToneRegions
        let model: String
        let report: Report
    }
    let directory: AITemporaryDirectory
    let url: URL
    let recipe: AIColorRecipe
    let regions: AIToneRegions
    let model: String
    let report: Report

    static func fileName(_ name: String) -> String {
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:\\?*\"<>|"))
        let clean = String(name.unicodeScalars.filter { !invalid.contains($0) }).trimmingCharacters(in: .whitespacesAndNewlines)
        return "AI-" + (clean.isEmpty ? "Color-Look" : String(clean.prefix(60))) + ".cube"
    }

    static func compile(recipe: AIColorRecipe, model: String, regions: AIToneRegions = .standard) throws -> Self {
        let recipe = try recipe.validated()
        let regions = try regions.validated()
        let directory = try AITemporaryDirectory()
        let url = directory.url.appendingPathComponent(fileName(recipe.name))
        var native = sony2fuji_color_look_report()
        let version: UInt32 = regions == .standard ? 1 : 2
        let values = recipe.parameters + (version == 1 ? [] : regions.parameters)
        let status = values.withUnsafeBufferPointer { buffer in
            url.path.withCString { path in sony2fuji_compile_color_look(version, buffer.baseAddress, buffer.count, path, &native) }
        }
        guard status == SONY2FUJI_STATUS_OK else {
            if status == SONY2FUJI_STATUS_PROCESSING_ERROR && native.grid_size == 129 {
                let recovery = regions == .standard ? "请降低饱和度或色相偏移后重新生成。" : "请重置明暗分区或放宽过渡范围后重试。"
                throw AIError.message(String(format: "配方变化过于陡峭，129-grid 的采样误差 %.4f 超过 0.02，未生成可用外观。", native.max_error) + recovery)
            }
            if status == SONY2FUJI_STATUS_INVALID_ARGUMENT { throw AIError.message("原生引擎拒绝了无效的颜色配方。") }
            throw AIError.message("无法生成 CUBE，请检查可用内存和磁盘空间。")
        }
        let report = Report(gridSize: native.grid_size, maxError: native.max_error, meanError: native.mean_error, p99Error: native.p99_error)
        let metadata = Metadata(recipe: recipe, regions: regions, model: model, report: report)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(metadata)
        guard data.count <= 65_536 else { throw AIError.message("外观元数据超过限制。") }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("#RawLabRecipe:".utf8) + data + Data("\n".utf8))
        return Self(directory: directory, url: url, recipe: recipe, regions: regions, model: model, report: report)
    }
}
