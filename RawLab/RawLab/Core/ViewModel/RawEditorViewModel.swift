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
    @Published var hdrPresentation: HDRPresentation?
    @Published var hdrReference: HDRPresentation?
    @Published var sourceIsHDR=false
    var importPreviousRevision: UUID?
    @Published var nativeImageSize: CGSize?
    @Published var basePreviewImage: UIImage?
    @Published var hasImage = false
    @Published var statusMessage: String?
    @Published var retryLegacyX3fImport: ((@escaping (RawSettings) -> Void) -> Void)?
    @Published var isBusy = false
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
    }
    var comparisonReferenceKey: ComparisonReferenceKey?
    var basePreviewLens = LensCorrectionSettings()
    @Published var histogram: Sony2FujiProcessor.RGBHistogram? = nil
    @Published var baseHistogram: Sony2FujiProcessor.RGBHistogram? = nil
    @Published var availableLUTs: [LUTOption] = []
    @Published var isLoadingLUTs = false
    @Published var isImportingLooks = false
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

    let processor = Sony2FujiProcessor()
    let renderQueue = DispatchQueue(label: "com.rawlab.preview", qos: .userInitiated)
    let renderStateLock = NSLock()
    @Published var sourceFile: PhotoSourceFile?
    @Published var sourceRevision = UUID() { didSet { hslSourceRevision &+= 1; acceptedPreviewRequest = nil; closeQuickPresets() } }
    var sourceKind: ImageSourceKind?
    var sourceIsX3f: Bool { sourceKind == .raw && (sourceDisplayName as NSString?)?.pathExtension.lowercased() == "x3f" }
    var sourceIdentity: PhotoIdentity?
    @Published var sourceDisplayName: String?
    var restoredSettings: RawSettings?
    var pendingSettings: RawSettings?
    var editSaveWork: DispatchWorkItem?
    var settingsSaveRevision = UUID()
    var editRecordMetadata: EditorRecordMetadata?
    var persistedEditorSettings: PersistedEditorSettings?
    var failedDraftSource: EditorEditSource?
    var loadedEditRecord: VersionedPhotoEdit?
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
    @Published var adjustmentReloadRequired = false
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
    var latestRenderID = UUID()
    var activeImportRevision: UUID?
    let resultDelivery: (@escaping () -> Void) -> Void
    let exportQueue: DispatchQueue
    let importQueue: DispatchQueue
    let lookImportCoordinator: LookImportCoordinator
    var previewWorkItem: DispatchWorkItem?
    var histogramWorkItem: DispatchWorkItem?
    var lastPreviewRequest: PreviewRequest?
    var previewLongEdge = 1280
    var requestedPreviewLongEdge = 1280
    var previewResizeWorkItem: DispatchWorkItem?
    var currentPreviewSettings = RawSettings.default
    let sampleResourceName = "sample"
    let sampleResourceExtension = "ARW"
    let previewMaxDimension: CGFloat = 1280
    let interactivePreviewMaxDimension: CGFloat = 720
    let histogramDelay: TimeInterval = 0.25
    var lutMap: [String: LUTReference] = [:]
    var didStartLUTLoad = false
    var rawLUTID: String?
    var rawLUTApplied = false

    var editPersistence: EditPersistence?
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
        do {
            let store = try editPersistence ?? EditPersistence.appStore()
            self.editPersistence = store
            adjustmentSession = IOSAdjustmentTransferSession(store: store)
        }
        catch { self.editPersistence = nil; editSaveState = .failed(error.localizedDescription) }
    }

}
