import Foundation

public struct MasterRecipe: Identifiable, Hashable, Codable {
    public let id: String
    public let name: String
    public let subtitle: String
    public let summary: String
    public let lutFileName: String
    public let exposureDelta: Double       // EV offset, e.g. +0.40 EV
    public let shadowsDelta: Double        // Shadows offset, e.g. +20.0
    public let highlightsDelta: Double     // Highlights offset, e.g. -15.0
    public let contrastDelta: Double       // Contrast offset, e.g. -15.0
    public let saturationDelta: Double     // Saturation offset, e.g. -8.0
    public let tintDelta: Double           // Tint offset, e.g. +5.0
    public let hsl: HSLSettings
    public let settingsVersion: Int?
    public let tone: ToneControlsSettings?
    public let atmosphere: AtmosphereSettings?
    public let grading: ColorGradingSettings?
    public let curve: ToneCurveSettings?
    // 仅供无版本旧记录的一次性迁移；新配方校准不能改写历史基值。
    public let legacyDefaults: LegacyDefaults?

    public struct LegacyDefaults: Hashable, Codable, Sendable {
        public let exposureDelta: Double
        public let shadowsDelta: Double
        public let highlightsDelta: Double
        public let contrastDelta: Double
        public let saturationDelta: Double
        public let tintDelta: Double

        public init(exposureDelta: Double, shadowsDelta: Double, highlightsDelta: Double,
                    contrastDelta: Double, saturationDelta: Double, tintDelta: Double) {
            self.exposureDelta = exposureDelta
            self.shadowsDelta = shadowsDelta
            self.highlightsDelta = highlightsDelta
            self.contrastDelta = contrastDelta
            self.saturationDelta = saturationDelta
            self.tintDelta = tintDelta
        }
    }

    // 界面显示用的名称：汉字写的人名按当前语言显示（翻译目录以原名为键）
    public var title: String { L10n.text(name) }

    public var migrationDefaults: LegacyDefaults {
        legacyDefaults ?? LegacyDefaults(exposureDelta: exposureDelta, shadowsDelta: shadowsDelta,
            highlightsDelta: highlightsDelta, contrastDelta: contrastDelta,
            saturationDelta: saturationDelta, tintDelta: tintDelta)
    }

    public var version: Int { settingsVersion ?? 3 }
    public var isValid: Bool {
        guard hsl.isValid, [3, 4].contains(version) else { return false }
        if version == 3 { return tone == nil && atmosphere == nil && grading == nil && curve == nil }
        return tone?.isValid == true && atmosphere?.isValid == true && grading?.isValid == true && curve?.isValid == true
    }

    private static let packageSharedDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    private static let packageRepoRoot: URL = packageSharedDirectory.deletingLastPathComponent()

    public static let allRecipes: [MasterRecipe] = {
        let candidates = [
            Bundle.main.url(forResource: "master-recipes", withExtension: "json"),
            ProcessInfo.processInfo.environment["RAWLAB_MASTER_RECIPE_CATALOG"].map { URL(fileURLWithPath: $0) },
            URL(fileURLWithPath: "Shared/master-recipes.json"),
            URL(fileURLWithPath: "../Shared/master-recipes.json"),
            URL(fileURLWithPath: "../../Shared/master-recipes.json"),
            packageSharedDirectory.appendingPathComponent("master-recipes.json")
        ].compactMap { $0 }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: url),
              let recipes = try? JSONDecoder().decode([MasterRecipe].self, from: data),
              recipes.count == 14, Set(recipes.map(\.id)).count == recipes.count,
              recipes.allSatisfy({ $0.isValid }) else {
            preconditionFailure("Missing or invalid bundled master recipe catalog")
        }
        return recipes
    }()

    public static var hamadaDaylightV2: MasterRecipe { recipe(for: "hamada_daylight_v2")! }
    public static var takashiYasuiZen: MasterRecipe { recipe(for: "takashi_yasui_zen")! }
    public static var takahiroSakaiBlue: MasterRecipe { recipe(for: "takahiro_sakai_blue")! }
    public static var withlukeEpic: MasterRecipe { recipe(for: "withluke_epic")! }
    public static var danielCassonAutumn: MasterRecipe { recipe(for: "daniel_casson_autumn")! }
    public static var billyDinhCinema: MasterRecipe { recipe(for: "billy_dinh_cinema")! }
    public static var rkrkrkCyberpunk: MasterRecipe { recipe(for: "rkrkrk_cyberpunk")! }
    public static var samaliveVintage: MasterRecipe { recipe(for: "samalive_vintage")! }
    public static var iwonaFairyTale: MasterRecipe { recipe(for: "iwona_fairy_tale")! }
    public static var cinestill800t: MasterRecipe { recipe(for: "cinestill_800t")! }
    public static var wilsonLeeGolden: MasterRecipe { recipe(for: "wilson_lee_golden")! }
    public static var luizclasPortrait: MasterRecipe { recipe(for: "luizclas_portrait")! }
    public static var ivanIvanchenkoTwilight: MasterRecipe { recipe(for: "ivan_ivanchenko_twilight")! }
    public static var jungraphyNeon: MasterRecipe { recipe(for: "jungraphy_neon")! }

    public static func recipe(for id: String?) -> MasterRecipe? {
        guard let id, !id.isEmpty else { return nil }
        return allRecipes.first { $0.id == id }
    }

    public func artworkURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: id, withExtension: "png", subdirectory: "MasterRecipeIcons"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("MasterRecipeIcons").appendingPathComponent("\(id).png")
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        for directory in ["RawLabMac", "../RawLabMac", "../../RawLabMac",
                          Self.packageRepoRoot.appendingPathComponent("RawLabMac").path] {
            let local = URL(fileURLWithPath: "\(directory)/Resources/MasterRecipeIcons/\(id).png")
            if FileManager.default.fileExists(atPath: local.path) { return local }
        }
        return nil
    }

    public func lutURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: lutFileName, withExtension: nil, subdirectory: "MasterRecipes"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        if let resourceURL = Bundle.main.resourceURL {
            let bundleRecipe = resourceURL.appendingPathComponent("MasterRecipes").appendingPathComponent(lutFileName)
            if FileManager.default.fileExists(atPath: bundleRecipe.path) {
                return bundleRecipe
            }
            let bundleLUT = resourceURL.appendingPathComponent("LUTs").appendingPathComponent(lutFileName)
            if FileManager.default.fileExists(atPath: bundleLUT.path) {
                return bundleLUT
            }
        }
        let searchCandidates = [
            "RawLabMac/Resources/MasterRecipes/\(lutFileName)",
            "experiments/hamada-neural/runs/run_b2_full/\(lutFileName)",
            "../RawLabMac/Resources/MasterRecipes/\(lutFileName)",
            "../../RawLabMac/Resources/MasterRecipes/\(lutFileName)",
            Self.packageRepoRoot.appendingPathComponent("RawLabMac/Resources/MasterRecipes/\(lutFileName)").path
        ]
        for candidate in searchCandidates {
            let url = URL(fileURLWithPath: candidate)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}
