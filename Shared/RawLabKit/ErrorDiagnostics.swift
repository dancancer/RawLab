import Foundation

public struct DiagnosticEnvironment: Codable, Sendable {
    public let platform: String
    public let appVersion: String
    public let build: String
    public let osVersion: String
    public let deviceModel: String

    public init(platform: String, appVersion: String, build: String, osVersion: String, deviceModel: String) {
        self.platform = platform
        self.appVersion = appVersion
        self.build = build
        self.osVersion = osVersion
        self.deviceModel = deviceModel
    }
}

public struct DiagnosticNativeError: Codable, Sendable {
    public let status: Int
    public var reason: Int?
    public var field: Int?

    public init(status: Int, reason: Int? = nil, field: Int? = nil) {
        self.status = status
        self.reason = reason
        self.field = field
    }
}

public final class ErrorDiagnostics: @unchecked Sendable {
    public enum Operation: String, Codable, Sendable {
        case photoImport, preview, photoExport, lookImport, batchExport, editPersistence, adjustment
    }

    private static let photoExtensions: Set<String> = [
        "3fr", "arq", "arw", "cr2", "cr3", "crw", "dcr", "dng", "erf", "fff", "heic", "heif",
        "iiq", "jpeg", "jpg", "kdc", "mos", "mrw", "nef", "nrw", "orf", "pef", "png", "raf", "raw",
        "rw2", "rwl", "sr2", "srf", "srw", "tif", "tiff", "x3f"
    ]

    public static func fileNameExtension(_ url: URL) -> String? {
        let suffix = url.pathExtension.lowercased()
        return suffix.isEmpty ? nil : allowedExtension(suffix)
    }

    public static func allowedExtension(_ suffix: String) -> String {
        photoExtensions.contains(suffix) ? suffix : "unknown"
    }

    public static func redactedContext(_ values: [String: String]) -> [String: String] {
        var context = values
        if let suffix = context["extension"] {
            let allowed = allowedExtension(suffix)
            context["extension"] = allowed
            if allowed == "unknown" { context["declaredType"] = nil }
        }
        for key in ["declaredType", "providerType", "detectedType"] where context[key]?.hasPrefix("dyn.") == true {
            context[key] = nil
        }
        return context
    }

    private struct ErrorCode: Codable {
        let domain: String
        let code: Int

        init(_ error: NSError) {
            let domain = error.domain
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
            self.domain = domain.utf8.count <= 120 && domain.unicodeScalars.allSatisfy(allowed.contains) ? domain : "unknown"
            code = error.code
        }
    }

    private struct Failure: Codable {
        let domain: String
        let code: Int
        let native: DiagnosticNativeError?
        let underlying: [ErrorCode]

        init(_ error: NSError, native: DiagnosticNativeError?) {
            let first = ErrorCode(error)
            domain = first.domain
            code = first.code
            self.native = native
            var cause = error.userInfo[NSUnderlyingErrorKey] as? NSError
            var codes: [ErrorCode] = []
            for _ in 0..<4 {
                guard let current = cause else { break }
                codes.append(ErrorCode(current))
                cause = current.userInfo[NSUnderlyingErrorKey] as? NSError
            }
            underlying = codes
        }
    }

    private struct Event: Codable {
        let timestamp: Date
        let environment: DiagnosticEnvironment
        let operation: Operation
        let stage: String
        let attemptID: UUID?
        let outcome: String
        var context: [String: String]
        let error: Failure?
    }

    private struct Report: Codable {
        var schemaVersion = 1
        let events: [Event]
    }

    private let directory: URL
    private let environment: DiagnosticEnvironment
    private let capacity: Int
    private let queue = DispatchQueue(label: "com.rawlab.error-diagnostics", qos: .utility)
    private var cachedEvents: [Event]?

    public init(directory: URL, environment: DiagnosticEnvironment, capacity: Int = 64) {
        self.directory = directory
        self.environment = environment
        self.capacity = max(2, capacity)
    }

    public func record(_ error: NSError, operation: Operation, stage: String, attemptID: UUID? = nil,
                       context: [String: String] = [:], native: DiagnosticNativeError? = nil) {
        let event = Event(timestamp: Date(), environment: environment, operation: operation, stage: stage,
                          attemptID: attemptID, outcome: "failed", context: context, error: Failure(error, native: native))
        queue.async { self.append(event) }
    }

    public func recordImportSuccess(attemptID: UUID, context: [String: String]) {
        let event = Event(timestamp: Date(), environment: environment, operation: .photoImport, stage: "completed",
                          attemptID: attemptID, outcome: "succeeded", context: context, error: nil)
        queue.async {
            if self.events().last(where: { $0.operation == .photoImport })?.error != nil {
                self.append(event)
            }
        }
    }

    public func reportData() throws -> Data? {
        try queue.sync {
            let entries = events()
            guard entries.contains(where: { $0.error != nil }) else { return nil }
            return try encode(entries)
        }
    }

    public func makeExportFile() throws -> URL? {
        guard let data = try reportData() else { return nil }
        let name = "RawLab-ErrorLog-\(UUID().uuidString.prefix(8)).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    private var journal: URL { directory.appendingPathComponent("errors.json") }

    private func events() -> [Event] {
        if let cachedEvents { return cachedEvents }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = (try? Data(contentsOf: journal)).flatMap { try? decoder.decode(Report.self, from: $0) }
        let entries = report?.schemaVersion == 1 ? Array((report?.events ?? []).suffix(capacity)) : []
        cachedEvents = entries
        return entries
    }

    private func append(_ event: Event) {
        var entries = events()
        entries.append(event)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        cachedEvents = entries
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var directory = self.directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
            try encode(entries).write(to: journal, options: .atomic)
        } catch {
            // A storage failure must leave the in-memory report available for this session.
        }
    }

    private func encode(_ entries: [Event]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let redacted = entries.map { event in
            var event = event
            event.context = Self.redactedContext(event.context)
            return event
        }
        return try encoder.encode(Report(events: redacted))
    }
}
