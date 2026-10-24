import Foundation

enum UpdateAdapterEvent {
    case found(UpdateDescriptor?), progress(Double), preparing, verified, installing, pendingRestart
    case failed(String, String), ended
}

struct UpdateAdapterError: LocalizedError {
    let code: String
    let detail: String
    var errorDescription: String? { detail.isEmpty ? code : detail }
}

@MainActor protocol UpdateAdapter: AnyObject {
    var unavailableReason: String? { get }
    var canCheck: Bool { get }
    var hasActiveSession: Bool { get }
    var hasAvailableRelease: Bool { get }
    var hasPreparedInstaller: Bool { get }
    func check(token: UUID, emit: @escaping (UUID, UpdateAdapterEvent) -> Void) throws
    func download(_ release: UpdateDescriptor, token: UUID) throws
    func cancel()
    func install(restart: Bool) async throws
}

@MainActor final class UnavailableUpdateAdapter: UpdateAdapter {
    let unavailableReason: String?
    var canCheck: Bool { false }
    var hasActiveSession: Bool { false }
    var hasAvailableRelease: Bool { false }
    var hasPreparedInstaller: Bool { false }
    init(_ reason: String) { unavailableReason = reason }
    func check(token: UUID, emit: @escaping (UUID, UpdateAdapterEvent) -> Void) throws { throw UpdateAdapterError(code: "unsupported", detail: "") }
    func download(_ release: UpdateDescriptor, token: UUID) throws { throw UpdateAdapterError(code: "unsupported", detail: "") }
    func cancel() {}
    func install(restart: Bool) async throws { throw UpdateAdapterError(code: "unsupported", detail: "") }
}
