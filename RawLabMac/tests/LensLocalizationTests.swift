import Foundation

@main struct LensLocalizationTests {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "LensLocalizationTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
            count += 1
        }
        let previous = UserDefaults.standard.object(forKey: L10n.preferenceKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: L10n.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: L10n.preferenceKey) }
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent("fixture.ARW")
        try Data("fixture".utf8).write(to: input)
        var settings = Adjustments()
        settings.applyMasterRecipe(.hamadaDaylightV2)
        settings.exposure = 1.25
        settings.setHSL(.hue, channel: 2, value: 27)
        settings.waveletNoiseReduction = WaveletDenoiseSettings(enabled: true, luma: 35, chroma: 22, coarse: 51)
        settings.lensCorrection = LensCorrectionSettings(distortion: true, tca: true, autoCrop: false,
            mode: .manual, profileID: "stable-profile-id")
        let state = PhotoEditState(settings: settings, filmID: "stable-film-id", masterRecipeID: settings.masterRecipeID)
        let persistence = try EditPersistence(directory: directory.appendingPathComponent("edits"))
        try persistence.save(input, state: state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let frozen = try encoder.encode(state)
        let statuses: [(sony2fuji_lens_state, String)] = [
            (SONY2FUJI_LENS_OFF, "镜头校正已关闭"),
            (SONY2FUJI_LENS_MATCHED, "已匹配镜头"),
            (SONY2FUJI_LENS_NO_DATABASE, "镜头数据库不可用"),
            (SONY2FUJI_LENS_NO_CAMERA, "未找到机身或传感器尺寸信息"),
            (SONY2FUJI_LENS_NO_LENS, "未匹配镜头，请手动选择"),
            (SONY2FUJI_LENS_AMBIGUOUS, "有多个匹配镜头，请手动选择"),
            (SONY2FUJI_LENS_NO_CALIBRATION, "此镜头没有所选校正的标定数据"),
            (SONY2FUJI_LENS_MISSING_FOCAL_LENGTH, "照片缺少有效焦距，未应用校正"),
            (SONY2FUJI_LENS_EMBEDDED_GEOMETRY, "DNG 已执行内嵌 Stage3 处理，未叠加校正"),
            (SONY2FUJI_LENS_UNSUPPORTED_INPUT, "此输入不支持镜头校正")
        ]
        func info(_ status: sony2fuji_lens_state, _ distortion: Bool = false, _ tca: Bool = false) -> LensInfo {
            LensInfo(state: status, detectedLens: "Original lens name", selectedLens: "Original profile name",
                focalLength: 35, appliedDistortion: distortion, appliedTCA: tca, cropScale: 1.2, candidates: [])
        }
        for language in AppLanguage.allCases where language != .system {
            UserDefaults.standard.set(language.rawValue, forKey: L10n.preferenceKey)
            for (status, key) in statuses {
                try check(info(status).message == L10n.text(key), "\(language.rawValue): typed status \(key)")
            }
            for (distortion, tca) in [(true, false), (false, true), (true, true)] {
                let features = [distortion ? L10n.text("畸变") : nil, tca ? L10n.text("横向色差") : nil]
                    .compactMap { $0 }.joined(separator: " / ")
                try check(info(SONY2FUJI_LENS_MATCHED, distortion, tca).message == L10n.format("已校正%@", features),
                    "\(language.rawValue): applied feature names are translated before formatting")
            }
            let reopened = try EditPersistence(directory: directory.appendingPathComponent("edits")).state(for: input)
            try check(reopened == state, "\(language.rawValue): complete saved settings survive reopening")
            try check(try encoder.encode(state) == frozen, "\(language.rawValue): locale lookup does not change snapshot")
            try check(settings.lensSettings.coreProfileID == "stable-profile-id", "stable native profile identity")
            try check(info(SONY2FUJI_LENS_MATCHED).detectedLens == "Original lens name", "native lens name unchanged")
        }
        guard count == 102 else { throw NSError(domain: "LensLocalizationTests", code: 2) }
        print("PASS: \(count) six-language Lens status and full persistence checks")
    }
}
