import Foundation
import Combine

@MainActor final class DesktopUpdateController: ObservableObject {
    @Published private(set) var preferences: UpdatePreferences
    @Published private(set) var storageError: String?
    @Published private(set) var preparingInstallation = false
    @Published private(set) var recovering = false
    @Published private(set) var recoveryError: String?
    @Published private(set) var recoveryNeedsRestart = false
    let adapter: UpdateAdapter
    let gate: UpdateInstallGate
    let currentVersion: String
    let currentBuild: String
    private let store: UpdateStore
    private let backup: UpdateDataBackup
    private let now: () -> Date
    private var automaticDownload = false
    private var automaticCheck = false
    private var adapterToken: UUID?
    private var retryDownload = false
    private var cancelForQuit: (UUID, (Bool) -> Void)?
    private var timer: Timer?
    private var recoveryStartup = false
    var state: UpdateTaskState { preferences.pendingUpdate }
    var unavailableReason: String? { storageError == nil ? adapter.unavailableReason : "storage" }
    var canCheck: Bool { unavailableReason == nil && adapter.canCheck && !preparingInstallation && !requiresRecovery }
    var canDownload: Bool { unavailableReason == nil && state.phase == .available }
    var canCancel: Bool { [.checking, .downloading, .verifying, .packageReady, .waitingForTasks, .readyToInstall].contains(state.phase) && !preparingInstallation }
    var canChooseInstall: Bool { unavailableReason == nil && [.packageReady, .waitingForTasks, .readyToInstall].contains(state.phase) && !preparingInstallation }
    var requiresStartupHealthCheck: Bool { [.installing, .pendingRestart].contains(state.phase) }
    var requiresRecovery: Bool { backup.hasPendingRecovery || recovering || recoveryNeedsRestart ||
        state.failure.map { [.installing, .pendingRestart].contains($0.stage) } == true }
    var canRestorePreviousData: Bool { recoveryStartup && requiresRecovery && !recovering && !recoveryNeedsRestart &&
        storageError == nil && adapter.unavailableReason == nil && state.previousVersion == currentVersion &&
        state.previousBuild == currentBuild && state.backupPath != nil }

    init(adapter: UpdateAdapter, gate: UpdateInstallGate, store: UpdateStore = UpdateStore(),
         currentVersion: String, currentBuild: String, automaticCheck: Bool = true, now: @escaping () -> Date = Date.init) {
        self.adapter = adapter; self.gate = gate; self.store = store
        self.currentVersion = currentVersion; self.currentBuild = currentBuild; self.now = now
        backup = UpdateDataBackup(dataRoot: store.directory.deletingLastPathComponent(), updateRoot: store.directory)
        do { preferences = try store.load(automaticCheck: automaticCheck) }
        catch { preferences = UpdatePreferences(); storageError = error.localizedDescription }
        if storageError == nil, backup.hasPendingRecovery, let receipt = preferences.recoveryReceipt {
            do { try backup.finishRecovery(receipt) } catch { recoveryError = error.localizedDescription }
        }
        recoveryStartup = requiresStartupHealthCheck || requiresRecovery
        if storageError == nil && !requiresStartupHealthCheck {
            let old = preferences.pendingUpdate
            preferences.pendingUpdate.restoreAfterLaunch(version: currentVersion, build: currentBuild, trusted: false)
            if preferences.pendingUpdate != old { _ = save(preferences) }
        }
    }

    func restorePreviousData() async {
        guard canRestorePreviousData, let path = state.backupPath else { return }
        recovering = true; recoveryError = nil
        defer { recovering = false }
        do {
            let backup = self.backup, previous = currentVersion, build = currentBuild, target = state.release?.version
            let receipt = try await Task.detached {
                let directory = URL(fileURLWithPath: path), manifest = try backup.verify(URL(fileURLWithPath: path))
                guard manifest.previousVersion == previous, manifest.previousBuild == build, manifest.targetVersion == target else {
                    throw UpdateAdapterError(code: "recovery", detail: "Backup does not match this trusted version")
                }
                return try backup.restore(directory)
            }.value
            var next = preferences; next.skippedVersion = state.release?.identity
            next.automaticInstall = false; next.pendingUpdate = UpdateTaskState(); next.recoveryReceipt = receipt.path
            recoveryNeedsRestart = true
            guard save(next) else { return }
            try backup.finishRecovery(receipt.path)
        } catch { recoveryError = error.localizedDescription }
    }

    func startPolling() {
        guard timer == nil else { return }
        let value = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshGate() }
        }
        timer = value; RunLoop.main.add(value, forMode: .common)
    }
    func stopPolling() { timer?.invalidate(); timer = nil }

    func finishStartupHealthCheck(healthy: Bool) {
        guard requiresStartupHealthCheck, !backup.hasPendingRecovery else { return }
        var backupValid = false
        if let path = state.backupPath, let manifest = try? backup.verify(URL(fileURLWithPath: path)) {
            backupValid = manifest.targetVersion == state.release?.version && manifest.previousVersion == state.previousVersion && manifest.previousBuild == state.previousBuild
        }
        var next = preferences
        next.pendingUpdate.restoreAfterLaunch(version: currentVersion, build: currentBuild,
            trusted: healthy && backupValid && adapter.unavailableReason == nil)
        _ = save(next)
    }

    func setAutomaticCheck(_ value: Bool) { var next = preferences; next.automaticCheck = value; _ = save(next) }
    func setAutomaticInstall(_ value: Bool) {
        guard !value || unavailableReason == nil else { return }
        var next = preferences; next.automaticInstall = value
        let revoke = !value && (automaticDownload || state.choice == .automaticOnQuit)
        if revoke { next.pendingUpdate.cancel() }
        if save(next), revoke { automaticDownload = false; adapter.cancel() }
    }
    func check(manual: Bool) {
        guard canCheck, !requiresStartupHealthCheck else { return }
        if !manual {
            guard preferences.automaticCheck, state.phase != .failed,
                  preferences.remindAfter.map({ $0 <= now() }) ?? true,
                  preferences.lastCheck.map({ now().timeIntervalSince($0) >= 86400 || $0 > now() }) ?? true else { return }
        }
        var next = preferences; let token = next.pendingUpdate.beginCheck(); next.lastCheck = now()
        guard save(next) else { return }
        automaticDownload = !manual && preferences.automaticInstall
        automaticCheck = !manual; adapterToken = token
        do { try adapter.check(token: token) { [weak self] token, event in self?.receive(token, event) } }
        catch { fail(error, token: token) }
    }
    func download() {
        guard canDownload else { return }
        if !adapter.hasAvailableRelease {
            guard canCheck else { return }; retryDownload = true; check(manual: true); return
        }
        guard let release = state.release else { return }
        var next = preferences
        guard let token = next.pendingUpdate.beginDownload(), save(next) else { return }
        adapterToken = token
        do { try adapter.download(release, token: token) }
        catch { fail(error, token: token) }
    }
    func retry() {
        guard state.phase == .failed, canCheck else { return }
        retryDownload = state.failure?.stage != .checking
        check(manual: true)
    }
    func cancel() {
        guard canCancel else { return }
        adapter.cancel(); automaticDownload = false; retryDownload = false
        var next = preferences; next.pendingUpdate.cancel(); _ = save(next)
    }
    func skip() {
        guard state.phase == .available, let release = state.release else { return }
        var next = preferences; next.skippedVersion = release.identity; next.pendingUpdate = UpdateTaskState()
        if save(next) { adapter.cancel() }
    }
    func remindLater() {
        guard state.phase == .available else { return }
        var next = preferences; next.remindAfter = now().addingTimeInterval(86400); next.pendingUpdate = UpdateTaskState()
        if save(next) { adapter.cancel() }
    }

    func choose(_ choice: UpdateInstallChoice) {
        guard canChooseInstall else { return }
        var next = preferences; guard next.pendingUpdate.choose(choice) else { return }
        _ = next.pendingUpdate.admit(blockedBy: gate.blockers())
        guard save(next) else { return }
        if choice == .restartNow || choice == .afterTasks { Task { _ = await self.installPrepared(restart: true) } }
    }

    func refreshGate() {
        guard canChooseInstall, state.choice != .none else { return }
        let reasons = gate.blockers()
        if reasons != state.blockers {
            var next = preferences; _ = next.pendingUpdate.admit(blockedBy: reasons); guard save(next) else { return }
        }
        if state.choice == .afterTasks && !reasons.contains(where: { ["draft", "save", "journal", "tasks"].contains($0) }) {
            Task { _ = await self.installPrepared(restart: true) }
        }
    }

    // AppKit 的正常退出在这里等待，避免 Sparkle 将未获选择的准备任务随退出安装。
    func prepareForQuit(_ completion: @escaping (Bool) -> Void) {
        if recovering { completion(false); return }
        if [.installing, .pendingRestart].contains(state.phase) && state.choice != .none { completion(true); return }
        guard cancelForQuit == nil, !preparingInstallation else { completion(false); return }
        let selected = state.choice == .onQuit || state.choice == .automaticOnQuit && preferences.automaticInstall
        if selected && canChooseInstall {
            Task { completion(await self.installPrepared(restart: false)) }; return
        }
        guard adapter.hasActiveSession, let token = adapterToken else { completion(true); return }
        cancelForQuit = (token, completion)
        var next = preferences; next.pendingUpdate.cancel(); _ = save(next)
        adapter.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, let pending = self.cancelForQuit, pending.0 == token else { return }
            self.cancelForQuit = nil; pending.1(false)
        }
    }

    private func installPrepared(restart: Bool) async -> Bool {
        guard canChooseInstall, state.choice != .none, !preparingInstallation else { return false }
        if state.choice == .automaticOnQuit && !preferences.automaticInstall { return false }
        let reasons = gate.prepare()
        var next = preferences; guard next.pendingUpdate.admit(blockedBy: reasons) else { _ = save(next); return false }
        guard save(next) else { return false }
        let token = state.attempt, target = state.release?.version ?? ""
        preparingInstallation = true; defer { preparingInstallation = false }
        do {
            let backup = self.backup, previous = currentVersion, build = currentBuild
            let path = try await Task.detached { try backup.create(previous: previous, target: target, previousBuild: build) }.value
            _ = try backup.verify(path)
            guard state.attempt == token else { return false }
            next = preferences
            guard next.pendingUpdate.admit(blockedBy: gate.prepare()) else { _ = save(next); return false }
            next.pendingUpdate.backupPath = path.path; next.pendingUpdate.previousVersion = previous
            next.pendingUpdate.previousBuild = build; next.recoveryReceipt = nil
            guard next.pendingUpdate.installing(token: token), save(next) else { return false }
            try await adapter.install(restart: restart)
            next = preferences; _ = next.pendingUpdate.awaitingRestart(token: token); return save(next)
        } catch { fail(error, token: token); return false }
    }

    private func receive(_ token: UUID, _ event: UpdateAdapterEvent) {
        if case .ended = event {
            if adapterToken == token { adapterToken = nil }
            if let pending = cancelForQuit, pending.0 == token { cancelForQuit = nil; pending.1(true) }
            objectWillChange.send()
            return
        }
        guard state.attempt == token else { return }
        var next = preferences
        switch event {
        case .found(let release):
            if automaticCheck, let release, release.identity == preferences.skippedVersion {
                guard next.pendingUpdate.found(nil, token: token), save(next) else { return }
                adapter.cancel(); automaticDownload = false; return
            }
            guard next.pendingUpdate.found(release, token: token), save(next) else { return }
            if release != nil && (automaticDownload || retryDownload) { retryDownload = false; download() }
        case .progress(let value):
            if next.pendingUpdate.received(value, token: token) { preferences = next }
        case .preparing:
            if next.pendingUpdate.preparing(token: token) { _ = save(next) }
        case .verified:
            guard next.pendingUpdate.verified(token: token) else { return }
            if automaticDownload && preferences.automaticInstall { _ = next.pendingUpdate.choose(.automaticOnQuit) }
            _ = save(next)
        case .installing: break
        case .pendingRestart:
            if next.pendingUpdate.awaitingRestart(token: token) { _ = save(next) }
        case .failed(let code, let detail):
            if next.pendingUpdate.fail(code, detail: detail, token: token) { _ = save(next); adapter.cancel() }
        case .ended: break
        }
    }
    private func fail(_ error: Error, token: UUID) {
        var next = preferences
        if next.pendingUpdate.fail((error as? UpdateAdapterError)?.code ?? "operation", detail: error.localizedDescription, token: token) { _ = save(next); adapter.cancel() }
    }
    @discardableResult private func save(_ next: UpdatePreferences) -> Bool {
        guard storageError == nil else { return false }
        do { try store.save(next); preferences = next; return true }
        catch {
            storageError = error.localizedDescription; preferences.pendingUpdate.cancel(); adapter.cancel(); return false
        }
    }
}
