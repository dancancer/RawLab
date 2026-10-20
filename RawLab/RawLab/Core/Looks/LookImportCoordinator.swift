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

    func importLooks(from sources: [URL], completion: @escaping (LookImportBatchResult) -> Void) {
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

            var imported: [ManagedLook] = []
            var failures: [LookImportFailure] = []
            for source in sources {
                do {
                    let record = try library.importLook(from: source)
                    imported.append(ManagedLook(record: record, url: library.url(for: record)))
                } catch {
                    failures.append(LookImportFailure(fileName: source.lastPathComponent,
                                                      reason: Self.reason(for: error)))
                }
            }
            self.deliver { completion(LookImportBatchResult(imported: imported, failures: failures)) }
        }
    }

    private func ensureLibrary() throws -> LookLibrary {
        if let library { return library }
        let library = try LookLibrary(directory: directory)
        self.library = library
        return library
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
        case nil: return .system
        }
    }
}
