import RawLabKit
import Foundation
import ImageIO

extension LensMatchState {
    init(native state: sony2fuji_lens_state) {
        switch state {
        case SONY2FUJI_LENS_OFF: self = .off
        case SONY2FUJI_LENS_MATCHED: self = .matched
        case SONY2FUJI_LENS_NO_DATABASE: self = .noDatabase
        case SONY2FUJI_LENS_NO_CAMERA: self = .noCamera
        case SONY2FUJI_LENS_AMBIGUOUS: self = .ambiguous
        case SONY2FUJI_LENS_NO_CALIBRATION: self = .noCalibration
        case SONY2FUJI_LENS_MISSING_FOCAL_LENGTH: self = .missingFocalLength
        case SONY2FUJI_LENS_EMBEDDED_GEOMETRY: self = .embeddedGeometry
        case SONY2FUJI_LENS_UNSUPPORTED_INPUT: self = .unsupportedInput
        default: self = .unmatched
        }
    }
}

extension LensInfo {
    init(state: sony2fuji_lens_state, detectedLens: String, selectedLens: String,
         appliedDistortion: Bool, appliedTCA: Bool, cropScale: Float,
         candidates: [LensCandidate], appliedVignetting: Bool = false, sourceMetadata: DisplayLensMetadata? = nil) {
        self.init(
            state: LensMatchState(native: state),
            detectedLens: detectedLens,
            selectedLens: selectedLens,
            appliedDistortion: appliedDistortion,
            appliedTCA: appliedTCA,
            cropScale: cropScale,
            candidates: candidates,
            appliedVignetting: appliedVignetting,
            sourceMetadata: sourceMetadata
        )
    }
}

extension DisplayLensMetadata {
    func overriding(_ settings: LensCorrectionSettings) throws -> DisplayLensMetadata {
        guard let value = applying(settings) else {
            throw Sony2FujiProcessor.ProcessorError.processFailed(L10n.text("无效或不可用的镜头校正设置"))
        }
        return value
    }

    func withNative<T>(_ body: (inout sony2fuji_lens_metadata) throws -> T) rethrows -> T {
        try cameraMake.withCString { make in try cameraModel.withCString { model in
            try lensMake.withCString { lensMake in try lensModel.withCString { lensModel in
                var native = sony2fuji_lens_metadata()
                native.version = SONY2FUJI_LENS_METADATA_VERSION
                native.struct_size = UInt32(MemoryLayout<sony2fuji_lens_metadata>.size)
                native.camera_make = make; native.camera_model = model
                native.lens_make = lensMake; native.lens_model = lensModel
                native.focal_length = Float(focalLength); native.aperture = Float(aperture)
                native.crop_factor = Float(cropFactor); native.source_orientation = orientation
                return try body(&native)
            } }
        } }
    }
}

final class LensCatalogCache {
    private struct Key: Equatable { let url: URL; let size: Int?; let modified: Date?; let metadata: DisplayLensMetadata? }
    private let lock = NSLock()
    private var key: Key?
    private var profiles: [LensCandidate] = []

    func candidates(session: OpaquePointer, url: URL, metadata: DisplayLensMetadata? = nil) throws -> [LensCandidate] {
        lock.lock()
        defer { lock.unlock() }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let next = Key(url: url.standardizedFileURL, size: values?.fileSize, modified: values?.contentModificationDate, metadata: metadata)
        if key == next { return profiles }
        var report = sony2fuji_lens_report_v2()
        var count: UInt32 = 0
        func inspect(_ profiles: UnsafeMutablePointer<sony2fuji_lens_profile_v2>?, _ capacity: UInt32) -> sony2fuji_status {
            if let metadata { return metadata.withNative { sony2fuji_session_inspect_lens_metadata_v2(session, &$0, &report, profiles, capacity, &count) } }
            return url.path.withCString { sony2fuji_session_inspect_lens_v2(session, $0, &report, profiles, capacity, &count) }
        }
        let status = inspect(nil, 0)
        guard status == SONY2FUJI_STATUS_OK else { throw Sony2FujiProcessor.ProcessorError.processFailed(L10n.text("无法读取镜头配置列表")) }
        var storage = [sony2fuji_lens_profile_v2](repeating: sony2fuji_lens_profile_v2(), count: Int(count))
        let loaded = storage.withUnsafeMutableBufferPointer { inspect($0.baseAddress, count) }
        guard loaded == SONY2FUJI_STATUS_OK else { throw Sony2FujiProcessor.ProcessorError.processFailed(L10n.text("无法读取镜头配置列表")) }
        profiles = storage.map { LensCandidate(id: lensText($0.base.id), maker: lensText($0.base.maker), model: lensText($0.base.model),
            hasDistortion: $0.base.has_distortion != 0, hasTCA: $0.base.has_tca != 0, isMatch: $0.base.is_match != 0, hasVignetting: $0.has_vignetting != 0) }
        key = next
        return profiles
    }
}

private func lensText<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}

extension Sony2FujiProcessor {
    func configureDisplayLens(_ session: OpaquePointer, metadata: DisplayLensMetadata?, settings: LensCorrectionSettings) throws {
        let status: sony2fuji_status
        if let metadata { status = try metadata.overriding(settings).withNative { sony2fuji_session_set_display_lens_metadata(session, &$0) } }
        else { status = sony2fuji_session_set_display_lens_metadata(session, nil) }
        guard status == SONY2FUJI_STATUS_OK else { throw ProcessorError.processFailed(L10n.text("无效或不可用的镜头校正设置")) }
    }

    func loadLensDatabase(_ session: OpaquePointer,
                          inputType: sony2fuji_input_type = SONY2FUJI_INPUT_RAW) throws {
        let framework = Bundle.main.bundleURL.appendingPathComponent("Frameworks/sony2fuji.framework")
        let bundled = Bundle(url: framework)?.url(forResource: "Lensfun", withExtension: nil)
        guard let url = lensDatabaseURL ?? Bundle.main.url(forResource: "Lensfun", withExtension: nil) ?? bundled else {
            if inputType == SONY2FUJI_INPUT_DISPLAY_BUFFER { return }
            throw ProcessorError.processFailed(L10n.text("镜头数据库未打包到应用中"))
        }
        let status = url.path.withCString { sony2fuji_session_set_lens_database(session, $0) }
        guard status == SONY2FUJI_STATUS_OK else {
            if inputType == SONY2FUJI_INPUT_DISPLAY_BUFFER { return }
            throw ProcessorError.processFailed(L10n.text("镜头数据库不可用"))
        }
    }

    func readLens(_ session: OpaquePointer, url: URL, metadata: DisplayLensMetadata? = nil) throws -> LensInfo {
        let candidates = try lensCatalog.candidates(session: session, url: url, metadata: metadata)
        var report = sony2fuji_lens_report_v2()
        guard sony2fuji_session_get_lens_report_v2(session, &report) == SONY2FUJI_STATUS_OK else {
            throw ProcessorError.processFailed(L10n.text("无法读取镜头校正状态"))
        }
        return LensInfo(state: report.base.state, detectedLens: lensText(report.base.lens_model), selectedLens: lensText(report.base.profile.model),
            appliedDistortion: report.base.applied_distortion != 0, appliedTCA: report.base.applied_tca != 0, cropScale: report.base.crop_scale, candidates: candidates, appliedVignetting: report.applied_vignetting != 0, sourceMetadata: metadata)
    }
}
