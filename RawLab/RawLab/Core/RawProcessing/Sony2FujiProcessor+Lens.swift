import RawLabKit
import RawLabNativeTypes
import Foundation
import ImageIO

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

    func validateRawFileForTransfer(url: URL, x3fMode: X3fMode) throws {
        if isNormalX3f(url, settings: {
            var s = RawSettings.default
            s.x3fMode = x3fMode
            return s
        }()) {
            _ = try x3fDefaultMode(for: url)
            return
        }
        try withRawSession(reuse: true, inputType: SONY2FUJI_INPUT_RAW) { session in
            var report = sony2fuji_lens_report_v2()
            var count: UInt32 = 0
            let status = url.path.withCString {
                sony2fuji_session_inspect_lens_v2(session, $0, &report, nil, 0, &count)
            }
            guard status == SONY2FUJI_STATUS_OK else {
                throw processingFailure(status, input: url, session: session)
            }
        }
    }

    func resolveRawWhiteBalanceForTransfer(url: URL, settings: RawSettings) throws -> RawWhiteBalance? {
        try withRawSession(reuse: true, inputType: SONY2FUJI_INPUT_RAW) { session in
            var req = sony2fuji_recipe_wb_request()
            req.version = SONY2FUJI_RECIPE_WB_REQUEST_VERSION
            req.struct_size = UInt32(MemoryLayout<sony2fuji_recipe_wb_request>.size)
            req.processing_version = settings.processing.core
            req.x3f_mode = settings.x3fMode.core
            req.exposure_mode = settings.exposureMode.core
            req.recipe_active = 1
            req.recipe_strength = 1
            req.custom_wb = 1
            req.temperature = 6500
            req.tint = 0
            var res = sony2fuji_recipe_wb_result()
            let status = url.path.withCString { pathPtr -> sony2fuji_status in
                req.input_path = pathPtr
                return sony2fuji_session_resolve_recipe_wb(session, &req, &res)
            }
            if status == SONY2FUJI_STATUS_UNSUPPORTED {
                return nil
            }
            guard status == SONY2FUJI_STATUS_OK else {
                throw processingFailure(status, input: url, session: session)
            }
            guard res.camera_calibrated != 0 else { return nil }
            return RawWhiteBalance(
                temperature: Double(res.camera_temperature),
                tint: Double(res.camera_tint),
                isCalibrated: true
            )
        }
    }

    func validateLensForTransfer(url: URL, isRaw: Bool, x3fMode: X3fMode, lens: LensCorrectionSettings) throws {
        guard lens.isEnabled else { return }
        if isRaw {
            var x3fSettings = RawSettings.default
            x3fSettings.x3fMode = x3fMode
            if isNormalX3f(url, settings: x3fSettings) {
                throw AdjustmentTransferError.incompatible(L10n.text("此输入不支持镜头校正"))
            }
            try withRawSession(reuse: true, inputType: SONY2FUJI_INPUT_RAW) { session in
                try configureLensCorrectionForTransfer(session, settings: lens)
                var report = sony2fuji_lens_report_v2()
                var count: UInt32 = 0
                let status = url.path.withCString {
                    sony2fuji_session_inspect_lens_v2(session, $0, &report, nil, 0, &count)
                }
                guard status == SONY2FUJI_STATUS_OK else {
                    throw processingFailure(status, input: url, session: session)
                }
                try ensureLensMatchedForTransfer(report, lens: lens)
            }
        } else {
            let metadata = try DisplayLensMetadata.read(url).overriding(lens)
            try withRawSession(reuse: false, inputType: SONY2FUJI_INPUT_DISPLAY_BUFFER) { session in
                try configureLensCorrectionForTransfer(session, settings: lens)
                var report = sony2fuji_lens_report_v2()
                var count: UInt32 = 0
                let status = metadata.withNative { native in
                    sony2fuji_session_inspect_lens_metadata_v2(session, &native, &report, nil, 0, &count)
                }
                guard status == SONY2FUJI_STATUS_OK else {
                    throw processingFailure(status, input: url, session: session)
                }
                try ensureLensMatchedForTransfer(report, lens: lens)
            }
        }
    }

    private func configureLensCorrectionForTransfer(_ session: OpaquePointer, settings: LensCorrectionSettings) throws {
        var config = sony2fuji_lens_correction_config_v2()
        config.base.version = SONY2FUJI_LENS_CORRECTION_CONFIG_V2_VERSION
        config.base.struct_size = UInt32(MemoryLayout<sony2fuji_lens_correction_config_v2>.size)
        config.base.distortion = settings.distortion ? 1 : 0
        config.base.tca = settings.tca ? 1 : 0
        config.base.auto_crop = settings.autoCrop ? 1 : 0
        config.vignetting = settings.vignetting ? 1 : 0
        let status = settings.coreProfileID.withCString { profilePtr in
            config.base.profile_id = profilePtr
            return sony2fuji_session_set_lens_correction_v2(session, &config)
        }
        guard status == SONY2FUJI_STATUS_OK else {
            throw ProcessorError.processFailed(L10n.text("无效或不可用的镜头校正设置"))
        }
    }

    private func ensureLensMatchedForTransfer(_ report: sony2fuji_lens_report_v2, lens: LensCorrectionSettings) throws {
        let info = LensInfo(
            state: report.base.state,
            detectedLens: lensText(report.base.lens_model),
            selectedLens: lensText(report.base.profile.model),
            appliedDistortion: report.base.profile.has_distortion != 0,
            appliedTCA: report.base.profile.has_tca != 0,
            cropScale: report.base.crop_scale,
            candidates: [],
            appliedVignetting: report.has_vignetting != 0
        )
        guard report.base.state == SONY2FUJI_LENS_MATCHED else {
            throw AdjustmentTransferError.incompatible(info.message)
        }
        guard (!lens.distortion || report.base.profile.has_distortion != 0),
              (!lens.tca || report.base.profile.has_tca != 0),
              (!lens.vignetting || report.has_vignetting != 0) else {
            throw AdjustmentTransferError.incompatible(L10n.text("此镜头没有所选校正的标定数据"))
        }
    }
}
