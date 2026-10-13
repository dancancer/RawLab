import Foundation

struct LensCandidate: Identifiable, Equatable {
    let id: String
    let maker: String
    let model: String
    let hasDistortion: Bool
    let hasTCA: Bool
    let isMatch: Bool
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
    var message: String {
        switch state {
        case SONY2FUJI_LENS_OFF: return L10n.text("镜头校正已关闭")
        case SONY2FUJI_LENS_MATCHED:
            let applied = [appliedDistortion ? L10n.text("畸变") : nil, appliedTCA ? L10n.text("横向色差") : nil].compactMap { $0 }
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

final class LensCatalogCache {
    private struct Key: Equatable { let url: URL; let size: Int?; let modified: Date? }
    private let lock = NSLock()
    private var key: Key?
    private var profiles: [LensCandidate] = []

    func candidates(session: OpaquePointer, url: URL) throws -> [LensCandidate] {
        lock.lock()
        defer { lock.unlock() }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let next = Key(url: url.standardizedFileURL, size: values?.fileSize, modified: values?.contentModificationDate)
        if key == next { return profiles }
        var report = sony2fuji_lens_report()
        var count: UInt32 = 0
        let status = url.path.withCString { sony2fuji_session_inspect_lens(session, $0, &report, nil, 0, &count) }
        guard status == SONY2FUJI_STATUS_OK else { throw Sony2FujiProcessor.ProcessorError.processFailed(L10n.text("无法读取镜头配置列表")) }
        var storage = [sony2fuji_lens_profile](repeating: sony2fuji_lens_profile(), count: Int(count))
        let loaded = url.path.withCString { path in storage.withUnsafeMutableBufferPointer {
            sony2fuji_session_inspect_lens(session, path, &report, $0.baseAddress, count, &count)
        } }
        guard loaded == SONY2FUJI_STATUS_OK else { throw Sony2FujiProcessor.ProcessorError.processFailed(L10n.text("无法读取镜头配置列表")) }
        profiles = storage.map { LensCandidate(id: lensText($0.id), maker: lensText($0.maker), model: lensText($0.model),
            hasDistortion: $0.has_distortion != 0, hasTCA: $0.has_tca != 0, isMatch: $0.is_match != 0) }
        key = next
        return profiles
    }
}

private func lensText<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}

extension Sony2FujiProcessor {
    func loadLensDatabase(_ session: OpaquePointer) throws {
        let framework = Bundle.main.bundleURL.appendingPathComponent("Frameworks/sony2fuji.framework")
        let bundled = Bundle(url: framework)?.url(forResource: "Lensfun", withExtension: nil)
        guard let url = lensDatabaseURL ?? Bundle.main.url(forResource: "Lensfun", withExtension: nil) ?? bundled else {
            throw ProcessorError.processFailed(L10n.text("镜头数据库未打包到应用中"))
        }
        let status = url.path.withCString { sony2fuji_session_set_lens_database(session, $0) }
        guard status == SONY2FUJI_STATUS_OK else { throw ProcessorError.processFailed(L10n.text("镜头数据库不可用")) }
    }

    func configureLens(_ session: OpaquePointer, settings: LensCorrectionSettings) throws {
        var config = sony2fuji_lens_correction_config()
        config.version = SONY2FUJI_LENS_CORRECTION_CONFIG_VERSION
        config.struct_size = UInt32(MemoryLayout<sony2fuji_lens_correction_config>.size)
        config.distortion = settings.distortion ? 1 : 0
        config.tca = settings.tca ? 1 : 0
        config.auto_crop = settings.autoCrop ? 1 : 0
        let status = settings.coreProfileID.withCString { config.profile_id = $0; return sony2fuji_session_set_lens_correction(session, &config) }
        guard status == SONY2FUJI_STATUS_OK else { throw ProcessorError.processFailed(L10n.text("无效或不可用的镜头校正设置")) }
    }

    func readLens(_ session: OpaquePointer, url: URL) throws -> LensInfo {
        let candidates = try lensCatalog.candidates(session: session, url: url)
        var report = sony2fuji_lens_report()
        guard sony2fuji_session_get_lens_report(session, &report) == SONY2FUJI_STATUS_OK else {
            throw ProcessorError.processFailed(L10n.text("无法读取镜头校正状态"))
        }
        return LensInfo(state: report.state, detectedLens: lensText(report.lens_model), selectedLens: lensText(report.profile.model),
            appliedDistortion: report.applied_distortion != 0, appliedTCA: report.applied_tca != 0, cropScale: report.crop_scale, candidates: candidates)
    }
}
