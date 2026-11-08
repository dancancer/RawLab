import Foundation

@main enum AgentRecipeSDRFallbackTests {
    static func main() throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let engine = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("agent-sdr-fallback.jpg")
        do {
            _ = try engine.agentRecipe(source, settings: Adjustments(), lut: nil, output: output)
            throw NSError(domain: "gain-map sources must never produce raster Agent recipes", code: 1)
        } catch let error as HDRNativeError {
            guard error.reason == UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_SYSTEM) else { throw error }
        } catch let error as RenderError {
            guard HDRSourceInfo.systemSupportsHDR && error.localizedDescription ==
                    L10n.text("HDR 原片的 Agent 配方需要启用 HDR 编辑。") else {
                throw NSError(domain: "macOS 14 must retain the unsupported-system HDR diagnostic", code: 1)
            }
        }
        print("PASS: SDR-mode gain-map sources cannot produce raster Agent recipes")
    }
}
