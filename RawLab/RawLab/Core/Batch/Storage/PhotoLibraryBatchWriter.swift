import Photos
import PhotosUI
import SwiftUI
import UIKit

enum PhotoLibraryBatchWriter {
    static func authorize() throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            let semaphore = DispatchSemaphore(value: 0)
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status = $0; semaphore.signal() }
            semaphore.wait()
        }
        guard status == .authorized || status == .limited else {
            throw BatchExportError.global(L10n.text("无法保存照片，请在系统设置中允许 RawLab 添加照片。"))
        }
    }

    static func assetExists(_ identifier: String) -> Bool? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        if PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).count > 0 { return true }
        return status == .authorized ? false : nil
    }

    static func write(data: Data, outputName: String, target: BatchTarget,
                      checkpoint: @escaping (String) throws -> Void) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var writeError: Error?
        var checkpointError: Error?
        var didSucceed = false
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = outputName
            request.addResource(with: .photo, data: data, options: options)
            if let identifier = request.placeholderForCreatedAsset?.localIdentifier {
                do { try checkpoint(identifier) } catch { checkpointError = error }
            }
        }) { success, error in
            didSucceed = success; writeError = error; semaphore.signal()
        }
        semaphore.wait()
        if !didSucceed { throw BatchExportError.global(writeError?.localizedDescription ?? L10n.format("保存 %@ 失败。", String(describing: target.displayName))) }
        if checkpointError != nil { throw BatchExportError.uncertain(L10n.text("照片已写入，但任务记录未更新，请先核对保存结果。")) }
    }
}
