import Foundation

struct ManagedLook: Equatable {
    let record: UserLook
    let url: URL
}

enum LookImportFailureReason: Error, Equatable {
    case invalidLook
    case unreadableSource
    case invalidRegistry
    case invalidName
    case missingLook
    case missingColor, missingReference, unsupportedColor, conflictingColor, compatibilityChanged
    case dcp(DCPCompilerError)
    case system

    var localizedDescription: String {
        switch self {
        case .invalidLook:
            return LookLibraryError.invalidLook.localizedDescription
        case .unreadableSource:
            return LookLibraryError.unreadableSource.localizedDescription
        case .invalidRegistry:
            return LookLibraryError.invalidRegistry.localizedDescription
        case .invalidName:
            return LookLibraryError.invalidName.localizedDescription
        case .missingLook:
            return LookLibraryError.missingLook.localizedDescription
        case .missingColor: return LookLibraryError.missingColor.localizedDescription
        case .missingReference: return LookLibraryError.missingReference.localizedDescription
        case .unsupportedColor: return LookLibraryError.unsupportedColor.localizedDescription
        case .conflictingColor: return LookLibraryError.conflictingColor.localizedDescription
        case .compatibilityChanged: return LookLibraryError.compatibilityChanged.localizedDescription
        case .dcp(let error):
            return error.localizedDescription
        case .system:
            return L10n.text("无法读取外观文件。")
        }
    }
}

struct LookImportFailure: Equatable {
    let fileName: String
    let reason: LookImportFailureReason
}

struct LookImportBatchResult: Equatable {
    let imported: [ManagedLook]
    let failures: [LookImportFailure]
}

enum LookImportDecision: Equatable {
    case preserve(String?)
    case select(String)
}

enum LookImportSelection {
    static func decision(previousID: String?, imported: [ManagedLook]) -> LookImportDecision {
        guard let id = imported.last?.record.id else { return .preserve(previousID) }
        return .select(id)
    }
}

final class LookImportCoordinator {
    typealias Delivery = (@escaping () -> Void) -> Void
    typealias CompatibilityPrompt = (URL, LUTCompatibility, @escaping (LUTCompatibility?) -> Void) -> Void

    private let queue: DispatchQueue
    private let directory: URL
    private let delivery: Delivery
    private var library: LookLibrary?

    init(directory: URL = LookLibrary.defaultDirectory,
         delivery: @escaping Delivery = { DispatchQueue.main.async(execute: $0) }) {
        self.queue = DispatchQueue(label: "com.rawlab.look-library", qos: .userInitiated)
        self.directory = directory
        self.delivery = delivery
    }

    func load(completion: @escaping (Result<[ManagedLook], LookImportFailureReason>) -> Void) {
        queue.async {
            do {
                let library = try self.ensureLibrary()
                let snapshot = library.looks.map { ManagedLook(record: $0, url: library.url(for: $0)) }
                self.deliver { completion(.success(snapshot)) }
            } catch {
                self.deliver { completion(.failure(Self.reason(for: error))) }
            }
        }
    }

    func importLooks(from sources: [URL], compatibilityPrompt: CompatibilityPrompt? = nil,
                     completion: @escaping (LookImportBatchResult) -> Void) {
        queue.async {
            guard !sources.isEmpty else {
                self.deliver { completion(LookImportBatchResult(imported: [], failures: [])) }
                return
            }

            guard let library = try? self.ensureLibrary() else {
                let failures = sources.map {
                    LookImportFailure(fileName: $0.lastPathComponent, reason: .invalidRegistry)
                }
                self.deliver { completion(LookImportBatchResult(imported: [], failures: failures)) }
                return
            }

            self.importNext(sources, index: 0, library: library, prompt: compatibilityPrompt,
                            imported: [], failures: [], completion: completion)
        }
    }

    private func importNext(_ sources: [URL], index: Int, library: LookLibrary, prompt: CompatibilityPrompt?,
                            imported: [ManagedLook], failures: [LookImportFailure],
                            completion: @escaping (LookImportBatchResult) -> Void) {
        guard index < sources.count else {
            deliver { completion(.init(imported: imported, failures: failures)) }; return
        }
        let source = sources[index]
        let access = source.startAccessingSecurityScopedResource()
        var nextImported = imported
        var nextFailures = failures
        do {
            let record = try library.importLook(from: source)
            nextImported.append(.init(record: record, url: library.url(for: record)))
        } catch {
            if (error as? LookLibraryError)?.needsCompatibility == true,
               let prompt, let draft = try? LUTCompatibility.inspect(source) {
                deliver {
                    prompt(source, draft) { confirmed in
                        self.queue.async {
                            var resolved = imported
                            var rejected = failures
                            if let confirmed {
                                do {
                                    let record = try library.importLook(from: source, compatibility: confirmed)
                                    resolved.append(.init(record: record, url: library.url(for: record)))
                                } catch {
                                    rejected.append(.init(fileName: source.lastPathComponent, reason: Self.reason(for: error)))
                                }
                            }
                            if access { source.stopAccessingSecurityScopedResource() }
                            self.importNext(sources, index: index + 1, library: library, prompt: prompt,
                                            imported: resolved, failures: rejected, completion: completion)
                        }
                    }
                }
                return
            }
            nextFailures.append(.init(fileName: source.lastPathComponent, reason: Self.reason(for: error)))
        }
        if access { source.stopAccessingSecurityScopedResource() }
        importNext(sources, index: index + 1, library: library, prompt: prompt,
                   imported: nextImported, failures: nextFailures, completion: completion)
    }

    private func ensureLibrary() throws -> LookLibrary {
        if let library { return library }
        let library = try LookLibrary(directory: directory)
        self.library = library
        return library
    }

    func rename(id: String, name: String, completion: @escaping (Result<ManagedLook, LookImportFailureReason>) -> Void) {
        queue.async {
            do {
                let library = try self.ensureLibrary()
                try library.rename(id: id, to: name)
                guard let record = library.looks.first(where: { $0.id == id }) else { throw LookLibraryError.missingLook }
                self.deliver { completion(.success(.init(record: record, url: library.url(for: record)))) }
            } catch { self.deliver { completion(.failure(Self.reason(for: error))) } }
        }
    }

    private func deliver(_ work: @escaping () -> Void) {
        delivery(work)
    }

    private static func reason(for error: Error) -> LookImportFailureReason {
        if let error = error as? DCPCompilerError { return .dcp(error) }
        switch error as? LookLibraryError {
        case .invalidLook: return .invalidLook
        case .unreadableSource: return .unreadableSource
        case .invalidRegistry: return .invalidRegistry
        case .invalidName: return .invalidName
        case .missingLook: return .missingLook
        case .missingColor: return .missingColor
        case .missingReference: return .missingReference
        case .unsupportedColor: return .unsupportedColor
        case .conflictingColor: return .conflictingColor
        case .compatibilityChanged: return .compatibilityChanged
        case nil: return .system
        }
    }
}
