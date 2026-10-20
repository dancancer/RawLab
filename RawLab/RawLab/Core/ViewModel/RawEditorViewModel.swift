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
    @Published var nativeImageSize: CGSize?
    @Published var basePreviewImage: UIImage?
    @Published var hasImage = false
    @Published var statusMessage: String?
    @Published var isBusy = false
    @Published var previewRendering = false
    @Published var previewResizePending = false
    @Published var histogram: [CGFloat] = []
    @Published var baseHistogram: [CGFloat] = []
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
    @Published var sourceRevision = UUID()
    var sourceKind: ImageSourceKind?
    var sourceIdentity: PhotoIdentity?
    @Published var sourceDisplayName: String?
    var restoredSettings: RawSettings?
    var pendingSettings: RawSettings?
    var editSaveWork: DispatchWorkItem?
    var editNoticeID = UUID()
    var basePreviewGeometry = GeometrySettings()
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
    let histogramBins = 128
    var lutMap: [String: LUTReference] = [:]
    var didStartLUTLoad = false
    var rawLUTID: String?
    var rawLUTApplied = false

    var editPersistence: EditPersistence?

    init(editPersistence: EditPersistence? = nil,
         lookImportCoordinator: LookImportCoordinator = LookImportCoordinator(),
         exportQueue: DispatchQueue = .global(qos: .userInitiated),
         importQueue: DispatchQueue = .global(qos: .userInitiated),
         resultDelivery: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.lookImportCoordinator = lookImportCoordinator
        self.resultDelivery = resultDelivery
        self.exportQueue = exportQueue
        self.importQueue = importQueue
        do { self.editPersistence = try editPersistence ?? EditPersistence.appStore() }
        catch { self.editPersistence = nil; editSaveState = .failed(error.localizedDescription) }
    }

}
