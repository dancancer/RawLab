import Foundation

@main enum HDRSettingsTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    static func main() throws {
        var settings = HDRSettings()
        require(settings.mode == .hdr && settings.isIdentity && settings.isValid, "HDR defaults differ")
        settings.exposure = 1.5; settings.temperature = 10000; settings.tint = 42
        settings.contrast = -75; settings.highlights = 100; settings.shadows = -100; settings.saturation = -100
        settings.geometry.quarterTurns = 1
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(settings)
        let restoredRecord = try JSONDecoder().decode(HDRSettings.self, from: data)
        require(restoredRecord == settings, "HDR settings did not round-trip")
        let text = String(decoding: data, as: UTF8.self)
        require(text.contains("record_version") && text.contains("hdr_processing_version"), "HDR version identity missing")
        require(!text.contains("headroom") && !text.contains("preview"), "runtime display state was persisted")
        var unknown = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        unknown["record_version"] = 2
        do {
            _ = try JSONDecoder().decode(HDRSettings.self, from: JSONSerialization.data(withJSONObject: unknown))
            fatalError("unknown HDR record was silently accepted")
        } catch is DecodingError {}
        var invalid = settings; invalid.exposure = .nan
        require(!invalid.isValid, "nonfinite HDR parameter accepted")
        invalid = settings; invalid.exposure = 5
        require(!invalid.isValid, "HDR exposure range was not checked")
        var initial = HDRSettings(); initial.exposure = 2; initial.contrast = -25
        initial.highlights = 50; initial.geometry.quarterTurns = 2
        let enabled = try HDRSettings.enabling(stored: nil, initial: initial, sourceIsHDR: true, conflicts: [])
        require(enabled.exposure == 2 && enabled.contrast == -25 && enabled.highlights == 50 &&
            enabled.geometry.quarterTurns == 2 && enabled.temperature == 6500 && enabled.tint == 0,
            "first HDR conversion did not copy common UI values")
        do {
            _ = try HDRSettings.enabling(stored: nil, initial: initial, sourceIsHDR: true, conflicts: ["white_balance", "look"])
            fatalError("conflicting conversion was partially accepted")
        } catch HDRSettings.ModeError.conflicts(let fields) { require(fields == ["white_balance", "look"], "conflict fields were lost") }
        do {
            _ = try HDRSettings.enabling(stored: nil, initial: initial, sourceIsHDR: false, conflicts: [])
            fatalError("SDR source was elevated into HDR")
        } catch HDRSettings.ModeError.unsupportedSource {}
        settings.mode = .sdr
        let restored = try HDRSettings.enabling(stored: settings, initial: initial, sourceIsHDR: true, conflicts: ["look"])
        require(restored.mode == .hdr && restored.exposure == settings.exposure && restored.tint == 42,
            "existing HDR snapshot was rebuilt from dormant SDR values")
        var reset = restored; reset.reset()
        require(reset.mode == .hdr && reset.isIdentity, "HDR reset changed edit mode")
        print("PASS HDR settings persistence, conversion, validation and reset")
    }
}
