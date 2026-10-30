import Foundation

@main struct AdjustmentTransferSummaryTests {
    struct Fixtures: Decodable {
        let cases: [Fixture]
    }

    struct Fixture: Decodable {
        let id: String
        let payload: AdjustmentTransferPayload
        let expected: Expected
    }

    struct Expected: Decodable {
        let groups: [Group]
        let count: Int
        let includesGeometry: Bool
        let valuesZH: [String: String]
        let recipeNote: String?

        enum CodingKeys: String, CodingKey {
            case groups, count, includesGeometry = "includes_geometry"
            case valuesZH = "values_zh", recipeNote = "recipe_note"
        }
    }

    struct Group: Decodable {
        let id: String
        let fields: [String]
    }

    static var checks = 0

    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        checks += 1
        print("PASS: \(message)")
    }

    static func payload(_ values: [AdjustmentTransferField: AdjustmentTransferValue]) throws -> AdjustmentTransferPayload {
        try AdjustmentTransferPayload(
            source: AdjustmentTransferSource(identifier: "all-fields.ARW", isRaw: true, processingVersion: 2, recipe: nil),
            values: Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
        )
    }

    static func allFieldsPayload() throws -> AdjustmentTransferPayload {
        var values: [AdjustmentTransferField: AdjustmentTransferValue] = [:]
        for field in AdjustmentTransferField.allCases where !field.isHDRRelative {
            switch field {
            case .look: values[field] = .object(["kind": .string("neutral"), "id": .null])
            case .exposureMode: values[field] = .string("scene")
            case .whiteBalanceMode: values[field] = .string("camera")
            case .temperature, .tint, .lensProfile: values[field] = .null
            case .curve: values[field] = ToneCurveSettings().transferValue
            case .gradingShadows, .gradingMidtones, .gradingHighlights:
                values[field] = .object(["hue": .number(0), "saturation": .number(0)])
            case .waveletDenoise: values[field] = .null
            case .flipHorizontal, .flipVertical, .lensDistortion, .lensTCA, .lensAutoCrop:
                values[field] = .boolean(false)
            case .rawDenoise: values[field] = .number(0)
            case .postRGBDenoise, .chromaDenoise: values[field] = .number(0)
            case .cropWidth, .cropHeight: values[field] = .number(1)
            case .quarterTurns: values[field] = .number(0)
            default: values[field] = .number(0)
            }
        }
        return try payload(values)
    }

    static func main() throws {
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let resourcesURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let decoder = JSONDecoder()
        let fixtures = try decoder.decode(Fixtures.self, from: Data(contentsOf: fixtureURL)).cases
        let locale = Locale(identifier: "zh-Hans")
        let identityText: (String) -> String = { $0 }

        for fixture in fixtures {
            let summary = AdjustmentTransferSummary(payload: fixture.payload, locale: locale, text: identityText)
            check(summary.groups.map(\.id) == fixture.expected.groups.map(\.id), "\(fixture.id) preserves group order")
            for (actual, expected) in zip(summary.groups, fixture.expected.groups) {
                check(actual.fields.map(\.rawValue) == expected.fields,
                      "\(fixture.id) preserves enum field order in \(expected.id)")
            }
            let expectedFields = Set(fixture.expected.groups.flatMap(\.fields))
            check(expectedFields == Set(fixture.expected.valuesZH.keys),
                  "\(fixture.id) expected values cover exactly the grouped fields")
            check(summary.count == fixture.expected.count, "\(fixture.id) reports payload field count")
            check(summary.includesGeometry == fixture.expected.includesGeometry, "\(fixture.id) reports geometry inclusion")
            check(summary.recipeNote == fixture.expected.recipeNote, "\(fixture.id) reports recipe context")

            for (rawField, expected) in fixture.expected.valuesZH {
                guard let field = AdjustmentTransferField(rawValue: rawField) else {
                    fatalError("Unknown fixture field \(rawField)")
                }
                let actual = summary.valueText(for: field, lookName: { kind, id in
                    if kind == "builtin" && id == "acros" { return "Acros" }
                    if kind == "recipe" && id == "recipe-v3" { return "Recipe V3" }
                    if kind == "recipe" && id == "recipe-v4" { return "Recipe V4" }
                    return nil
                })
                check(actual == expected, "\(fixture.id) formats \(rawField) as \(expected)")
                check(!actual.contains("object") && !actual.contains("[") && !actual.contains("{"),
                      "\(fixture.id) does not expose serialized object text for \(rawField)")
            }
        }

        let allFields = AdjustmentTransferSummary(payload: try allFieldsPayload(), locale: locale, text: identityText)
        check(allFields.count == AdjustmentTransferField.allCases.count - 2, "All legal legacy fields are represented")
        for field in allFields.payload.fields {
            let value = allFields.valueText(for: field, lookName: { _, _ in nil })
            check(!value.contains("object") && !value.contains("[") && !value.contains("{"),
                  "Every legal field has a human-readable value: \(field.rawValue)")
        }

        let camera = try XCTFixture(id: "camera-wb", fixtures: fixtures).payload
        let english = AdjustmentTransferSummary(payload: camera, locale: Locale(identifier: "en-US"), text: {
            $0 == "相机白平衡（按目标照片）" ? "Camera white balance (per target photo)" : $0
        })
        check(english.valueText(for: .whiteBalanceMode, lookName: { _, _ in nil }) == "Camera white balance (per target photo)",
              "Text resolver supplies an English camera white-balance translation")
        let germanExposure = try XCTFixture(id: "exposure", fixtures: fixtures).payload
        let german = AdjustmentTransferSummary(payload: germanExposure, locale: Locale(identifier: "de-DE"), text: identityText)
        check(german.valueText(for: .exposure, lookName: { _, _ in nil }) == "+0,70 EV",
              "Locale controls numeric decimal punctuation without changing the payload")

        let recipeV3 = try XCTFixture(id: "recipe-v3", fixtures: fixtures).payload
        let recipeV4 = try XCTFixture(id: "recipe-v4-objects", fixtures: fixtures).payload
        let hdr = try XCTFixture(id: "hdr-seven", fixtures: fixtures).payload
        let enText = generatedText(language: "en", resourcesURL: resourcesURL)
        let deText = generatedText(language: "de", resourcesURL: resourcesURL)
        try checkGeneratedLanguage("en", locale: Locale(identifier: "en-US"), text: enText,
                                   recipeV3: recipeV3, recipeV4: recipeV4, hdr: hdr)
        try checkGeneratedLanguage("de", locale: Locale(identifier: "de-DE"), text: deText,
                                   recipeV3: recipeV3, recipeV4: recipeV4, hdr: hdr)
        print("PASS \(checks) adjustment transfer summary checks")
    }

    private static func generatedText(language: String, resourcesURL: URL) -> (String) -> String {
        guard let resources = Bundle(path: resourcesURL.path),
              let path = resources.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            fatalError("Missing generated " + language + " Localizable.strings bundle")
        }
        return { key in
            let value = bundle.localizedString(forKey: key, value: nil, table: nil)
            guard value != key else { fatalError("Missing generated " + language + " key: " + key) }
            return value
        }
    }

    private static func checkGeneratedLanguage(_ language: String,
                                               locale: Locale,
                                               text: @escaping (String) -> String,
                                               recipeV3: AdjustmentTransferPayload,
                                               recipeV4: AdjustmentTransferPayload,
                                               hdr: AdjustmentTransferPayload) throws {
        let lookName: (String, String) -> String? = { kind, id in
            guard kind == "recipe", id == "recipe-v3" || id == "recipe-v4" else { return nil }
            return id
        }
        let recipeSummary = AdjustmentTransferSummary(payload: recipeV3, locale: locale, text: text)
        check(recipeSummary.valueText(for: .look, lookName: lookName) == text("配方") + " · recipe-v3",
              "Generated " + language + " resource localizes recipe look type")
        check(recipeSummary.valueText(for: .whiteBalanceMode, lookName: lookName) == text("相机白平衡（按目标照片）"),
              "Generated " + language + " resource localizes camera white balance")
        let note = String(format: text("以下为配方逻辑值；强度为 %@。部分范围会按此强度换算。"), locale: locale, arguments: ["65%"])
        check(recipeSummary.recipeNote == note, "Generated " + language + " resource localizes recipe note")

        let objectSummary = AdjustmentTransferSummary(payload: recipeV4, locale: locale, text: text)
        let denoise = [text("开启"), text("亮度降噪") + " 20", text("色彩降噪") + " 30",
                       text("粗色斑抑制") + " 40", text("自定义")].joined(separator: " · ")
        check(objectSummary.valueText(for: .waveletDenoise, lookName: lookName) == denoise,
              "Generated " + language + " resource localizes wavelet values")

        let hdrSummary = AdjustmentTransferSummary(payload: hdr, locale: locale, text: text)
        let hdrTemperature = "7200 K（" + text("相对白平衡") + "）"
        check(hdrSummary.valueText(for: .hdrTemperature, lookName: lookName) == hdrTemperature,
              "Generated " + language + " resource localizes HDR relative white balance")
    }

    private static func XCTFixture(id: String, fixtures: [Fixture]) throws -> Fixture {
        guard let fixture = fixtures.first(where: { $0.id == id }) else {
            throw NSError(domain: "AdjustmentTransferSummaryTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing fixture \(id)"])
        }
        return fixture
    }
}
