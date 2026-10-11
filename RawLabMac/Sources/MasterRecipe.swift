import Foundation

struct MasterRecipe: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let subtitle: String
    let summary: String
    let lutFileName: String
    let exposureDelta: Double       // EV offset
    let shadowsDelta: Double        // Shadows offset
    let highlightsDelta: Double     // Highlights offset
    let contrastDelta: Double       // Contrast offset
    let saturationDelta: Double     // Saturation offset
    let tintDelta: Double           // Tint offset

    // 0. 滨田英明 - 日系高调日光
    static let hamadaDaylightV2 = MasterRecipe(
        id: "hamada_daylight_v2",
        name: "滨田英明",
        subtitle: "日系青空 · 高调日光",
        summary: "高调通透日光，蓝天转日系天青色，柔和哑光暗部与奶油蜜桃肤色",
        lutFileName: "hamada_daylight_pro_v2.cube",
        exposureDelta: 0.40,
        shadowsDelta: 20.0,
        highlightsDelta: -15.0,
        contrastDelta: -15.0,
        saturationDelta: -8.0,
        tintDelta: 5.0
    )

    // 1. 保井崇志 - 极简禅意街拍
    static let takashiYasuiZen = MasterRecipe(
        id: "takashi_yasui_zen",
        name: "保井崇志",
        subtitle: "极简禅意 · 日系街拍",
        summary: "强明暗对比，深沉冷青暗部，大面积克制黑阶与点睛暖光",
        lutFileName: "takashi_yasui_zen.cube",
        exposureDelta: 0.00,
        shadowsDelta: -25.0,
        highlightsDelta: -35.0,
        contrastDelta: 30.0,
        saturationDelta: -15.0,
        tintDelta: 2.0
    )

    // 2. 酒井贵弘 - 空气清透淡蓝
    static let takahiroSakaiBlue = MasterRecipe(
        id: "takahiro_sakai_blue",
        name: "酒井贵弘",
        subtitle: "空气清透 · 少女淡蓝",
        summary: "日系通透水光肌，空气感透明青蓝，暗部大面积展开与柔润高光",
        lutFileName: "takahiro_sakai_blue.cube",
        exposureDelta: 0.35,
        shadowsDelta: 35.0,
        highlightsDelta: -25.0,
        contrastDelta: -15.0,
        saturationDelta: -10.0,
        tintDelta: 4.0
    )

    // 3. withluke - 史诗风光
    static let withlukeEpic = MasterRecipe(
        id: "withluke_epic",
        name: "withluke",
        subtitle: "史诗自然 · 雾气冷青",
        summary: "苍茫雪山与森林雾气，去除数码刺眼生绿，苔原冷绿与柔和暖金交织",
        lutFileName: "withluke_epic.cube",
        exposureDelta: 0.10,
        shadowsDelta: 25.0,
        highlightsDelta: -30.0,
        contrastDelta: 10.0,
        saturationDelta: -12.0,
        tintDelta: -2.0
    )

    // 4. Daniel Casson - 乡村秋日油画
    static let danielCassonAutumn = MasterRecipe(
        id: "daniel_casson_autumn",
        name: "Daniel Casson",
        subtitle: "乡村秋日 · 古典油画",
        summary: "英国乡村秋日油画风，厚重大地色，枯草金黄与深林墨绿交织",
        lutFileName: "daniel_casson_autumn.cube",
        exposureDelta: 0.15,
        shadowsDelta: 25.0,
        highlightsDelta: -25.0,
        contrastDelta: 15.0,
        saturationDelta: 5.0,
        tintDelta: -3.0
    )

    // 5. Billy Dinh - 纽约电影叙事
    static let billyDinhCinema = MasterRecipe(
        id: "billy_dinh_cinema",
        name: "Billy Dinh",
        subtitle: "纽约电影 · 戏剧光影",
        summary: "电影叙事宽画幅质感，强反差光影切割，深邃暗部与聚光灯金光",
        lutFileName: "billy_dinh_cinema.cube",
        exposureDelta: -0.20,
        shadowsDelta: -15.0,
        highlightsDelta: -30.0,
        contrastDelta: 25.0,
        saturationDelta: -10.0,
        tintDelta: 2.0
    )

    // 6. rkrkrk - 赛博朋克
    static let rkrkrkCyberpunk = MasterRecipe(
        id: "rkrkrk_cyberpunk",
        name: "rkrkrk",
        subtitle: "赛博朋克 · 极致反差",
        summary: "致密城市肌理，硬朗大S曲线，浓郁橙青与紫金冷暖对撞",
        lutFileName: "rkrkrk_cyberpunk.cube",
        exposureDelta: 0.00,
        shadowsDelta: 25.0,
        highlightsDelta: -40.0,
        contrastDelta: 25.0,
        saturationDelta: 15.0,
        tintDelta: 5.0
    )

    // 7. Samalive - 油润复古胶片
    static let samaliveVintage = MasterRecipe(
        id: "samalive_vintage",
        name: "Samalive",
        subtitle: "油润复古 · 城市胶片",
        summary: "温暖油润复古城市胶片，暗部沉稳不脏，温润暖金高光与漫游故事感",
        lutFileName: "samalive_vintage.cube",
        exposureDelta: 0.15,
        shadowsDelta: 20.0,
        highlightsDelta: -25.0,
        contrastDelta: -5.0,
        saturationDelta: 5.0,
        tintDelta: 4.0
    )

    // 8. Iwona - 童话油画微光
    static let iwonaFairyTale = MasterRecipe(
        id: "iwona_fairy_tale",
        name: "Iwona",
        subtitle: "童话油画 · 梦幻微光",
        summary: "童话绘本油画感，深邃沉静暗部，暖金柔光包裹与漫反射微光",
        lutFileName: "iwona_fairy_tale.cube",
        exposureDelta: 0.10,
        shadowsDelta: 15.0,
        highlightsDelta: -20.0,
        contrastDelta: -15.0,
        saturationDelta: -5.0,
        tintDelta: 3.0
    )

    // 9. CineStill 800T - 钨丝电影光晕
    static let cinestill800t = MasterRecipe(
        id: "cinestill_800t",
        name: "CineStill 800T",
        subtitle: "钨丝电影 · 红色光晕",
        summary: "经典电影夜景胶片，点光源高光泛红晕(Halation)，暗部深邃冷青绿",
        lutFileName: "cinestill_800t.cube",
        exposureDelta: 0.10,
        shadowsDelta: 20.0,
        highlightsDelta: -35.0,
        contrastDelta: 10.0,
        saturationDelta: 10.0,
        tintDelta: -5.0
    )

    // 10. Wilson Lee - 暖调日系金光
    static let wilsonLeeGolden = MasterRecipe(
        id: "wilson_lee_golden",
        name: "Wilson Lee",
        subtitle: "暖调日系 · 漫射金光",
        summary: "加州阳光与日系胶片融合，城市漫射金光，通透温润微光感",
        lutFileName: "wilson_lee_golden.cube",
        exposureDelta: 0.25,
        shadowsDelta: 20.0,
        highlightsDelta: -20.0,
        contrastDelta: -10.0,
        saturationDelta: 0.0,
        tintDelta: 3.0
    )

    // 11. Luiz Clas - 暖金光影人像
    static let luizclasPortrait = MasterRecipe(
        id: "luizclas_portrait",
        name: "Luiz Clas",
        subtitle: "暖金光影 · 质感人像",
        summary: "黄金时刻质感大片，大光比下人物温润通透，深邃阴影与金黄发丝轮廓",
        lutFileName: "luizclas_portrait.cube",
        exposureDelta: 0.20,
        shadowsDelta: 25.0,
        highlightsDelta: -35.0,
        contrastDelta: 10.0,
        saturationDelta: 5.0,
        tintDelta: 4.0
    )

    // 12. Ivan Ivanchenko - 暮色黄昏油画
    static let ivanIvanchenkoTwilight = MasterRecipe(
        id: "ivan_ivanchenko_twilight",
        name: "Ivan Ivanchenko",
        subtitle: "暮色黄昏 · 相邻色过渡",
        summary: "黄昏柔和微光，暖金高光与柔和青蓝暗部，低反差油画人像与相邻色呼应",
        lutFileName: "ivan_ivanchenko_twilight.cube",
        exposureDelta: 0.15,
        shadowsDelta: 25.0,
        highlightsDelta: -30.0,
        contrastDelta: -20.0,
        saturationDelta: -5.0,
        tintDelta: 2.0
    )

    // 13. Jungraphy - 霓虹都市冷青粉紫
    static let jungraphyNeon = MasterRecipe(
        id: "jungraphy_neon",
        name: "Jungraphy",
        subtitle: "霓虹都市 · 冷青粉紫",
        summary: "首尔都市霓虹夜景，冷青基底与粉紫高光对撞，雨夜路面反射倒影",
        lutFileName: "jungraphy_neon.cube",
        exposureDelta: 0.00,
        shadowsDelta: 25.0,
        highlightsDelta: -35.0,
        contrastDelta: 15.0,
        saturationDelta: 15.0,
        tintDelta: 8.0
    )

    static let allRecipes: [MasterRecipe] = [
        hamadaDaylightV2,
        takashiYasuiZen,
        takahiroSakaiBlue,
        withlukeEpic,
        danielCassonAutumn,
        billyDinhCinema,
        rkrkrkCyberpunk,
        samaliveVintage,
        iwonaFairyTale,
        cinestill800t,
        wilsonLeeGolden,
        luizclasPortrait,
        ivanIvanchenkoTwilight,
        jungraphyNeon,
    ]

    static func recipe(for id: String?) -> MasterRecipe? {
        guard let id, !id.isEmpty else { return nil }
        return allRecipes.first { $0.id == id }
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
