import AppKit
import Combine
import Darwin

final class MacUpdateRunLease {
    private let descriptor: Int32
    init(directory: URL = UpdateStore.defaultDirectory) throws {
        let current = ProcessInfo.processInfo.processIdentifier
        guard !NSWorkspace.shared.runningApplications.contains(where: {
            $0.processIdentifier != current && $0.bundleIdentifier == "com.rawtools.rawlab.mac"
        }) else { throw UpdateAdapterError(code: "other_instance", detail: "") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent("run.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw UpdateAdapterError(code: "storage", detail: "") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); throw UpdateAdapterError(code: "other_instance", detail: "")
        }
        self.descriptor = descriptor
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

@MainActor final class MacUpdateRuntime: ObservableObject {
    @Published private(set) var model: EditorModel?
    @Published private(set) var controller: DesktopUpdateController?
    @Published private(set) var startupError: String?
    let legacy = UpdateChecker()
    private var lease: MacUpdateRunLease?
    private var started = false
    private var controllerChanges: AnyCancellable?

    func start(delegate: RawLabMacDelegate) async {
        guard !started else { return }; started = true
        do { lease = try MacUpdateRunLease() }
        catch { startupError = (error as? UpdateAdapterError)?.code ?? "storage"; return }
        let adapter = await makeMacUpdateAdapter()
        let updates = DesktopUpdateController(adapter: adapter, gate: UpdateInstallGate(),
            currentVersion: legacy.currentVersion,
            currentBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            automaticCheck: legacy.automatic)
        controller = updates
        delegate.updates = updates
        controllerChanges = updates.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if updates.storageError != nil || updates.requiresRecovery { startupError = "recovery"; return }
        let candidate = EditorModel(onUsage: { UsageAnalytics.shared.record($0) })
        candidate.registerUpdateGate(updates.gate)
        updates.retryStartup = { [weak self, weak delegate] in
            guard let self, let delegate else { return }
            Task { await self.openEditor(candidate, updates: updates, delegate: delegate) }
        }
        await openEditor(candidate, updates: updates, delegate: delegate)
    }

    private func openEditor(_ candidate: EditorModel, updates: DesktopUpdateController, delegate: RawLabMacDelegate) async {
        await updates.finishStartupHealthCheck(healthy: candidate.updateDataHealthy && updates.storageError == nil)
        if updates.requiresStartupHealthCheck && !updates.requiresRecovery {
            startupError = "trust"; return
        }
        if updates.storageError != nil || updates.requiresRecovery {
            startupError = "recovery"; return
        }
        startupError = nil; updates.retryStartup = nil
        model = candidate
        delegate.model = candidate
        updates.startPolling()
        if legacy.automatic != updates.preferences.automaticCheck { legacy.automatic = updates.preferences.automaticCheck }
        if updates.unavailableReason != nil { await legacy.check(manual: false) }
        else { updates.check(manual: false) }
    }
}
