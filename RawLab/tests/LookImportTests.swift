import RawLabKit
import RawLabNative
import Foundation

private enum LookImportTestError: Error {
    case message(String)
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw LookImportTestError.message(message) }
    print("PASS: \(message)")
}

private func awaitResult<T>(_ start: (@escaping (T) -> Void) -> Void) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    var result: T?
    start {
        result = $0
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + 30) == .success, let result else {
        throw LookImportTestError.message("look import operation timed out")
    }
    return result
}

private func writeCube(to url: URL) throws {
    let values = (0..<8).map { "\($0 & 1) \(($0 >> 1) & 1) \(($0 >> 2) & 1)" }
    let contents = "#Gamma:F-Log2 to Test\n#Gamut:F-Gamut to ITU-R BT.709\nLUT_3D_SIZE 2\n"
        + values.joined(separator: "\n") + "\n"
    try contents.write(to: url, atomically: true, encoding: .utf8)
}

@main
struct LookImportTests {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(
            "rawlab-ios-looks-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let cube = root.appendingPathComponent("Warm custom.cube")
        let dcp = root.appendingPathComponent("Camera custom.dcp")
        let unsupportedDCP = root.appendingPathComponent("Missing curve.dcp")
        let automaticBlackDCP = root.appendingPathComponent("Automatic black.dcp")
        let bothOptionsDCP = root.appendingPathComponent("Missing curve and black.dcp")
        try writeCube(to: cube)
        let dcpBytes = DCPTestFixtures.make()
        try dcpBytes.write(to: dcp)
        try DCPTestFixtures.make(missing: [50940]).write(to: unsupportedDCP)
        try DCPTestFixtures.make(missing: [51110]).write(to: automaticBlackDCP)
        try DCPTestFixtures.make(missing: [50940, 51110]).write(to: bothOptionsDCP)

        let coordinator = LookImportCoordinator(
            directory: root.appendingPathComponent("library", isDirectory: true),
            delivery: { $0() })
        var importCallbackWasMain = true
        let result = try awaitResult { completion in
            coordinator.importLooks(from: [cube, unsupportedDCP, dcp]) { value in
                importCallbackWasMain = Thread.isMainThread
                completion(value)
            }
        }
        try check(!importCallbackWasMain, "look conversion callbacks stay off the main thread")
        try check(result.imported.count == 2, "mixed CUBE/DCP batch keeps every successful look")
        try check(result.imported.last?.record.format == "rlook", "DCP is stored as a managed RLOOK")
        try check(result.failures.count == 1 && result.failures[0].fileName == unsupportedDCP.lastPathComponent,
                  "failed batch reports the source filename")
        try check(result.failures[0].reason == .dcp(.missingToneCurve),
                  "failed batch preserves the typed DCP reason")
        let sourceAfterImport = try Data(contentsOf: dcp)
        try check(sourceAfterImport == dcpBytes, "DCP import preserves the original source bytes")
        try check(result.imported.allSatisfy { manager.fileExists(atPath: $0.url.path) },
                  "successful imports have durable managed files")

        let previousSelection = result.imported.first!.record.id
        try check(LookImportSelection.decision(previousID: previousSelection,
                                               imported: result.imported) == .select(result.imported.last!.record.id),
                  "mixed batch selects the last successful look")
        let failedOnly = try awaitResult { completion in
            coordinator.importLooks(from: [unsupportedDCP], completion: completion)
        }
        try check(failedOnly.imported.isEmpty &&
                  LookImportSelection.decision(previousID: previousSelection,
                                               imported: failedOnly.imported) == .preserve(previousSelection),
                  "all-failed batch preserves the previous selection")
        try check(LookImportSelection.decision(previousID: previousSelection, imported: []) == .preserve(previousSelection),
                  "cancelled batch preserves the previous selection")

        var curveReason: DCPCompilerError?
        let curvePrompted = try awaitResult { completion in
            coordinator.importLooks(from: [unsupportedDCP], dcpOptionsPrompt: { _, reason, reply in
                curveReason = reason
                reply(DCPImportOptions(toneCurveJSON: Data("[[0,0],[1,1]]".utf8)))
            }, completion: completion)
        }
        try check(curveReason == .missingToneCurve, "missing embedded tone opens the DCP options prompt")
        try check(curvePrompted.imported.count == 1 && curvePrompted.failures.isEmpty,
                  "a supplied JSON x/y-pairs curve resumes DCP import")
        var blackReason: DCPCompilerError?
        let blackPrompted = try awaitResult { completion in
            coordinator.importLooks(from: [automaticBlackDCP], dcpOptionsPrompt: { _, reason, reply in
                blackReason = reason
                reply(DCPImportOptions(omitAutomaticBlack: true))
            }, completion: completion)
        }
        try check(blackReason == .automaticBlack, "automatic black opens the DCP options prompt")
        try check(blackPrompted.imported.count == 1 && blackPrompted.failures.isEmpty,
                  "explicitly omitting automatic black resumes DCP import")
        var bothOptionsReason: DCPCompilerError?
        let bothOptionsPrompted = try awaitResult { completion in
            coordinator.importLooks(from: [bothOptionsDCP], dcpOptionsPrompt: { _, reason, reply in
                bothOptionsReason = reason
                reply(DCPImportOptions(toneCurveJSON: Data("[[0,0],[1,1]]".utf8), omitAutomaticBlack: true))
            }, completion: completion)
        }
        try check(bothOptionsReason == .missingToneCurve, "combined DCP options start at the missing-tone prompt")
        try check(bothOptionsPrompted.imported.count == 1 && bothOptionsPrompted.failures.isEmpty,
                  "one DCP options prompt can provide both the curve and black policy")
        var retryPromptCount = 0
        var retryReasons: [DCPCompilerError] = []
        let retriedBothOptions = try awaitResult { completion in
            coordinator.importLooks(from: [bothOptionsDCP], dcpOptionsPrompt: { _, reason, reply in
                retryPromptCount += 1
                retryReasons.append(reason)
                if retryPromptCount == 1 {
                    reply(DCPImportOptions(toneCurveJSON: Data("[[0,0],[1,1]]".utf8)))
                } else {
                    reply(DCPImportOptions(omitAutomaticBlack: true))
                }
            }, completion: completion)
        }
        try check(retryReasons == [.missingToneCurve, .automaticBlack],
                  "combined DCP retry asks for the missing tone then the remaining black policy")
        try check(retryPromptCount == 2 && retriedBothOptions.imported.count == 1 && retriedBothOptions.failures.isEmpty,
                  "a second DCP options prompt preserves the selected curve")
        let cancelledDCP = try awaitResult { completion in
            coordinator.importLooks(from: [automaticBlackDCP], dcpOptionsPrompt: { _, _, reply in
                reply(nil)
            }, completion: completion)
        }
        try check(cancelledDCP.imported.isEmpty && cancelledDCP.failures.isEmpty &&
                  LookImportSelection.decision(previousID: previousSelection, imported: cancelledDCP.imported) == .preserve(previousSelection),
                  "cancelling DCP options keeps the current look selected")

        let restored = LookImportCoordinator(
            directory: root.appendingPathComponent("library", isDirectory: true),
            delivery: { $0() })
        let loaded = try awaitResult { completion in restored.load(completion: completion) }
        guard case .success(let snapshot) = loaded else {
            throw LookImportTestError.message("managed look startup snapshot failed")
        }
        let expectedManagedIDs = (result.imported + curvePrompted.imported + blackPrompted.imported + bothOptionsPrompted.imported + retriedBothOptions.imported).map { $0.record.id }
        try check(snapshot.looks.map { $0.record.id } == expectedManagedIDs &&
                  snapshot.looks.allSatisfy { manager.fileExists(atPath: $0.url.path) },
                  "managed look IDs and files survive a fresh startup snapshot")
        let unknown = root.appendingPathComponent("Unknown.cube")
        try "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n".write(to: unknown, atomically: true, encoding: .utf8)
        var prompts = 0
        let cancelled = try awaitResult { completion in
            coordinator.importLooks(from: [unknown], compatibilityPrompt: { _, _, reply in
                prompts += 1; reply(nil)
            }, completion: completion)
        }
        try check(prompts == 1 && cancelled.imported.isEmpty && cancelled.failures.isEmpty,
                  "cancelling compatibility skips installation without an error")
        try check(LookImportSelection.decision(previousID: previousSelection, imported: cancelled.imported) == .preserve(previousSelection),
                  "cancelled compatibility keeps the current look")
        let confirmed = try awaitResult { completion in
            coordinator.importLooks(from: [cube, unknown], compatibilityPrompt: { _, draft, reply in
                prompts += 1
                var configured = draft
                configured.contract.selectInput("srgb")
                configured.contract.selectOutput("srgb")
                reply(configured)
            }, completion: completion)
        }
        try check(prompts == 2 && confirmed.imported.count == 2 && confirmed.imported.last?.record.isCompatibility == true,
                  "normal import remains silent and a mixed batch resumes after compatibility confirmation")
        let renameTarget = confirmed.imported.last!
        let renameBytes = try Data(contentsOf: renameTarget.url)
        let renamed: Result<ManagedLook, LookImportFailureReason> = try awaitResult { completion in
            coordinator.rename(id: renameTarget.record.id, name: "  My compatible look  ", completion: completion)
        }
        guard case .success(let changed) = renamed else { throw LookImportTestError.message("rename failed") }
        try check(changed.record.name == "My compatible look" && changed.record.id == renameTarget.record.id && changed.record.isCompatibility,
                  "rename changes the display name and preserves look identity and compatibility state")
        let renamedBytes = try Data(contentsOf: changed.url)
        try check(renamedBytes == renameBytes, "renaming never rewrites LUT bytes")
        let libraryDirectory = root.appendingPathComponent("library")
        let registry = libraryDirectory.appendingPathComponent("registry.json")
        let badID = UUID().uuidString
        let badFile = libraryDirectory.appendingPathComponent("\(badID).rlook")
        try Data("future look".utf8).write(to: badFile)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: registry)) as! [String: Any]
        var records = json["looks"] as! [Any]
        let validCount = records.count
        records.append(["id": badID, "name": "Future iOS look", "fileName": "\(badID).rlook",
                        "sourceName": "future.rlook", "format": "rlook", "formatVersion": 99])
        records.append(NSNull())
        json["looks"] = records
        try JSONSerialization.data(withJSONObject: json).write(to: registry)
        let damaged = LookImportCoordinator(directory: libraryDirectory, delivery: { $0() })
        let damagedLoad = try awaitResult { damaged.load(completion: $0) }
        guard case .success(let rows) = damagedLoad else { throw LookImportTestError.message("mixed library cannot load") }
        try check(rows.looks.count == validCount && rows.unreadableLooks.count == 2,
                  "iOS UI snapshot contains unreadable rows alongside valid looks")
        try check(rows.unreadableLooks[0].displayName == "Future iOS look"
                  && rows.unreadableLooks[0].fileName == "\(badID).rlook"
                  && !rows.unreadableLooks[0].reason.isEmpty,
                  "iOS unreadable UI row exposes name, fileName and reason")
        try check(!rows.unreadableLooks[1].displayName.isEmpty, "iOS nameless unreadable row has a fallback")
        let deleted = try awaitResult { damaged.removeUnreadable(rows.unreadableLooks[0], completion: $0) }
        guard case .success(let remaining) = deleted else { throw LookImportTestError.message("unreadable deletion failed") }
        try check(remaining == [rows.unreadableLooks[1]] && !manager.fileExists(atPath: badFile.path),
                  "iOS UI deletion returns refreshed rows and clears corrupt managed file")
        let afterRemoval = LookImportCoordinator(directory: libraryDirectory, delivery: { $0() })
        let restartLoad = try awaitResult { afterRemoval.load(completion: $0) }
        guard case .success(let restartRows) = restartLoad else { throw LookImportTestError.message("restart failed") }
        try check(restartRows.looks.count == validCount && restartRows.unreadableLooks == remaining,
                  "iOS deleted row stays absent after restart while siblings remain")
        let lastDeleted = try awaitResult { afterRemoval.removeUnreadable(remaining[0], completion: $0) }
        guard case .success(let empty) = lastDeleted else { throw LookImportTestError.message("last deletion failed") }
        try check(empty.isEmpty, "iOS all unreadable UI rows can be removed")
        let customRemoved: Result<Void, LookImportFailureReason> = try awaitResult {
            afterRemoval.remove(id: renameTarget.record.id, completion: $0)
        }
        guard case .success = customRemoved else { throw LookImportTestError.message("custom look removal failed") }
        let postDeleteLoad = try awaitResult { afterRemoval.load(completion: $0) }
        guard case .success(let postDeleteRows) = postDeleteLoad else { throw LookImportTestError.message("post-delete reload failed") }
        try check(!postDeleteRows.looks.contains { $0.record.id == renameTarget.record.id } && !manager.fileExists(atPath: changed.url.path),
                  "removing a custom look deletes it from LookLibrary and storage")
        print("PASS: iOS look import regression suite")
    }
}
