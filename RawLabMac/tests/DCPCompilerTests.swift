import Foundation

@main
struct DCPCompilerTests {
    static func main() throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--fixtures" {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try DCPTestFixtures.make().write(to: directory.appendingPathComponent("Supported camera look.dcp"))
            try DCPTestFixtures.make(missing: [50940]).write(to: directory.appendingPathComponent("Missing tone.dcp"))
            try DCPTestFixtures.make(missing: [51110]).write(to: directory.appendingPathComponent("Auto black.dcp"))
            return
        }
        if CommandLine.arguments.count == 3 {
            do {
                let source = URL(fileURLWithPath: CommandLine.arguments[1])
                let output = try DCPCompiler.compile(source: source)
                try output.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(2)
            }
            return
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL") \(label)")
            if !condition { failures += 1 }
        }
        func rejects(_ data: Data, reason: DCPCompilerError, _ label: String) {
            do { _ = try DCPCompiler.compile(data: data, sourceName: "test.dcp"); check(false, label) }
            catch let error as DCPCompilerError { check(error == reason, label) }
            catch { check(false, "\(label): \(error)") }
        }
        for bigEndian in [false, true] {
            let output = try DCPCompiler.compile(data: DCPTestFixtures.make(bigEndian: bigEndian), sourceName: "test.dcp")
            check(output.starts(with: Data("RLOOKDCP".utf8)), "native compiler produces RLOOK for both byte orders")
            check(output[8] == 1 && output.count < 64 * 1024 * 1024, "look-only profiles retain v1 format and bounded output")
            check(output.range(of: Data("test.dcp".utf8)) != nil, "compiled file records its original source name")
        }
        rejects(DCPTestFixtures.make(missing: [50940]), reason: .missingToneCurve, "missing tone is not inferred as identity")
        rejects(DCPTestFixtures.make(missing: [51110]), reason: .automaticBlack, "missing black policy is Adobe Auto, not None")
        rejects(DCPTestFixtures.make(override: [51110: DCPTestFixtures.uint32(0)]), reason: .automaticBlack, "explicit automatic black is unsupported")
        rejects(DCPTestFixtures.make(missing: [50965]), reason: .invalidCalibration, "missing ForwardMatrix is explained")
        rejects(DCPTestFixtures.make(missing: [50779]), reason: .invalidCalibration, "D65 must be explicit")
        rejects(DCPTestFixtures.make(override: [52539: DCPTestFixtures.uint32(1)]), reason: .unsupportedStages, "unsupported HDR stage is explained")
        rejects(DCPTestFixtures.make(override: [52537: DCPTestFixtures.uint32(1)]), reason: .tripleIlluminant, "triple HSM is unsupported")
        rejects(DCPTestFixtures.make(override: [51108: DCPTestFixtures.uint32(2)]), reason: .invalidTable, "unknown HSV encoding is explained")
        rejects(Data("not a DCP".utf8), reason: .malformed, "malformed header is rejected without a trap")
        let valid = DCPTestFixtures.make()
        for length in [0, 7, 8, 10, valid.count - 1] {
            rejects(Data(valid.prefix(length)), reason: .malformed, "truncated DCP is rejected")
        }
        let nearlySingular = DCPTestFixtures.rationals([(1, 1), (1, 1), (0, 1),
            (50000001, 50000000), (50000002, 50000001), (0, 1), (0, 1), (0, 1), (1, 1)])
        rejects(DCPTestFixtures.make(override: [50722: nearlySingular]), reason: .invalidCalibration,
                "near-singular ColorMatrix is rejected consistently with the reference")
        rejects(DCPTestFixtures.overlappingRationals(), reason: .tooLarge,
                "overlapping Rational payloads cannot multiply parser work beyond source size")
        let stageOnly = try DCPCompiler.compile(data: DCPTestFixtures.make(missing: [50981, 50982]), sourceName: "matrix.dcp")
        check(stageOnly[8] == 2, "absent look table uses existing v2 format")
        if failures > 0 { exit(1) }
    }
}
