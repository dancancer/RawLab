import Foundation
import CryptoKit

struct BatchExportRunner {
    typealias Cancellation = () -> Bool

    static func run<Payload>(job: BatchExportJob,
                    journalStore: BatchJournalStore?,
                    render: @escaping (_ target: BatchTarget, _ settings: RawSettings) throws -> Payload,
                    write: @escaping (_ payload: Payload, _ outputName: String, _ target: BatchTarget,
                                      _ checkpoint: @escaping (String) throws -> Void) throws -> Void,
                    cleanup: @escaping (_ payload: Payload) -> Void = { _ in },
                    shouldCancel: @escaping Cancellation = { false },
                    didUpdate: @escaping (BatchExportJob) -> Void = { _ in },
                    onlyIDs: Set<String>? = nil) throws -> BatchExportJob {
        var job = job
        try job.validate()
        job.status = .running
        job.globalError = nil
        try journalStore?.save(job)
        didUpdate(job)

        for index in job.targets.indices {
            guard [.pending, .failed, .cancelled].contains(job.targets[index].status),
                  onlyIDs == nil || onlyIDs!.contains(job.targets[index].id) else { continue }
            if shouldCancel() {
                markRemainingCancelled(&job, from: index)
                job.status = .cancelled
                job.updatedAt = Date()
                try journalStore?.save(job)
                didUpdate(job)
                return job
            }

            job.targets[index].status = .processing
            job.targets[index].errorMessage = nil
            job.targets[index].outputAssetIdentifier = nil
            job.targets[index].outputFileURL = nil
            try journalStore?.save(job)
            didUpdate(job)
            do {
                let target = job.targets[index]
                if job.settingsMode == .perTargetFrozen { try target.frozen!.verifyFiles(input: target.sourceURL) }
                let payload = try render(target, job.settings(for: target))
                defer { cleanup(payload) }
                job.targets[index].status = .publishing
                try journalStore?.save(job)
                didUpdate(job)
                try write(payload, job.targets[index].outputName, job.targets[index]) { identifier in
                    if identifier.hasPrefix("file:") {
                        job.targets[index].outputFileURL = URL(fileURLWithPath: String(identifier.dropFirst(5)))
                        job.targets[index].outputAssetIdentifier = nil
                    } else {
                        job.targets[index].outputAssetIdentifier = identifier
                        job.targets[index].outputFileURL = nil
                    }
                    try journalStore?.save(job)
                    didUpdate(job)
                }
                job.targets[index].status = .succeeded
            } catch let error as BatchExportError {
                switch error {
                case .uncertain(let message):
                    job.targets[index].status = .needsConfirmation
                    job.targets[index].errorMessage = message
                    job.globalError = message
                    job.status = .interrupted
                    try journalStore?.save(job)
                    didUpdate(job)
                    return job
                case .target(let message):
                    job.targets[index].status = .failed
                    job.targets[index].errorMessage = message
                case .global(let message):
                    job.targets[index].status = .failed
                    job.targets[index].errorMessage = message
                    job.globalError = message
                    job.status = .failed
                    job.updatedAt = Date()
                    try journalStore?.save(job)
                    didUpdate(job)
                    return job
                }
            } catch {
                job.targets[index].status = .failed
                job.targets[index].errorMessage = error.localizedDescription
            }
            job.updatedAt = Date()
            try journalStore?.save(job)
            didUpdate(job)
        }

        if job.status != .cancelled && job.status != .failed {
            if job.targets.contains(where: { [.pending, .cancelled, .needsConfirmation].contains($0.status) }) { job.status = .interrupted }
            else { job.status = job.targets.contains(where: { $0.status == .failed }) ? .partialFailure : .completed }
        }
        job.updatedAt = Date()
        try journalStore?.save(job)
        didUpdate(job)
        return job
    }

    static func retryFailed<Payload>(job: BatchExportJob,
                            journalStore: BatchJournalStore?,
                            render: @escaping (_ target: BatchTarget, _ settings: RawSettings) throws -> Payload,
                            write: @escaping (_ payload: Payload, _ outputName: String, _ target: BatchTarget,
                                              _ checkpoint: @escaping (String) throws -> Void) throws -> Void,
                            cleanup: @escaping (_ payload: Payload) -> Void = { _ in },
                            shouldCancel: @escaping Cancellation = { false },
                            didUpdate: @escaping (BatchExportJob) -> Void = { _ in }) throws -> BatchExportJob {
        var retry = job
        let failedIDs = Set(job.targets.filter { $0.status == .failed }.map(\.id))
        for index in retry.targets.indices where retry.targets[index].status == .failed {
            retry.targets[index].status = .pending
            retry.targets[index].errorMessage = nil
        }
        retry.status = .draft
        return try run(job: retry, journalStore: journalStore, render: render, write: write,
                       cleanup: cleanup,
                       shouldCancel: shouldCancel, didUpdate: didUpdate, onlyIDs: failedIDs)
    }

    private static func markRemainingCancelled(_ job: inout BatchExportJob, from index: Int) {
        for remaining in index..<job.targets.count where [.pending, .processing, .failed, .cancelled].contains(job.targets[remaining].status) {
            job.targets[remaining].status = .cancelled
        }
    }
}
