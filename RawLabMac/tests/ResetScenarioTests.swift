import CoreFoundation
import Foundation

/// P1 第③步：macOS 消费共享重置场景向量 `reset-scenarios-v1.json`。
/// 种子经 `MacAdjustmentTransfer.prepare` 写入，重置走生产入口
/// `EditorAdjustmentRules.prepareReset`，观察通道复用 `MacAdjustmentTransfer.capture`；
/// `@spec_default` 期望引用 spec 表的 macOS 默认值（按 scale_from_protocol 反映射），
/// 与现状的分歧按第①步棘轮模式登记进 `knownResetDivergences`。
@main
struct ResetScenarioTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        print("PASS: \(message)")
    }

    static func state(_ settings: Adjustments = Adjustments(), film: String = "") -> PhotoEditState {
        PhotoEditState(settings: settings, filmID: film, masterRecipeID: settings.masterRecipeID)
    }

    /// 场景 id -> 已登记的精确 diff-key 集；未登记的分歧与「已修复仍留档」都必红，棘轮只减不增。
    static let knownResetDivergences: [String: Set<String>] = [:]

    static func main() throws {
        try resetScenarioFixtures()
    }

    static func resetScenarioFixtures() throws {
        let url = URL(fileURLWithPath: "Shared/fixtures/reset-scenarios-v1.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        check(root["fixture_version"] as? Int == 1, "Reset fixture version is 1")
        let specURL = URL(fileURLWithPath: "Shared/specs/adjustment-fields-v1.json")
        let specRows = (try JSONSerialization.jsonObject(with: Data(contentsOf: specURL)) as! [String: Any])["fields"] as! [[String: Any]]
        let specFields = Dictionary(uniqueKeysWithValues: specRows.map { ($0["field_id"] as! String, $0) })
        let scenarios = root["scenarios"] as! [[String: Any]]
        var ids = Set<String>()
        var evaluated = Set<String>()
        for scenario in scenarios {
            let id = scenario["id"] as! String
            check(ids.insert(id).inserted, "Unique scenario ID: \(id)")
            if let platforms = scenario["platforms"] as? [String], !platforms.contains("macos") { continue }
            evaluated.insert(id)
            let diffs = try evaluate(id, scenario, specFields: specFields)
            let registered = knownResetDivergences[id] ?? []
            check(diffs == registered, "Scenario \(id): divergences \(diffs.sorted()) registered \(registered.sorted())")
        }
        check(evaluated.count == scenarios.count, "macOS evaluates every scenario including hdr_rendition")
        check(Set(knownResetDivergences.keys).isSubset(of: evaluated), "no stale knownResetDivergences entries")
    }

    static func evaluate(_ id: String, _ scenario: [String: Any], specFields: [String: Any]) throws -> Set<String> {
        let targetSpec = scenario["target"] as! [String: Any]
        let kind = targetSpec["kind"] as! String
        let asShot = (targetSpec["as_shot_wb"] as? [NSNumber])?.map(\.doubleValue)
        let lensValid = targetSpec["lens_valid"] as! Bool
        let supportsRawDenoise = targetSpec["supports_raw_denoise"] as! Bool
        let availableLooks = Set(targetSpec["available_looks"] as! [String])

        var initialSettings = Adjustments()
        if kind == "hdr" { initialSettings.hdr = HDRSettings() }
        if kind == "sdr_raw" {
            initialSettings.resolveRawNoiseReductionSupport(supportsRawDenoise)
            if let asShot { initialSettings.resolveWhiteBalance(WhiteBalance(temperature: asShot[0], tint: asShot[1])) }
        }
        let context = MacAdjustmentTransferContext(identifier: "scenario-target", isRaw: kind == "sdr_raw",
            sourceIsHDR: kind == "hdr", availableLookIDs: availableLooks,
            defaultExposureMode: kind == "sdr_raw" ? .preview : .sensor,
            validateLensRequest: lensValid ? { _ in } : nil)
        var seeded = state(initialSettings)
        if let seedObj = targetSpec["seed_payload"], !(seedObj is NSNull) {
            let seedPayload = try JSONDecoder().decode(AdjustmentTransferPayload.self, from: JSONSerialization.data(withJSONObject: seedObj))
            var seedContext = context
            seedContext.validateLensRequest = { _ in }
            seeded = try MacAdjustmentTransfer.prepare(payload: seedPayload, target: seeded, context: seedContext)
        }

        let scopeObj = scenario["scope"] as! [String: Any]
        let scope = try resetScope(scopeObj)
        let resetContext = EditorAdjustmentContext(isRaw: kind == "sdr_raw", defaultExposureMode: .preview,
            neutralFilmID: "")
        let expect = scenario["expect"] as! [String: Any]
        let expectValues = expect["values"] as! [String: Any]
        let untouched = expect["untouched"] as! [String]
        var observed = Set<AdjustmentTransferField>()
        for key in expectValues.keys { observed.insert(AdjustmentTransferField(rawValue: key)!) }
        for key in untouched { observed.insert(AdjustmentTransferField(rawValue: key)!) }

        var diffs = Set<String>()
        let before = observed.isEmpty ? [:] : try MacAdjustmentTransfer.capture(scope: .custom(observed), snapshot: seeded, context: context).values
        switch EditorAdjustmentRules.prepareReset(scope: scope, snapshot: seeded, context: resetContext) {
        case .candidate(let candidate):
            let after = observed.isEmpty ? [:] : try MacAdjustmentTransfer.capture(scope: .custom(observed), snapshot: candidate, context: context).values
            for key in expectValues.keys.sorted() {
                let expected = try expectation(expectValues[key]!, fieldID: key, specFields: specFields)
                if !matchesValue(after[key], expected) { diffs.insert(key) }
            }
            for key in untouched where !matchesValue(before[key], after[key]) { diffs.insert(key) }
            if (expect["status"] as? String) != "changed" { diffs.insert("status") }
            if ProcessInfo.processInfo.environment["RAWLAB_RESET_DEBUG"] != nil, !diffs.isEmpty {
                for key in diffs.sorted() {
                    let line = "DEBUG \(id) \(key): before=\(String(describing: before[key])) after=\(String(describing: after[key])) expected=\(String(describing: (try? expectation((expect["values"] as! [String: Any])[key]!, fieldID: key, specFields: specFields))))\n"
                    FileHandle.standardError.write(Data(line.utf8))
                }
            }
        case .unchanged:
            if (expect["status"] as? String) != "unchanged" { diffs.insert("status") }
        case .blocked:
            if (expect["status"] as? String) != "blocked" { diffs.insert("status") }
        }
        return diffs
    }

    static func resetScope(_ scope: [String: Any]) throws -> EditorResetScope {
        switch scope["kind"] as! String {
        case "tool":
            switch scope["field"] as! String {
            case "light.contrast": return .tool(.contrast)
            case "detail.sharpening": return .tool(.sharpening)
            default: fatalError("Unsupported single-reset field: \(scope["field"]!)")
            }
        case "group":
            switch scope["group"] as! String {
            case "light": return .group(.light)
            case "color": return .group(.color)
            case "geometry": return .group(.geometry)
            case "hdr_rendition": return .group(.hdrRendition)
            default: fatalError("Unsupported reset group: \(scope["group"]!)")
            }
        case "all": return .all
        default: fatalError("Unsupported reset scope kind: \(scope["kind"]!)")
        }
    }

    /// @spec_default：spec 表本端默认值按 scale_from_protocol 反映射回协议空间。
    static func expectation(_ marker: Any, fieldID: String, specFields: [String: Any]) throws -> AdjustmentTransferValue {
        if let text = marker as? String, text == "@spec_default" {
            let model = ((specFields[fieldID] as! [String: Any])["model"] as! [String: Any])["macos"] as! [String: Any]
            if model["default"] is NSNull { return .null }
            if let number = model["default"] as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
                let value = number.doubleValue
                switch model["scale_from_protocol"] as! String {
                case "p": return .number(value)
                case "p * 100": return .number(value / 100)
                case "(p - 1) * 100": return .number(value / 100 + 1)
                case "p - 1": return .number(value + 1)
                case "-p * 100": return .number(-value / 100)
                case "-p": return .number(-value)
                default: fatalError("Unsupported scale_from_protocol for \(fieldID)")
                }
            }
            return try JSONDecoder().decode(AdjustmentTransferValue.self,
                from: JSONSerialization.data(withJSONObject: model["default"]!, options: [.fragmentsAllowed]))
        }
        if marker is NSNull { return .null }
        return try JSONDecoder().decode(AdjustmentTransferValue.self,
            from: JSONSerialization.data(withJSONObject: marker, options: [.fragmentsAllowed]))
    }

    static func matchesValue(_ actual: AdjustmentTransferValue?, _ expected: AdjustmentTransferValue?, tolerance: Double = 1e-6) -> Bool {
        guard let actual, let expected else { return actual == nil && expected == nil }
        switch (actual, expected) {
        case (.null, .null): return true
        case let (.boolean(a), .boolean(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.number(a), .number(b)): return abs(a - b) <= tolerance
        case let (.array(a), .array(b)):
            return a.count == b.count && zip(a, b).allSatisfy { matchesValue($0, $1, tolerance: tolerance) }
        case let (.object(a), .object(b)):
            return a.keys == b.keys && b.allSatisfy { matchesValue(a[$0.key], $0.value, tolerance: tolerance) }
        default: return false
        }
    }
}
