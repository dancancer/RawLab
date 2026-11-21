import Foundation
import XCTest
@testable import RawLabKit

final class AdjustmentTransferSummaryTests: XCTestCase {
    private struct Fixtures: Decodable {
        let cases: [Fixture]
    }

    private struct Fixture: Decodable {
        let id: String
        let payload: AdjustmentTransferPayload
        let expected: Expected
    }

    private struct Expected: Decodable {
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

    private struct Group: Decodable {
        let id: String
        let fields: [String]
    }

    private func payload(_ values: [AdjustmentTransferField: AdjustmentTransferValue]) throws -> AdjustmentTransferPayload {
        try AdjustmentTransferPayload(
            source: AdjustmentTransferSource(identifier: "all-fields.ARW", isRaw: true, processingVersion: 2, recipe: nil),
            values: Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
        )
    }

    private func allFieldsPayload() throws -> AdjustmentTransferPayload {
        var values: [AdjustmentTransferField: AdjustmentTransferValue] = [:]
        for field in AdjustmentTransferField.legacyFields {
            switch field {
            case .look: values[field] = .object(["kind": .string("neutral"), "id": .null])
            case .exposureMode: values[field] = .string("scene")
            case .whiteBalanceMode: values[field] = .string("camera")
            case .temperature, .tint, .lensProfile: values[field] = .null
            case .curve: values[field] = ToneCurveSettings().transferValue
            case .gradingShadows, .gradingMidtones, .gradingHighlights:
                values[field] = .object(["hue": .number(0), "saturation": .number(0)])
            case .waveletDenoise: values[field] = .null
            case .flipHorizontal, .flipVertical, .lensDistortion, .lensTCA, .lensVignetting, .lensAutoCrop:
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

    private func generatedText(language: String, resourcesURL: URL) throws -> (String) -> String {
        let resources = try XCTUnwrap(Bundle(path: resourcesURL.path))
        let path = try XCTUnwrap(resources.path(forResource: language, ofType: "lproj"))
        let bundle = try XCTUnwrap(Bundle(path: path))
        return { key in
            let value = bundle.localizedString(forKey: key, value: nil, table: nil)
            XCTAssertNotEqual(value, key, "Missing generated \(language) key: \(key)")
            return value
        }
    }

    private func checkGeneratedLanguage(
        _ language: String,
        locale: Locale,
        text: @escaping (String) -> String,
        recipeV3: AdjustmentTransferPayload,
        recipeV4: AdjustmentTransferPayload,
        hdr: AdjustmentTransferPayload
    ) {
        let lookName: (String, String) -> String? = { kind, id in
            guard kind == "recipe", id == "recipe-v3" || id == "recipe-v4" else { return nil }
            return id
        }
        let recipeSummary = AdjustmentTransferSummary(payload: recipeV3, locale: locale, text: text)
        XCTAssertEqual(recipeSummary.valueText(for: .look, lookName: lookName), text("配方") + " · recipe-v3")
        XCTAssertEqual(recipeSummary.valueText(for: .whiteBalanceMode, lookName: lookName), text("相机白平衡（按目标照片）"))
        let note = String(format: text("以下为配方逻辑值；强度为 %@。部分范围会按此强度换算。"), locale: locale, arguments: ["65%"])
        XCTAssertEqual(recipeSummary.recipeNote, note)

        let objectSummary = AdjustmentTransferSummary(payload: recipeV4, locale: locale, text: text)
        let denoise = [
            text("开启"), text("亮度降噪") + " 20", text("色彩降噪") + " 30",
            text("粗色斑抑制") + " 40", text("自定义")
        ].joined(separator: " · ")
        XCTAssertEqual(objectSummary.valueText(for: .waveletDenoise, lookName: lookName), denoise)

        let hdrSummary = AdjustmentTransferSummary(payload: hdr, locale: locale, text: text)
        let hdrTemperature = "7200 K（" + text("相对白平衡") + "）"
        XCTAssertEqual(hdrSummary.valueText(for: .hdrTemperature, lookName: lookName), hdrTemperature)
    }

    func testAdjustmentTransferSummaryFixturesAndLocalization() throws {
        let fixtureURL = RawLabKitTestSupport.repoRoot.appendingPathComponent("Shared/fixtures/adjustment-summary-v1.json")
        let resourcesURL = RawLabKitTestSupport.repoRoot.appendingPathComponent("RawLab/RawLab/Resources")
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: fixtureURL)).cases
        let locale = Locale(identifier: "zh-Hans")
        let identityText: (String) -> String = { $0 }

        for fixture in fixtures {
            let summary = AdjustmentTransferSummary(payload: fixture.payload, locale: locale, text: identityText)
            XCTAssertEqual(summary.groups.map(\.id), fixture.expected.groups.map(\.id))
            for (actual, expected) in zip(summary.groups, fixture.expected.groups) {
                XCTAssertEqual(actual.fields.map(\.rawValue), expected.fields)
            }
            let expectedFields = Set(fixture.expected.groups.flatMap(\.fields))
            XCTAssertEqual(expectedFields, Set(fixture.expected.valuesZH.keys))
            XCTAssertEqual(summary.count, fixture.expected.count)
            XCTAssertEqual(summary.includesGeometry, fixture.expected.includesGeometry)
            XCTAssertEqual(summary.recipeNote, fixture.expected.recipeNote)

            for (rawField, expected) in fixture.expected.valuesZH {
                let field = try XCTUnwrap(AdjustmentTransferField(rawValue: rawField))
                let actual = summary.valueText(for: field, lookName: { kind, id in
                    if kind == "builtin" && id == "acros" { return "Acros" }
                    if kind == "recipe" && id == "recipe-v3" { return "Recipe V3" }
                    if kind == "recipe" && id == "recipe-v4" { return "Recipe V4" }
                    return nil
                })
                XCTAssertEqual(actual, expected)
                XCTAssertFalse(actual.contains("object") || actual.contains("[") || actual.contains("{"))
            }
        }

        let allFields = AdjustmentTransferSummary(payload: try allFieldsPayload(), locale: locale, text: identityText)
        XCTAssertEqual(allFields.count, AdjustmentTransferField.legacyFields.count)
        for field in allFields.payload.fields {
            let value = allFields.valueText(for: field, lookName: { _, _ in nil })
            XCTAssertFalse(value.contains("object") || value.contains("[") || value.contains("{"))
        }

        let camera = try XCTUnwrap(fixtures.first(where: { $0.id == "camera-wb" })).payload
        let english = AdjustmentTransferSummary(payload: camera, locale: Locale(identifier: "en-US"), text: {
            $0 == "相机白平衡（按目标照片）" ? "Camera white balance (per target photo)" : $0
        })
        XCTAssertEqual(english.valueText(for: .whiteBalanceMode, lookName: { _, _ in nil }), "Camera white balance (per target photo)")

        let germanExposure = try XCTUnwrap(fixtures.first(where: { $0.id == "exposure" })).payload
        let german = AdjustmentTransferSummary(payload: germanExposure, locale: Locale(identifier: "de-DE"), text: identityText)
        XCTAssertEqual(german.valueText(for: .exposure, lookName: { _, _ in nil }), "+0,70 EV")

        let recipeV3 = try XCTUnwrap(fixtures.first(where: { $0.id == "recipe-v3" })).payload
        let recipeV4 = try XCTUnwrap(fixtures.first(where: { $0.id == "recipe-v4-objects" })).payload
        let hdr = try XCTUnwrap(fixtures.first(where: { $0.id == "hdr-seven" })).payload
        let enText = try generatedText(language: "en", resourcesURL: resourcesURL)
        let deText = try generatedText(language: "de", resourcesURL: resourcesURL)
        checkGeneratedLanguage("en", locale: Locale(identifier: "en-US"), text: enText, recipeV3: recipeV3, recipeV4: recipeV4, hdr: hdr)
        checkGeneratedLanguage("de", locale: Locale(identifier: "de-DE"), text: deText, recipeV3: recipeV3, recipeV4: recipeV4, hdr: hdr)
    }
}
