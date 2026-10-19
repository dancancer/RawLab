import Foundation

enum PhotoSourceFileTests {
    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw TestFailure.message(message) }
        print("PASS: \(message)")
    }

    static func run(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("external.png")
        let bytes = Data("immutable input".utf8)
        try bytes.write(to: input)
        var file: PhotoSourceFile? = try .copy(input)
        let path = file!.withReadAccess({ $0 })
        let queue = DispatchQueue(label: "com.rawlab.tests.source-file")
        let gate = DispatchSemaphore(value: 0)
        let result = ResultCollector()
        var outcome: Result<Data, Error>?
        queue.async { [reader = file!] in
            gate.wait()
            let read = Result {
                try reader.withReadAccess { url in
                    try check(FileManager.default.fileExists(atPath: url.path), "Captured source survives its editor release")
                    return try Data(contentsOf: url)
                }
            }
            result.append { outcome = read }
        }
        file = nil
        try check(FileManager.default.fileExists(atPath: path.path), "Queued reader owns the managed file")
        gate.signal()
        queue.sync {}
        try result.take().forEach { $0() }
        try check(try outcome!.get() == bytes, "Scoped reader reads the original bytes")
        try check(!FileManager.default.fileExists(atPath: path.path), "Completed reader releases the managed file")

        var active: PhotoSourceFile? = try .copy(input)
        let activePath = try active!.withReadAccess { url in
            active = nil
            try check(try Data(contentsOf: url) == bytes, "Read scope retains its owner after the last external value is cleared")
            return url
        }
        try check(!FileManager.default.fileExists(atPath: activePath.path), "Read scope releases the last owner when it returns")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let external = PhotoSourceFile.externallyManaged(input)
            let encoded = try encoder.encode(external)
            try check(try encoded == encoder.encode(input), "Source encoding stays byte-compatible with a plain URL")
            let decoded = try JSONDecoder().decode(PhotoSourceFile.self, from: encoded)
            try check(try decoded == external && decoded.withReadAccess { try Data(contentsOf: $0) } == bytes,
                      "Journal URL decoding preserves the path and readable bytes")
        }
        try check(try Data(contentsOf: input) == bytes, "Externally managed and decoded files are never deleted by source release")
    }
}
