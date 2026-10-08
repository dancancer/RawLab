import Foundation

struct WhiteBalance: Equatable {
    let temperature: Double
    let tint: Double
}

enum WhiteBalanceMode: String, CaseIterable, Identifiable {
    case asShot = "拍摄时设置", custom = "自定义"
    var id: String { rawValue }
}

struct Adjustments: Equatable {
    var exposureMode = ExposureMode.scene
    var exposure = 0.0
    var temperature = 6500.0
    var tint = 0.0
    var whiteBalanceMode = WhiteBalanceMode.asShot
    private(set) var asShotWhiteBalance: WhiteBalance?
    var strength = 1.0
    var contrast = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var toneCurve = 0.0
    var saturation = 0.0
    var sharpening = 0.0

    func apply(to request: inout sony2fuji_request) {
        request.exposure_ev = Float(exposure)
        request.brightness = 1
        let cameraWB = whiteBalanceMode == .asShot ||
            (temperature == asShotWhiteBalance?.temperature && tint == asShotWhiteBalance?.tint)
        request.wb_mode = cameraWB ? SONY2FUJI_WB_CAMERA : SONY2FUJI_WB_TEMPERATURE
        request.temperature = cameraWB ? 6500 : Float(temperature)
        request.tint = cameraWB ? 0 : Float(tint)
        request.contrast = Float(1 + contrast / 100)
        request.saturation = Float(1 + saturation / 100)
        // The core's positive highlight value compresses light; UI positive brightens.
        request.highlights = Float(-highlights / 100)
        request.shadows = Float(shadows / 100)
        request.tone_curve = Float(toneCurve / 100)
        request.sharpening = Float(sharpening / 100)
    }

    mutating func reset(_ group: AdjustmentGroup) {
        for parameter in group.parameters {
            set(parameter, to: parameter.spec(for: self).defaultValue)
        }
        if group == .input { exposureMode = .scene; resetWhiteBalance() }
    }

    func isDefault(_ group: AdjustmentGroup) -> Bool {
        group.parameters.allSatisfy { self[keyPath: $0.spec.keyPath] == $0.spec(for: self).defaultValue }
            && (group != .input || exposureMode == .scene)
    }

    mutating func resolveWhiteBalance(_ camera: WhiteBalance?) {
        asShotWhiteBalance = camera
        if whiteBalanceMode == .asShot { resetWhiteBalance() }
    }

    mutating func resetWhiteBalance() {
        temperature = asShotWhiteBalance?.temperature ?? 6500
        tint = asShotWhiteBalance?.tint ?? 0
        whiteBalanceMode = .asShot
    }

    mutating func set(_ parameter: AdjustmentParameter, to value: Double) {
        self[keyPath: parameter.spec.keyPath] = value
        if parameter.isWhiteBalance {
            whiteBalanceMode = temperature == asShotWhiteBalance?.temperature && tint == asShotWhiteBalance?.tint ? .asShot : .custom
        }
    }

    mutating func resetAll() {
        let camera = asShotWhiteBalance
        self = Adjustments()
        resolveWhiteBalance(camera)
    }

    var isDefault: Bool { AdjustmentGroup.allCases.allSatisfy { isDefault($0) } }
}

enum AdjustmentGroup: String, CaseIterable, Identifiable {
    case film = "胶片模拟", input = "输入调整", tone = "明暗", color = "色彩", detail = "细节"
    var id: String { rawValue }
    var parameters: [AdjustmentParameter] {
        switch self {
        case .film: return [.strength]
        case .input: return [.exposure, .temperature, .tint]
        case .tone: return [.contrast, .highlights, .shadows, .toneCurve]
        case .color: return [.saturation]
        case .detail: return [.sharpening]
        }
    }
}

struct AdjustmentSpec {
    let title: String
    let keyPath: WritableKeyPath<Adjustments, Double>
    let range: ClosedRange<Double>
    var defaultValue: Double
    let step: Double
    let unit: String
    var multiplier = 1.0
    var decimals = 0
    var reciprocalScale = false

    func position(for value: Double) -> Double {
        if reciprocalScale {
            return (1 / range.lowerBound - 1 / value) / (1 / range.lowerBound - 1 / range.upperBound)
        }
        return (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    func value(at position: Double) -> Double {
        let position = min(1, max(0, position))
        let value = reciprocalScale ? 1 / (1 / range.lowerBound - position * (1 / range.lowerBound - 1 / range.upperBound)) :
            range.lowerBound + position * (range.upperBound - range.lowerBound)
        return min(range.upperBound, max(range.lowerBound, (value / step).rounded() * step))
    }

    func text(_ value: Double) -> String {
        String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), decimals, value * multiplier)
    }

    func parse(_ text: String) -> Double? {
        guard let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite else { return nil }
        return min(range.upperBound, max(range.lowerBound, number / multiplier))
    }
    func progress(for value: Double) -> Double {
        let origin = position(for: defaultValue)
        let offset = position(for: value) - origin
        let distance = offset < 0 ? origin : 1 - origin
        return distance > 0 ? min(1, max(-1, offset / distance)) : 0
    }
}

enum AdjustmentParameter: String, CaseIterable, Identifiable {
    case strength, exposure, temperature, tint, contrast, highlights, shadows, toneCurve, saturation, sharpening
    var id: String { rawValue }
    var isWhiteBalance: Bool { self == .temperature || self == .tint }
    func spec(for settings: Adjustments) -> AdjustmentSpec {
        var value = spec
        if self == .temperature { value.defaultValue = settings.asShotWhiteBalance?.temperature ?? 6500 }
        if self == .tint { value.defaultValue = settings.asShotWhiteBalance?.tint ?? 0 }
        return value
    }
    static let photoTools: [Self] = [.exposure, .highlights, .shadows, .contrast, .toneCurve,
                                    .saturation, .temperature, .tint, .sharpening]
    var symbol: String {
        switch self {
        case .strength: return "camera.aperture"
        case .exposure: return "plusminus.circle"
        case .highlights: return "sun.max"
        case .shadows: return "moon"
        case .contrast: return "circle.lefthalf.filled"
        case .toneCurve: return "waveform.path"
        case .saturation: return "drop.halffull"
        case .temperature: return "thermometer.medium"
        case .tint: return "camera.filters"
        case .sharpening: return "triangle"
        }
    }
    var spec: AdjustmentSpec {
        switch self {
        case .strength: return AdjustmentSpec(title: "强度", keyPath: \.strength, range: 0...2, defaultValue: 1, step: 0.01, unit: "%", multiplier: 100)
        case .exposure: return AdjustmentSpec(title: "曝光", keyPath: \.exposure, range: -4...4, defaultValue: 0, step: 0.05, unit: "EV", decimals: 2)
        case .temperature: return AdjustmentSpec(title: "色温", keyPath: \.temperature, range: 2000...50000, defaultValue: 6500, step: 10, unit: "K", reciprocalScale: true)
        case .tint: return AdjustmentSpec(title: "色调", keyPath: \.tint, range: -150...150, defaultValue: 0, step: 1, unit: "")
        case .contrast: return AdjustmentSpec(title: "对比度", keyPath: \.contrast, range: -100...100, defaultValue: 0, step: 1, unit: "%")
        case .highlights: return AdjustmentSpec(title: "高光", keyPath: \.highlights, range: -100...100, defaultValue: 0, step: 1, unit: "%")
        case .shadows: return AdjustmentSpec(title: "阴影", keyPath: \.shadows, range: -100...100, defaultValue: 0, step: 1, unit: "%")
        case .toneCurve: return AdjustmentSpec(title: "S 曲线", keyPath: \.toneCurve, range: -100...100, defaultValue: 0, step: 1, unit: "%")
        case .saturation: return AdjustmentSpec(title: "饱和度", keyPath: \.saturation, range: -100...100, defaultValue: 0, step: 1, unit: "%")
        case .sharpening: return AdjustmentSpec(title: "锐化", keyPath: \.sharpening, range: 0...200, defaultValue: 0, step: 1, unit: "%")
        }
    }
}

struct PhotoViewport: Equatable {
    private(set) var magnification: CGFloat = 1
    private(set) var pixelMode = false
    mutating func fit() { self = PhotoViewport() }
    mutating func actualPixels() { magnification = 1; pixelMode = true }
    mutating func toggleActualPixels() {
        if pixelMode || magnification != 1 { fit() } else { actualPixels() }
    }
    mutating func zoom(by multiplier: CGFloat) {
        magnification = min(16, max(0.1, magnification * multiplier))
    }
    func factor(fit: CGFloat, displayScale: CGFloat) -> CGFloat {
        (pixelMode ? 1 / max(1, displayScale) : fit) * magnification
    }
}

struct PhotoEditState {
    var settings: Adjustments
    var filmID: String
}

struct PhotoEditSession {
    private var edits: [URL: PhotoEditState] = [:]
    mutating func save(_ url: URL, settings: Adjustments, filmID: String) {
        edits[url.standardizedFileURL] = PhotoEditState(settings: settings, filmID: filmID)
    }
    func state(for url: URL, defaultFilmID: String) -> PhotoEditState {
        edits[url.standardizedFileURL] ?? PhotoEditState(settings: Adjustments(), filmID: defaultFilmID)
    }
}
