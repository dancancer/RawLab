import Foundation

private var failures = 0
private func check(_ value: Bool, _ label: String) {
    print("\(value ? "PASS" : "FAIL") \(label)")
    if !value { failures += 1 }
}

private func rejects(_ label: String, _ action: () throws -> Void) {
    do { try action(); check(false, label) }
    catch { check(true, label) }
}

private func cube(at url: URL, tagged: Bool = true) throws {
    let header = tagged ? "#Gamma:F-Log2 to Test\n#Gamut:F-Gamut to ITU-R BT.709\n" : ""
    let values = (0..<8).map { "\($0 & 1) \(($0 >> 1) & 1) \(($0 >> 2) & 1)" }
    try (header + "LUT_3D_SIZE 2\n" + values.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
}

private func rlook(at url: URL) throws {
    var data = Data("RLOOKDCP".utf8)
    func append<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    for value: UInt32 in [1, 0, 0, 2, 2, 2, 4097, 2] { append(value) }
    for _ in 0..<2 {
        for i in 0..<9 { append((i % 4 == 0 ? 1.0 : 0.0).bitPattern) }
    }
    append(1.0.bitPattern)
    for _ in 0..<8 {
        for value: Float in [0, 1, 1] { append(value.bitPattern) }
    }
    for i in 0...4096 { append((Double(i) / 4096).bitPattern) }
    data.append(contentsOf: "{}".utf8)
    try data.write(to: url)
}

@main
struct LookLibraryTests {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("rawlab-looks-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let source = root.appendingPathComponent("A long imported look.cube")
        try cube(at: source)
        let original = try Data(contentsOf: source)
        let directory = root.appendingPathComponent("library", isDirectory: true)
        let library = try LookLibrary(directory: directory)
        check(library.looks.isEmpty, "new library starts empty without a registry")
        let first = try library.importLook(from: source)
        let second = try library.importLook(from: source)
        check(first.id != second.id && library.url(for: first) != library.url(for: second), "same-name imports cannot overwrite each other")
        check(first.name == "A long imported look" && first.format == "cube" && first.formatVersion == 0, "import uses native validation and preserves display metadata")
        check(try Data(contentsOf: source) == original, "import preserves source bytes")
        check(try Data(contentsOf: library.url(for: first)) == original, "library owns an exact managed copy")
        try manager.removeItem(at: source)
        let restored = try LookLibrary(directory: directory)
        check(restored.looks.map(\.id) == library.looks.map(\.id), "library IDs and order survive restart after original removal")
        check(manager.fileExists(atPath: restored.url(for: first).path), "restart does not depend on the original path")

        for (input, gamut) in [("F-Log", "F-Gamut"), ("F-Log2", "F-Gamut"), ("F-Log2C", "F-GamutC")] {
            for output in ["ETERNA", input] {
                let fuji = root.appendingPathComponent("\(input)-\(output).cube")
                let header = "#Gamma:\(input) to \(output)\n#Gamut:\(gamut) to ITU-R BT.709\nLUT_3D_SIZE 2\n"
                try (header + Array(repeating: "0.4 0.4 0.4\n", count: 8).joined()).write(to: fuji, atomically: true, encoding: .utf8)
                let bytes = try Data(contentsOf: fuji)
                let item = try restored.importLook(from: fuji)
                check(item.format == "cube" && item.formatVersion == 0, "Fuji display and technical contracts import via native validation")
                try manager.removeItem(at: fuji)
                let reloaded = try LookLibrary(directory: directory)
                check(reloaded.looks.contains { $0.id == item.id }, "Fuji import registry survives restart")
                check(try Data(contentsOf: reloaded.url(for: item)) == bytes, "Fuji managed bytes survive original deletion")
                try restored.remove(id: item.id)
            }
        }

        try restored.rename(id: first.id, to: "  My renamed look  ")
        let renamed = try LookLibrary(directory: directory)
        check(renamed.looks.first?.name == "My renamed look" && renamed.looks.first?.id == first.id, "rename persists without changing identity")
        rejects("blank rename preserves library") { try renamed.rename(id: first.id, to: " \n ") }
        check(try LookLibrary(directory: directory).looks.first?.name == "My renamed look", "failed rename keeps the saved name")

        let untagged = root.appendingPathComponent("untagged.cube")
        try cube(at: untagged, tagged: false)
        let beforeNames = try manager.contentsOfDirectory(atPath: directory.path).sorted()
        rejects("untagged look is rejected before installation") { _ = try renamed.importLook(from: untagged) }
        do { _ = try renamed.importLook(from: untagged); check(false, "missing color is diagnosed") }
        catch { check(error.localizedDescription.contains("缺少输入或输出颜色信息"), "missing color is distinct from a damaged file") }
        check(try manager.contentsOfDirectory(atPath: directory.path).sorted() == beforeNames, "failed validation leaves no staged files or index entries")
        if var compatibility = try LUTCompatibility.inspect(untagged) {
            check(!compatibility.canImport, "unknown input and output require a user choice")
            check(compatibility.candidates?.count == 10, "Swift preserves native hypotheses without selecting one")
            if let candidate = compatibility.candidates?.first {
                let photo = compatibility.applying(candidate, displayInput: false)
                let raster = compatibility.applying(candidate, displayInput: true)
                check(photo?.contract.baseRendering == "rawlab-neutral-v1" && raster?.contract.baseRendering == "source-display",
                      "Candidate bases follow the preview source without inventing camera rendering")
                let previewJSON = try JSONSerialization.jsonObject(with: Data(try photo!.previewRequest().utf8)) as! [String: Any]
                check(previewJSON["confirmed"] == nil && previewJSON.count == 2, "Preview requests carry no import confirmation")
            }
            if let log = compatibility.candidates?.first(where: { $0.contract.input.reference == "scene" }) {
                check(compatibility.applying(log, displayInput: true) == nil, "Raster photos cannot preview a scene Log hypothesis")
            }
            var conditions = LUTReferenceConditions()
            check(!conditions.canCompare, "Reference metrics start unavailable")
            conditions.sameSource = true; conditions.sameGeometry = true; conditions.sameProcessing = true; conditions.knownSRGB = true
            check(!conditions.canCompare, "Reference metrics need provenance as well as matching conditions")
            conditions.referenceSource = "Independent renderer, same source, EV 0, as-shot WB, LUT 100%, sRGB"
            check(conditions.canCompare, "Explicit matching conditions enable descriptive comparison")
            compatibility.contract.selectInput("srgb")
            compatibility.contract.selectOutput("srgb")
            check(compatibility.canImport, "explicit display choices produce a complete compatibility draft")
            check(try manager.contentsOfDirectory(atPath: directory.path).sorted() == beforeNames, "inspecting or cancelling a compatibility draft installs nothing")
            let original = try Data(contentsOf: untagged)
            let imported = try renamed.importLook(from: untagged, compatibility: compatibility)
            check(imported.isCompatibility && imported.colorState == "approximate-base", "confirmed neutral-base import carries the compatibility badge state")
            check(try Data(contentsOf: untagged) == original, "compatibility never modifies the original LUT")
            check(try Data(contentsOf: renamed.url(for: imported)).starts(with: original), "managed compatibility asset preserves original bytes")
            rejects("reimporting a compatibility file requires another explicit confirmation") {
                _ = try renamed.importLook(from: renamed.url(for: imported))
            }
            let reopened = try LookLibrary(directory: directory)
            check(reopened.looks.first(where: { $0.id == imported.id })?.isCompatibility == true, "compatibility badge survives restart")
            try renamed.remove(id: imported.id)
        } else { check(false, "untagged valid CUBE offers compatibility") }
        let vlt = root.appendingPathComponent("Documented.vlt")
        let contract = #"{"version":1,"input":{"space":"vlog-vgamut","reference":"scene","range":"full"},"output":{"space":"srgb","reference":"display","range":"full"},"interpolation":"linear","base_rendering":"none","evidence":{"source":"Synthetic reference","conditions":"Black identity fixture"}}"#
        let vltText = "# panasonic vlt file version 1.0\n# source vlt file \"\"\nLUT_3D_SIZE 17\n\n" +
            Array(repeating: "0 0 0\n", count: 4913).joined() + "#RawLabColorContract:\(contract)\n"
        try vltText.write(to: vlt, atomically: true, encoding: .utf8)
        do {
            let imported = try renamed.importLook(from: vlt)
            check(imported.format == "vlt" && imported.formatVersion == 1, "VLT retains its format and original sampling")
            check(try Data(contentsOf: renamed.url(for: imported)) == Data(contentsOf: vlt), "VLT stores original table and color evidence together")
            let persisted = try String(contentsOf: directory.appendingPathComponent("registry.json"), encoding: .utf8)
            check(persisted.contains("declared-unverified"), "declared color evidence is not persisted as verified appearance")
            let restart = try LookLibrary(directory: directory)
            check(restart.looks.contains { $0.id == imported.id }, "VLT and its status survive restart")
            try renamed.remove(id: imported.id)
        } catch { check(false, "documented VLT imports successfully: \(error)") }
        let invalid = root.appendingPathComponent("bad.rlook")
        try Data("not a profile".utf8).write(to: invalid)
        rejects("malformed native profile cannot enter library") { _ = try renamed.importLook(from: invalid) }
        let native = root.appendingPathComponent("Native.rlook")
        try rlook(at: native)
        let nativeBefore = try Data(contentsOf: native)
        let importedNative = try renamed.importLook(from: native)
        check(importedNative.format == "rlook" && importedNative.formatVersion == 1, "native RLOOK import records validated version")
        try renamed.remove(id: importedNative.id)
        let nativeAfterRemoval = try Data(contentsOf: native)
        check(!manager.fileExists(atPath: renamed.url(for: importedNative).path) && nativeAfterRemoval == nativeBefore, "delete removes only managed content, not source")
        check(!(try LookLibrary(directory: directory)).looks.contains { $0.id == importedNative.id }, "deletion survives restart")

        try manager.removeItem(at: renamed.url(for: second))
        let missing = try LookLibrary(directory: directory)
        check(missing.looks.contains { $0.id == second.id }, "missing stored file retains a removable record")
        try missing.remove(id: second.id)
        check(!(try LookLibrary(directory: directory)).looks.contains { $0.id == second.id }, "missing record can be removed without deleting other files")

        let rollbackDirectory = root.appendingPathComponent("rollback", isDirectory: true)
        let rollback = try LookLibrary(directory: rollbackDirectory)
        try manager.createDirectory(at: rollbackDirectory.appendingPathComponent("registry.json"), withIntermediateDirectories: true)
        rejects("failed index installation rolls back imported bytes") { _ = try rollback.importLook(from: native) }
        let remaining = try manager.contentsOfDirectory(atPath: rollbackDirectory.path)
        check(rollback.looks.isEmpty && remaining == ["registry.json"], "registry failure leaves library unchanged")

        let brokenDirectory = root.appendingPathComponent("broken", isDirectory: true)
        try manager.createDirectory(at: brokenDirectory, withIntermediateDirectories: true)
        let brokenRegistry = brokenDirectory.appendingPathComponent("registry.json")
        let brokenBytes = Data("{broken registry".utf8)
        try brokenBytes.write(to: brokenRegistry)
        rejects("corrupt registry is reported rather than replaced with empty state") { _ = try LookLibrary(directory: brokenDirectory) }
        check(try Data(contentsOf: brokenRegistry) == brokenBytes, "corrupt registry remains available for recovery")

        // P2-16 “1 坏 + 2 好”：单条目损坏只降级这一条，原文保留并可精确删除。
        let mixedDirectory = root.appendingPathComponent("mixed-looks", isDirectory: true)
        try manager.createDirectory(at: mixedDirectory, withIntermediateDirectories: true)
        let mixed = try LookLibrary(directory: mixedDirectory)
        let keepNative = try mixed.importLook(from: native)
        let mixedCube = root.appendingPathComponent("mixed-a.cube")
        try cube(at: mixedCube)
        let keepCube = try mixed.importLook(from: mixedCube)
        let mixedRegistry = mixedDirectory.appendingPathComponent("registry.json")
        let badEntry = #"{"color_state":null,"file_name":"mismatch.cube","format":"cube","format_version":0,"id":"7C9E1B12-45A5-4E2F-9C3D-1B2A3C4D5E6F","name":"Bad look","source_name":"bad.cube"}"#
        try String(contentsOf: mixedRegistry, encoding: .utf8)
            .replacingOccurrences(of: "\"looks\" : [\n", with: "\"looks\" : [\n    " + badEntry + ",\n")
            .write(to: mixedRegistry, atomically: true, encoding: .utf8)
        let reloadedMixed = try LookLibrary(directory: mixedDirectory)
        check(reloadedMixed.looks.map(\.id) == [keepNative.id, keepCube.id], "one bad look never blocks the readable looks")
        check(reloadedMixed.unreadableLooks.count == 1
              && reloadedMixed.unreadableLooks[0].id == "7C9E1B12-45A5-4E2F-9C3D-1B2A3C4D5E6F"
              && reloadedMixed.unreadableLooks[0].fileName == "mismatch.cube",
              "bad look is kept as an unreadable record with identity")
        try reloadedMixed.rename(id: keepNative.id, to: "Renamed survivor")
        check(try String(contentsOf: mixedRegistry, encoding: .utf8).contains(badEntry), "rename passes the unreadable look record through unchanged")
        let badRecord = reloadedMixed.unreadableLooks[0]
        try reloadedMixed.remove(badRecord)
        let afterRemoval = try String(contentsOf: mixedRegistry, encoding: .utf8)
        let survivorIDs = try LookLibrary(directory: mixedDirectory).looks.map(\.id)
        check(!afterRemoval.contains(badEntry) && survivorIDs == [keepNative.id, keepCube.id],
              "bad look can be removed and the library keeps the readable looks")
        rejects("already removed bad look needs a fresh confirmation") { try reloadedMixed.remove(badRecord) }

        // 红锚点 B3：坏条目的 file_name 可能恰好指向存活文件——删除前须校验安全路径与文件归属。
        let ownershipDirectory = root.appendingPathComponent("ownership-looks", isDirectory: true)
        try manager.createDirectory(at: ownershipDirectory, withIntermediateDirectories: true)
        let ownership = try LookLibrary(directory: ownershipDirectory)
        let ownedSource = root.appendingPathComponent("owned.cube")
        try cube(at: ownedSource)
        let owned = try ownership.importLook(from: ownedSource)
        let orphanName = "11111111-2222-3333-4444-555555555555.cube"
        try Data("orphan".utf8).write(to: ownershipDirectory.appendingPathComponent(orphanName))
        // r2 红锚点 B3/S5：APFS 默认大小写不敏感——坏条目 file_name 的大小写变体指向同一实体
        // 文件，归属判重必须折叠大小写（Windows #314 同用 OrdinalIgnoreCase）；共享文件只在
        // 最后一条引用删除后清理；非 UUID 遗留名、同名目录与 registry 自身不得被顺带删除。
        let sharedName = "9f1e2d3c-4b5a-4678-9abc-def012345678.cube"
        let dirName = "5a4b3c2d-1e6f-4789-abcd-ef0123456789.cube"
        try Data("shared".utf8).write(to: ownershipDirectory.appendingPathComponent(sharedName))
        try Data("legacy".utf8).write(to: ownershipDirectory.appendingPathComponent("legacy.cube"))
        try manager.createDirectory(at: ownershipDirectory.appendingPathComponent(dirName), withIntermediateDirectories: true)
        let ownedRegistry = ownershipDirectory.appendingPathComponent("registry.json")
        func ghostEntry(_ fileName: String, _ id: String, _ name: String) -> String {
            #"{"file_name":"\#(fileName)","format":"cube","format_version":0,"id":"\#(id)","name":"\#(name)","source_name":"\#(name).cube"}"#
        }
        let ghostBlock = [
            ghostEntry(owned.fileName, "7C9E1B12-45A5-4E2F-9C3D-1B2A3C4D5E6F", "Shadow"),
            ghostEntry(orphanName, "8D9F2C23-56B7-4F8A-9E10-213243546576", "Orphan"),
            ghostEntry("\(owned.id).CUBE", "7E0A3D34-67C8-409B-8F21-324354657687", "UpperExt"),
            ghostEntry("\(owned.id.lowercased()).cube", "6D1B4E45-78D9-4A0C-9032-435465768798", "LowerUUID"),
            ghostEntry(sharedName, "5C2C5F56-89EA-4B1D-8143-546576879809", "TwinA"),
            ghostEntry(sharedName, "4B3D6067-9AFB-4C2E-9254-657687980910", "TwinB"),
            ghostEntry("legacy.cube", "3A4E7178-AB0C-4D3F-8365-768798091021", "Legacy"),
            ghostEntry(dirName, "295F8289-BC1D-4E40-9476-879809102132", "DirGhost"),
            ghostEntry("registry.json", "1860939A-CD2E-4F51-8587-980910213243", "Registryish"),
            ghostEntry("../owned.cube", "0771A4AB-DE3F-4052-9698-091021324354", "Escape"),
        ].map { "    " + $0 + ",\n" }.joined()
        try String(contentsOf: ownedRegistry, encoding: .utf8)
            .replacingOccurrences(of: "\"looks\" : [\n", with: "\"looks\" : [\n" + ghostBlock)
            .write(to: ownedRegistry, atomically: true, encoding: .utf8)
        let ownedLibrary = try LookLibrary(directory: ownershipDirectory)
        func ghost(_ name: String) -> LookLibrary.UnreadableLook? {
            ownedLibrary.unreadableLooks.first { $0.json.contains("\"name\":\"\(name)\"") }
        }
        if let shadow = ghost("Shadow"), let orphan = ghost("Orphan"), let upperExt = ghost("UpperExt"),
           let lowerUUID = ghost("LowerUUID"), let twinA = ghost("TwinA"), let twinB = ghost("TwinB"),
           let legacy = ghost("Legacy"), let dirGhost = ghost("DirGhost"),
           let registryish = ghost("Registryish"), let escape = ghost("Escape") {
            check(ownedLibrary.looks.map(\.id) == [owned.id] && ownedLibrary.unreadableLooks.count == 10,
                  "ownership scenario keeps the valid look and all ten ghosts")
            try ownedLibrary.remove(shadow)
            check(manager.fileExists(atPath: ownedLibrary.url(for: owned).path),
                  "removing a bad entry whose file_name shadows a live look keeps the managed file")
            try ownedLibrary.remove(upperExt)
            check(manager.fileExists(atPath: ownedLibrary.url(for: owned).path),
                  "removing a ghost whose file_name only differs in extension case keeps the managed file")
            try ownedLibrary.remove(lowerUUID)
            check(manager.fileExists(atPath: ownedLibrary.url(for: owned).path),
                  "removing a ghost whose file_name only differs in UUID case keeps the managed file")
            try ownedLibrary.remove(twinA)
            check(manager.fileExists(atPath: ownershipDirectory.appendingPathComponent(sharedName).path),
                  "removing the first ghost sharing a managed name keeps the file for the twin")
            try ownedLibrary.remove(twinB)
            check(!manager.fileExists(atPath: ownershipDirectory.appendingPathComponent(sharedName).path),
                  "the last ghost sharing a managed name cleans the orphaned file")
            try ownedLibrary.remove(legacy)
            check(manager.fileExists(atPath: ownershipDirectory.appendingPathComponent("legacy.cube").path),
                  "a real non-UUID managed-style file is left to the user")
            try ownedLibrary.remove(dirGhost)
            check(manager.fileExists(atPath: ownershipDirectory.appendingPathComponent(dirName).path),
                  "a directory wearing a managed file name is never moved or deleted")
            try ownedLibrary.remove(registryish)
            check(manager.fileExists(atPath: ownedRegistry.path), "removing a ghost never deletes the registry itself")
            try ownedLibrary.remove(escape)
            check(ownedLibrary.looks.map(\.id) == [owned.id] && ownedLibrary.unreadableLooks.count == 1
                  && manager.fileExists(atPath: ownedSource.path),
                  "a traversing file_name is dropped from the registry and touches no file")
            try ownedLibrary.remove(orphan)
            check(!manager.fileExists(atPath: ownershipDirectory.appendingPathComponent(orphanName).path),
                  "removing a bad entry with its own UUID file still cleans that file")
            check(ownedLibrary.looks.map(\.id) == [owned.id] && ownedLibrary.unreadableLooks.isEmpty
                  && manager.fileExists(atPath: ownedLibrary.url(for: owned).path),
                  "ownership ghosts delete independently and keep the library readable")
        } else {
            check(false, "ownership scenario exposes every ghost")
        }

        let recoveryDirectory = root.appendingPathComponent("recovery", isDirectory: true)
        let recovering = try LookLibrary(directory: recoveryDirectory)
        let interrupted = try recovering.importLook(from: native)
        let stagedRemoval = recoveryDirectory.appendingPathComponent(".remove-\(interrupted.fileName)")
        try manager.moveItem(at: recovering.url(for: interrupted), to: stagedRemoval)
        let beforeCommit = try LookLibrary(directory: recoveryDirectory)
        check(manager.fileExists(atPath: beforeCommit.url(for: interrupted).path) &&
              !manager.fileExists(atPath: stagedRemoval.path), "restart restores a removal interrupted before registry commit")
        if manager.fileExists(atPath: beforeCommit.url(for: interrupted).path) {
            try manager.moveItem(at: beforeCommit.url(for: interrupted), to: stagedRemoval)
        }
        let recoveryRegistry = recoveryDirectory.appendingPathComponent("registry.json")
        var registry = try JSONSerialization.jsonObject(with: Data(contentsOf: recoveryRegistry)) as! [String: Any]
        registry["looks"] = []
        try JSONSerialization.data(withJSONObject: registry).write(to: recoveryRegistry, options: .atomic)
        let unrelated = recoveryDirectory.appendingPathComponent(".remove-personal.cube")
        try Data("unrelated".utf8).write(to: unrelated)
        let afterCommit = try LookLibrary(directory: recoveryDirectory)
        check(afterCommit.looks.isEmpty && !manager.fileExists(atPath: stagedRemoval.path), "restart finishes a removal whose registry commit already succeeded")
        check(manager.fileExists(atPath: unrelated.path), "removal recovery ignores files without a managed UUID")

        // r2 红锚点 B3：大小写不敏感卷上 `.remove-<小写id>.cube` 属于存活条目 `<大写id>.cube`，
        // 重启必须恢复而非按「无主」删除。
        let caseDirectory = root.appendingPathComponent("recovery-case", isDirectory: true)
        let caseRecovering = try LookLibrary(directory: caseDirectory)
        let caseLook = try caseRecovering.importLook(from: native)
        try manager.moveItem(at: caseRecovering.url(for: caseLook),
                             to: caseDirectory.appendingPathComponent(".remove-\(caseLook.fileName.lowercased())"))
        let caseRestored = try LookLibrary(directory: caseDirectory)
        check(caseRestored.looks.map(\.id) == [caseLook.id]
              && manager.fileExists(atPath: caseRestored.url(for: caseLook).path),
              "restart restores a staged removal whose name differs in case from the live entry")

        let dcpSource = root.appendingPathComponent("My camera look.DCP")
        let dcpBytes = DCPTestFixtures.make()
        try dcpBytes.write(to: dcpSource)
        let dcpDirectory = root.appendingPathComponent("dcp-library")
        try manager.createDirectory(at: dcpDirectory, withIntermediateDirectories: true)
        let dcpLibrary = try LookLibrary(directory: dcpDirectory)
        do {
            let converted = try dcpLibrary.importLook(from: dcpSource)
            let duplicate = try dcpLibrary.importLook(from: dcpSource)
            check(converted.name == "My camera look" && converted.sourceName == "My camera look.DCP", "DCP import preserves the original name and provenance")
            check(converted.format == "rlook" && converted.formatVersion == 1 && converted.fileName == "\(converted.id).rlook", "DCP is stored as validated RLOOK, not renamed DCP bytes")
            check(converted.id != duplicate.id, "same-name DCP imports have independent managed files")
            let compiled = try Data(contentsOf: dcpLibrary.url(for: converted))
            check(compiled.starts(with: Data("RLOOKDCP".utf8)), "DCP managed copy contains native RLOOK stages")
            check(try Data(contentsOf: dcpSource) == dcpBytes, "conversion never rewrites the original DCP")
            try manager.removeItem(at: dcpSource)
            let dcpRestored = try LookLibrary(directory: dcpDirectory)
            check(dcpRestored.looks == dcpLibrary.looks && manager.fileExists(atPath: dcpRestored.url(for: converted).path), "converted looks survive restart and source deletion")
            let noLook = root.appendingPathComponent("No table.dcp")
            try DCPTestFixtures.make(missing: [50981, 50982]).write(to: noLook)
            check(try dcpRestored.importLook(from: noLook).formatVersion == 2, "DCP without LookTable is installed as RLOOK v2")
        } catch { check(false, "supported DCP imports automatically: \(error.localizedDescription)") }

        let unsupported = root.appendingPathComponent("Missing tone.dcp")
        try DCPTestFixtures.make(missing: [50940]).write(to: unsupported)
        let saved = dcpLibrary.looks
        let beforeFailure = try manager.contentsOfDirectory(atPath: dcpDirectory.path).sorted()
        do { _ = try dcpLibrary.importLook(from: unsupported); check(false, "unsupported DCP is rejected") }
        catch let error as DCPCompilerError { check(error == .missingToneCurve, "unsupported DCP exposes its specific missing-curve reason") }
        catch { check(false, "unsupported DCP must not be flattened into generic invalid-look error") }
        let afterFailure = try manager.contentsOfDirectory(atPath: dcpDirectory.path).sorted()
        check(dcpLibrary.looks == saved && afterFailure == beforeFailure,
              "failed DCP conversion leaves no staging files or registry changes")
        try DCPTestFixtures.make().write(to: dcpSource)
        rejects("failed DCP index installation rolls back converted bytes") { _ = try rollback.importLook(from: dcpSource) }
        check(try manager.contentsOfDirectory(atPath: rollbackDirectory.path) == ["registry.json"], "DCP index failure leaves no converted file behind")

        if failures != 0 { exit(1) }
    }
}
