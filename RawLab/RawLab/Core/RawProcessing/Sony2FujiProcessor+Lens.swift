import Foundation
import ImageIO

struct LensCandidate: Identifiable, Equatable {
    let id: String
    let maker: String
    let model: String
    let hasDistortion: Bool
    let hasTCA: Bool
    let isMatch: Bool
    var hasVignetting = false
    var title: String { model.localizedCaseInsensitiveContains(maker) ? model : "\(maker) \(model)" }
}

struct LensInfo: Equatable {
    let state: sony2fuji_lens_state
    let detectedLens: String
    let selectedLens: String
    let appliedDistortion: Bool
    let appliedTCA: Bool
    let cropScale: Float
    let candidates: [LensCandidate]
    var appliedVignetting = false
    var sourceMetadata: DisplayLensMetadata? = nil
    var message: String {
        switch state {
        case SONY2FUJI_LENS_OFF: return L10n.text("镜头校正已关闭")
        case SONY2FUJI_LENS_MATCHED:
            let applied = [appliedDistortion ? L10n.text("畸变") : nil, appliedTCA ? L10n.text("横向色差") : nil, appliedVignetting ? L10n.text("暗角校正") : nil].compactMap { $0 }
            return applied.isEmpty ? L10n.text("已匹配镜头") : L10n.format("已校正%@", applied.joined(separator: " / "))
        case SONY2FUJI_LENS_NO_DATABASE: return L10n.text("镜头数据库不可用")
        case SONY2FUJI_LENS_NO_CAMERA: return L10n.text("未找到机身或传感器尺寸信息")
        case SONY2FUJI_LENS_AMBIGUOUS: return L10n.text("有多个匹配镜头，请手动选择")
        case SONY2FUJI_LENS_NO_CALIBRATION: return L10n.text("此镜头没有所选校正的标定数据")
        case SONY2FUJI_LENS_MISSING_FOCAL_LENGTH: return L10n.text("照片缺少有效焦距，未应用校正")
        case SONY2FUJI_LENS_EMBEDDED_GEOMETRY: return L10n.text("DNG 已执行内嵌 Stage3 处理，未叠加校正")
        case SONY2FUJI_LENS_UNSUPPORTED_INPUT: return L10n.text("此输入不支持镜头校正")
        default: return L10n.text("未匹配镜头，请手动选择")
        }
    }
}


struct DisplayLensMetadata: Equatable {
    let sourceURL: URL
    var cameraMake = "", cameraModel = "", lensMake = "", lensModel = ""
    var focalLength: Double = 0, aperture: Double = 0, cropFactor: Double = 0
    var orientation: Int32 = 1

    static func read(_ url: URL) -> DisplayLensMetadata {
        var result = DisplayLensMetadata(sourceURL: url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return result }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let auxiliary = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        func text(_ value: Any?, limit: Int) -> String {
            let value = (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return String(decoding: Array(value.utf8.prefix(limit)), as: UTF8.self)
        }
        func number(_ value: Any?) -> Double {
            guard let number = value as? NSNumber, number.doubleValue.isFinite, number.doubleValue > 0 else { return 0 }
            return number.doubleValue
        }
        result.cameraMake = text(tiff[kCGImagePropertyTIFFMake], limit: 120)
        result.cameraModel = text(tiff[kCGImagePropertyTIFFModel], limit: 120)
        result.lensMake = text(exif[kCGImagePropertyExifLensMake], limit: 120)
        result.lensModel = text(exif[kCGImagePropertyExifLensModel] ?? auxiliary[kCGImagePropertyExifAuxLensModel], limit: 248)
        result.focalLength = number(exif[kCGImagePropertyExifFocalLength])
        result.aperture = number(exif[kCGImagePropertyExifFNumber])
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        result.orientation = (1...8).contains(orientation) ? orientation : 1
        return result
    }

    func overriding(_ settings: LensCorrectionSettings) throws -> DisplayLensMetadata {
        guard settings.focalLength.map({ $0.isFinite && (0.1...10000).contains($0) }) ?? true,
              settings.cropFactor.map({ $0.isFinite && (0.1...100).contains($0) }) ?? true else {
            throw Sony2FujiProcessor.ProcessorError.processFailed(L10n.text("无效或不可用的镜头校正设置"))
        }
        var value = self
        value.focalLength = settings.focalLength ?? focalLength
        value.cropFactor = settings.cropFactor ?? cropFactor
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

    func configureLens(_ session: OpaquePointer, settings: LensCorrectionSettings) throws {
        var config = sony2fuji_lens_correction_config_v2()
        config.base.version = SONY2FUJI_LENS_CORRECTION_CONFIG_V2_VERSION
        config.base.struct_size = UInt32(MemoryLayout<sony2fuji_lens_correction_config_v2>.size)
        config.base.distortion = settings.distortion ? 1 : 0
        config.base.tca = settings.tca ? 1 : 0
        config.base.auto_crop = settings.autoCrop ? 1 : 0
        config.vignetting = settings.vignetting ? 1 : 0
        let status = settings.coreProfileID.withCString { config.base.profile_id = $0; return sony2fuji_session_set_lens_correction_v2(session, &config) }
        guard status == SONY2FUJI_STATUS_OK else { throw ProcessorError.processFailed(L10n.text("无效或不可用的镜头校正设置")) }
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
