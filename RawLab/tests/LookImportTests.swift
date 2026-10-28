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
        try writeCube(to: cube)
        let dcpBytes = DCPTestFixtures.make()
        try dcpBytes.write(to: dcp)
        try DCPTestFixtures.make(missing: [50940]).write(to: unsupportedDCP)

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

        let restored = LookImportCoordinator(
            directory: root.appendingPathComponent("library", isDirectory: true),
            delivery: { $0() })
        let loaded = try awaitResult { completion in restored.load(completion: completion) }
        guard case .success(let snapshot) = loaded else {
            throw LookImportTestError.message("managed look startup snapshot failed")
        }
        try check(snapshot.map { $0.record.id } == result.imported.map { $0.record.id } &&
                  snapshot.allSatisfy { manager.fileExists(atPath: $0.url.path) },
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
        print("PASS: iOS look import regression suite")
    }
}
