import Foundation

// 界面显示用的名称：汉字写的人名按当前语言显示（翻译目录以原名为键）
extension MasterRecipe {
    var title: String { L10n.text(name) }
}

struct MasterRecipe: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let subtitle: String
    let summary: String
    let lutFileName: String
    let exposureDelta: Double       // EV offset, e.g. +0.40 EV
    let shadowsDelta: Double        // Shadows offset, e.g. +20.0
    let highlightsDelta: Double     // Highlights offset, e.g. -15.0
    let contrastDelta: Double       // Contrast offset, e.g. -15.0
    let saturationDelta: Double     // Saturation offset, e.g. -8.0
    let tintDelta: Double           // Tint offset, e.g. +5.0
    let hsl: HSLSettings
    let settingsVersion: Int?
    let tone: ToneControlsSettings?
    let atmosphere: AtmosphereSettings?
    let grading: ColorGradingSettings?
    let curve: ToneCurveSettings?
    // 仅供无版本旧记录的一次性迁移；新配方校准不能改写历史基值。
    let legacyDefaults: LegacyDefaults?

    struct LegacyDefaults: Hashable, Codable {
        let exposureDelta: Double
        let shadowsDelta: Double
        let highlightsDelta: Double
        let contrastDelta: Double
        let saturationDelta: Double
        let tintDelta: Double
    }

    var migrationDefaults: LegacyDefaults {
        legacyDefaults ?? LegacyDefaults(exposureDelta: exposureDelta, shadowsDelta: shadowsDelta,
            highlightsDelta: highlightsDelta, contrastDelta: contrastDelta,
            saturationDelta: saturationDelta, tintDelta: tintDelta)
    }

    var version: Int { settingsVersion ?? 3 }
    var isValid: Bool {
        guard hsl.isValid, [3, 4].contains(version) else { return false }
        if version == 3 { return tone == nil && atmosphere == nil && grading == nil && curve == nil }
        return tone?.isValid == true && atmosphere?.isValid == true && grading?.isValid == true && curve?.isValid == true
    }

    static let allRecipes: [MasterRecipe] = {
        let candidates = [
            Bundle.main.url(forResource: "master-recipes", withExtension: "json"),
            URL(fileURLWithPath: "Shared/master-recipes.json"),
            URL(fileURLWithPath: "../Shared/master-recipes.json"),
            URL(fileURLWithPath: "../../Shared/master-recipes.json")
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

    static var hamadaDaylightV2: MasterRecipe { recipe(for: "hamada_daylight_v2")! }
    static var takashiYasuiZen: MasterRecipe { recipe(for: "takashi_yasui_zen")! }
    static var takahiroSakaiBlue: MasterRecipe { recipe(for: "takahiro_sakai_blue")! }
    static var withlukeEpic: MasterRecipe { recipe(for: "withluke_epic")! }
    static var danielCassonAutumn: MasterRecipe { recipe(for: "daniel_casson_autumn")! }
    static var billyDinhCinema: MasterRecipe { recipe(for: "billy_dinh_cinema")! }
    static var rkrkrkCyberpunk: MasterRecipe { recipe(for: "rkrkrk_cyberpunk")! }
    static var samaliveVintage: MasterRecipe { recipe(for: "samalive_vintage")! }
    static var iwonaFairyTale: MasterRecipe { recipe(for: "iwona_fairy_tale")! }
    static var cinestill800t: MasterRecipe { recipe(for: "cinestill_800t")! }
    static var wilsonLeeGolden: MasterRecipe { recipe(for: "wilson_lee_golden")! }
    static var luizclasPortrait: MasterRecipe { recipe(for: "luizclas_portrait")! }
    static var ivanIvanchenkoTwilight: MasterRecipe { recipe(for: "ivan_ivanchenko_twilight")! }
    static var jungraphyNeon: MasterRecipe { recipe(for: "jungraphy_neon")! }

    static func recipe(for id: String?) -> MasterRecipe? {
        guard let id, !id.isEmpty else { return nil }
        return allRecipes.first { $0.id == id }
    }

    func artworkURL() -> URL? {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("MasterRecipeIcons").appendingPathComponent("\(id).png")
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        for directory in ["RawLabMac", "../RawLabMac", "../../RawLabMac"] {
            let local = URL(fileURLWithPath: "\(directory)/Resources/MasterRecipeIcons/\(id).png")
            if FileManager.default.fileExists(atPath: local.path) { return local }
        }
        return nil
    }

    func lutURL() -> URL? {
        // 1. Bundle MasterRecipes directory
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
        // 2. Local development fallback paths
        let searchCandidates = [
            "RawLabMac/Resources/MasterRecipes/\(lutFileName)",
            "experiments/hamada-neural/runs/run_b2_full/\(lutFileName)",
            "../RawLabMac/Resources/MasterRecipes/\(lutFileName)",
            "../../RawLabMac/Resources/MasterRecipes/\(lutFileName)"
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
