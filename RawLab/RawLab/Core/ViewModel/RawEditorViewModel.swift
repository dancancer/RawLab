import RawLabKit
import RawLabNative
import CoreGraphics
import Foundation
import ImageIO
import UIKit

final class RawEditorViewModel: ObservableObject {
    enum PreviewQuality: Equatable {
        case interactive
        case final
    }

    @Published var previewImage: UIImage?
    @Published var detailOverlay: PhotoDetailOverlay?
    @Published var detailTiles: [PhotoDetailOverlay] = []
    @Published var detailBacking: PhotoDetailBacking?
    @Published var hdrPresentation: HDRPresentation?
    @Published var hdrReference: HDRPresentation?
    @Published var sourceIsHDR=false
    @Published var rawHDRSource: HDRSourceInfo?
    var sourceSupportsCameraHDR: Bool { rawHDRSource != nil }
    var sourceIsProRAW: Bool { rawHDRSource?.isProRAW == true }
    @Published var cameraHDRPreflight=false
    var importPreviousRevision: UUID?
    @Published var nativeImageSize: CGSize?
    @Published var sourceNativeSize: CGSize?
    @Published var basePreviewImage: UIImage?
    @Published var hasImage = false
    @Published var statusMessage: String? {
        didSet {
            statusHasDiagnostics = false
            retryLegacyX3fImport = nil
            resetUnusableImportRecord = nil
        }
    }
    // Q3/Q4：粘贴提示（已翻译文案）。非阻塞：粘贴 Sheet 打开时由 Sheet 展示，否则由根视图横幅展示。
    @Published var transferResultNotices: [String] = []
    var hdrResourceNotice = HDRResourceNotice()
    @Published var statusHasDiagnostics = false
    @Published var retryLegacyX3fImport: ((@escaping (RawSettings) -> Void) -> Void)?
    @Published var resetUnusableImportRecord: ((((RawSettings) -> Void)?) -> Void)?
    @Published var isBusy = false
    @Published var isExportingHDR = false
    @Published var hdrExportProgress: Double? = nil
    @Published var isStoppingHDRExport = false
    final class ExportCancellation {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    }
    var hdrExportCancellation: ExportCancellation?
    func cancelHDRExport() {
        if isExportingHDR {
            isStoppingHDRExport = true
        }
        hdrExportCancellation?.cancel()
    }
    final class ImportCancellation {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    }
    var activeImportCancellation: ImportCancellation?
    @Published var previewRendering = false
    @Published var previewResizePending = false
    @Published var previewFailed = false
    var hslSourceRevision: UInt64 = 1
    var hslFrameRevision: UInt64 = 0
    var acceptedPreviewRequest: PreviewRequest?
    var acceptedPreviewFrameID: UUID? { didSet { if oldValue != acceptedPreviewFrameID { hslFrameRevision &+= 1 } } }
    var committedPreviewSettings: RawSettings?

    struct ComparisonReferenceKey: Equatable {
        let sourceRevision: UUID
        let file: PhotoSourceFile?
        let identity: PhotoIdentity?
        let kind: ImageSourceKind?
        let processing: ProcessingIdentity
        let x3fMode: X3fMode
        let geometry: GeometrySettings
        let lens: LensCorrectionSettings
        let longEdge: Int
        let hdrMode: HDRSettings.Mode?
        let hdrCamera: HDRCameraDevelopmentSettings?
    }
    var comparisonReferenceKey: ComparisonReferenceKey?
    var basePreviewLens = LensCorrectionSettings()
    @Published var histogram: Sony2FujiProcessor.RGBHistogram? = nil
    @Published var baseHistogram: Sony2FujiProcessor.RGBHistogram? = nil
    @Published var unreadableLooks: [LookLibrary.UnreadableLook] = []
    @Published var availableLUTs: [LUTOption] = []
    @Published var lookBrowser = LookBrowserState()
    @Published var recentLooks = RecentLooks()
    var recentLooksURL: URL?
    @Published var isLoadingLUTs = false
    @Published var isImportingLooks = false
    @Published var isUpdatingLooks = false
    var isLookLibraryBusy: Bool { isImportingLooks || isUpdatingLooks }
    @Published var rawWhiteBalance: Sony2FujiProcessor.RawWhiteBalance?
    @Published var lensInfo: LensInfo?
    @Published var editSaveState: EditSaveState = .idle

    enum EditSaveState: Equatable {
        case idle
        case restored
        case saved
        case failed(String)
    }

    struct PreviewRequest: Equatable {
        let settings: RawSettings
        let quality: PreviewQuality
        let includeHistogram: Bool
        let longEdge: Int
    }

    struct PreviewLUTFileIdentity: Equatable {
        let url: URL
        let fileNumber: UInt64?
        let size: UInt64?
        let modificationDate: Date?
    }

    struct PreviewCacheKey: Equatable {
        let sourceRevision: UUID
        let settings: RawSettings
        let referenceKey: ComparisonReferenceKey
        let lut: PreviewLUTFileIdentity?
        let edge: Int
        let quality: PreviewQuality
        let includeHistogram: Bool
    }

    struct CompletedPreview {
        let key: PreviewCacheKey
        let previewImage: UIImage?
        let basePreviewImage: UIImage?
        var histogram: Sony2FujiProcessor.RGBHistogram?
        // CGImage retains the same pixel data; keep its buffer metadata until analysis finishes.
        var histogramInput: Sony2FujiProcessor.Buffer?
        let baseHistogram: Sony2FujiProcessor.RGBHistogram?
        let nativeImageSize: CGSize?
        let hdrPresentation: HDRPresentation?
        let hdrReference: HDRPresentation?
        let basePreviewGeometry: GeometrySettings
        let basePreviewProcessing: ProcessingIdentity
        let basePreviewLens: LensCorrectionSettings
        let comparisonReferenceKey: ComparisonReferenceKey?
        let rawWhiteBalance: Sony2FujiProcessor.RawWhiteBalance?
        let lensInfo: LensInfo?
        let sourceOrientation: CGImagePropertyOrientation?

        var estimatedMemoryBytes: Int {
            var total = 0
            func add(_ bytes: Int) {
                total = bytes > Int.max - total ? Int.max : total + bytes
            }
            for image in [previewImage, basePreviewImage] {
                if let cgImage = image?.cgImage { add(cgImage.bytesPerRow * cgImage.height) }
            }
            if let hdrPresentation { add(hdrPresentation.image.byteCount) }
            if let hdrReference { add(hdrReference.image.byteCount) }
            return total
        }
    }

    let processor = Sony2FujiProcessor()
    let renderQueue = DispatchQueue(label: "com.rawlab.preview", qos: .userInitiated)
    let renderStateLock = NSLock()
    @Published var sourceFile: PhotoSourceFile?
    @Published var sourceRevision = UUID() {
        didSet {
            cancelProcessingMigration()
            processingMigrationReceipt = nil
            pendingResetMigrationClear = nil
            hslSourceRevision &+= 1
            acceptedPreviewRequest = nil
            viewportEngine.sourceDidChange()
            sourceNativeSize = nil
            InspectionSamplerCache.shared.clear()
            InspectionOverlayRenderer.shared.clear()
            closeQuickPresets()
        }
    }
    var sourceKind: ImageSourceKind?
    var sourceIsX3f: Bool {
        sourceKind == .raw && sourceFile?.withReadAccess { $0.pathExtension.lowercased() == "x3f" } == true
    }
    var sourceIdentity: PhotoIdentity?
    @Published var importedPhotoRevision = UUID()
    @Published var sourceDisplayName: String?
    var restoredSettings: RawSettings?
    var pendingSettings: RawSettings?
    var editSaveWork: DispatchWorkItem?
    var settingsSaveRevision = UUID()
    var editRecordMetadata: EditorRecordMetadata?
    var persistedEditorSettings: PersistedEditorSettings?
    var failedDraftSource: EditorEditSource?
    var loadedEditRecord: PhotoEditRecord?
    @Published var processingMigrationReceipt: ProcessingMigrationReceipt<PhotoEditState>?
    @Published var matchingProcessing = false
    var processingMigrationCancellation: ProcessingMigrationCancellation?
    var processingMigrationAttemptSource: UUID?
    var pendingResetMigrationClear: (source: EditorEditSource, state: PhotoEditState, queued: Bool)?
    static let processingMigrationQueue = DispatchQueue(label: "com.rawlab.processing-migration", qos: .utility)
    let batchSelection = IOSBatchSelection()
    @Published var collectionExportPreparing = false
    @Published var collectionExportFreezing = false
    @Published var collectionExportReview: IOSCollectionExportReview?
    @Published var collectionExportError: String?
    var collectionExportGeneration = UUID()
    var makeCollectionJournal: () throws -> BatchJournalStore = BatchJournalStore.appStore
    var adjustmentSession: IOSAdjustmentTransferSession?
    var adjustmentInteraction: IOSAdjustmentInteraction?
    var adjustmentSourceValidator: (() throws -> Void)?
    var hasAdjustmentDraft = false { didSet { if hasAdjustmentDraft && quickPresetState.isPreparing { cancelQuickPreset() } } }
    @Published var adjustmentInteractionRejected = false
    @Published var adjustmentHistoryRevision = UUID()
    @Published var adjustmentRestoredSettings: RawSettings?
    @Published var adjustmentHistoryResults: [IOSAdjustmentTransferOutcome] = []
    var adjustmentHistoryRequest: IOSAdjustmentHistoryRequest?
    let adjustmentQueue = DispatchQueue(label: "com.rawlab.adjustment-transfer", qos: .userInitiated)
    @Published var adjustmentPreparing = false
    var adjustmentPreparationID = UUID()
    var adjustmentClipboardSourceName: String?
    @Published var quickPresetsVisible = false { didSet { if !quickPresetsVisible { cancelQuickPreset() } } }
    @Published var quickPresetState = IOSQuickPresetState.idle
    var quickPresetGeneration = UUID()
    var editNoticeID = UUID()
    var basePreviewGeometry = GeometrySettings()
    var basePreviewProcessing = ProcessingIdentity.current
    var sourceOrientation: CGImagePropertyOrientation?
    var draftBuffer: Sony2FujiProcessor.Buffer?
    var draftPreviewBuffer: Sony2FujiProcessor.Buffer?
    var fullRasterROIBuffer: Sony2FujiProcessor.Buffer? {
        get { viewportEngine.fullRasterROIBuffer }
        set { viewportEngine.fullRasterROIBuffer = newValue }
    }
    var latestRenderID = UUID()
    var activeImportRevision: UUID?
    let resultDelivery: (@escaping () -> Void) -> Void
    let exportQueue: DispatchQueue
    let importQueue: DispatchQueue
    let lookImportCoordinator: LookImportCoordinator
    let viewportEngine: ViewportRenderEngine
    var previewWorkItem: DispatchWorkItem?
    var detailDebounceWorkItem: DispatchWorkItem? { viewportEngine.detailDebounceWorkItem }
    var lastDetailRequest: PhotoDetailRequest? { viewportEngine.lastDetailRequest }
    var detailTileCache: [PhotoDetailTileKey: PhotoDetailOverlay] { viewportEngine.tileCache.tiles }
    var detailBackingMaxLongEdge: Int { viewportEngine.detailBackingMaxLongEdge }
    private var memoryWarningObserver: NSObjectProtocol?
    var histogramWorkItem: DispatchWorkItem?
    var lastPreviewRequest: PreviewRequest?
    var onPreviewRequest: ((PreviewRequest, UUID) -> Void)?
    var onViewportResize: ((Bool) -> Void)?
    var completedPreviewCache: [CompletedPreview] {
        get { viewportEngine.completedPreviewCache }
        set { viewportEngine.setCompletedPreviewCache(newValue) }
    }
    var completedPreviewCacheBytes: Int { viewportEngine.completedPreviewCacheBytes }
    var previewLongEdge = 1280
    var requestedPreviewLongEdge = 1280
    var previewResizeWorkItem: DispatchWorkItem?
    var currentPreviewSettings = RawSettings.default {
        didSet { if oldValue != currentPreviewSettings { cancelProcessingMigration() } }
    }
    let previewMaxDimension: CGFloat = 1280
    let interactivePreviewMaxDimension: CGFloat = 720
    let histogramDelay: TimeInterval = 0.25
    var lutMap: [String: LUTReference] = [:]
    var didStartLUTLoad = false

    var editPersistence: EditPersistence?
    var openEditPersistence: () throws -> EditPersistence = EditPersistence.appStore
    let presetStore: AdjustmentPresetStore

    init(editPersistence: EditPersistence? = nil,
         presetStore: AdjustmentPresetStore = AdjustmentPresetStore(),
         lookImportCoordinator: LookImportCoordinator = LookImportCoordinator(),
         exportQueue: DispatchQueue = .global(qos: .userInitiated),
         importQueue: DispatchQueue = .global(qos: .userInitiated),
         resultDelivery: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.presetStore = presetStore
        self.lookImportCoordinator = lookImportCoordinator
        self.resultDelivery = resultDelivery
        self.exportQueue = exportQueue
        self.importQueue = importQueue
        self.viewportEngine = ViewportRenderEngine(
            processor: processor,
            renderQueue: renderQueue,
            renderStateLock: renderStateLock,
            resultDelivery: resultDelivery
        )
        self.viewportEngine.attach(self)
        do {
            let store = try editPersistence ?? openEditPersistence()
            self.editPersistence = store
            if let quarantined = store.consumeQuarantinedError() {
                ErrorDiagnostics.log(quarantined, operation: .editPersistence, stage: "quarantineStore")
            }
            adjustmentSession = IOSAdjustmentTransferSession(store: store)
            recentLooksURL = store.directory.appendingPathComponent("recent-looks.json")
            recentLooks = RecentLooks.load(from: recentLooksURL!)
        }
        catch {
            self.editPersistence = nil
            ErrorDiagnostics.log(error, operation: .editPersistence, stage: "openStore")
            editSaveState = .failed(error.localizedDescription)
        }
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.viewportEngine.reclaimMemory(
                releaseRaster: true,
                keepRequest: true,
                preservePrewarmFrameID: self.acceptedPreviewFrameID
            )
            InspectionSamplerCache.shared.clear()
            InspectionOverlayRenderer.shared.clear()
            self.renderQueue.async { [weak self] in
                self?.processor.clearHDRSessionCache()
            }
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

}
