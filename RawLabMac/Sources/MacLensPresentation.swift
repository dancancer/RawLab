import Foundation

/// Catalog identity and calibration capability are separate from the last
/// render's applied corrections. A stale report must never confirm a draft.
struct MacLensPresentation {
    let settings: LensCorrectionSettings
    let info: LensInfo?
    let previewIsCurrent: Bool

    var candidate: LensCandidate? {
        guard let info else { return nil }
        if settings.mode == .manual {
            return info.candidates.first { $0.id == settings.profileID }
        }
        let matches = info.candidates.filter(\.isMatch)
        return matches.count == 1 ? matches[0] : nil
    }

    var selectedTitle: String {
        if let candidate { return candidate.title }
        if settings.mode == .manual {
            return L10n.text(settings.profileID == nil ? "选择镜头…" : "所选镜头不可用")
        }
        return L10n.text("自动匹配")
    }

    var identityStatusKey: String {
        guard info != nil else { return "镜头信息尚未就绪" }
        if settings.mode == .manual {
            if settings.profileID == nil { return "未匹配镜头，请手动选择" }
            return candidate == nil ? "所选镜头不可用" : "手动选择"
        }
        guard candidate != nil else {
            return (info?.candidates.filter(\.isMatch).count ?? 0) > 1
                ? "有多个匹配镜头，请手动选择" : "未匹配镜头，请手动选择"
        }
        return settings.isEnabled ? "已匹配配置" : "已匹配配置 · 校正尚未开启"
    }

    var correctionStatusKey: String {
        if !settings.isEnabled { return "镜头校正已关闭" }
        if info == nil { return "正在读取镜头信息…" }
        if !previewIsCurrent { return "正在预览镜头校正…" }
        return ""
    }

    var correctionStatus: String {
        correctionStatusKey.isEmpty ? (info?.message ?? "") : L10n.text(correctionStatusKey)
    }

    /// These report states describe the input, rather than a particular
    /// calibration toggle. Only the report for this draft is authoritative.
    var inputAllowsCorrection: Bool {
        guard previewIsCurrent, let info else { return true }
        switch info.state {
        case SONY2FUJI_LENS_NO_DATABASE, SONY2FUJI_LENS_NO_CAMERA,
             SONY2FUJI_LENS_MISSING_FOCAL_LENGTH, SONY2FUJI_LENS_EMBEDDED_GEOMETRY,
             SONY2FUJI_LENS_UNSUPPORTED_INPUT:
            return false
        default: return true
        }
    }

    func canChangeCorrection(tca: Bool) -> Bool {
        // A retained enabled option can always be switched off, including when
        // its calibration disappears or the current input is unsupported.
        if tca ? settings.tca : settings.distortion { return true }
        let calibrated = tca ? candidate?.hasTCA : candidate?.hasDistortion
        return calibrated == true && inputAllowsCorrection
    }

    func correctionDetailKey(tca: Bool) -> String {
        let calibrated = tca ? candidate?.hasTCA : candidate?.hasDistortion
        guard let calibrated else { return "未匹配镜头" }
        if !calibrated { return tca ? "横向色差标定不可用" : "畸变标定不可用" }
        let enabled = tca ? settings.tca : settings.distortion
        if !enabled { return tca ? "减少边缘彩色条纹" : "修正直线弯曲" }
        if !previewIsCurrent { return "正在预览镜头校正…" }
        let applied = tca ? info?.appliedTCA : info?.appliedDistortion
        return applied == true ? "已应用" : (tca ? "横向色差未应用" : "畸变未应用")
    }

    var cropPercent: Int? {
        guard settings.isEnabled, settings.autoCrop, previewIsCurrent,
              let info, info.appliedDistortion || info.appliedTCA,
              info.cropScale.isFinite, info.cropScale > 1.0001 else { return nil }
        return Int(((1 - 1 / info.cropScale) * 100).rounded())
    }
}

/// The chooser owns a local selection. Browsing, searching, or dismissing it
/// cannot modify the editor's draft; only an explicit use action produces one.
struct MacLensChooserState {
    var query = ""
    private(set) var selectedID: String?

    init(settings: LensCorrectionSettings, candidates: [LensCandidate]) {
        if settings.mode == .manual, candidates.contains(where: { $0.id == settings.profileID }) {
            selectedID = settings.profileID
        } else {
            let matches = candidates.filter(\.isMatch)
            selectedID = matches.count == 1 ? matches[0].id : nil
        }
    }

    func filtered(_ candidates: [LensCandidate]) -> [LensCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? candidates : candidates.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    mutating func select(_ id: String, candidates: [LensCandidate]) {
        guard candidates.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    func usableCandidate(in candidates: [LensCandidate]) -> LensCandidate? {
        // Search may temporarily hide the selection. Do not let Return silently
        // choose an invisible row or a profile removed from the catalog.
        filtered(candidates).first { $0.id == selectedID }
    }

    func appliedSettings(to settings: LensCorrectionSettings, candidates: [LensCandidate]) -> LensCorrectionSettings? {
        guard let candidate = usableCandidate(in: candidates) else { return nil }
        return Self.applying(candidate, to: settings)
    }

    static func applying(_ candidate: LensCandidate, to settings: LensCorrectionSettings) -> LensCorrectionSettings {
        var updated = settings
        updated.mode = .manual
        updated.profileID = candidate.id
        return updated
    }

    static func capabilityKeys(for candidate: LensCandidate) -> [String] {
        [candidate.hasDistortion ? "畸变标定" : "畸变标定不可用",
         candidate.hasTCA ? "横向色差标定" : "横向色差标定不可用"]
    }
}
