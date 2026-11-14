import Foundation

/// V-RESET：iOS 消费共享重置场景向量 `reset-scenarios-v1.json`。
/// 种子经 `IOSAdjustmentTransfer.prepare` 写入，重置走生产入口
/// `EditorAdjustmentRules.prepareReset`，观察通道复用 `IOSAdjustmentTransfer.capture` 的
/// wire JSON 序列化值；不再本地解析 `@spec_default`，真实序列化分歧显式登记进
/// `knownResetDivergences`。
@main
struct IOSResetScenarioTests {
    struct ResetDiff {
        let key: String
        let summary: String
    }

    struct ResetDivergence {
        let ledgerId: String
        let fieldReasons: [String: String]
        var expectedKeys: Set<String> { Set(fieldReasons.keys) }
    }

    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        print("PASS: \(message)")
    }

    static func state(_ settings: RawSettings = .default) -> PhotoEditState {
        .init(settings: settings, updatedAt: Date(timeIntervalSince1970: 100))
    }

    /// 棘轮上限按 `(scenario, field)` 计数，只减不增；iOS 基线为 0（0 scenario / 0 field divergences），严禁上调。
    /// 收口口径（P2-23 / S1）：仅 Mac 存在 4 条 SDR `detail.denoise` null 序列化分歧，iOS 已与规范字面量对齐。
    static let maxKnownFieldDivergences = 0

    /// 显式例外清单（逐条精确到 `(scenario, field)`）：未登记的分歧或清单外字段差异必红；已修复仍留档也必红。
    static let knownResetDivergences: [String: ResetDivergence] = [:]

    static func main() throws {
        try resetScenarioFixtures()
    }

    static func resetScenarioFixtures() throws {
        try verifyWirePresenceContract()
        for (id, div) in knownResetDivergences {
            check(!div.ledgerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Reset divergence \(id): non-blank ledgerId")
            check(!div.fieldReasons.isEmpty, "Reset divergence \(id): per-field reasons required")
            for (field, reason) in div.fieldReasons {
                check(!reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Reset divergence \(id).\(field): non-blank reason")
            }
        }
        let totalFieldDivergences = knownResetDivergences.values.reduce(0) { $0 + $1.fieldReasons.count }
        check(totalFieldDivergences <= maxKnownFieldDivergences,
              "Reset field divergences (\(totalFieldDivergences)) must not exceed monotonic ratchet cap (\(maxKnownFieldDivergences))")

        let url = URL(fileURLWithPath: "Shared/fixtures/reset-scenarios-v1.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        check(root["fixture_version"] as? Int == 1, "Reset fixture version is 1")
        let scenarios = root["scenarios"] as! [[String: Any]]
        var ids = Set<String>()
        var evaluated = Set<String>()
        var skipped = Set<String>()
        var problems = [String]()
        for scenario in scenarios {
            let id = scenario["id"] as! String
            check(ids.insert(id).inserted, "Unique scenario ID: \(id)")
            if let platforms = scenario["platforms"] as? [String], !platforms.contains("ios") { skipped.insert(id); continue }
            evaluated.insert(id)
            let diffs = try evaluate(id, scenario)
            let actualKeys = Set(diffs.map(\.key))
            let summary = diffs.map(\.summary).joined(separator: "; ")
            if let known = knownResetDivergences[id] {
                if diffs.isEmpty {
                    problems.append("Scenario \(id) now matches fixture; remove stale divergence (\(known.ledgerId))")
                } else if actualKeys != known.expectedKeys {
                    problems.append("Scenario \(id) divergence keys changed (expected=\(known.expectedKeys.sorted()), actual=\(actualKeys.sorted())): \(summary)")
                } else {
                    for diff in diffs {
                        let reason = known.fieldReasons[diff.key]!
                        print("KNOWN DIVERGENCE [\(id).\(diff.key)] (\(known.ledgerId) - \(reason)): \(diff.summary)")
                    }
                }
            } else if !diffs.isEmpty {
                problems.append("Scenario \(id) diverged: \(summary)")
            }
        }
        check(evaluated.count + skipped.count == scenarios.count, "every scenario is evaluated or platform-skipped")
        check(Set(knownResetDivergences.keys).isSubset(of: evaluated), "no stale knownResetDivergences entries")
        if !problems.isEmpty { fatalError(problems.joined(separator: "\n")) }
        print("PASS: \(evaluated.count) iOS reset scenarios evaluated (\(skipped.count) platform-scoped skipped, \(knownResetDivergences.count) scenario / \(totalFieldDivergences) field divergences; ratchet cap \(maxKnownFieldDivergences))")
    }

    static func evaluate(_ id: String, _ scenario: [String: Any]) throws -> [ResetDiff] {
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
        let expectValuesRaw = expect["values"] as! [String: Any]
        let untouched = expect["untouched"] as! [String]
        var observed = Set<AdjustmentTransferField>()
        for key in expectValuesRaw.keys { observed.insert(AdjustmentTransferField(rawValue: key)!) }
        for key in untouched { observed.insert(AdjustmentTransferField(rawValue: key)!) }

        var diffs = [ResetDiff]()
        let before = observed.isEmpty ? [:] : try wireValues(IOSAdjustmentTransfer.capture(scope: .custom(observed), snapshot: seeded, context: context))
        let expectValues = try JSONDecoder().decode([String: AdjustmentTransferValue].self,
            from: JSONSerialization.data(withJSONObject: expectValuesRaw))
        switch EditorAdjustmentRules.prepareReset(scope, snapshot: seeded, context: resetContext) {
        case .candidate(let candidate, _):
            let after = observed.isEmpty ? [:] : try wireValues(IOSAdjustmentTransfer.capture(scope: .custom(observed), snapshot: candidate, context: context))
            diffs.append(contentsOf: diffWireValues(before: before, after: after, expectValues: expectValues, untouched: untouched))
            if (expect["status"] as? String) != "changed" {
                diffs.append(.init(key: "status", summary: "status expected=\(expect["status"] as? String ?? "<missing>"), actual=changed"))
            }
        case .unchanged:
            if (expect["status"] as? String) != "unchanged" {
                diffs.append(.init(key: "status", summary: "status expected=\(expect["status"] as? String ?? "<missing>"), actual=unchanged"))
            }
        case .blocked:
            if (expect["status"] as? String) != "blocked" {
                diffs.append(.init(key: "status", summary: "status expected=\(expect["status"] as? String ?? "<missing>"), actual=blocked"))
            }
        }
        return diffs
    }

    static func diffWireValues(
        before: [String: AdjustmentTransferValue],
        after: [String: AdjustmentTransferValue],
        expectValues: [String: AdjustmentTransferValue],
        untouched: [String]
    ) -> [ResetDiff] {
        var diffs = [ResetDiff]()
        for key in expectValues.keys.sorted() {
            let expected = expectValues[key]!
            let actual = after[key]
            if !matchesValue(actual, expected) {
                diffs.append(.init(key: key, summary: "\(key) expected=\(renderValue(expected)), actual=\(renderValue(actual))"))
            }
        }
        for key in untouched where !matchesValue(before[key], after[key]) {
            diffs.append(.init(key: key, summary: "\(key) untouched \(renderValue(before[key])) -> \(renderValue(after[key]))"))
        }
        return diffs
    }

    static func verifyWirePresenceContract() throws {
        check(!matchesValue(nil, .null), "Wire presence contract: missing key must not equal explicit null")
        check(!matchesValue(.null, nil), "Wire presence contract: explicit null must not equal missing key")
        check(matchesValue(.null, .null), "Wire presence contract: explicit null equals explicit null")
        check(matchesValue(nil, nil), "Wire presence contract: missing equals missing")
        let diffs = diffWireValues(
            before: ["geometry.lens.profile_id": .null],
            after: [:],
            expectValues: ["color.white_balance.temperature_kelvin": .null],
            untouched: ["geometry.lens.profile_id"]
        )
        check(diffs.contains { $0.key == "color.white_balance.temperature_kelvin" && $0.summary.contains("expected=null, actual=<missing>") },
              "Wire presence contract: omitted expect key must fail against explicit null")
        check(diffs.contains { $0.key == "geometry.lens.profile_id" && $0.summary.contains("null -> <missing>") },
              "Wire presence contract: dropped untouched null key must fail")
    }

    static func wireValues(_ payload: AdjustmentTransferPayload) throws -> [String: AdjustmentTransferValue] {
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(AdjustmentTransferPayload.self, from: data).values
    }

    static func renderValue(_ value: AdjustmentTransferValue?) -> String {
        guard let value else { return "<missing>" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode([value]), let text = String(data: data, encoding: .utf8),
              text.count >= 2 else { return String(describing: value) }
        return String(text.dropFirst().dropLast())
    }

    static func resetScope(_ scope: [String: Any]) -> EditorAdjustmentScope {
        switch scope["kind"] as! String {
        case "tool":
            switch scope["field"] as! String {
            case "light.contrast": return .tool(.adjustment(.contrast))
            case "detail.sharpening": return .tool(.adjustment(.sharpening))
            case "hdr.peak_limit_ev": return .tool(.hdrPeakLimit)
            default: fatalError("Unsupported single-reset field: \(scope["field"]!)")
            }
        case "group":
            switch scope["group"] as! String {
            case "light": return .group(.light)
            case "color": return .group(.color)
            case "detail": return .group(.detail)
            case "geometry": return .group(.geometry)
            case "hdr_rendition": return .group(.hdrRendition)
            default: fatalError("Unsupported reset group: \(scope["group"]!)")
            }
        case "all": return .all
        default: fatalError("Unsupported reset scope kind: \(scope["kind"]!)")
        }
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
