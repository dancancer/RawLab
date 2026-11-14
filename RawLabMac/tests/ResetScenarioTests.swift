import Foundation

/// V-RESET：macOS 消费共享重置场景向量 `reset-scenarios-v1.json`。
/// 种子经 `MacAdjustmentTransfer.prepare` 写入，重置走生产入口
/// `EditorAdjustmentRules.prepareReset`，观察通道复用 `MacAdjustmentTransfer.capture` 的
/// wire JSON 序列化值；不再本地解析 `@spec_default`，真实序列化分歧显式登记进
/// `knownResetDivergences`。
@main
struct ResetScenarioTests {
    struct ResetDiff {
        let key: String
        let summary: String
    }

    struct ResetDivergence {
        let ledgerId: String
        let reason: String
        let expectedKeys: Set<String>
    }

    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        print("PASS: \(message)")
    }

    static func state(_ settings: Adjustments = Adjustments(), film: String = "") -> PhotoEditState {
        PhotoEditState(settings: settings, filmID: film, masterRecipeID: settings.masterRecipeID)
    }

    /// 显式例外清单：未登记的分歧或清单外字段差异必红；已修复仍留档也必红（棘轮只减不增）。
    static let knownResetDivergences: [String: ResetDivergence] = [
        "all-reset-raw": ResetDivergence(
            ledgerId: "P2-23",
            reason: "Mac SDR Adjustments resets chromaNoiseReduction and waveletNoiseReduction to nil (wire null), whereas iOS/Android/Windows serialize 0 and the disabled wavelet object.",
            expectedKeys: ["detail.denoise.chroma_mode", "detail.denoise.wavelet"]
        ),
        "group-reset-detail-raw": ResetDivergence(
            ledgerId: "P2-23",
            reason: "Mac detail-group reset clears chromaNoiseReduction and waveletNoiseReduction to nil (wire null), whereas iOS/Android/Windows serialize 0 and the disabled wavelet object.",
            expectedKeys: ["detail.denoise.chroma_mode", "detail.denoise.wavelet"]
        ),
    ]

    static func main() throws {
        try resetScenarioFixtures()
    }

    static func resetScenarioFixtures() throws {
        let url = URL(fileURLWithPath: "Shared/fixtures/reset-scenarios-v1.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        check(root["fixture_version"] as? Int == 1, "Reset fixture version is 1")
        let scenarios = root["scenarios"] as! [[String: Any]]
        var ids = Set<String>()
        var evaluated = Set<String>()
        var problems = [String]()
        for scenario in scenarios {
            let id = scenario["id"] as! String
            check(ids.insert(id).inserted, "Unique scenario ID: \(id)")
            if let platforms = scenario["platforms"] as? [String], !platforms.contains("macos") { continue }
            evaluated.insert(id)
            let diffs = try evaluate(id, scenario)
            let actualKeys = Set(diffs.map(\.key))
            let summary = diffs.map(\.summary).joined(separator: "; ")
            if let known = knownResetDivergences[id] {
                if diffs.isEmpty {
                    problems.append("Scenario \(id) now matches fixture; remove stale divergence (\(known.ledgerId): \(known.reason))")
                } else if actualKeys != known.expectedKeys {
                    problems.append("Scenario \(id) divergence keys changed (expected=\(known.expectedKeys.sorted()), actual=\(actualKeys.sorted())): \(summary)")
                } else {
                    print("KNOWN DIVERGENCE [\(id)] (\(known.ledgerId) - \(known.reason)): \(summary)")
                }
            } else if !diffs.isEmpty {
                problems.append("Scenario \(id) diverged: \(summary)")
            }
        }
        check(evaluated.count == scenarios.count, "macOS evaluates every scenario including hdr_rendition")
        check(Set(knownResetDivergences.keys).isSubset(of: evaluated), "no stale knownResetDivergences entries")
        if !problems.isEmpty { fatalError(problems.joined(separator: "\n")) }
        print("PASS: \(evaluated.count) macOS reset scenarios evaluated (0 platform-scoped skipped, \(knownResetDivergences.count) registered divergences)")
    }

    static func evaluate(_ id: String, _ scenario: [String: Any]) throws -> [ResetDiff] {
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
        let resetContext = EditorAdjustmentContext(isRaw: kind == "sdr_raw",
            defaultExposureMode: kind == "sdr_raw" ? .preview : .sensor, neutralFilmID: "")
        let expect = scenario["expect"] as! [String: Any]
        let expectValuesRaw = expect["values"] as! [String: Any]
        let untouched = expect["untouched"] as! [String]
        var observed = Set<AdjustmentTransferField>()
        for key in expectValuesRaw.keys { observed.insert(AdjustmentTransferField(rawValue: key)!) }
        for key in untouched { observed.insert(AdjustmentTransferField(rawValue: key)!) }

        var diffs = [ResetDiff]()
        let before = observed.isEmpty ? [:] : try wireValues(MacAdjustmentTransfer.capture(scope: .custom(observed), snapshot: seeded, context: context))
        let expectValues = try JSONDecoder().decode([String: AdjustmentTransferValue].self,
            from: JSONSerialization.data(withJSONObject: expectValuesRaw))
        switch EditorAdjustmentRules.prepareReset(scope: scope, snapshot: seeded, context: resetContext) {
        case .candidate(let candidate):
            let after = observed.isEmpty ? [:] : try wireValues(MacAdjustmentTransfer.capture(scope: .custom(observed), snapshot: candidate, context: context))
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

    static func resetScope(_ scope: [String: Any]) throws -> EditorResetScope {
        switch scope["kind"] as! String {
        case "tool":
            switch scope["field"] as! String {
            case "light.contrast": return .tool(.contrast)
            case "detail.sharpening": return .tool(.sharpening)
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
