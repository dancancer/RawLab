import Foundation

@main struct LensSettingsTests {
    static func main() throws {
        var settings = Adjustments()
        precondition(settings.lensCorrection == nil && !settings.lensSettings.isEnabled)
        settings.lensCorrection = LensCorrectionSettings(distortion: true, tca: true, autoCrop: false,
            mode: .manual, profileID: "RawLab\nTest 24mm f/2.8\nRawLab Test\n1.000000")
        let encoded = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(Adjustments.self, from: encoded)
        precondition(restored == settings && !settings.isDefault(.lens))
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "lensCorrection")
        let old = try JSONDecoder().decode(Adjustments.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(old.lensCorrection == nil && old.lensSettings.autoCrop)
        settings.reset(.lens)
        precondition(settings.lensCorrection == nil && settings.isDefault(.lens))
        settings.lensCorrection = restored.lensCorrection
        settings.resetAll()
        precondition(settings.lensCorrection == nil)
        let automatic = LensCorrectionSettings(distortion: true, tca: true)
        precondition(automatic.coreProfileID.isEmpty)
        var manual = automatic; manual.mode = .manual
        precondition(!manual.coreProfileID.isEmpty)
        manual.profileID = "selected"; precondition(manual.coreProfileID == "selected")
        print("Lens settings, legacy JSON, reset and automatic/manual selection passed")
    }
}
