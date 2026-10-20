import Foundation
import CryptoKit

enum BatchSourceKind: String, Codable, Equatable {
    case raw
    case raster
}

enum BatchTargetStatus: String, Codable, Equatable {
    case pending
    case processing
    case publishing
    case needsConfirmation
    case succeeded
    case failed
    case cancelled

    var title: String {
        switch self {
        case .pending: return L10n.text("等待导出")
        case .processing: return L10n.text("正在显影")
        case .publishing: return L10n.text("正在保存")
        case .needsConfirmation: return L10n.text("保存结果待确认")
        case .succeeded: return L10n.text("已保存")
        case .failed: return L10n.text("导出失败")
        case .cancelled: return L10n.text("未处理")
        }
    }
}

enum BatchJobStatus: String, Codable, Equatable {
    case draft
    case running
    case completed
    case partialFailure
    case cancelled
    case interrupted
    case failed
}

enum BatchOutputFormat: String, Codable, Equatable, Hashable {
    case jpeg
    case renderedDNG = "dng"

    var title: String {
        switch self {
        case .jpeg: return "JPEG"
        case .renderedDNG: return L10n.text("DNG · 渲染型")
        }
    }

    var suffix: String {
        switch self {
        case .jpeg: return "jpg"
        case .renderedDNG: return "dng"
        }
    }
}

enum BatchExportError: LocalizedError {
    case target(String)
    case global(String)
    case uncertain(String)

    var errorDescription: String? {
        switch self {
        case .target(let message), .global(let message), .uncertain(let message):
            return message
        }
    }
}

struct BatchSourceSnapshot: Codable, Equatable {
    let identity: PhotoIdentity
    var sourceFile: PhotoSourceFile
    let displayName: String
    let sourceKind: BatchSourceKind
    let settings: RawSettings
    var lookURL: URL?
    var lookName: String?

    private enum CodingKeys: String, CodingKey {
        case sourceFile = "sourceURL"
        case identity, displayName, sourceKind, settings, lookURL, lookName
    }

    init(identity: PhotoIdentity,
         sourceFile: PhotoSourceFile,
         displayName: String,
         sourceKind: BatchSourceKind = .raw,
         settings: RawSettings) {
        self.identity = identity
        self.sourceFile = sourceFile
        self.displayName = displayName
        self.sourceKind = sourceKind
        self.settings = settings
    }

    func settings(for targetKind: BatchSourceKind) -> RawSettings {
        guard sourceKind == .raster, targetKind == .raw else { return settings }
        var result = settings
        result.exposureMode = RawSettings.default.exposureMode
        result.whiteBalanceMode = .camera
        result.temperature = 6500
        if result.masterRecipeID == nil { result.tint = 0 }
        result.noiseReduction = 0
        result.lensCorrection = nil
        return result
    }
}

struct BatchTarget: Codable, Equatable, Identifiable {
    let identity: PhotoIdentity
    var sourceURL: URL
    let displayName: String
    var sourceKind: BatchSourceKind
    var status: BatchTargetStatus
    var errorMessage: String?
    var outputName: String
    var outputAssetIdentifier: String?
    var outputFileURL: URL?

    var id: String { identity.key }

    init(identity: PhotoIdentity,
         sourceURL: URL,
         displayName: String,
         sourceKind: BatchSourceKind = .raw,
         status: BatchTargetStatus = .pending,
         errorMessage: String? = nil,
         outputName: String? = nil,
         outputFileURL: URL? = nil) {
        self.identity = identity
        self.sourceURL = sourceURL
        self.displayName = displayName
        self.sourceKind = sourceKind
        self.status = status
        self.errorMessage = errorMessage
        self.outputName = outputName ?? OutputNameAllocator.baseName(for: displayName)
        self.outputFileURL = outputFileURL
    }

    private enum CodingKeys: String, CodingKey {
        case identity, sourceURL, displayName, sourceKind, status, errorMessage
        case outputName, outputAssetIdentifier, outputFileURL
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        identity = try values.decode(PhotoIdentity.self, forKey: .identity)
        sourceURL = try values.decode(URL.self, forKey: .sourceURL)
        displayName = try values.decode(String.self, forKey: .displayName)
        sourceKind = try values.decodeIfPresent(BatchSourceKind.self, forKey: .sourceKind) ?? .raw
        status = try values.decodeIfPresent(BatchTargetStatus.self, forKey: .status) ?? .pending
        errorMessage = try values.decodeIfPresent(String.self, forKey: .errorMessage)
        outputName = try values.decodeIfPresent(String.self, forKey: .outputName)
            ?? OutputNameAllocator.baseName(for: displayName)
        outputAssetIdentifier = try values.decodeIfPresent(String.self, forKey: .outputAssetIdentifier)
        outputFileURL = try values.decodeIfPresent(URL.self, forKey: .outputFileURL)
    }
}

struct BatchExportJob: Codable, Equatable, Identifiable {
    let id: UUID
    var source: BatchSourceSnapshot
    var targets: [BatchTarget]
    var status: BatchJobStatus
    var outputFormat: BatchOutputFormat
    var longEdge: Int?
    var createdAt: Date
    var updatedAt: Date
    var globalError: String?

    init(id: UUID = UUID(),
         source: BatchSourceSnapshot,
         targets: [BatchTarget],
         outputFormat: BatchOutputFormat = .jpeg,
         longEdge: Int? = nil,
         status: BatchJobStatus = .draft,
         createdAt: Date = Date()) {
        self.id = id
        self.source = source
        self.targets = OutputNameAllocator.assignUniqueNames(targets, suffix: outputFormat.suffix)
        self.status = status
        self.outputFormat = outputFormat
        self.longEdge = ExportSize.normalized(longEdge)
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.globalError = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, targets, status, outputFormat, longEdge, createdAt, updatedAt, globalError
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        source = try values.decode(BatchSourceSnapshot.self, forKey: .source)
        targets = try values.decode([BatchTarget].self, forKey: .targets)
        status = try values.decode(BatchJobStatus.self, forKey: .status)
        outputFormat = try values.decodeIfPresent(BatchOutputFormat.self, forKey: .outputFormat) ?? .jpeg
        longEdge = try values.decodeIfPresent(Int.self, forKey: .longEdge)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        globalError = try values.decodeIfPresent(String.self, forKey: .globalError)
    }
}

extension BatchExportJob {
    func recovered(assetExists: (String) -> Bool? = { _ in nil },
                   fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> BatchExportJob {
        var copy = self
        func existingDNGOutput(for target: BatchTarget) -> URL? {
            let currentDestination = BatchFileOutputStore.destination(jobID: id, outputName: target.outputName)
            if fileExists(currentDestination) { return currentDestination }
            if let output = target.outputFileURL, fileExists(output) { return output }
            if let asset = target.outputAssetIdentifier,
               asset.hasPrefix("file:") {
                let output = URL(fileURLWithPath: String(asset.dropFirst(5)))
                if fileExists(output) { return output }
            }
            return nil
        }

        for index in copy.targets.indices {
            switch copy.targets[index].status {
            case .processing:
                copy.targets[index].status = .pending
            case .succeeded:
                guard outputFormat == .renderedDNG else { break }
                if let output = existingDNGOutput(for: copy.targets[index]) {
                    copy.targets[index].outputFileURL = output
                    copy.targets[index].outputAssetIdentifier = nil
                    copy.targets[index].errorMessage = nil
                } else {
                    copy.targets[index].outputFileURL = nil
                    copy.targets[index].outputAssetIdentifier = nil
                    copy.targets[index].status = .pending
                    copy.targets[index].errorMessage = nil
                }
            case .publishing, .needsConfirmation:
                if outputFormat == .renderedDNG {
                    if let output = existingDNGOutput(for: copy.targets[index]) {
                        copy.targets[index].outputFileURL = output
                        copy.targets[index].outputAssetIdentifier = nil
                        copy.targets[index].status = .succeeded
                    } else {
                        copy.targets[index].outputFileURL = nil
                        copy.targets[index].outputAssetIdentifier = nil
                        copy.targets[index].status = .pending
                    }
                    if copy.globalError == copy.targets[index].errorMessage { copy.globalError = nil }
                    copy.targets[index].errorMessage = nil
                } else if let asset = copy.targets[index].outputAssetIdentifier, let exists = assetExists(asset) {
                    copy.targets[index].status = exists ? .succeeded : .pending
                    if !exists { copy.targets[index].outputAssetIdentifier = nil }
                    copy.targets[index].errorMessage = nil
                } else {
                    copy.targets[index].status = .needsConfirmation
                    copy.targets[index].errorMessage = L10n.text("保存时发生中断，请先核对照片图库，避免重复生成。")
                }
            default: break
            }
        }
        if status == .running || copy.targets.contains(where: { $0.status == .needsConfirmation }) { copy.status = .interrupted }
        if outputFormat == .renderedDNG && copy.status == .completed &&
            copy.targets.contains(where: { $0.status != .succeeded }) {
            copy.status = .interrupted
        }
        if !copy.targets.isEmpty && copy.targets.allSatisfy({ $0.status == .succeeded }) { copy.status = .completed }
        return copy
    }
}
