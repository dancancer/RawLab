import Combine
import Darwin
import Foundation

public enum DiagnosticLevel: String, Codable, Sendable {
    case info
    case warn
    case error
}

public struct DiagnosticBreadcrumb: Codable, Equatable, Sendable {
    public let timestamp: String
    public let seq: Int
    public let level: DiagnosticLevel
    public let category: String
    public let stage: String
    public let message: String
    public let context: [String: String]

    public init(
        timestamp: String,
        seq: Int,
        level: DiagnosticLevel,
        category: String,
        stage: String,
        message: String,
        context: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.seq = seq
        self.level = level
        self.category = category
        self.stage = stage
        self.message = message
        self.context = context
    }
}

public struct DiagnosticManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public let reportID: String
    public let sessionID: String?
    public let createdAt: String
    public let environment: DiagnosticEnvironment
    public let recordingActive: Bool
    public let sessionStartedAt: String?
    public let breadcrumbCount: Int
    public let droppedBreadcrumbs: Int
    public let recentErrorCount: Int
    public let userNote: String?
}

public enum DiagnosticArchiveError: Error, Sendable {
    case coordinationFailed
}

public struct DiagnosticReportBundle: Sendable {
    public let reportID: String
    public let manifest: DiagnosticManifest
    public let manifestJSON: String
    public let breadcrumbsJSONL: String
    public let recentErrorsJSON: String
    public let readmeText: String

    /// Packages the diagnostic files into a standard `.zip` archive using Apple's native `NSFileCoordinator` `.forUploading`.
    public func zipData() throws -> Data {
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory
            .appendingPathComponent("rawlab-diag-stage-\(UUID().uuidString)", isDirectory: true)
        let packageDir = workspace.appendingPathComponent("RawLab-Diag-\(reportID)", isDirectory: true)
        try fm.createDirectory(at: packageDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workspace) }

        try Data(manifestJSON.utf8).write(to: packageDir.appendingPathComponent("manifest.json"), options: .atomic)
        try Data(breadcrumbsJSONL.utf8).write(to: packageDir.appendingPathComponent("breadcrumbs.jsonl"), options: .atomic)
        try Data(recentErrorsJSON.utf8).write(to: packageDir.appendingPathComponent("recent-errors.json"), options: .atomic)
        try Data(readmeText.utf8).write(to: packageDir.appendingPathComponent("README.txt"), options: .atomic)

        var coordinatorError: NSError?
        var archiveResult: Result<Data, Error>?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: packageDir, options: .forUploading, error: &coordinatorError) { zipURL in
            archiveResult = Result { try Data(contentsOf: zipURL) }
        }
        if let coordinatorError {
            throw coordinatorError
        }
        guard let archiveResult else {
            throw DiagnosticArchiveError.coordinationFailed
        }
        return try archiveResult.get()
    }

    public var previewText: String {
        var sections: [String] = [
            "=== manifest.json ===",
            manifestJSON,
            "=== recent-errors.json ===",
            recentErrorsJSON,
            "=== breadcrumbs.jsonl (\(manifest.breadcrumbCount) entries, dropped \(manifest.droppedBreadcrumbs)) ===",
            breadcrumbsJSONL.isEmpty ? "(empty)" : String(breadcrumbsJSONL.prefix(32_768)),
        ]
        if breadcrumbsJSONL.count > 32_768 {
            sections.append("... [preview truncated]")
        }
        return sections.joined(separator: "\n")
    }
}

public enum DiagnosticReportID {
    public static func generate(now: Date = Date(), random: UUID = UUID()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        let day = formatter.string(from: now)
        let hex = random.uuidString.replacingOccurrences(of: "-", with: "").prefix(8).uppercased()
        return "RL-\(day)-\(hex)"
    }

    public static func isValid(_ value: String) -> Bool {
        value.range(of: "^RL-\\d{8}-[0-9A-F]{8}$", options: .regularExpression) != nil
    }
}

public enum DiagnosticRedactor {
    // Matches directory segments (allowing single spaces inside folder names, never crossing ` /` or `:`)
    // followed by a final file/leaf segment (including spaced filenames ending in an extension).
    private static let pathTailPattern =
        #"(?:[\\/](?:[^\s\\/\r\n"'<>:*?|](?:[^\r\n\\/"'<>:*?|]{0,80}?[^\s\\/\r\n"'<>:*?|])?[\\/])*(?:[^\s\\/\r\n"'<>:*?|][^\r\n\\/"'<>:*?|]{0,120}?\.[A-Za-z0-9]{1,10}\b|[^\s\\/\r\n"'<>()\[\]{}:*?|]*))?"#

    private static let fileURIRegex = try! NSRegularExpression(
        pattern: #"(?i)(?:file|content)://[^\s"'<>()\[\]{}]+"#
    )
    private static let windowsPathRegex = try! NSRegularExpression(
        pattern: #"(?i)(?:[a-z]:|\\\\[^\\/\s"'<>:*?|]+)"# +
            #"(?:[\\/](?:[^\s\\/\r\n"'<>:*?|](?:[^\r\n\\/"'<>:*?|]{0,80}?[^\s\\/\r\n"'<>:*?|])?[\\/])*(?:[^\s\\/\r\n"'<>:*?|][^\r\n\\/"'<>:*?|]{0,120}?\.[a-z0-9]{1,10}\b|[^\s\\/\r\n"'<>()\[\]{}:*?|]+))+"#
    )
    private static let posixSensitivePathRegex = try! NSRegularExpression(
        pattern: #"/(?:[Uu]sers|home|private/var|var/mobile|var/folders|tmp|Volumes|data/user|data/data|storage|sdcard|mnt)"# +
            #"(?:[\\/](?:[^\s\\/\r\n"'<>:*?|](?:[^\r\n\\/"'<>:*?|]{0,80}?[^\s\\/\r\n"'<>:*?|])?[\\/])*(?:[^\s\\/\r\n"'<>:*?|][^\r\n\\/"'<>:*?|]{0,120}?\.[A-Za-z0-9]{1,10}\b|[^\s\\/\r\n"'<>()\[\]{}:*?|]+))+"#
    )
    private static let bareMediaFilenameRegex = try! NSRegularExpression(
        pattern: #"(?i)(?<![A-Za-z0-9_<>])(?:[A-Za-z0-9_\u0080-\uFFFF][^\s\\/"'<>()\[\]{}:*?|]*)\.(3fr|arq|arw|cr2|cr3|crw|dcr|dng|erf|fff|heic|heif|iiq|jpeg|jpg|kdc|mos|mrw|nef|nrw|orf|pef|png|raf|raw|rw2|rwl|sr2|srf|srw|tif|tiff|x3f|cube|dcp)\b"#
    )

    public static func cleanText(_ input: String, maxLength: Int = 512, extraPaths: [(String, String)] = []) -> String {
        guard !input.isEmpty else { return "" }
        var text = replace(regex: fileURIRegex, in: input, with: "<uri>")

        var replacements = defaultPathReplacements() + extraPaths
        replacements.sort { $0.0.count > $1.0.count }
        for (rawPrefix, token) in replacements {
            let trimmed = rawPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
            guard trimmed.count > 1 else { continue }
            if let prefixRegex = buildPrefixRegex(trimmed) {
                text = replace(regex: prefixRegex, in: text, with: token)
            }
        }

        text = replace(regex: windowsPathRegex, in: text, with: "<path>")
        text = replace(regex: posixSensitivePathRegex, in: text, with: "<path>")
        text = replace(regex: bareMediaFilenameRegex, in: text, with: "<file>.$1")
        if text.count > maxLength {
            return String(text.prefix(maxLength)) + " [truncated]"
        }
        return text
    }

    public static func cleanUserNote(_ note: String?, extraPaths: [(String, String)] = []) -> String? {
        guard let raw = note?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return cleanText(raw, maxLength: 200, extraPaths: extraPaths)
    }

    public static func cleanIdentifier(_ value: String, fallback: String = "unknown") -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let safe = String(trimmed.unicodeScalars.prefix(64).map { allowed.contains($0) ? Character($0) : "_" })
        return safe.isEmpty ? fallback : safe
    }

    public static func cleanContext(_ raw: [String: String], extraPaths: [(String, String)] = []) -> [String: String] {
        let base = ErrorDiagnostics.redactedContext(raw)
        var output: [String: String] = [:]
        for key in base.keys.sorted().prefix(24) {
            guard let value = base[key] else { continue }
            let safeKey = cleanIdentifier(key, fallback: "key")
            output[safeKey] = cleanText(value, maxLength: 256, extraPaths: extraPaths)
        }
        return output
    }

    private static func buildPrefixRegex(_ trimmedPrefix: String) -> NSRegularExpression? {
        let hasLeadingSlash = trimmedPrefix.hasPrefix("/") || trimmedPrefix.hasPrefix("\\")
        let parts = trimmedPrefix
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !parts.isEmpty else { return nil }
        let prefixPattern = (hasLeadingSlash ? #"[\\/]"# : "") + parts.joined(separator: #"[\\/]"#)
        return try? NSRegularExpression(pattern: "(?i)" + prefixPattern + pathTailPattern)
    }

    private static func defaultPathReplacements() -> [(String, String)] {
        var pairs: [(String, String)] = []
        let home = NSHomeDirectory()
        if !home.isEmpty && home != "/" { pairs.append((home, "<user>")) }
        let temp = FileManager.default.temporaryDirectory.path
        if !temp.isEmpty && temp != "/" { pairs.append((temp, "<temp>")) }
        let bundle = Bundle.main.bundlePath
        if !bundle.isEmpty && bundle != "/" { pairs.append((bundle, "<app>")) }
        return pairs
    }

    private static func replace(regex: NSRegularExpression, in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}

// MARK: - Alibaba Cloud SLS WebTracking Configuration & Upload

public enum DiagnosticUploadError: Error, Equatable, Sendable {
    case emptyDiagnostics
    case invalidEndpoint
    case serviceUnavailable(statusCode: Int)
    case networkFailure
    case payloadTooLarge
}

public struct SLSDiagnosticUploadConfiguration: Sendable, Equatable {
    public static let productionURLString =
        "https://proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-shanghai.cn-shanghai.log.aliyuncs.com/logstores/logstore-diagnostics/track"

    public let endpoint: URL

    public init(endpoint: URL) {
        self.endpoint = endpoint
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowLoopback: Bool = false
    ) throws -> SLSDiagnosticUploadConfiguration {
        let raw = environment["RAWLAB_DIAGNOSTIC_UPLOAD_URL"] ?? productionURLString
        return try parse(raw, allowLoopback: allowLoopback)
    }

    public static func parse(_ raw: String, allowLoopback: Bool = false) throws -> SLSDiagnosticUploadConfiguration {
        guard let components = URLComponents(string: raw),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let host = components.host?.lowercased(),
              let url = components.url else {
            throw DiagnosticUploadError.invalidEndpoint
        }
        let pathParts = components.path.split(separator: "/")
        guard pathParts.count == 3,
              pathParts[0] == "logstores",
              pathParts[2] == "track",
              pathParts[1].range(of: "^[a-z0-9][a-z0-9_-]{1,62}$", options: .regularExpression) != nil else {
            throw DiagnosticUploadError.invalidEndpoint
        }
        if allowLoopback && components.scheme == "http" && (host == "127.0.0.1" || host == "localhost") {
            return SLSDiagnosticUploadConfiguration(endpoint: url)
        }
        guard components.scheme == "https",
              (components.port == nil || components.port == 443),
              host.hasSuffix(".log.aliyuncs.com"),
              host.count > ".log.aliyuncs.com".count else {
            throw DiagnosticUploadError.invalidEndpoint
        }
        return SLSDiagnosticUploadConfiguration(endpoint: url)
    }
}

public struct SLSDiagnosticPayload: Sendable {
    public static let maxChunkBytes = 200_000
    public static let maxTotalBodyBytes = 950_000

    public let body: Data
    public let rawByteCount: Int

    public static func build(bundle: DiagnosticReportBundle) throws -> SLSDiagnosticPayload {
        let chunks = splitLines(bundle.breadcrumbsJSONL, maxBytes: maxChunkBytes, maxChunks: 4)
        let totalChunks = max(1, chunks.count)
        let normalizedChunks = chunks.isEmpty ? [""] : chunks
        var logs: [[String: String]] = []
        for (index, chunk) in normalizedChunks.enumerated() {
            var item: [String: String] = [
                "report_id": bundle.reportID,
                "schema_version": String(bundle.manifest.schemaVersion),
                "platform": bundle.manifest.environment.platform,
                "app_version": bundle.manifest.environment.appVersion,
                "build": bundle.manifest.environment.build,
                "os_version": bundle.manifest.environment.osVersion,
                "device_model": bundle.manifest.environment.deviceModel,
                "chunk_index": String(index),
                "chunk_count": String(totalChunks),
                "breadcrumbs_jsonl": chunk,
            ]
            if index == 0 {
                item["manifest_json"] = bundle.manifestJSON
                item["recent_errors_json"] = bundle.recentErrorsJSON
                if let note = bundle.manifest.userNote, !note.isEmpty {
                    item["user_note"] = note
                }
            }
            logs.append(item)
        }
        let envelope: [String: Any] = [
            "__topic__": "rawlab-diagnostic-v1",
            "__source__": bundle.manifest.environment.platform,
            "__tags__": [
                "platform": bundle.manifest.environment.platform,
                "app_version": bundle.manifest.environment.appVersion,
            ],
            "__logs__": logs,
        ]
        let body = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        guard body.count <= maxTotalBodyBytes else {
            throw DiagnosticUploadError.payloadTooLarge
        }
        return SLSDiagnosticPayload(body: body, rawByteCount: body.count)
    }

    private static func splitLines(_ text: String, maxBytes: Int, maxChunks: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        var chunks: [String] = []
        var currentLines: [Substring] = []
        var currentBytes = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineBytes = line.utf8.count + 1
            if !currentLines.isEmpty && currentBytes + lineBytes > maxBytes {
                chunks.append(currentLines.joined(separator: "\n"))
                currentLines.removeAll(keepingCapacity: true)
                currentBytes = 0
                if chunks.count >= maxChunks { break }
            }
            if lineBytes <= maxBytes {
                currentLines.append(line)
                currentBytes += lineBytes
            }
        }
        if !currentLines.isEmpty && chunks.count < maxChunks {
            let tail = currentLines.joined(separator: "\n")
            if !tail.isEmpty { chunks.append(tail) }
        }
        return chunks
    }
}

public protocol DiagnosticUploadTransport: Sendable {
    func upload(payload: SLSDiagnosticPayload, reportID: String) async throws
}

public struct URLSessionDiagnosticUploadTransport: DiagnosticUploadTransport {
    public let configuration: SLSDiagnosticUploadConfiguration
    private let session: URLSession

    public init(configuration: SLSDiagnosticUploadConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 20
            config.httpShouldSetCookies = false
            self.session = URLSession(configuration: config)
        }
    }

    public func upload(payload: SLSDiagnosticPayload, reportID: String) async throws {
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("0.6.0", forHTTPHeaderField: "x-log-apiversion")
        request.setValue(String(payload.rawByteCount), forHTTPHeaderField: "x-log-bodyrawsize")
        request.httpBody = payload.body

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw DiagnosticUploadError.networkFailure
        }
        guard let http = response as? HTTPURLResponse else {
            throw DiagnosticUploadError.networkFailure
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DiagnosticUploadError.serviceUnavailable(statusCode: http.statusCode)
        }
    }
}

// MARK: - Bounded Local Diagnostic Session Store

public final class DiagnosticSessionStore: @unchecked Sendable {
    public static let defaultLeaseDuration: TimeInterval = 30 * 60
    public static let maxBreadcrumbs = 500
    public static let maxBreadcrumbBytes = 450_000
    private static let preservedHeadCount = 10

    private struct Lease: Codable {
        var schemaVersion: Int = 1
        var sessionID: String
        var startedAt: String
        var expiresAt: String
        var remainingLaunches: Int
    }

    private struct SessionMeta: Codable {
        var schemaVersion: Int = 1
        var sessionID: String
        var pendingReportID: String?
        var startedAt: String
        var droppedBreadcrumbs: Int
    }

    public struct StateSnapshot: Equatable, Sendable {
        public let isRecording: Bool
        public let expiresAt: Date?
        public let sessionID: String?
        public let breadcrumbCount: Int
        public let hasRecentErrors: Bool
        public let recoveredPreviousSession: Bool

        public var hasExportableLogs: Bool {
            breadcrumbCount > 0 || hasRecentErrors
        }
    }

    public let directory: URL
    public let errorDiagnostics: ErrorDiagnostics
    public let leaseDuration: TimeInterval
    private let nowProvider: @Sendable () -> Date
    private let queue = DispatchQueue(label: "com.rawlab.diagnostic-session", qos: .utility)

    private let fastLock = NSLock()
    private var fastActiveUntil: Date?

    private var activeLease: Lease?
    private var sessionMeta: SessionMeta?
    private var breadcrumbs: [DiagnosticBreadcrumb] = []
    private var nextSeq: Int = 1
    private var loadedFromDisk = false
    private var launchResumedInProcess = false
    private var recoveredPreviousSessionFlag = false

    public init(
        directory: URL,
        errorDiagnostics: ErrorDiagnostics,
        leaseDuration: TimeInterval = DiagnosticSessionStore.defaultLeaseDuration,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.errorDiagnostics = errorDiagnostics
        self.leaseDuration = max(10, leaseDuration)
        self.nowProvider = now

        errorDiagnostics.setFailureObserver { [weak self] operation, stage, domain, code, context, native in
            guard let self else { return }
            var merged = context
            merged["errorDomain"] = domain
            merged["errorCode"] = String(code)
            if let native {
                merged["nativeStatus"] = String(native.status)
                if let reason = native.reason { merged["nativeReason"] = String(reason) }
                if let field = native.field { merged["nativeField"] = String(field) }
            }
            self.record(
                level: .error,
                category: operation.rawValue,
                stage: stage,
                message: "\(domain) (\(code))",
                context: merged
            )
        }
    }

    public var isRecording: Bool {
        let now = nowProvider()
        fastLock.lock()
        let expires = fastActiveUntil
        fastLock.unlock()
        guard let expires else { return false }
        return now < expires
    }

    /// Evaluates persistent lease at most once per process/store instance so window or activity recreation
    /// never consumes `remainingLaunches`.
    @discardableResult
    public func resumeOnLaunch() -> StateSnapshot {
        queue.sync {
            ensureLoadedLocked()
            let now = nowProvider()
            if launchResumedInProcess {
                expireIfNeededLocked(now: now)
                return snapshotLocked(now: now)
            }
            launchResumedInProcess = true

            if var lease = readLeaseLocked(),
               let expiresAt = Self.parseISO8601(lease.expiresAt),
               now < expiresAt,
               lease.remainingLaunches > 0 {
                lease.remainingLaunches -= 1
                activeLease = lease
                writeLeaseLocked(lease)
                setFastActiveUntil(expiresAt)
                if sessionMeta == nil {
                    sessionMeta = SessionMeta(
                        sessionID: lease.sessionID,
                        pendingReportID: lease.sessionID,
                        startedAt: lease.startedAt,
                        droppedBreadcrumbs: 0
                    )
                }
                appendBreadcrumbLocked(
                    level: .info,
                    category: "lifecycle",
                    stage: "relaunch",
                    message: "Diagnostic recording resumed across launch",
                    context: ["remainingLaunches": String(lease.remainingLaunches)],
                    now: now
                )
            } else {
                if readLeaseLocked() != nil {
                    removeLeaseLocked()
                    if !breadcrumbs.isEmpty {
                        recoveredPreviousSessionFlag = true
                    }
                } else if !breadcrumbs.isEmpty {
                    recoveredPreviousSessionFlag = true
                }
                activeLease = nil
                setFastActiveUntil(nil)
            }
            return snapshotLocked(now: now)
        }
    }

    @discardableResult
    public func setRecordingEnabled(_ enabled: Bool) -> StateSnapshot {
        queue.sync {
            ensureLoadedLocked()
            launchResumedInProcess = true
            let now = nowProvider()
            if enabled {
                let sessionID = DiagnosticReportID.generate(now: now)
                let startedISO = Self.formatISO8601(now)
                let expiresDate = now.addingTimeInterval(leaseDuration)
                let lease = Lease(
                    sessionID: sessionID,
                    startedAt: startedISO,
                    expiresAt: Self.formatISO8601(expiresDate),
                    remainingLaunches: 1
                )
                activeLease = lease
                sessionMeta = SessionMeta(
                    sessionID: sessionID,
                    pendingReportID: sessionID,
                    startedAt: startedISO,
                    droppedBreadcrumbs: 0
                )
                breadcrumbs.removeAll(keepingCapacity: true)
                nextSeq = 1
                recoveredPreviousSessionFlag = false
                writeLeaseLocked(lease)
                setFastActiveUntil(expiresDate)
                let env = errorDiagnostics.environment
                appendBreadcrumbLocked(
                    level: .info,
                    category: "lifecycle",
                    stage: "recordingStarted",
                    message: "User enabled diagnostic recording",
                    context: [
                        "platform": env.platform,
                        "appVersion": env.appVersion,
                        "build": env.build,
                        "osVersion": env.osVersion,
                        "deviceModel": env.deviceModel,
                    ],
                    now: now
                )
            } else {
                if activeLease != nil {
                    appendBreadcrumbLocked(
                        level: .info,
                        category: "lifecycle",
                        stage: "recordingStopped",
                        message: "User stopped diagnostic recording",
                        context: [:],
                        now: now
                    )
                }
                activeLease = nil
                removeLeaseLocked()
                setFastActiveUntil(nil)
            }
            return snapshotLocked(now: now)
        }
    }

    public func record(
        level: DiagnosticLevel = .info,
        category: String,
        stage: String,
        message: String,
        context: [String: String] = [:]
    ) {
        let now = nowProvider()
        fastLock.lock()
        let expires = fastActiveUntil
        fastLock.unlock()
        guard let expires else { return }
        if now >= expires {
            queue.async { self.expireIfNeededLocked(now: now) }
            return
        }
        let safeCategory = DiagnosticRedactor.cleanIdentifier(category, fallback: "general")
        let safeStage = DiagnosticRedactor.cleanIdentifier(stage, fallback: "step")
        let safeMessage = DiagnosticRedactor.cleanText(message, maxLength: 512)
        let safeContext = DiagnosticRedactor.cleanContext(context)
        queue.async {
            self.ensureLoadedLocked()
            self.expireIfNeededLocked(now: now)
            guard self.activeLease != nil else { return }
            self.appendBreadcrumbLocked(
                level: level,
                category: safeCategory,
                stage: safeStage,
                message: safeMessage,
                context: safeContext,
                now: now
            )
        }
    }

    public func stateSnapshot() -> StateSnapshot {
        queue.sync {
            ensureLoadedLocked()
            let now = nowProvider()
            expireIfNeededLocked(now: now)
            return snapshotLocked(now: now)
        }
    }

    public func buildReportBundle(
        userNote: String? = nil,
        stopActiveRecording: Bool = false,
        consumeReportID: Bool = false
    ) throws -> DiagnosticReportBundle {
        let recentErrorsData = try errorDiagnostics.reportData()
        return try queue.sync {
            ensureLoadedLocked()
            let now = nowProvider()
            expireIfNeededLocked(now: now)
            if stopActiveRecording, activeLease != nil {
                appendBreadcrumbLocked(
                    level: .info,
                    category: "lifecycle",
                    stage: "recordingSealedForReport",
                    message: "Diagnostic recording sealed for export/upload",
                    context: [:],
                    now: now
                )
                activeLease = nil
                removeLeaseLocked()
                setFastActiveUntil(nil)
            }
            let errorCount = Self.countErrors(in: recentErrorsData)
            guard !breadcrumbs.isEmpty || errorCount > 0 else {
                throw DiagnosticUploadError.emptyDiagnostics
            }

            let reportID: String
            if let pending = sessionMeta?.pendingReportID, DiagnosticReportID.isValid(pending) {
                reportID = pending
            } else {
                reportID = DiagnosticReportID.generate(now: now)
                if sessionMeta != nil && !consumeReportID {
                    sessionMeta?.pendingReportID = reportID
                    persistMetaOnlyLocked()
                }
            }
            if consumeReportID, sessionMeta != nil {
                sessionMeta?.pendingReportID = nil
                persistMetaOnlyLocked()
            }

            let cleanedNote = DiagnosticRedactor.cleanUserNote(userNote)
            let manifest = DiagnosticManifest(
                reportID: reportID,
                sessionID: sessionMeta?.sessionID,
                createdAt: Self.formatISO8601(now),
                environment: errorDiagnostics.environment,
                recordingActive: activeLease != nil,
                sessionStartedAt: sessionMeta?.startedAt,
                breadcrumbCount: breadcrumbs.count,
                droppedBreadcrumbs: sessionMeta?.droppedBreadcrumbs ?? 0,
                recentErrorCount: errorCount,
                userNote: cleanedNote
            )
            let manifestEncoder = JSONEncoder()
            manifestEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let manifestJSON = String(decoding: try manifestEncoder.encode(manifest), as: UTF8.self)
            let breadcrumbsJSONL = try encodeBreadcrumbsJSONLLocked()
            let recentErrorsJSON: String
            if let recentErrorsData {
                recentErrorsJSON = String(decoding: recentErrorsData, as: UTF8.self)
            } else {
                recentErrorsJSON = "{\n  \"events\" : [\n\n  ],\n  \"schemaVersion\" : 1\n}"
            }
            let readme = """
            RawLab Diagnostic Package (\(reportID))
            ========================================
            Contents:
            - manifest.json: App/OS/device environment summary and report metadata.
            - breadcrumbs.jsonl: Redacted step-by-step runtime events recorded while diagnostic logging was enabled.
            - recent-errors.json: Bounded recent error codes and stages.

            Privacy Notice:
            Photo pixels, thumbnails, original file names, personal folder paths, EXIF GPS/serials, and AI prompts/keys are excluded.
            """
            return DiagnosticReportBundle(
                reportID: reportID,
                manifest: manifest,
                manifestJSON: manifestJSON,
                breadcrumbsJSONL: breadcrumbsJSONL,
                recentErrorsJSON: recentErrorsJSON,
                readmeText: readme
            )
        }
    }

    public func makeTemporaryZipFile(userNote: String? = nil, stopActiveRecording: Bool = false) throws -> URL {
        let bundle = try buildReportBundle(userNote: userNote, stopActiveRecording: stopActiveRecording)
        let zipData = try bundle.zipData()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawLab-Diag-\(bundle.reportID).zip")
        try zipData.write(to: url, options: .atomic)
        return url
    }

    public func exportZip(to destination: URL, userNote: String? = nil, stopActiveRecording: Bool = false) throws -> String {
        let bundle = try buildReportBundle(userNote: userNote, stopActiveRecording: stopActiveRecording)
        let zipData = try bundle.zipData()
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try zipData.write(to: destination, options: .atomic)
        return bundle.reportID
    }

    @discardableResult
    public func clearAll() -> StateSnapshot {
        errorDiagnostics.clear()
        return queue.sync {
            ensureLoadedLocked()
            activeLease = nil
            sessionMeta = nil
            breadcrumbs.removeAll()
            nextSeq = 1
            recoveredPreviousSessionFlag = false
            setFastActiveUntil(nil)
            removeLeaseLocked()
            try? FileManager.default.removeItem(at: breadcrumbsURL)
            try? FileManager.default.removeItem(at: metaURL)
            return snapshotLocked(now: nowProvider())
        }
    }

    // MARK: - Private Storage Helpers

    private var leaseURL: URL { directory.appendingPathComponent("recording-lease.json") }
    private var breadcrumbsURL: URL { directory.appendingPathComponent("session-active.jsonl") }
    private var metaURL: URL { directory.appendingPathComponent("session-meta.json") }

    private func setFastActiveUntil(_ date: Date?) {
        fastLock.lock()
        fastActiveUntil = date
        fastLock.unlock()
    }

    private func ensureLoadedLocked() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        if let metaData = try? Data(contentsOf: metaURL),
           let decodedMeta = try? JSONDecoder().decode(SessionMeta.self, from: metaData),
           decodedMeta.schemaVersion == 1 {
            sessionMeta = decodedMeta
        }
        if let rawText = try? String(contentsOf: breadcrumbsURL, encoding: .utf8) {
            let decoder = JSONDecoder()
            var loaded: [DiagnosticBreadcrumb] = []
            for line in rawText.split(separator: "\n") {
                if let entry = try? decoder.decode(DiagnosticBreadcrumb.self, from: Data(line.utf8)) {
                    loaded.append(entry)
                }
            }
            breadcrumbs = loaded
            nextSeq = (loaded.last?.seq ?? 0) + 1
        }
    }

    private func expireIfNeededLocked(now: Date) {
        guard let lease = activeLease else { return }
        if let expires = Self.parseISO8601(lease.expiresAt), now >= expires {
            appendBreadcrumbLocked(
                level: .info,
                category: "lifecycle",
                stage: "leaseExpired",
                message: "Diagnostic recording automatically stopped after lease window",
                context: [:],
                now: now
            )
            activeLease = nil
            removeLeaseLocked()
            setFastActiveUntil(nil)
        }
    }

    private func appendBreadcrumbLocked(
        level: DiagnosticLevel,
        category: String,
        stage: String,
        message: String,
        context: [String: String],
        now: Date
    ) {
        let entry = DiagnosticBreadcrumb(
            timestamp: Self.formatISO8601(now),
            seq: nextSeq,
            level: level,
            category: category,
            stage: stage,
            message: message,
            context: context
        )
        nextSeq += 1
        breadcrumbs.append(entry)
        trimBreadcrumbsIfNeededLocked()
        persistSessionLocked()
    }

    private func trimBreadcrumbsIfNeededLocked() {
        var dropped = 0
        if breadcrumbs.count > Self.maxBreadcrumbs {
            let overflow = breadcrumbs.count - Self.maxBreadcrumbs
            let removeStart = min(Self.preservedHeadCount, breadcrumbs.count)
            let removable = max(0, breadcrumbs.count - removeStart)
            let actualRemove = min(overflow, removable)
            if actualRemove > 0 {
                breadcrumbs.removeSubrange(removeStart..<(removeStart + actualRemove))
                dropped += actualRemove
            }
        }
        if let encoded = try? encodeBreadcrumbsJSONLLocked(), encoded.utf8.count > Self.maxBreadcrumbBytes {
            while breadcrumbs.count > Self.preservedHeadCount + 1 {
                breadcrumbs.remove(at: Self.preservedHeadCount)
                dropped += 1
                if let current = try? encodeBreadcrumbsJSONLLocked(), current.utf8.count <= Self.maxBreadcrumbBytes {
                    break
                }
            }
        }
        if dropped > 0 {
            if sessionMeta == nil {
                let now = nowProvider()
                let id = DiagnosticReportID.generate(now: now)
                sessionMeta = SessionMeta(
                    sessionID: id,
                    pendingReportID: id,
                    startedAt: Self.formatISO8601(now),
                    droppedBreadcrumbs: dropped
                )
            } else {
                sessionMeta?.droppedBreadcrumbs += dropped
            }
        }
    }

    private func encodeBreadcrumbsJSONLLocked() throws -> String {
        if breadcrumbs.isEmpty { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var lines: [String] = []
        lines.reserveCapacity(breadcrumbs.count)
        for item in breadcrumbs {
            lines.append(String(decoding: try encoder.encode(item), as: UTF8.self))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func persistSessionLocked() {
        do {
            try prepareDirectoryLocked()
            let jsonl = try encodeBreadcrumbsJSONLLocked()
            try Data(jsonl.utf8).write(to: breadcrumbsURL, options: .atomic)
            if let meta = sessionMeta {
                try JSONEncoder().encode(meta).write(to: metaURL, options: .atomic)
            }
        } catch {
            // Keep in-memory breadcrumbs available for the current session even if disk write fails.
        }
    }

    private func persistMetaOnlyLocked() {
        guard let meta = sessionMeta else { return }
        do {
            try prepareDirectoryLocked()
            try JSONEncoder().encode(meta).write(to: metaURL, options: .atomic)
        } catch {}
    }

    private func readLeaseLocked() -> Lease? {
        guard let data = try? Data(contentsOf: leaseURL),
              let lease = try? JSONDecoder().decode(Lease.self, from: data),
              lease.schemaVersion == 1 else {
            return nil
        }
        return lease
    }

    private func writeLeaseLocked(_ lease: Lease) {
        do {
            try prepareDirectoryLocked()
            try JSONEncoder().encode(lease).write(to: leaseURL, options: .atomic)
        } catch {}
    }

    private func removeLeaseLocked() {
        try? FileManager.default.removeItem(at: leaseURL)
    }

    private func prepareDirectoryLocked() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    private func snapshotLocked(now: Date) -> StateSnapshot {
        let expiresAt = activeLease.flatMap { Self.parseISO8601($0.expiresAt) }
        let recentErrors = (try? errorDiagnostics.reportData()) != nil
        return StateSnapshot(
            isRecording: activeLease != nil && (expiresAt.map { now < $0 } ?? false),
            expiresAt: expiresAt,
            sessionID: activeLease?.sessionID ?? sessionMeta?.sessionID,
            breadcrumbCount: breadcrumbs.count,
            hasRecentErrors: recentErrors,
            recoveredPreviousSession: recoveredPreviousSessionFlag
        )
    }

    private static func countErrors(in data: Data?) -> Int {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = object["events"] as? [[String: Any]] else {
            return 0
        }
        return events.filter { $0["error"] != nil }.count
    }

    private static func formatISO8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: value) { return parsed }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: value)
    }
}

// MARK: - Observable UI Coordinator (Shared by macOS & iOS)

@MainActor
public final class DiagnosticCenter: ObservableObject {
    public nonisolated static let appErrorDiagnostics: ErrorDiagnostics = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawLab/Diagnostics", isDirectory: true)
        #if os(iOS)
        let platform = "ios"
        #else
        let platform = "macos"
        #endif
        return ErrorDiagnostics(directory: support, environment: standardEnvironment(platform: platform))
    }()

    public nonisolated static let sharedStore: DiagnosticSessionStore = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawLab/Diagnostics", isDirectory: true)
        return DiagnosticSessionStore(directory: support, errorDiagnostics: appErrorDiagnostics)
    }()

    public static let shared = DiagnosticCenter(store: sharedStore)

    public nonisolated static func recordBreadcrumb(
        level: DiagnosticLevel = .info,
        category: String,
        stage: String,
        message: String,
        context: [String: String] = [:]
    ) {
        sharedStore.record(level: level, category: category, stage: stage, message: message, context: context)
    }

    @Published public private(set) var isRecording = false
    @Published public private(set) var recordingExpiresAt: Date?
    @Published public private(set) var hasExportableLogs = false
    @Published public private(set) var recoveredPreviousSession = false
    @Published public private(set) var isUploading = false
    @Published public private(set) var lastUploadedReportID: String?
    @Published public private(set) var feedbackMessageKey: String?
    @Published public private(set) var feedbackIsError = false

    public nonisolated let store: DiagnosticSessionStore
    private var uploadTransport: DiagnosticUploadTransport?
    private var expirationTimer: Timer?
    private var sessionBegan = false

    public init(store: DiagnosticSessionStore, uploadTransport: DiagnosticUploadTransport? = nil) {
        self.store = store
        self.uploadTransport = uploadTransport
        apply(store.stateSnapshot())
    }

    public func configure(uploadTransport: DiagnosticUploadTransport?) {
        self.uploadTransport = uploadTransport
    }

    public func beginSession() {
        guard !sessionBegan else {
            refreshState()
            return
        }
        sessionBegan = true
        apply(store.resumeOnLaunch())
        scheduleExpirationCheck()
    }

    public func refreshState() {
        apply(store.stateSnapshot())
        scheduleExpirationCheck()
    }

    public func setRecordingEnabled(_ enabled: Bool) {
        feedbackMessageKey = nil
        feedbackIsError = false
        if enabled { lastUploadedReportID = nil }
        apply(store.setRecordingEnabled(enabled))
        scheduleExpirationCheck()
    }

    public nonisolated func record(
        level: DiagnosticLevel = .info,
        category: String,
        stage: String,
        message: String,
        context: [String: String] = [:]
    ) {
        store.record(level: level, category: category, stage: stage, message: message, context: context)
    }

    public func clearLogs() {
        lastUploadedReportID = nil
        feedbackIsError = false
        apply(store.clearAll())
        scheduleExpirationCheck()
        feedbackMessageKey = "已清除本地诊断日志。"
    }

    public func recordExportSuccess() {
        refreshState()
        feedbackIsError = false
        feedbackMessageKey = "诊断包已保存，可通过微信、小红书或 Issue 发送给开发者。"
    }

    public func recordExportFailure() {
        refreshState()
        feedbackIsError = true
        feedbackMessageKey = "无法导出诊断包。"
    }

    public func uploadLogs(userNote: String? = nil) async -> String? {
        guard !isUploading else { return nil }
        isUploading = true
        feedbackMessageKey = nil
        feedbackIsError = false
        defer {
            isUploading = false
            refreshState()
        }

        do {
            let store = self.store
            let (bundle, payload) = try await Task.detached(priority: .utility) {
                // Only consume/rotate pendingReportID after upload succeeds so failed retries keep the same ID,
                // while a later upload after new errors mints a fresh reportID.
                let bundle = try store.buildReportBundle(userNote: userNote, stopActiveRecording: true, consumeReportID: false)
                let payload = try SLSDiagnosticPayload.build(bundle: bundle)
                return (bundle, payload)
            }.value
            let transport: DiagnosticUploadTransport
            if let injected = uploadTransport {
                transport = injected
            } else {
                let config = try SLSDiagnosticUploadConfiguration.resolve()
                transport = URLSessionDiagnosticUploadTransport(configuration: config)
            }
            try await transport.upload(payload: payload, reportID: bundle.reportID)
            _ = try? store.buildReportBundle(userNote: userNote, stopActiveRecording: false, consumeReportID: true)
            lastUploadedReportID = bundle.reportID
            feedbackIsError = false
            feedbackMessageKey = "上传成功，请复制诊断码发送给开发者。"
            return bundle.reportID
        } catch let error as DiagnosticUploadError {
            feedbackIsError = true
            switch error {
            case .emptyDiagnostics:
                feedbackMessageKey = "暂无可导出的错误日志。"
            case .payloadTooLarge:
                feedbackMessageKey = "日志体积超出云端单次上限，请使用「保存到设备」导出诊断包。"
            case .invalidEndpoint, .serviceUnavailable, .networkFailure:
                feedbackMessageKey = "云端上传暂不可用，请先将诊断包保存到设备后发送。"
            }
            return nil
        } catch {
            feedbackIsError = true
            feedbackMessageKey = "云端上传暂不可用，请先将诊断包保存到设备后发送。"
            return nil
        }
    }

    public var statusSummaryKey: String {
        if isRecording {
            return "正在记录详细诊断日志（30 分钟或下次重启后自动关闭）。请复现问题后导出或上传。"
        }
        if recoveredPreviousSession && hasExportableLogs {
            return "检测到上次录制的诊断日志，可直接保存到设备或一键上传。"
        }
        if hasExportableLogs {
            return "已有可导出的本地诊断记录；详细日志录制当前处于关闭状态。"
        }
        return "默认关闭。遇到问题时可打开开关复现操作，随后将诊断包保存到设备或一键上传。"
    }

    private func apply(_ snapshot: DiagnosticSessionStore.StateSnapshot) {
        isRecording = snapshot.isRecording
        recordingExpiresAt = snapshot.expiresAt
        hasExportableLogs = snapshot.hasExportableLogs
        recoveredPreviousSession = snapshot.recoveredPreviousSession
    }

    private func scheduleExpirationCheck() {
        expirationTimer?.invalidate()
        expirationTimer = nil
        guard isRecording, let expiresAt = recordingExpiresAt else { return }
        let delay = max(0.5, expiresAt.timeIntervalSinceNow + 0.1)
        expirationTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshState()
            }
        }
    }

    public nonisolated static func standardEnvironment(platform: String) -> DiagnosticEnvironment {
        var hardware = utsname()
        uname(&hardware)
        let machine = withUnsafeBytes(of: hardware.machine) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        let process = ProcessInfo.processInfo
        let version = process.operatingSystemVersion
        let bundle = Bundle.main
        let model = process.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? (machine.isEmpty ? "unknown" : machine)
        return DiagnosticEnvironment(
            platform: platform,
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            deviceModel: DiagnosticRedactor.cleanIdentifier(model)
        )
    }
}
