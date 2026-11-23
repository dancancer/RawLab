@_exported import CSony2Fuji
@_exported import RawLabNativeTypes
import RawLabKit
import Foundation

public enum DCPCompiler {
    private static let maxSourceBytes = 128 * 1024 * 1024

    public static func compile(source: URL, options: DCPImportOptions = .init()) throws -> Data {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxSourceBytes + 1) ?? Data()
        return try compile(data: data, sourceName: source.lastPathComponent, options: options)
    }

    public static func compile(data: Data, sourceName: String, options: DCPImportOptions = .init()) throws -> Data {
        if options.toneCurveJSON?.isEmpty == true { throw DCPCompilerError.invalidToneCurve }
        var blob = sony2fuji_blob()
        defer { sony2fuji_release_blob(&blob) }
        var reason = SONY2FUJI_DCP_ERROR_NONE
        let status = sourceName.withCString { name in
            data.withUnsafeBytes { bytes in
                let compile = { (curve: UnsafeRawPointer?, curveSize: Int) in
                    sony2fuji_compile_dcp_with_options(bytes.baseAddress, bytes.count, name,
                                                       curve, curveSize,
                                                       options.omitAutomaticBlack ? 1 : 0,
                                                       &blob, &reason)
                }
                guard let curve = options.toneCurveJSON else { return compile(nil, 0) }
                return curve.withUnsafeBytes { curveBytes in
                    compile(curveBytes.baseAddress, curveBytes.count)
                }
            }
        }
        guard status == SONY2FUJI_STATUS_OK else {
            if reason != SONY2FUJI_DCP_ERROR_NONE { throw DCPCompilerError(reason: reason) }
            if status == SONY2FUJI_STATUS_OUT_OF_MEMORY {
                throw POSIXError(.ENOMEM)
            }
            throw DCPCompilerError.malformed
        }
        guard let bytes = blob.data, blob.size_bytes > 0 else { throw DCPCompilerError.malformed }
        return Data(bytes: bytes, count: blob.size_bytes)
    }
}
