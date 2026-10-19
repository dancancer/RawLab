import Foundation

enum BatchSourceJournalTests {
    private struct LegacySnapshot: Codable {
        let identity: PhotoIdentity
        let sourceURL: URL
        let displayName: String
        let sourceKind: BatchSourceKind
        let settings: RawSettings
        let lookURL: URL?
        let lookName: String?
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw NSError(domain: "BatchSourceJournalTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        print("PASS: \(message)")
    }

    static func run(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("external.raw")
        try Data("original source".utf8).write(to: input)
        var source = BatchSourceSnapshot(identity: PhotoIdentity(resourceIdentifier: "journal-source"),
                                        sourceFile: try .copy(input), displayName: "original.raw", settings: .default)
        let path = source.sourceFile.withReadAccess { $0 }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for hasLook in [false, true] {
            source.lookURL = hasLook ? root.appendingPathComponent("look.cube") : nil
            source.lookName = hasLook ? "Film" : nil
            let legacy = LegacySnapshot(identity: source.identity, sourceURL: path, displayName: "original.raw",
                                        sourceKind: .raw, settings: .default, lookURL: source.lookURL, lookName: source.lookName)
            let bytes = try encoder.encode(legacy)
            try check(try encoder.encode(source) == bytes, "Batch snapshot preserves exact legacy JSON bytes (look: \(hasLook))")
            let decoded = try JSONDecoder().decode(BatchSourceSnapshot.self, from: bytes)
            try check(decoded == source, "Legacy snapshot decodes with equality independent of runtime owner")
        }
        let decoded = try JSONDecoder().decode(BatchSourceSnapshot.self, from: encoder.encode(source))
        var job = BatchExportJob(source: source, targets: [])
        source.sourceFile = .externallyManaged(input)
        try check(FileManager.default.fileExists(atPath: path.path), "Captured batch job retains the source after editor release")
        try BatchInputStore.prepare(&job, look: nil, root: root.appendingPathComponent("jobs"))
        try check(try job.source.sourceFile.withReadAccess { try Data(contentsOf: $0) } == Data("original source".utf8),
                  "Batch preparation freezes the captured source bytes")
        try check(!FileManager.default.fileExists(atPath: path.path), "Batch copy releases its editor owner; decoded journals acquire none")
        withExtendedLifetime(decoded) {}
        try check(try Data(contentsOf: input) == Data("original source".utf8), "Replacing a snapshot preserves externally managed input")
    }
}
