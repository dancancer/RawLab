import Foundation

@main struct GeometrySettingsTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
        }
        var settings = Adjustments()
        check(settings.geometry == nil && settings.geometrySettings.isIdentity && settings.isDefault(.geometry),
              "new edits keep the full original canvas")
        let legacy = try JSONDecoder().decode(Adjustments.self, from: Data("{}".utf8))
        check(legacy.geometry == nil && legacy.geometrySettings.isIdentity && legacy.exposureMode == .scene,
              "old records retain their exposure interpretation and identity geometry")
        let partial = try JSONDecoder().decode(Adjustments.self, from: Data("{\"geometry\":{\"quarterTurns\":1}}".utf8))
        check(partial.geometrySettings.quarterTurns == 1 && partial.geometrySettings.cropWidth == 1 &&
              partial.geometrySettings.cropHeight == 1 && !partial.geometrySettings.flipHorizontal &&
              partial.geometrySettings.perspectiveHorizontal == 0 && partial.geometrySettings.perspectiveVertical == 0,
              "missing geometry and perspective fields use identity values")
        check(MemoryLayout<sony2fuji_geometry_config>.size == 40 &&
              MemoryLayout<sony2fuji_perspective_config>.size == 16,
              "perspective adds its own config without changing the basic geometry ABI")
        settings.setGeometry(.cropWidth, to: 0.6)
        settings.setGeometry(.cropHeight, to: 0.7)
        settings.setGeometry(.cropX, to: 0.2)
        settings.setGeometry(.cropY, to: 0.1)
        settings.rotateGeometry(clockwise: true)
        settings.flipGeometry(horizontal: true)
        settings.flipGeometry(horizontal: false)
        settings.setGeometry(.straightenDegrees, to: -7.5)
        settings.setGeometry(.perspectiveHorizontal, to: 0.3)
        settings.setGeometry(.perspectiveVertical, to: -0.2)
        let restored = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(settings))
        check(restored == settings && !restored.isDefault(.geometry), "every geometry setting survives JSON")
        let neutral = settings.neutralGeometrySettings
        check(neutral.geometrySettings == settings.geometrySettings && neutral.exposure == 0 && neutral.masterRecipeID == nil,
              "color comparison uses the same crop and transformed canvas")
        settings.setGeometry(.cropX, to: 1)
        check(settings.geometrySettings.cropX == 1 - settings.geometrySettings.cropWidth && settings.geometrySettings.isValid,
              "moving the crop cannot extend its right edge beyond the canvas")
        settings.setGeometry(.cropWidth, to: 1)
        check(settings.geometrySettings.cropWidth == 1 - settings.geometrySettings.cropX && settings.geometrySettings.isValid,
              "expanding the crop retains its valid origin")
        settings.setGeometry(.cropHeight, to: 0)
        settings.setGeometry(.cropY, to: 1)
        check(settings.geometrySettings.cropHeight > 0 && settings.geometrySettings.isValid,
              "crop height stays positive at the lower and upper boundaries")
        settings.setGeometry(.straightenDegrees, to: 100)
        check(settings.geometrySettings.straightenDegrees == 45, "straightening uses the core angle range")
        settings.setGeometry(.perspectiveHorizontal, to: 100)
        settings.setGeometry(.perspectiveVertical, to: -100)
        check(settings.geometrySettings.perspectiveHorizontal == 1 && settings.geometrySettings.perspectiveVertical == -1 &&
              GeometryParameter.perspectiveHorizontal.multiplier == 100 && GeometryParameter.perspectiveVertical.unit == "%",
              "perspective controls show percent and clamp to the normalized core range")
        let finite = settings
        settings.setGeometry(.cropX, to: .nan)
        settings.setGeometry(.straightenDegrees, to: .infinity)
        settings.setGeometry(.perspectiveHorizontal, to: .nan)
        settings.setGeometry(.perspectiveVertical, to: .infinity)
        check(settings == finite, "nonfinite numeric edits leave the current crop unchanged")
        settings.reset(.geometry)
        check(settings.geometry == nil && settings.isDefault(.geometry), "group reset restores identity")
        settings.setGeometry(.perspectiveVertical, to: 0.4)
        check(!settings.geometrySettings.isIdentity && !settings.isDefault(.geometry),
              "perspective alone changes geometry identity and cache equality")
        settings.setGeometry(.perspectiveVertical, to: 0)
        check(settings.geometry == nil, "zero perspective restores canonical identity")
        for _ in 0..<4 { settings.rotateGeometry(clockwise: false) }
        check(settings.geometry == nil, "four left turns return to identity")
        settings.rotateGeometry(clockwise: true)
        settings.rotateGeometry(clockwise: false)
        check(settings.geometry == nil, "left and right turns cancel")
        settings.flipGeometry(horizontal: true)
        settings.flipGeometry(horizontal: true)
        check(settings.geometry == nil, "two flips return to identity")
        settings.rotateGeometry(clockwise: true)
        settings.resetAll()
        check(settings.geometry == nil && settings.isDefault, "reset all includes geometry")
        for record in ["{\"cropX\":0.8,\"cropWidth\":0.5}", "{\"cropWidth\":0}",
                       "{\"quarterTurns\":4}", "{\"straightenDegrees\":46}",
                       "{\"perspectiveHorizontal\":1.1}", "{\"perspectiveVertical\":-1.1}"] {
            do {
                _ = try JSONDecoder().decode(Adjustments.self, from: Data("{\"geometry\":\(record)}".utf8))
                preconditionFailure("Invalid saved geometry accepted: \(record)")
            } catch DecodingError.dataCorrupted { checks += 1 }
        }
        let keys = ["几何编辑", "几何", "裁切、旋转、翻转、透视和拉直", "水平翻转", "垂直翻转", "重置几何编辑",
                    "向右旋转 90°", "向左旋转 90°", "裁切左边", "裁切上边", "裁切宽度", "裁切高度", "拉直",
                    "水平透视", "垂直透视", "裁切百分比基于旋转、翻转、透视和拉直后的画面。", "无效的几何参数"]
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        for language in ["en", "zh-Hans", "de", "fr", "ja", "es"] {
            let url = resources.appendingPathComponent("\(language).lproj/Localizable.strings")
            let strings = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: String]
            for key in keys { check(strings[key]?.isEmpty == false, "\(language): geometry key \(key)") }
        }
        print("PASS: \(checks) geometry migration, control bounds, reset and six-language checks")
    }
}
