import RawLabKit
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
        let state = MacPhotoEditState(settings: settings, filmID: "stable-film-id", masterRecipeID: settings.masterRecipeID)
        let persistence = try MacEditPersistence(directory: directory.appendingPathComponent("edits"))
        try persistence.save(input, state: state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let frozen = try encoder.encode(state)
        let statuses: [(LensMatchState, String)] = [
            (.off, "镜头校正已关闭"),
            (.matched, "已匹配镜头"),
            (.noDatabase, "镜头数据库不可用"),
            (.noCamera, "未找到机身或传感器尺寸信息"),
            (.unmatched, "未匹配镜头，请手动选择"),
            (.ambiguous, "有多个匹配镜头，请手动选择"),
            (.noCalibration, "此镜头没有所选校正的标定数据"),
            (.missingFocalLength, "照片缺少有效焦距，未应用校正"),
            (.embeddedGeometry, "DNG 已执行内嵌 Stage3 处理，未叠加校正"),
            (.unsupportedInput, "此输入不支持镜头校正")
        ]
        func info(_ status: LensMatchState, _ distortion: Bool = false, _ tca: Bool = false) -> LensInfo {
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
                try check(info(.matched, distortion, tca).message == L10n.format("已校正%@", features),
                    "\(language.rawValue): applied feature names are translated before formatting")
            }
            let reopened = try MacEditPersistence(directory: directory.appendingPathComponent("edits")).state(for: input)
            try check(reopened == state, "\(language.rawValue): complete saved settings survive reopening")
            try check(try encoder.encode(state) == frozen, "\(language.rawValue): locale lookup does not change snapshot")
            try check(settings.lensSettings.coreProfileID == "stable-profile-id", "stable native profile identity")
            try check(info(.matched).detectedLens == "Original lens name", "native lens name unchanged")
        }
        guard count == 102 else { throw NSError(domain: "LensLocalizationTests", code: 2) }
        print("PASS: \(count) six-language Lens status and full persistence checks")
    }
}
