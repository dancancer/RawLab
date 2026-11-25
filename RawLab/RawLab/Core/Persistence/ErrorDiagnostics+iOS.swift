import RawLabKit
import Foundation

#if os(iOS)
import ImageIO
import UniformTypeIdentifiers

extension ErrorDiagnostics {
    static var app: ErrorDiagnostics {
        DiagnosticCenter.appErrorDiagnostics
    }

    @discardableResult static func log(_ error: Error, operation: Operation, stage: String,
                                       attemptID: UUID? = nil, context: [String: String] = [:]) -> Bool {
        guard !(error is CancellationError) else { return false }
        let nsError = error as NSError
        guard !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError),
              !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return false }
        let diagnosticSource = (error as? BatchExportError)?.underlyingError ?? error
        let native: DiagnosticNativeError?
        if let error = diagnosticSource as? HDRNativeError {
            native = .init(status: Int(error.status.rawValue), reason: Int(error.reason), field: Int(error.field))
        } else if let error = diagnosticSource as? Sony2FujiProcessor.ProcessorError, let status = error.diagnosticStatus {
            native = .init(status: Int(status.rawValue))
        } else {
            native = nil
        }
        app.record(nsError, operation: operation, stage: stage, attemptID: attemptID, context: context, native: native)
        return true
    }

    static func fileContext(_ url: URL, inspectContent: Bool = false) -> [String: String] {
        var values: [String: String] = [:]
        if let suffix = fileNameExtension(url) {
            values["extension"] = suffix
            if suffix != "unknown" { values["declaredType"] = UTType(filenameExtension: suffix)?.identifier }
        }
        if let resource = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isUbiquitousItemKey]) {
            if let size = resource.fileSize { values["bytes"] = String(size) }
            values["providerType"] = resource.contentType?.identifier
            if let cloud = resource.isUbiquitousItem { values["icloud"] = String(cloud) }
        }
        if inspectContent, let image = CGImageSourceCreateWithURL(url as CFURL, nil) {
            values["detectedType"] = CGImageSourceGetType(image) as String?
            if let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] {
                if let width = properties[kCGImagePropertyPixelWidth] as? Int { values["width"] = String(width) }
                if let height = properties[kCGImagePropertyPixelHeight] as? Int { values["height"] = String(height) }
            }
        }
        return redactedContext(values)
    }
}

extension RawEditorViewModel {
    @discardableResult
    func reportError(_ error: Error, operation: ErrorDiagnostics.Operation, stage: String,
                     attemptID: UUID? = nil, context: [String: String] = [:], message: String? = nil) -> Bool {
        guard ErrorDiagnostics.log(error, operation: operation, stage: stage, attemptID: attemptID, context: context) else { return false }
        statusMessage = message ?? error.localizedDescription
        statusHasDiagnostics = true
        return true
    }
}
#endif
