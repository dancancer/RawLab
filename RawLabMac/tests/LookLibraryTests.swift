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
        check(try manager.contentsOfDirectory(atPath: directory.path).sorted() == beforeNames, "failed validation leaves no staged files or index entries")
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

        if failures != 0 { exit(1) }
    }
}
