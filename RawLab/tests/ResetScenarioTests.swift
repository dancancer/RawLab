import Foundation
import CoreFoundation

/// P1 第③步：iOS 消费共享重置场景向量 `reset-scenarios-v1.json`。
/// 种子经 `IOSAdjustmentTransfer.prepare` 写入，重置走生产入口
/// `EditorAdjustmentRules.prepareReset`，观察通道复用 `IOSAdjustmentTransfer.capture`；
/// `@spec_default` 期望引用 spec 表的 iOS 默认值（按 scale_from_protocol 反映射），
/// 与现状的分歧按第①步棘轮模式登记进 `knownResetDivergences`。
@main
struct IOSResetScenarioTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        print("PASS: \(message)")
    }

    static func state(_ settings: RawSettings = .default) -> PhotoEditState {
        .init(settings: settings, updatedAt: Date(timeIntervalSince1970: 100))
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
        var skipped = Set<String>()
        for scenario in scenarios {
            let id = scenario["id"] as! String
            check(ids.insert(id).inserted, "Unique scenario ID: \(id)")
            if let platforms = scenario["platforms"] as? [String], !platforms.contains("ios") { skipped.insert(id); continue }
            evaluated.insert(id)
            let diffs = try evaluate(id, scenario, specFields: specFields)
            let registered = knownResetDivergences[id] ?? []
            check(diffs == registered, "Scenario \(id): divergences \(diffs.sorted()) registered \(registered.sorted())")
        }
        check(evaluated.count + skipped.count == scenarios.count, "every scenario is evaluated or platform-skipped")
        check(Set(knownResetDivergences.keys).isSubset(of: evaluated), "no stale knownResetDivergences entries")
    }

    static func evaluate(_ id: String, _ scenario: [String: Any], specFields: [String: Any]) throws -> Set<String> {
        let targetSpec = scenario["target"] as! [String: Any]
        let kind = targetSpec["kind"] as! String
        let asShot = (targetSpec["as_shot_wb"] as? [NSNumber])?.map(\.doubleValue)
        let lensValid = targetSpec["lens_valid"] as! Bool
        let availableLooks = Set(targetSpec["available_looks"] as! [String])
        var builtins = [String: String]()
        for look in availableLooks where look.hasPrefix("builtin:") {
            let file = String(look.dropFirst(8))
            builtins[file] = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        }
        var initialSettings = RawSettings.default
        if kind == "hdr" { initialSettings.hdr = HDRSettings() }
        let context = IOSAdjustmentTransferContext(identifier: "scenario-target", isRaw: kind == "sdr_raw",
            sourceIsHDR: kind == "hdr", availableLookIDs: availableLooks, builtinLookIDs: builtins,
            cameraTemperature: kind == "sdr_raw" ? asShot?[0] : nil,
            cameraTint: kind == "sdr_raw" ? asShot?[1] : nil,
            defaultExposureMode: kind == "sdr_raw" ? .preview : .sensor,
            validateLensRequest: lensValid ? { _ in } : nil)
        var seeded = state(initialSettings)
        if let seedObj = targetSpec["seed_payload"], !(seedObj is NSNull) {
            let seedPayload = try JSONDecoder().decode(AdjustmentTransferPayload.self, from: JSONSerialization.data(withJSONObject: seedObj))
            var seedContext = context
            seedContext.validateLensRequest = { _ in }
            seeded = try IOSAdjustmentTransfer.prepare(payload: seedPayload, target: seeded, context: seedContext)
        }

        let scope = resetScope(scenario["scope"] as! [String: Any])
        let resetContext = EditorAdjustmentContext(isRaw: kind == "sdr_raw",
            defaultExposureMode: kind == "sdr_raw" ? .preview : .sensor,
            cameraTemperature: asShot?[0], cameraTint: asShot?[1])
        let expect = scenario["expect"] as! [String: Any]
        let expectValues = expect["values"] as! [String: Any]
        let untouched = expect["untouched"] as! [String]
        var observed = Set<AdjustmentTransferField>()
        for key in expectValues.keys { observed.insert(AdjustmentTransferField(rawValue: key)!) }
        for key in untouched { observed.insert(AdjustmentTransferField(rawValue: key)!) }

        var diffs = Set<String>()
        let before = observed.isEmpty ? [:] : try IOSAdjustmentTransfer.capture(scope: .custom(observed), snapshot: seeded, context: context).values
        switch EditorAdjustmentRules.prepareReset(scope, snapshot: seeded, context: resetContext) {
        case .candidate(let candidate, _):
            let after = observed.isEmpty ? [:] : try IOSAdjustmentTransfer.capture(scope: .custom(observed), snapshot: candidate, context: context).values
            for key in expectValues.keys.sorted() {
                let expected = try expectation(expectValues[key]!, fieldID: key, hdr: kind == "hdr", specFields: specFields)
                if !matchesValue(after[key], expected) { diffs.insert(key) }
            }
            for key in untouched where !matchesValue(before[key], after[key]) { diffs.insert(key) }
            if (expect["status"] as? String) != "changed" { diffs.insert("status") }
            if ProcessInfo.processInfo.environment["RAWLAB_RESET_DEBUG"] != nil, !diffs.isEmpty {
                for key in diffs.sorted() {
                    let line = "DEBUG \(id) \(key): before=\(String(describing: before[key])) after=\(String(describing: after[key])) expected=\(String(describing: (try? expectation((expect["values"] as! [String: Any])[key]!, fieldID: key, hdr: kind == "hdr", specFields: specFields))))\n"
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

    static func resetScope(_ scope: [String: Any]) -> EditorAdjustmentScope {
        switch scope["kind"] as! String {
        case "tool":
            switch scope["field"] as! String {
            case "light.contrast": return .tool(.adjustment(.contrast))
            case "detail.sharpening": return .tool(.adjustment(.sharpening))
            default: fatalError("Unsupported single-reset field: \(scope["field"]!)")
            }
        case "group":
            switch scope["group"] as! String {
            case "light": return .group(.light)
            case "color": return .group(.color)
            case "geometry": return .group(.geometry)
            default: fatalError("Unsupported reset group: \(scope["group"]!)")
            }
        case "all": return .all
        default: fatalError("Unsupported reset scope kind: \(scope["kind"]!)")
        }
    }

    /// @spec_default：spec 表本端默认值按 scale_from_protocol 反映射回协议空间；
    /// HDR 目标优先取 hdr_default/hdr_scale_from_protocol；supported=false 键按 Q3 输出协议占位 0。
    static func expectation(_ marker: Any, fieldID: String, hdr: Bool, specFields: [String: Any]) throws -> AdjustmentTransferValue {
        if let text = marker as? String, text == "@spec_default" {
            let model = ((specFields[fieldID] as! [String: Any])["model"] as! [String: Any])["ios"] as! [String: Any]
            // Q3 裁定：supported=false 表示本端不建模该键（null 是「无字段」哨兵，协议非空），
            // 捕获输出协议占位 0 即合规，不得把哨兵误读成期望 null。
            if (model["supported"] as? Bool) == false { return .number(0) }
            let useHdr = hdr && (model["hdr_default"] as? NSNull) == nil && model["hdr_default"] != nil
            let def = useHdr ? model["hdr_default"]! : model["default"]!
            if def is NSNull { return .null }
            if let number = def as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
                let value = number.doubleValue
                switch model[useHdr ? "hdr_scale_from_protocol" : "scale_from_protocol"] as! String {
                case "p": return .number(value)
                case "p * 100": return .number(value / 100)
                case "(p - 1) * 100": return .number(value / 100 + 1)
                case "p - 1": return .number(value + 1)
                case "p / 100": return .number(value * 100)
                case "-p * 100": return .number(-value / 100)
                case "-p": return .number(-value)
                default: fatalError("Unsupported scale_from_protocol for \(fieldID)")
                }
            }
            return try JSONDecoder().decode(AdjustmentTransferValue.self,
                from: JSONSerialization.data(withJSONObject: def, options: [.fragmentsAllowed]))
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
