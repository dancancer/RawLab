import Foundation

enum IOSCameraMode { case importing, tethering }
enum IOSCameraPhase { case idle, connecting, browsing, ready, receiving, capturing, waiting, paused }
enum IOSCameraEvent {
    case phase(IOSCameraPhase)
    case device(CameraDeviceIdentity, CameraContentsFamily?)
    case assets([CameraRemoteAsset])
    case properties([UInt16: CameraProperty], writable: Bool, shutter: Bool)
    case manifest(CameraOriginalManifest)
    case incrementalJob(UUID)
    case progress(UUID, UInt64, UInt64)
    case thumbnail(String, Data)
    case preview(Data)
    case previewUnavailable
    case parameterFinished(Bool)
    case frame(Data, Date, UUID)
    case saved(CameraStoredOriginal)
    case failure(Error)
    case notice(String)
}

final class IOSCameraRun {
    let id = UUID(), endpoint: IOSCameraEndpoint
    let mode: IOSCameraMode
    let cardConfirmed: Bool
    let emit: (IOSCameraEvent) -> Void
    private let lock = NSLock()
    private var stopping = false
    private var session: SonyCameraSession?
    private var openingClient: CameraPTPClient?
    private var live: CameraLiveStream?
    private var frameTime: Date?
    private var liveToken = UUID()
    private var liveBeganAt: Date?
    // 下列调度状态只在 CameraWorkspaceBackend.queue 上访问。
    var knownAssets: [CameraRemoteAsset] = []
    var nextCardCheck: Date = .distantPast
    var lastHostHint: Int64 = 0
    var receiving = false
    init(endpoint: IOSCameraEndpoint, mode: IOSCameraMode, cardConfirmed: Bool, emit: @escaping (IOSCameraEvent) -> Void) {
        self.endpoint = endpoint; self.mode = mode; self.cardConfirmed = cardConfirmed; self.emit = emit
    }
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return stopping }
    var lastFrame: Date? { lock.lock(); defer { lock.unlock() }; return frameTime }
    func markFrame(_ date: Date) { lock.lock(); frameTime = date; lock.unlock() }
    func installing(_ client: CameraPTPClient) {
        lock.lock(); openingClient = client; let stopped = stopping; lock.unlock()
        if stopped { client.close() }
    }
    func install(_ value: SonyCameraSession) {
        lock.lock(); session = value; openingClient = nil; let stopped = stopping; lock.unlock()
        if stopped { value.requestStop() }
    }
    func currentSession() throws -> SonyCameraSession {
        lock.lock(); defer { lock.unlock() }
        guard !stopping, let session else { throw CameraProtocolError.cancelled }
        return session
    }
    var liveStarted: Date? { lock.lock(); defer { lock.unlock() }; return liveBeganAt }
    func isLiveCurrent(_ token: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return liveToken == token && !stopping }
    func beginLive() -> UUID {
        pauseLive()
        lock.lock(); defer { lock.unlock() }
        liveBeganAt = Date(); return liveToken
    }
    func installLive(_ value: CameraLiveStream, token: UUID) {
        lock.lock()
        let accepted = !stopping && liveToken == token
        if accepted { live = value }
        lock.unlock()
        if !accepted { value.close() }
    }
    func pauseLive() {
        lock.lock(); let old = live; live = nil; liveToken = UUID(); liveBeganAt = nil; frameTime = nil; lock.unlock()
        old?.close()
    }
    func stop() {
        lock.lock(); stopping = true
        let session = session, client = openingClient, live = live
        lock.unlock()
        session?.requestStop(); client?.close(); live?.close()
    }
    func finishSession() {
        lock.lock(); let current = session; session = nil; lock.unlock()
        current?.finish()
    }
}

final class CameraWorkspaceBackend {
    static let shared = CameraWorkspaceBackend()
    let queue = DispatchQueue(label: "rawlab.camera.owner", qos: .userInitiated)
    private var storage: CameraOriginalStore?
    private let ownerLock = NSLock()
    private var active: IOSCameraRun?
    private let clientID: UUID

    private init() {
        let defaults = UserDefaults.standard, key = "camera.ptpip.clientID"
        clientID = defaults.string(forKey: key).flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(clientID.uuidString, forKey: key)
    }
    private func store() throws -> CameraOriginalStore {
        if let storage { return storage }
        let created = try CameraOriginalStore(directory: CameraOriginalStore.applicationDirectory())
        storage = created; return created
    }
    func loadHistory(_ result: @escaping (Result<CameraOriginalManifest, Error>) -> Void) {
        queue.async { result(Result { try self.store().snapshot }) }
    }
    func dismissIncrementalJob(_ id: UUID, result: @escaping (Result<CameraOriginalManifest, Error>) -> Void) {
        queue.async {
            result(Result {
                let store = try self.store()
                try store.dismissIncrementalJob(id)
                return store.snapshot
            })
        }
    }
    private func owns(_ run: IOSCameraRun) -> Bool { ownerLock.lock(); defer { ownerLock.unlock() }; return active === run && !run.stopped }
    private func publishManifest(_ run: IOSCameraRun) { if let storage { run.emit(.manifest(storage.snapshot)) } }
    private func failure(_ error: Error, run: IOSCameraRun) {
        guard owns(run) else { return }
        run.stop(); run.emit(.phase(.paused)); run.emit(.failure(error)); publishManifest(run)
    }
    private func perform(_ run: IOSCameraRun, _ body: @escaping () throws -> Void) {
        queue.async {
            guard self.owns(run) else { return }
            do { try body() } catch { self.failure(error, run: run) }
        }
    }
    private func open(_ run: IOSCameraRun, purpose: CameraSessionPurpose) throws -> SonyCameraSession {
        guard owns(run) else { throw CameraProtocolError.cancelled }
        let session = try SonyCameraSession.open(host: run.endpoint.host, purpose: purpose, clientID: clientID, register: run.installing)
        run.install(session)
        guard owns(run) else { session.close(); throw CameraProtocolError.cancelled }
        return session
    }

    func connect(_ run: IOSCameraRun, resumeTether: Bool) {
        ownerLock.lock(); let previous = active; active = run; ownerLock.unlock()
        previous?.stop()
        perform(run) {
            previous?.finishSession()
            let store = try self.store()
            try store.recover()
            self.publishManifest(run)
            run.emit(.phase(.connecting))
            var session = try self.open(run, purpose: run.mode == .importing ? .importing : .tethering)
            run.emit(.device(session.device, session.family))
            if run.mode == .importing {
                let assets = try session.listAssets()
                run.knownAssets = assets; run.emit(.assets(assets)); run.emit(.phase(.browsing))
                return
            }
            if session.family != nil {
                let assets = try self.readCard(run)
                session = try run.currentSession()
                if resumeTether { try store.validateTetherResume(device: session.device, connectionKey: run.endpoint.connectionKey, assets: assets) }
                else { try store.beginTether(device: session.device, connectionKey: run.endpoint.connectionKey, baseline: assets) }
                run.knownAssets = assets
                if resumeTether {
                    try self.receivePendingTether(run, assets: assets)
                    try store.rebaseResumedTether(assets)
                    run.emit(.notice("Resumed registered transfers; import offline photos manually"))
                }
                session = try self.remoteSession(run)
            }
            self.publishManifest(run)
            try self.startRemoteDisplay(run, session: session)
            self.schedulePoll(run)
        }
    }
    func stop(_ run: IOSCameraRun?, completion: @escaping () -> Void = {}) {
        guard let run else { queue.async(execute: completion); return }
        ownerLock.lock(); if active === run { active = nil }; ownerLock.unlock()
        run.stop()
        queue.async {
            run.finishSession()
            completion()
        }
    }

    private func readCard(_ run: IOSCameraRun) throws -> [CameraRemoteAsset] {
        var session = try run.currentSession()
        if session.family == .legacy, !session.contentsEntered {
            run.pauseLive(); run.emit(.phase(.receiving)); run.finishSession()
            session = try open(run, purpose: .importing)
        }
        return try session.listAssets()
    }
    private func remoteSession(_ run: IOSCameraRun) throws -> SonyCameraSession {
        let session = try run.currentSession()
        if session.contentsEntered {
            run.pauseLive(); run.finishSession()
            return try open(run, purpose: .tethering)
        }
        return session
    }
    private func startRemoteDisplay(_ run: IOSCameraRun, session: SonyCameraSession) throws {
        let values = try session.properties()
        publishProperties(run, values: values, session: session)
        if let raw = values[0xd278]?.text {
            let url = try CameraWire.liveURL(raw, camera: run.endpoint.host)
            startLive(run, url: url)
        } else { run.emit(.notice("Camera live view is unavailable")) }
        let pending = try store().snapshot.tether?.shutterRequestedAt != nil
        run.emit(.phase(session.family == nil || !pending ? .ready : .waiting))
        run.nextCardCheck = Date().addingTimeInterval(session.family == .legacy ? 120 : 1.5)
    }
    private func publishProperties(_ run: IOSCameraRun, values: [UInt16: CameraProperty], session: SonyCameraSession) {
        let pending = storage?.snapshot.tether?.shutterRequestedAt != nil
        run.emit(.properties(values, writable: session.canWriteParameters,
            shutter: session.captureReady(values, cardConfirmed: run.cardConfirmed) && !pending && !run.receiving))
    }
    private func startLive(_ run: IOSCameraRun, url: URL) {
        let token = run.beginLive()
        DispatchQueue(label: "rawlab.camera.liveview", qos: .userInitiated).async { [weak self] in
            guard let self, self.owns(run) else { return }
            var stream: CameraLiveStream?
            do {
                let opened = try CameraLiveStream(host: run.endpoint.host, url: url); stream = opened; run.installLive(opened, token: token)
                var lastDelivered = Date.distantPast
                while self.owns(run), run.isLiveCurrent(token) {
                    let bytes = try opened.frame(), now = Date()
                    if run.isLiveCurrent(token), now.timeIntervalSince(lastDelivered) >= 0.1 {
                        run.emit(.frame(bytes, now, token)); lastDelivered = now
                    }
                }
            } catch {
                // 主命令队列决定是否仍为当前取景；切换 legacy 卡模式的主动关闭不算连接失败。
                self.queue.async {
                    guard self.owns(run), run.isLiveCurrent(token) else { return }
                    self.failure(error, run: run)
                }
            }
            stream?.close()
        }
    }

    private func schedulePoll(_ run: IOSCameraRun) {
        queue.asyncAfter(deadline: .now() + 1.5) {
            guard self.owns(run) else { return }
            do { try self.poll(run); self.schedulePoll(run) }
            catch CameraProtocolError.response(let op, let code) where op == 0x923c && code == 0x2005 {
                // 完整远端忙响应已对齐；只重读卡，不重发快门。
                self.schedulePoll(run)
            } catch { self.failure(error, run: run) }
        }
    }
    private func poll(_ run: IOSCameraRun) throws {
        let session = try run.currentSession()
        let properties = try session.properties()
        publishProperties(run, values: properties, session: session)
        if let began = run.liveStarted {
            if let frame = run.lastFrame {
                if Date().timeIntervalSince(frame) > 5 { throw CameraProtocolError.timeout }
            } else if Date().timeIntervalSince(began) > 8 { throw CameraProtocolError.timeout }
        }
        let store = try store(), record = store.snapshot.tether
        let pending = record?.shutterRequestedAt != nil
        let hostHint = properties[0xd215]?.number ?? 0
        let newHostHint = hostHint & 0x8000 != 0 && hostHint != run.lastHostHint
        run.lastHostHint = hostHint
        if session.family != nil, Date() >= run.nextCardCheck || newHostHint || pending && session.family == .legacy {
            let wasLegacy = session.family == .legacy
            run.receiving = true
            defer { run.receiving = false }
            let assets = try readCard(run)
            try receivePendingTether(run, assets: assets)
            run.knownAssets = assets
            let baseline = store.snapshot.tether?.baseline ?? []
            let newAssets = assets.filter { !baseline.contains($0.snapshot.key) }
            if !newAssets.isEmpty {
                var batch: [CameraAssetSnapshot] = [], bytes: UInt64 = 0
                for asset in newAssets {
                    guard asset.snapshot.transferable else { throw CameraProtocolError.unsupported("A new camera original exceeds the transfer budget") }
                    if batch.count == 64 || bytes + asset.snapshot.size > 2 << 30 { break }
                    batch.append(asset.snapshot); bytes += asset.snapshot.size
                }
                let job = try store.registerTetherAssets(batch)
                publishManifest(run)
                try receive(job, assets: assets, run: run)
            }
            try store.finishConfirmedShutter(owner: run.id)
            publishManifest(run)
            if wasLegacy { try startRemoteDisplay(run, session: remoteSession(run)) }
            else { run.emit(.phase(store.snapshot.tether?.shutterRequestedAt == nil ? .ready : .waiting)) }
            run.nextCardCheck = Date().addingTimeInterval(wasLegacy ? 120 : 1.5)
        }
        if let record = store.snapshot.tether, record.shutterOwner == run.id, let requested = record.shutterRequestedAt,
           Date().timeIntervalSince(requested) > 35 { throw CameraProtocolError.captureUnknown }
    }

    private func receivePendingTether(_ run: IOSCameraRun, assets: [CameraRemoteAsset]) throws {
        let snapshot = try store().snapshot
        let ids = Set(snapshot.tether?.jobIDs ?? [])
        for job in snapshot.jobs where ids.contains(job.id) && !job.complete {
            try receive(job, assets: assets, run: run)
        }
    }
    private func receive(_ job: CameraTransferJob, assets: [CameraRemoteAsset], run: IOSCameraRun) throws {
        let store = try store(), session = try run.currentSession()
        let sameCamera = job.incremental == nil
            ? job.camera.stableKey == session.device.stableKey && job.connectionKey == run.endpoint.connectionKey
            : job.matches(camera: session.device, connectionKey: run.endpoint.connectionKey)
        guard sameCamera else {
            throw CameraProtocolError.invalid("Transfer belongs to a different camera")
        }
        run.emit(.phase(.receiving))
        let bound = job.bindToListing(assets)
        for item in job.pendingItems {
            guard owns(run) else { throw CameraProtocolError.cancelled }
            guard let asset = bound[item.id] else {
                let error = CameraProtocolError.invalid("Camera original changed; select it again")
                try store.interrupt(job: job.id, item: item.id, error: error.localizedDescription, cancelled: false)
                throw error
            }
            let target = try store.begin(job: job.id, item: item.id)
            do {
                let digest = try session.download(asset, to: target.handle) { bytes in
                    run.emit(.progress(item.id, bytes, item.asset.size))
                }
                try target.handle.close()
                let original = try store.complete(job: job.id, item: item.id, digest: digest)
                publishManifest(run); run.emit(.saved(original))
            } catch {
                try? target.handle.close()
                try? store.interrupt(job: job.id, item: item.id, error: error.localizedDescription, cancelled: run.stopped)
                publishManifest(run); throw error
            }
        }
    }
    func importAssets(_ assets: [CameraRemoteAsset], incremental: CameraIncrementalPlan? = nil, run: IOSCameraRun) {
        perform(run) {
            guard run.mode == .importing, !run.receiving else { throw CameraProtocolError.invalid("Camera import is busy") }
            run.receiving = true; defer { run.receiving = false }
            let session = try run.currentSession()
            guard assets.allSatisfy({ $0.owner == session.id }) else { throw CameraProtocolError.invalid("Camera selection belongs to an old session") }
            let job = try self.store().enqueue(device: session.device, connectionKey: run.endpoint.connectionKey,
                                              assets: assets.map(\.snapshot), incremental: incremental)
            self.publishManifest(run)
            if incremental != nil { run.emit(.incrementalJob(job.id)) }
            try self.receive(job, assets: run.knownAssets, run: run)
            run.emit(.phase(.browsing))
        }
    }
    func resumeImport(jobID: UUID, run: IOSCameraRun) {
        perform(run) {
            guard run.mode == .importing, !run.receiving else { return }
            run.receiving = true; defer { run.receiving = false }
            let store = try self.store()
            try store.recover()
            self.publishManifest(run)
            guard let job = store.snapshot.jobs.first(where: { $0.id == jobID }) else {
                throw CameraProtocolError.invalid("Camera transfer job is missing")
            }
            if job.incremental != nil { run.emit(.incrementalJob(job.id)) }
            let assets = try run.currentSession().listAssets()
            run.knownAssets = assets; run.emit(.assets(assets))
            try self.receive(job, assets: assets, run: run)
            run.emit(.phase(.browsing))
        }
    }
    func refreshImport(_ run: IOSCameraRun) {
        perform(run) {
            guard run.mode == .importing, !run.receiving else { return }
            let assets = try run.currentSession().listAssets()
            run.knownAssets = assets
            run.emit(.assets(assets))
        }
    }
    func thumbnail(_ asset: CameraRemoteAsset, run: IOSCameraRun, large: Bool) {
        queue.async {
            guard self.owns(run), !run.receiving else { return }
            do {
                let data = try run.currentSession().preview(asset, large: large)
                run.emit(large ? .preview(data) : .thumbnail(asset.id, data))
            } catch CameraProtocolError.response { run.emit(large ? .previewUnavailable : .thumbnail(asset.id, Data())) }
            catch CameraProtocolError.unsupported { run.emit(large ? .previewUnavailable : .thumbnail(asset.id, Data())) }
            catch { self.failure(error, run: run) }
        }
    }
    func setParameter(_ code: UInt16, value: Int64, run: IOSCameraRun) {
        perform(run) {
            guard !run.receiving, run.mode == .tethering else { return }
            let session = try run.currentSession(), result = try session.setParameter(code, value: value)
            self.publishProperties(run, values: result.values, session: session)
            run.emit(.parameterFinished(result.confirmed))
        }
    }
    func capture(_ run: IOSCameraRun) {
        perform(run) {
            guard !run.receiving, run.mode == .tethering else { return }
            let store = try self.store(), session = try run.currentSession()
            guard store.snapshot.tether?.shutterRequestedAt == nil else { throw CameraProtocolError.captureUnknown }
            run.emit(.phase(.capturing))
            do {
                try session.capture(cardConfirmed: run.cardConfirmed) { try store.markShutterRequested(owner: run.id) }
                try store.acknowledgeShutter(owner: run.id)
                self.publishManifest(run); run.nextCardCheck = Date().addingTimeInterval(3)
                run.emit(.phase(.waiting))
            } catch CameraProtocolError.captureNotSent(let reason) {
                try store.clearUnsentShutter(owner: run.id)
                self.publishManifest(run); run.emit(.notice(reason)); run.emit(.phase(.ready))
            } catch {
                self.publishManifest(run); throw CameraProtocolError.captureUnknown
            }
        }
    }
    func original(_ sourceID: UUID, result: @escaping (Result<URL, Error>) -> Void) {
        queue.async { result(Result { try self.store().verifiedURL(sourceID) }) }
    }
}
