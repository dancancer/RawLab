import Foundation

protocol UsageSDKBackend: AnyObject {
    func start() throws
    func record(_ event: UsageEvent)
    func stop() throws
}

final class SerialUsageTransport: UsageAnalyticsTransport, UsageTransportFailureReporting, UsageTransportAvailability {
    var isAvailable: Bool { lock.lock(); defer { lock.unlock() }; return !retired }
    var unavailableReason: String? { isAvailable ? nil : "本地验证 SDK 已停止，请重启应用后重新开启统计。" }
    var onFailure: (() -> Void)?
    private let backend: UsageSDKBackend
    private let queue = DispatchQueue(label: "RawLab.usage.sdk", qos: .utility)
    private let lock = NSLock()
    private var enabled = false
    private var generation = 0
    private var pending = 0
    private var failed = false
    private var retired = false
    private let allowsRestart: Bool
    var hasFailed: Bool { lock.lock(); defer { lock.unlock() }; return failed }
    // SDK 状态只在 queue 上访问；撤回标记由调用线程立即更新。
    private var running = false
    private var closeFailed = false
    private var countedLaunch = false

    init(backend: UsageSDKBackend, allowsRestart: Bool = true) {
        self.backend = backend; self.allowsRestart = allowsRestart
    }
    func start() throws {
        lock.lock()
        guard !retired else { lock.unlock(); throw CocoaError(.featureUnsupported) }
        generation += 1; enabled = true; failed = false
        let token = generation
        lock.unlock()
        queue.async { [self] in
            guard accepts(token) else { return }
            do {
                try backend.start(); running = true
                // 异步启动被撤回时不计启动；只在真实 SDK 就绪后记录一次。
                if accepts(token), !countedLaunch {
                    backend.record(.appStarted); countedLaunch = true
                }
            }
            catch {
                do { try backend.stop() }
                catch { closeFailed = true }
                lock.lock()
                let current = generation == token && enabled
                if current { enabled = false; failed = true }
                if !allowsRestart || closeFailed { retired = true }
                lock.unlock()
                if current { onFailure?() }
            }
        }
    }
    func record(_ event: UsageEvent) {
        guard event != .appStarted else { return }
        lock.lock()
        guard enabled, pending < 32 else { lock.unlock(); return }
        let token = generation
        pending += 1
        lock.unlock()
        queue.async { [self] in
            defer { lock.lock(); pending -= 1; lock.unlock() }
            guard accepts(token), running else { return }
            backend.record(event)
        }
    }
    func stop() {
        lock.lock(); enabled = false; generation += 1
        if !allowsRestart { retired = true }
        lock.unlock()
        queue.async { [self] in
            guard running, !closeFailed else { return }
            do { try backend.stop(); running = false }
            catch {
                closeFailed = true
                lock.lock(); retired = true; failed = true; lock.unlock()
                onFailure?()
            }
        }
    }
    // 仅供独立验证器/退出协调使用，禁止在界面线程等待。
    func waitUntilIdle() { queue.sync {} }
    func whenIdle(_ completion: @escaping () -> Void) { queue.async(execute: completion) }
    private func accepts(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled && !retired && generation == token
    }
}
