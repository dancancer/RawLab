import Foundation

enum UpdatePhase: String, Codable {
    case idle, checking, available, downloading, verifying
    case packageReady = "package_ready", waitingForTasks = "waiting_for_tasks"
    case readyToInstall = "ready_to_install", installing, pendingRestart = "pending_restart", complete, failed
}

enum UpdateInstallChoice: String, Codable {
    case none, restartNow = "restart_now", afterTasks = "after_tasks", onQuit = "on_quit", automaticOnQuit = "automatic_on_quit"
}

struct UpdateDescriptor: Codable, Equatable {
    let version: String
    let build: String
    let platform: String
    let architecture: String
    let channel: String
    let assetURL: String
    let size: UInt64
    let sha256: String?
    let notes: String
    var identity: String { [platform, architecture, channel, version, build, assetURL, sha256 ?? ""].joined(separator: "|") }
}

struct UpdateFailure: Codable, Equatable {
    let stage: UpdatePhase
    let code: String
    let detail: String
}

struct UpdateTaskState: Codable, Equatable {
    var format = 1
    private(set) var phase = UpdatePhase.idle
    private(set) var attempt = UUID()
    private(set) var release: UpdateDescriptor?
    private(set) var failure: UpdateFailure?
    private(set) var choice = UpdateInstallChoice.none
    private(set) var progress: Double = 0
    private(set) var blockers: [String] = []
    var backupPath: String?
    var previousVersion: String?
    var previousBuild: String?

    mutating func beginCheck() -> UUID {
        if release == nil || ![.onQuit, .automaticOnQuit].contains(choice) { choice = .none; release = nil }
        attempt = UUID(); phase = .checking; failure = nil
        progress = 0; blockers = []; backupPath = nil; previousVersion = nil; previousBuild = nil
        return attempt
    }

    @discardableResult mutating func found(_ item: UpdateDescriptor?, token: UUID) -> Bool {
        guard accepts(token, in: [.checking]) else { return false }
        if item?.identity != release?.identity { choice = .none }
        release = item; phase = item == nil ? .idle : .available; return true
    }

    mutating func beginDownload() -> UUID? {
        guard phase == .available, release != nil else { return nil }
        attempt = UUID(); phase = .downloading; failure = nil; progress = 0; return attempt
    }

    @discardableResult mutating func received(_ fraction: Double, token: UUID) -> Bool {
        guard accepts(token, in: [.downloading]), fraction.isFinite else { return false }
        progress = min(1, max(progress, fraction)); return true
    }

    @discardableResult mutating func preparing(token: UUID) -> Bool {
        guard accepts(token, in: [.downloading]) else { return false }
        phase = .verifying; progress = 1; return true
    }

    @discardableResult mutating func verified(token: UUID) -> Bool {
        guard accepts(token, in: [.verifying]) else { return false }
        phase = .packageReady; return true
    }

    @discardableResult mutating func choose(_ value: UpdateInstallChoice) -> Bool {
        guard [.packageReady, .waitingForTasks, .readyToInstall].contains(phase), value != .none else { return false }
        choice = value; return true
    }

    @discardableResult mutating func admit(blockedBy reasons: [String]) -> Bool {
        guard [.packageReady, .waitingForTasks, .readyToInstall].contains(phase), choice != .none else { return false }
        blockers = reasons; phase = reasons.isEmpty ? .readyToInstall : .waitingForTasks
        return reasons.isEmpty
    }

    @discardableResult mutating func installing(token: UUID) -> Bool {
        guard accepts(token, in: [.readyToInstall]), choice != .none, blockers.isEmpty else { return false }
        phase = .installing; return true
    }

    @discardableResult mutating func awaitingRestart(token: UUID) -> Bool {
        guard accepts(token, in: [.installing]) else { return false }
        phase = .pendingRestart; return true
    }

    @discardableResult mutating func fail(_ code: String, detail: String, token: UUID) -> Bool {
        guard attempt == token, ![.idle, .available, .complete, .failed].contains(phase) else { return false }
        if phase != .checking { choice = .none }
        failure = UpdateFailure(stage: phase, code: code, detail: detail)
        phase = .failed; attempt = UUID(); blockers = []; return true
    }

    mutating func cancel(preservingChoice: Bool = false) {
        guard phase != .installing && phase != .pendingRestart else { return }
        // 安装或首启失败仍需旧版恢复，普通取消和正常退出不能丢弃恢复现场。
        guard failure.map({ [.installing, .pendingRestart].contains($0.stage) }) != true else { return }
        attempt = UUID(); phase = release == nil ? .idle : .available
        if !preservingChoice { choice = .none }
        failure = nil; progress = 0; blockers = []; backupPath = nil; previousVersion = nil; previousBuild = nil
    }

    mutating func disableAutomaticInstallation() {
        if choice == .automaticOnQuit { cancel() }
    }

    mutating func restoreAfterLaunch(version: String, build: String, trusted: Bool) {
        attempt = UUID(); blockers = []
        if phase != .available && phase != .checking && !(phase == .failed && failure?.stage == .checking) { choice = .none }
        guard phase != .failed && phase != .complete && phase != .idle && phase != .available else { return }
        if [.installing, .pendingRestart].contains(phase), trusted,
           release?.version == version, release?.build == build {
            phase = .complete; failure = nil
            backupPath = nil; previousVersion = nil; previousBuild = nil
        } else {
            failure = UpdateFailure(stage: phase, code: "interrupted", detail: "")
            phase = .failed
        }
    }

    private func accepts(_ token: UUID, in phases: [UpdatePhase]) -> Bool { attempt == token && phases.contains(phase) }
}

struct UpdatePreferences: Codable {
    var automaticCheck = true
    var automaticInstall = false
    var skippedVersion: String?
    var remindAfter: Date?
    var lastCheck: Date?
    var channel = "stable"
    var pendingUpdate = UpdateTaskState()
    var recoveryReceipt: String?
    var stateRepairReceipt: UpdateStateRepairReceipt?
}

struct UpdateStateRepairReceipt: Codable, Equatable {
    let id: UUID
    let sha256: String
}
