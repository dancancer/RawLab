import Foundation

@main
struct ChromaSettingsTests {
    static func check(_ value: Bool, _ name: String) {
        guard value else { fatalError(name) }
        print("PASS: \(name)")
    }
    static func main() throws {
        var settings = Adjustments()
        check(settings.denoiseMode == 0, "New denoising defaults off")
        check(ChromaNoiseReductionMode.allCases.map(\.title) == ["关闭", "细节优先", "去噪优先"], "Mode labels")
        settings.rawNoiseReduction = 2
        let encoded = try JSONEncoder().encode(settings)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "chromaNoiseReduction")
        let decoded = try JSONDecoder().decode(Adjustments.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(decoded.rawNoiseReduction == 2 && decoded.denoiseMode == 3 && decoded.chromaNoiseReduction == nil,
              "Old FBDD record retains its original meaning")
        settings = decoded
        settings.set(.denoiseMode, to: 1)
        check(settings.rawNoiseReduction == 0 && settings.chromaNoiseReduction == 1, "Selecting new mode clears legacy FBDD")
        settings.set(.denoiseMode, to: 2)
        let restored = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(settings))
        check(restored.denoiseMode == 2 && restored.rawNoiseReduction == 0, "New mode persists independently")
        settings.reset(.detail)
        check(settings.denoiseMode == 0 && settings.chromaNoiseReduction == nil && settings.rawNoiseReduction == 0,
              "Reset clears both legacy and new denoising")
        check(settings == Adjustments(), "Reset keeps default state canonical")
        settings.set(.denoiseMode, to: 1)
        settings.resolveRawNoiseReductionSupport(false)
        check(settings.denoiseMode == 1, "X-Trans FBDD capability does not disable chroma denoising")
    }
}
