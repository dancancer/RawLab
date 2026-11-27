import Foundation
import XCTest
@testable import RawLabKit

final class MacLensLocalizationTests: XCTestCase {
    private var tempRoot: URL!
    private var macosBundleURL: URL!
    private var previousPreference: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousPreference = UserDefaults.standard.object(forKey: L10n.preferenceKey)

        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent("RawLabLensLocalizationTests-\(UUID().uuidString)")
        macosBundleURL = tempRoot.appendingPathComponent("macos.bundle")
        let repoRoot = RawLabKitTestSupport.repoRoot
        let resourceRoot = repoRoot.appendingPathComponent("RawLabMac/Resources")
        try fm.createDirectory(
            at: macosBundleURL.appendingPathComponent("Contents/Resources"),
            withIntermediateDirectories: true
        )
        try fm.copyItem(
            at: repoRoot.appendingPathComponent("RawLabMac/Info.plist"),
            to: macosBundleURL.appendingPathComponent("Contents/Info.plist")
        )
        for language in ["en", "zh-Hans", "de", "fr", "ja", "es"] {
            let targetDir = macosBundleURL.appendingPathComponent("Contents/Resources/\(language).lproj")
            try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
            try fm.copyItem(
                at: resourceRoot.appendingPathComponent("\(language).lproj/Localizable.strings"),
                to: targetDir.appendingPathComponent("Localizable.strings")
            )
        }
    }

    override func tearDownWithError() throws {
        if let previousPreference {
            UserDefaults.standard.set(previousPreference, forKey: L10n.preferenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: L10n.preferenceKey)
        }
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    private func info(_ status: LensMatchState, _ distortion: Bool = false, _ tca: Bool = false) -> LensInfo {
        LensInfo(
            state: status,
            detectedLens: "Original lens name",
            selectedLens: "Original profile name",
            focalLength: 35,
            appliedDistortion: distortion,
            appliedTCA: tca,
            cropScale: 1.2,
            candidates: []
        )
    }

    func testSixLanguageLensStatusMessages() throws {
        let bundle = try XCTUnwrap(Bundle(url: macosBundleURL))
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
            (.unsupportedInput, "此输入不支持镜头校正"),
        ]
        var count = 0
        for language in AppLanguage.allCases where language != .system {
            XCTAssertNotNil(
                bundle.path(forResource: language.rawValue, ofType: "lproj"),
                "\(language.rawValue): resource bundle must contain lproj"
            )
            UserDefaults.standard.set(language.rawValue, forKey: L10n.preferenceKey)
            if language != .zhHans {
                XCTAssertNotEqual(
                    L10n.text("镜头校正已关闭", bundle: bundle),
                    "镜头校正已关闭",
                    "\(language.rawValue): localization catalog must actually translate instead of falling back to key"
                )
            }
            for (status, key) in statuses {
                XCTAssertEqual(
                    info(status).message(bundle: bundle),
                    L10n.text(key, bundle: bundle),
                    "\(language.rawValue): typed status \(key)"
                )
                count += 1
            }
        }
        XCTAssertEqual(count, 60)
    }

    func testSixLanguageAppliedFeatureFormatting() throws {
        let bundle = try XCTUnwrap(Bundle(url: macosBundleURL))
        var count = 0
        for language in AppLanguage.allCases where language != .system {
            UserDefaults.standard.set(language.rawValue, forKey: L10n.preferenceKey)
            for (distortion, tca) in [(true, false), (false, true), (true, true)] {
                let features = [
                    distortion ? L10n.text("畸变", bundle: bundle) : nil,
                    tca ? L10n.text("横向色差", bundle: bundle) : nil,
                ].compactMap { $0 }.joined(separator: " / ")
                XCTAssertEqual(
                    info(.matched, distortion, tca).message(bundle: bundle),
                    L10n.format("已校正%@", bundle: bundle, features),
                    "\(language.rawValue): applied feature names are translated before formatting"
                )
                count += 1
            }
        }
        XCTAssertEqual(count, 18)
    }

    func testSixLanguagePersistenceAndStableIdentity() throws {
        let directory = tempRoot.appendingPathComponent("persistence")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent("fixture.ARW")
        try Data("fixture".utf8).write(to: input)
        var settings = Adjustments()
        settings.applyMasterRecipe(.hamadaDaylightV2)
        settings.exposure = 1.25
        settings.setHSL(.hue, channel: 2, value: 27)
        settings.waveletNoiseReduction = WaveletDenoiseSettings(enabled: true, luma: 35, chroma: 22, coarse: 51)
        settings.lensCorrection = LensCorrectionSettings(
            distortion: true, tca: true, autoCrop: false,
            mode: .manual, profileID: "stable-profile-id"
        )
        let state = MacPhotoEditState(settings: settings, filmID: "stable-film-id", masterRecipeID: settings.masterRecipeID)
        let persistence = try MacEditPersistence(directory: directory.appendingPathComponent("edits"))
        try persistence.save(input, state: state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let frozen = try encoder.encode(state)

        var count = 0
        for language in AppLanguage.allCases where language != .system {
            UserDefaults.standard.set(language.rawValue, forKey: L10n.preferenceKey)
            let reopened = try MacEditPersistence(directory: directory.appendingPathComponent("edits")).state(for: input)
            XCTAssertEqual(reopened, state, "\(language.rawValue): complete saved settings survive reopening")
            XCTAssertEqual(try encoder.encode(state), frozen, "\(language.rawValue): locale lookup does not change snapshot")
            XCTAssertEqual(settings.lensSettings.coreProfileID, "stable-profile-id", "stable native profile identity")
            XCTAssertEqual(info(.matched).detectedLens, "Original lens name", "native lens name unchanged")
            count += 4
        }
        XCTAssertEqual(count, 24)
    }
}
