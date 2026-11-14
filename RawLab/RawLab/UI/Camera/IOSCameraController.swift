import SwiftUI
import ImageIO

enum IOSCameraParameter: CaseIterable, Identifiable {
    case shutter, aperture, iso, exposureCompensation, whiteBalance, focus, temperature
    var id: Self { self }
    var code: UInt16 {
        switch self {
        case .shutter: return 0xd20d
        case .aperture: return 0x5007
        case .iso: return 0xd21e
        case .exposureCompensation: return 0x5010
        case .whiteBalance: return 0x5005
        case .focus: return 0x500a
        case .temperature: return 0xd20f
        }
    }
    var title: String {
        switch self {
        case .shutter: return L10n.text("快门")
        case .aperture: return L10n.text("光圈")
        case .iso: return "ISO"
        case .exposureCompensation: return L10n.text("曝光补偿")
        case .whiteBalance: return L10n.text("白平衡")
        case .focus: return L10n.text("对焦模式")
        case .temperature: return L10n.text("色温")
        }
    }
    func descriptor(in properties: [UInt16: CameraProperty]) -> CameraProperty? {
        let codes = self == .iso ? [code, 0xd226] : [code]
        let available = codes.compactMap { properties[$0] }.filter { SonyCameraSession.parameterType($0.code) == $0.type }
        return available.first { $0.writable && $0.enabled == 1 && !$0.selectableValues.isEmpty } ?? available.first
    }
    func display(_ value: Int64) -> String {
        switch self {
        case .shutter:
            if value == 0 { return "Bulb" }
            let top = value >> 16 & 65535, bottom = value & 65535
            guard bottom > 0 else { return String(format: "0x%X", value) }
            return top % bottom == 0 ? "\(top / bottom) s" : "\(top)/\(bottom) s"
        case .aperture: return String(format: "f/%.1f", Double(value) / 100)
        case .iso:
            let sensitivity = value & 0xffffff, mode = value >> 24
            let base = sensitivity == 0xffffff ? L10n.text("自动") : String(sensitivity)
            return base + (mode == 0 ? "" : mode == 1 ? " · MFNR" : mode == 2 ? " · MFNR+" : "")
        case .exposureCompensation: return String(format: value > 0 ? "+%.1f EV" : "%.1f EV", Double(value) / 1000)
        case .temperature: return "\(value) K"
        case .focus:
            return [1: "MF", 2: "AF", 0x8004: "AF-C", 0x8005: "AF-A", 0x8006: "DMF", 0x8008: "AF-D"][value]
                ?? String(format: "0x%X", value)
        case .whiteBalance:
            let known: [Int64: String] = [2: "AWB", 4: L10n.text("日光"), 6: L10n.text("白炽灯"), 7: L10n.text("闪光灯"),
                0x8010: L10n.text("阴天"), 0x8011: L10n.text("阴影"), 0x8012: L10n.text("色温"),
                0x8001: "FL W", 0x8002: "FL C", 0x8003: "FL D", 0x8004: "FL Day"]
            return known[value] ?? String(format: "0x%X", value)
        }
    }
}

struct IOSCameraImportPreferences: Codable {
    var incremental = false
    var format = CameraImportFormat.rawAndJPEG
    var jpeg = CameraJPEGOptions()
}

@MainActor final class IOSCameraController: ObservableObject {
    @Published private(set) var phase = IOSCameraPhase.idle
    @Published private(set) var device: CameraDeviceIdentity?
    @Published private(set) var assets: [CameraRemoteAsset] = []
    @Published private(set) var properties: [UInt16: CameraProperty] = [:]
    @Published private(set) var manifest = CameraOriginalManifest()
    @Published private(set) var thumbnails: [String: UIImage] = [:]
    @Published private(set) var preview: UIImage?
    @Published private(set) var previewLoading = false
    @Published private(set) var frame: UIImage?
    @Published private(set) var frameAt: Date?
    @Published private(set) var progress: (id: UUID, bytes: UInt64, total: UInt64)?
    @Published private(set) var parameterBusy = false
    @Published private(set) var writable = false
    @Published private(set) var shutterReady = false
    @Published private(set) var savedCount = 0
    @Published private(set) var latestOriginal: CameraStoredOriginal?
    @Published private(set) var importPreferences = IOSCameraImportPreferences()
    @Published private(set) var scanning = false
    @Published private(set) var incrementalJobID: UUID?
    @Published var customCutoff: Date?
    @Published var includeUndated = false
    @Published var notice: String? {
        didSet {
            if !updatingListingLimitNotice {
                showingListingLimitNotice = false
            }
        }
    }
    @Published var selection: Set<String> = []
    private var showingListingLimitNotice = false
    private var updatingListingLimitNotice = false
    private var unavailableThumbnails: Set<String> = []
    private var pendingThumbnails: Set<String> = []
    private var thumbnailOrder: [String] = []
    private var run: IOSCameraRun?
    private var sessionStartedAt = Date.distantFuture
    private var contentsFamily: CameraContentsFamily?
    private let backend: CameraWorkspaceBackend
    private var skippedCameraKey: String?
    private(set) var endpoint: IOSCameraEndpoint?
    private(set) var mode = IOSCameraMode.importing
    @Published private(set) var originalBrowsingAvailable = true
    @Published private(set) var manualImportRequired = false
    @Published private(set) var listingLimitExceeded = false
    @Published private(set) var skippedAssets: [CameraAssetSnapshot] = []

    init(backend: CameraWorkspaceBackend = .shared) {
        self.backend = backend
        reloadHistory()
    }
    var connected: Bool { run != nil && phase != .connecting && phase != .paused && phase != .idle }
    var busy: Bool { [.connecting, .receiving, .capturing].contains(phase) || parameterBusy || scanning }
    var selectedAssets: [CameraRemoteAsset] { assets.filter { selection.contains($0.id) } }
    var selectionBytes: UInt64 { selectedAssets.reduce(0) { $0 + $1.snapshot.size } }
    var selectionAllowed: Bool {
        !selectedAssets.isEmpty && selectedAssets.count <= 64 && selectionBytes <= 2 << 30 && selectedAssets.allSatisfy { $0.snapshot.transferable }
    }
    var canCapture: Bool { connected && phase == .ready && !parameterBusy && shutterReady && originalBrowsingAvailable }
    var hasUnknownShot: Bool { manifest.tether?.shutterRequestedAt != nil }
    var unfinishedJobs: [CameraTransferJob] { manifest.jobs.filter { $0.dismissed != true && !$0.pendingItems.isEmpty }.reversed() }
    var originals: [CameraStoredOriginal] { manifest.originals.reversed() }
    var pendingIncrementalJob: CameraTransferJob? {
        guard let device, let endpoint else { return nil }
        return manifest.pendingIncrementalJob(device: device, connectionKey: endpoint.connectionKey)
    }
    var displayedIncrementalJob: CameraTransferJob? {
        manifest.jobs.first { $0.id == incrementalJobID } ?? pendingIncrementalJob
    }
    var cameraTimeZone: TimeZone { contentsFamily == .legacy ? .gmt : .current }
    var recentTetherOriginals: [CameraStoredOriginal] {
        let jobs = Set(manifest.tether?.jobIDs ?? [])
        let ids = Set(manifest.jobs.filter { jobs.contains($0.id) }.flatMap(\.items).compactMap(\.sourceID))
        return originals.filter { ids.contains($0.id) }
    }

    func connect(endpoint: IOSCameraEndpoint, mode: IOSCameraMode, cardConfirmed: Bool, resume: Bool) {
        manualImportRequired = false; listingLimitExceeded = false
        skippedCameraKey = nil; skippedAssets = []
        self.endpoint = endpoint; self.mode = mode; sessionStartedAt = Date()
        scanning = false; incrementalJobID = nil; contentsFamily = nil
        customCutoff = nil; includeUndated = false
        assets = []; selection = []; thumbnails = [:]; pendingThumbnails = []; unavailableThumbnails = []; thumbnailOrder = []
        latestOriginal = nil; previewLoading = false
        properties = [:]; device = nil; writable = false; shutterReady = false; parameterBusy = false
        preview = nil; frame = nil; frameAt = nil; progress = nil; savedCount = 0; notice = nil; phase = .connecting
        let owner = UUID()
        callbackOwner = owner
        let next = IOSCameraRun(endpoint: endpoint, mode: mode, cardConfirmed: cardConfirmed) { [weak self] event in
            Task { @MainActor in
                guard let self, self.callbackOwner == owner else { return }
                self.accept(event)
            }
        }
        run = next
        backend.connect(next, resumeTether: resume)
    }
    private var callbackOwner = UUID()
    private func accept(_ event: IOSCameraEvent) {
        switch event {
        case .phase(let value):
            phase = value
            if value == .browsing || value == .ready { pendingThumbnails = [] }
        case .device(let value, let family):
            device = value; contentsFamily = family; originalBrowsingAvailable = family != nil
            syncSkippedAssets()
            if mode == .importing {
                let saved = importPreferencesKey.flatMap { UserDefaults.standard.data(forKey: $0) }
                importPreferences = saved.flatMap { try? JSONDecoder().decode(IOSCameraImportPreferences.self, from: $0) }
                    ?? IOSCameraImportPreferences()
            }
        case .assets(let values):
            if assets.first?.owner != values.first?.owner {
                customCutoff = nil; includeUndated = false
            }
            listingLimitExceeded = false
            assets = values; selection.formIntersection(Set(values.map(\.id))); scanning = false
        case .properties(let values, let writable, let shutter): properties = values; self.writable = writable; shutterReady = shutter
        case .manifest(let value):
            let wasComplete = incrementalJobID.flatMap { id in manifest.jobs.first { $0.id == id }?.complete } == true
            manifest = value
            syncSkippedAssets()
            if !wasComplete, incrementalJobID.flatMap({ id in value.jobs.first { $0.id == id }?.complete }) == true {
                customCutoff = nil; includeUndated = false
            }
        case .incrementalJob(let id):
            incrementalJobID = id
            if !importPreferences.incremental { setIncrementalMode(true) }
        case .progress(let id, let bytes, let total): progress = (id, bytes, total)
        case .thumbnail(let id, let bytes):
            pendingThumbnails.remove(id)
            if let image = Self.decode(bytes, edge: 512) { cache(image, key: id) }
            else { unavailableThumbnails.insert(id) }
        case .preview(let bytes):
            previewLoading = false; preview = Self.decode(bytes, edge: 2048)
            if preview == nil { notice = L10n.text("预览不可用") }
        case .previewUnavailable: previewLoading = false; notice = L10n.text("预览不可用")
        case .parameterFinished(let confirmed):
            parameterBusy = false
            if !confirmed { notice = L10n.text("设置结果未确认，请重新连接后检查。") }
        case .frame(let bytes, let date, let token):
            guard let run, run.isLiveCurrent(token), let decoded = Self.decode(bytes, edge: 2048) else { return }
            frame = decoded; frameAt = date; run.markFrame(date)
        case .saved(let original):
            latestOriginal = original; savedCount += 1; progress = nil
        case .failure(let error):
            parameterBusy = false; previewLoading = false; shutterReady = false; scanning = false; progress = nil
            if case CameraProtocolError.tetherRecoveryRequired = error { manualImportRequired = true }
            else { manualImportRequired = false }
            if case CameraProtocolError.photoLimitExceeded = error {
                listingLimitExceeded = true
                updatingListingLimitNotice = true
                showingListingLimitNotice = true
                notice = message(error)
                updatingListingLimitNotice = false
            } else {
                notice = message(error)
            }
        case .listingLimitCleared:
            listingLimitExceeded = false
            if showingListingLimitNotice {
                showingListingLimitNotice = false
                notice = nil
            }
        case .notice(let detail):
            parameterBusy = false
            switch detail {
            case "": notice = nil
            case "Camera live view is unavailable": notice = L10n.text("相机未提供实时取景，其他可用功能仍可使用。")
            case "Resumed registered transfers; import offline photos manually": notice = L10n.text("已恢复已登记的接收任务。断线期间拍摄的照片请从相机手动导入。")
            default: notice = L10n.text("请将相机设为单张拍摄，并确认照片同时保存到相机存储卡。")
            }
        }
    }
    func clearNotice() {
        notice = nil; manualImportRequired = false
    }
    func stop(completion: @escaping () -> Void = {}) {
        let previous = run
        callbackOwner = UUID(); run = nil; phase = .paused; parameterBusy = false; shutterReady = false
        previewLoading = false; pendingThumbnails = []; scanning = false; progress = nil; listingLimitExceeded = false
        backend.stop(previous) { [weak self] in
            Task { @MainActor in self?.reloadHistory(); completion() }
        }
    }
    func reloadHistory() {
        backend.loadHistory { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let snapshot):
                    self?.manifest = snapshot
                    self?.syncSkippedAssets()
                case .failure: self?.notice = L10n.text("无法保存导入记录或原件。请检查可用空间后重试。")
                }
            }
        }
    }
    func importSelected() {
        guard let run, mode == .importing, phase == .browsing, !scanning, selectionAllowed else { return }
        phase = .receiving; notice = nil
        backend.importAssets(selectedAssets, run: run)
    }
    func resumeImport(_ job: CameraTransferJob) {
        guard let run, mode == .importing, phase == .browsing, !scanning else { return }
        phase = .receiving; notice = nil; backend.resumeImport(jobID: job.id, run: run)
    }
    private func syncSkippedAssets() {
        guard let device, let endpoint else { return }
        let bucket = CameraOriginalManifest.cameraBucket(device: device, connectionKey: endpoint.connectionKey)
        skippedCameraKey = bucket
        skippedAssets = manifest.skippedAssets(for: device, connectionKey: endpoint.connectionKey)
    }
    func skipFailedIncrementalItems(_ job: CameraTransferJob) {
        guard !busy, !job.failedItems.isEmpty else { return }
        applyIncrementalManifestAction(jobID: job.id) { done in backend.skipFailedIncrementalItems(job.id, result: done) }
    }
    func dismissIncrementalJob(_ job: CameraTransferJob) {
        guard !busy else { return }
        applyIncrementalManifestAction(jobID: job.id) { done in backend.dismissIncrementalJob(job.id, result: done) }
    }
    private func applyIncrementalManifestAction(jobID: UUID,
                                                _ execute: (@escaping (Result<CameraOriginalManifest, Error>) -> Void) -> Void) {
        let owner = callbackOwner
        scanning = true
        execute { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                guard self.callbackOwner == owner else { self.reloadHistory(); return }
                self.scanning = false
                switch result {
                case .success(let snapshot):
                    self.manifest = snapshot
                    self.syncSkippedAssets()
                    if self.incrementalJobID == jobID { self.incrementalJobID = nil }
                    self.notice = nil
                case .failure:
                    self.notice = L10n.text("无法保存导入记录或原件。请检查可用空间后重试。")
                }
            }
        }
    }
    // Q6：相机保存位置页的手动清理入口，回传被清理的原件数与释放字节。
    @Published private(set) var cleaningOriginals = false
    @Published private(set) var lastOriginalsCleanup: (originals: Int, freedBytes: UInt64)?
    @Published private(set) var originalsCleanupFailed = false
    var storedOriginalsCount: Int { manifest.originals.count }
    var storedOriginalsBytes: UInt64 { manifest.originals.reduce(0) { $0 + $1.size } }
    // 证据采集（ExportEvidenceStore 持久账本读取）由 App 启动时注入 provider，在 backend 队列
    // 上执行；「已导出」= 保存图库 / Files 另存 / 渲染 DNG / 批量导出成功后登记的内容标识
    // （打开过编辑器不算——RecentPhotoStore 是会被淘汰的 LRU）。模型测试不注入 = 无证据。
    static var exportedContentIdentifiersProvider: () -> Set<String> = { [] }
    func pruneExportedOriginals() {
        guard !cleaningOriginals else { return }
        let owner = callbackOwner
        cleaningOriginals = true
        lastOriginalsCleanup = nil
        originalsCleanupFailed = false
        backend.pruneExportedOriginals(exportedContentIdentifiers: Self.exportedContentIdentifiersProvider) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                guard self.callbackOwner == owner else { self.reloadHistory(); return }
                self.cleaningOriginals = false
                switch result {
                case .success(let pruned):
                    self.manifest = pruned.manifest
                    self.lastOriginalsCleanup = (pruned.originals, pruned.freedBytes)
                case .failure:
                    self.originalsCleanupFailed = true
                    self.notice = L10n.text("清理已导出的相机原件失败，请重试。")
                }
            }
        }
    }
    private var importPreferencesKey: String? {
        guard let device, let endpoint else { return nil }
        let cameraKey = device.serial.isEmpty ? device.stableKey + "|" + endpoint.connectionKey : device.stableKey
        return "camera.incremental.preferences." + cameraKey
    }
    private func persistImportPreferences() {
        guard let key = importPreferencesKey, let data = try? JSONEncoder().encode(importPreferences) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
    func setIncrementalMode(_ value: Bool) {
        importPreferences.incremental = value
        persistImportPreferences()
    }
    func setImportFormat(_ value: CameraImportFormat) {
        importPreferences.format = value
        persistImportPreferences()
    }
    func setJPEGOptions(_ value: CameraJPEGOptions) {
        guard value.isValid else { return }
        importPreferences.jpeg = value
        persistImportPreferences()
    }
    private var defaultIncrementalStart: Date {
        let now = Date()
        guard contentsFamily == .legacy else { return Calendar.current.startOfDay(for: now) }
        let wallDay = Calendar.current.dateComponents([.year, .month, .day], from: now)
        var cameraCalendar = Calendar(identifier: .gregorian)
        cameraCalendar.timeZone = .gmt
        return cameraCalendar.date(from: wallDay) ?? cameraCalendar.startOfDay(for: now)
    }
    func incrementalScan(customCutoff: Date?, includeUndated: Bool) -> CameraIncrementalScan {
        let boundaries = device.flatMap { device in
            endpoint.map { manifest.incrementalBoundaries(device: device, connectionKey: $0.connectionKey) }
        } ?? [:]
        let savedKeys: Set<String>
        if let owner = assets.first?.owner, customCutoff == nil {
            savedKeys = manifest.savedIncrementalKeys(owner: owner, jpeg: importPreferences.jpeg)
        } else { savedKeys = [] }
        let skippedKeys: Set<String>
        if skippedAssets.isEmpty {
            skippedKeys = []
        } else {
            let exact = Set(skippedAssets.map(\.key))
            let locators = Set(skippedAssets.map(\.withoutLocator))
            skippedKeys = Set(assets.compactMap { asset in
                exact.contains(asset.snapshot.key) || locators.contains(asset.snapshot.withoutLocator)
                    ? asset.snapshot.key : nil
            })
        }
        return CameraIncrementalScan(assets: assets, boundaries: boundaries, cutoff: defaultIncrementalStart,
                                     customCutoff: customCutoff, format: importPreferences.format,
                                     includeUndated: includeUndated, savedKeys: savedKeys, skippedKeys: skippedKeys)
    }
    func confirmSuggestedCutoff() {
        let scan = incrementalScan(customCutoff: nil, includeUndated: includeUndated)
        guard scan.needsCutoffConfirmation else { return }
        customCutoff = scan.start
    }
    func startIncremental(_ scan: CameraIncrementalScan) {
        guard let run, mode == .importing, phase == .browsing, !scanning, !scan.assets.isEmpty,
              scan.assets.count <= CameraIncrementalScan.maximumAssets,
              scan.assets.allSatisfy({ $0.snapshot.transferable }) else { return }
        let plan = CameraIncrementalPlan(format: importPreferences.format, jpeg: importPreferences.jpeg,
                                         boundary: nil, owner: scan.assets.first?.owner, boundaries: scan.nextBoundaries)
        phase = .receiving; notice = nil
        backend.importAssets(scan.assets, incremental: plan, run: run)
    }
    func refreshImport() {
        guard let run, mode == .importing, phase == .browsing, !scanning else { return }
        scanning = true; notice = nil
        backend.refreshImport(run)
    }
    func thumbnail(_ asset: CameraRemoteAsset) {
        guard let run, phase == .browsing, thumbnails[asset.id] == nil, !unavailableThumbnails.contains(asset.id),
              pendingThumbnails.insert(asset.id).inserted else { return }
        backend.thumbnail(asset, run: run, large: false)
    }
    func showPreview(_ asset: CameraRemoteAsset) {
        guard let run, !busy else { return }
        preview = thumbnails[asset.id]; previewLoading = true
        backend.thumbnail(asset, run: run, large: true)
    }
    func setParameter(_ descriptor: CameraProperty, value: Int64) {
        guard let run, phase == .ready, writable, !parameterBusy, descriptor.accepts(value) else { return }
        parameterBusy = true; notice = nil; backend.setParameter(descriptor.code, value: value, run: run)
    }
    func capture() {
        guard let run, canCapture else { return }
        phase = .capturing; notice = nil; backend.capture(run)
    }
    func openOriginal(_ original: CameraStoredOriginal, completion: @escaping (URL) -> Void) {
        stop { [weak self] in
            guard let self else { return }
            self.backend.original(original.id) { [weak self] result in
                Task { @MainActor in
                    switch result {
                    case .success(let url): completion(url)
                    case .failure: self?.notice = L10n.text("已保存的原件缺失或已改变，无法打开。")
                    }
                }
            }
        }
    }
    func original(for asset: CameraRemoteAsset) -> CameraStoredOriginal? {
        guard let device else { return nil }
        let source = manifest.jobs.reversed().filter { $0.camera.stableKey == device.stableKey && $0.createdAt >= sessionStartedAt }
            .flatMap(\.items).first { $0.asset == asset.snapshot && $0.phase == .saved }?.sourceID
        return manifest.originals.first { $0.id == source }
    }
    func showPreview(_ original: CameraStoredOriginal) {
        let owner = callbackOwner
        preview = thumbnails[original.id.uuidString]; previewLoading = true
        backend.original(original.id) { [weak self] result in
            let image = (try? result.get()).flatMap { Self.decodeURL($0, edge: 2048) }
            Task { @MainActor in
                guard let self, self.callbackOwner == owner else { return }
                self.previewLoading = false
                if let image { self.preview = image }
                else { self.notice = L10n.text("预览不可用") }
            }
        }
    }
    func thumbnail(_ original: CameraStoredOriginal) {
        let owner = callbackOwner
        let key = original.id.uuidString
        guard thumbnails[key] == nil, !unavailableThumbnails.contains(key), pendingThumbnails.insert(key).inserted else { return }
        backend.original(original.id) { [weak self] result in
            let image: UIImage? = (try? result.get()).flatMap { Self.decodeURL($0, edge: 512) }
            Task { @MainActor in
                guard let self, self.callbackOwner == owner else { return }
                self.pendingThumbnails.remove(key)
                if let image { self.cache(image, key: key) } else { self.unavailableThumbnails.insert(key) }
            }
        }
    }
    private func cache(_ image: UIImage, key: String) {
        thumbnails[key] = image; thumbnailOrder.removeAll { $0 == key }; thumbnailOrder.append(key)
        while thumbnailOrder.count > 64 { thumbnails.removeValue(forKey: thumbnailOrder.removeFirst()) }
    }
    nonisolated private static func decodeURL(_ url: URL, edge: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(source, edge: edge)
    }
    nonisolated private static func decode(_ data: Data, edge: Int) -> UIImage? {
        guard data.count <= CameraWire.dataLimit,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16384, height <= 16384, UInt64(width) * UInt64(height) <= 16_000_000 else { return nil }
        return thumbnail(source, edge: edge)
    }
    nonisolated private static func thumbnail(_ source: CGImageSource, edge: Int) -> UIImage? {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge, kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
    private func message(_ error: Error) -> String {
        switch error {
        case CameraProtocolError.captureUnknown: return L10n.text("拍摄结果尚未确认。请检查相机，重新连接只恢复原件接收。")
        case CameraProtocolError.captureNotSent: return L10n.text("请将相机设为单张拍摄，并确认照片同时保存到相机存储卡。")
        case CameraProtocolError.tetherRecoveryRequired: return L10n.text("无法确认上次联机的照片范围，已暂停自动恢复。请从相机导入，手动选择需要补传的照片。不会自动补拍。")
        case CameraProtocolError.unsupported: return L10n.text("当前相机模式未提供此功能。")
        case CameraProtocolError.jpegProcessing: return L10n.text("无法按所选设置处理 JPEG。")
        case CameraProtocolError.jpegGainMapAdjustment: return L10n.text("此 JPEG 含 HDR 增益图。请选择原样保存以保留 HDR。")
        case CameraProtocolError.importRecoveryRequired: return L10n.text("无法确认上次导入的原始文件，请重新选择照片。")
        case CameraProtocolError.photoLimitExceeded: return L10n.format("%@ · %@", L10n.text("照片"), L10n.text("已到上限"))
        case CameraProtocolError.itemFailed(let name, _): return L10n.format("保存 %@ 失败。", name)
        case CameraProtocolError.invalid,
             CameraProtocolError.transientTransfer,
             CameraProtocolError.invalidOriginalHeader,
             CameraProtocolError.response(_, 0x2019):
            return L10n.text("相机数据或原件校验未通过，已暂停。")
        default: return L10n.text("相机连接已断开。已保存的照片仍可查看。")
        }
    }
}
