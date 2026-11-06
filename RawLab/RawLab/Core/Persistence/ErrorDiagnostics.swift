import Foundation

struct DiagnosticEnvironment: Codable {
    let platform: String
    let appVersion: String
    let build: String
    let osVersion: String
    let deviceModel: String
}

struct DiagnosticNativeError: Codable {
    let status: Int
    var reason: Int? = nil
    var field: Int? = nil
}

final class ErrorDiagnostics {
    enum Operation: String, Codable {
        case photoImport, preview, photoExport, lookImport, batchExport, editPersistence, adjustment
    }

    private static let photoExtensions: Set<String> = [
        "3fr", "arq", "arw", "cr2", "cr3", "crw", "dcr", "dng", "erf", "fff", "heic", "heif",
        "iiq", "jpeg", "jpg", "kdc", "mos", "mrw", "nef", "nrw", "orf", "pef", "png", "raf", "raw",
        "rw2", "rwl", "sr2", "srf", "srw", "tif", "tiff", "x3f"
    ]

    static func fileNameExtension(_ url: URL) -> String? {
        let suffix = url.pathExtension.lowercased()
        return suffix.isEmpty ? nil : allowedExtension(suffix)
    }

    private static func allowedExtension(_ suffix: String) -> String {
        photoExtensions.contains(suffix) ? suffix : "unknown"
    }

    private static func redactedContext(_ values: [String: String]) -> [String: String] {
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

    init(directory: URL, environment: DiagnosticEnvironment, capacity: Int = 64) {
        self.directory = directory
        self.environment = environment
        self.capacity = max(2, capacity)
    }

    func record(_ error: NSError, operation: Operation, stage: String, attemptID: UUID? = nil,
                context: [String: String] = [:], native: DiagnosticNativeError? = nil) {
        let event = Event(timestamp: Date(), environment: environment, operation: operation, stage: stage,
                          attemptID: attemptID, outcome: "failed", context: context, error: Failure(error, native: native))
        queue.async { self.append(event) }
    }

    func recordImportSuccess(attemptID: UUID, context: [String: String]) {
        let event = Event(timestamp: Date(), environment: environment, operation: .photoImport, stage: "completed",
                          attemptID: attemptID, outcome: "succeeded", context: context, error: nil)
        queue.async {
            if self.events().last(where: { $0.operation == .photoImport })?.error != nil {
                self.append(event)
            }
        }
    }

    func reportData() throws -> Data? {
        try queue.sync {
            let entries = events()
            guard entries.contains(where: { $0.error != nil }) else { return nil }
            return try encode(entries)
        }
    }

    func makeExportFile() throws -> URL? {
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

#if os(iOS)
import ImageIO
import UniformTypeIdentifiers

extension ErrorDiagnostics {
    static let app: ErrorDiagnostics = {
        var hardware = utsname()
        uname(&hardware)
        let machine = withUnsafeBytes(of: hardware.machine) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        let process = ProcessInfo.processInfo
        let version = process.operatingSystemVersion
        let bundle = Bundle.main
        return ErrorDiagnostics(
            directory: URL.applicationSupportDirectory.appendingPathComponent("RawLab/Diagnostics", isDirectory: true),
            environment: DiagnosticEnvironment(
                platform: "ios", appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                deviceModel: process.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine
            )
        )
    }()

    @discardableResult static func log(_ error: Error, operation: Operation, stage: String,
                                       attemptID: UUID? = nil, context: [String: String] = [:]) -> Bool {
        guard !(error is CancellationError) else { return false }
        let nsError = error as NSError
        guard !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError),
              !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return false }
        let diagnosticSource = (error as? BatchExportError)?.underlyingError ?? error
        let native: DiagnosticNativeError?
        if let error = diagnosticSource as? HDRNativeError {
            native = .init(status: Int(error.status.rawValue), reason: Int(error.reason), field: Int(error.field))
        } else if let error = diagnosticSource as? Sony2FujiProcessor.ProcessorError, let status = error.diagnosticStatus {
            native = .init(status: Int(status.rawValue))
        } else {
            native = nil
        }
        app.record(nsError, operation: operation, stage: stage, attemptID: attemptID, context: context, native: native)
        return true
    }

    static func fileContext(_ url: URL, inspectContent: Bool = false) -> [String: String] {
        var values: [String: String] = [:]
        if let suffix = fileNameExtension(url) {
            values["extension"] = suffix
            if suffix != "unknown" { values["declaredType"] = UTType(filenameExtension: suffix)?.identifier }
        }
        if let resource = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isUbiquitousItemKey]) {
            if let size = resource.fileSize { values["bytes"] = String(size) }
            values["providerType"] = resource.contentType?.identifier
            if let cloud = resource.isUbiquitousItem { values["icloud"] = String(cloud) }
        }
        if inspectContent, let image = CGImageSourceCreateWithURL(url as CFURL, nil) {
            values["detectedType"] = CGImageSourceGetType(image) as String?
            if let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] {
                if let width = properties[kCGImagePropertyPixelWidth] as? Int { values["width"] = String(width) }
                if let height = properties[kCGImagePropertyPixelHeight] as? Int { values["height"] = String(height) }
            }
        }
        return redactedContext(values)
    }
}

extension RawEditorViewModel {
    @discardableResult
    func reportError(_ error: Error, operation: ErrorDiagnostics.Operation, stage: String,
                     attemptID: UUID? = nil, context: [String: String] = [:], message: String? = nil) -> Bool {
        guard ErrorDiagnostics.log(error, operation: operation, stage: stage, attemptID: attemptID, context: context) else { return false }
        statusMessage = message ?? error.localizedDescription
        statusHasDiagnostics = true
        return true
    }
}
#endif
