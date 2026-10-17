import Foundation

enum AdjustmentKind: String, CaseIterable, Identifiable {
    case strength
    case exposure
    case highlights
    case shadows
    case contrast
    case toneCurve
    case saturation
    case hsl
    case temperature
    case tint
    case noiseReduction
    case sharpening
    case vignette
    case grain

    static let toolCases: [AdjustmentKind] = allCases.filter { $0 != .tint }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .strength:
            return L10n.text("强度")
        case .exposure:
            return L10n.text("曝光")
        case .contrast:
            return L10n.text("对比度")
        case .highlights:
            return L10n.text("高光")
        case .shadows:
            return L10n.text("阴影")
        case .toneCurve:
            return L10n.text("S 曲线")
        case .saturation:
            return L10n.text("饱和度")
        case .hsl: return "HSL"
        case .temperature:
            return L10n.text("白平衡")
        case .tint:
            return L10n.text("色调")
        case .noiseReduction:
            return L10n.text("降噪")
        case .sharpening:
            return L10n.text("锐化")
        case .vignette:
            return L10n.text("暗角")
        case .grain:
            return L10n.text("颗粒")
        }
    }

    var iconName: String {
        switch self {
        case .strength:
            return "camera.aperture"
        case .exposure:
            return "plusminus.circle"
        case .contrast:
            return "circle.lefthalf.filled"
        case .highlights:
            return "sun.max.fill"
        case .shadows:
            return "moon"
        case .toneCurve:
            return "waveform.path.ecg"
        case .saturation:
            return "drop"
        case .hsl: return "slider.horizontal.3"
        case .temperature:
            return "thermometer"
        case .tint:
            return "circle.hexagongrid"
        case .noiseReduction:
            return "sparkles"
        case .sharpening:
            return "triangle"
        case .vignette:
            return "circle.dashed"
        case .grain:
            return "circle.dotted"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .strength:
            return RawSettings.lutStrengthRange
        case .exposure:
            return -4...4
        case .contrast:
            return -100...100
        case .highlights:
            return -100...100
        case .shadows:
            return -100...100
        case .toneCurve:
            return -100...100
        case .saturation:
            return -100...100
        case .hsl: return -100...100
        case .temperature:
            return RawSettings.temperatureRange
        case .tint:
            return RawSettings.tintRange
        case .noiseReduction:
            return 0...1
        case .sharpening:
            return 0...200
        case .vignette:
            return PhotoEffectsSettings.vignetteAmountRange
        case .grain:
            return PhotoEffectsSettings.grainAmountRange
        }
    }

    var step: Double {
        switch self {
        case .strength:
            return 0.01
        case .exposure:
            return 0.05
        case .contrast:
            return 1
        case .highlights, .shadows:
            return 1
        case .toneCurve:
            return 1
        case .saturation:
            return 1
        case .temperature:
            return 10
        case .tint:
            return 1
        case .noiseReduction:
            return 0.05
        case .sharpening:
            return 1
        case .vignette, .grain:
            return 1
        case .hsl: return 1
        }
    }

    func value(from settings: RawSettings) -> Double {
        switch self {
        case .strength:
            return settings.lutStrength
        case .exposure:
            return settings.exposure
        case .contrast:
            return (settings.contrast - 1) * 100
        case .highlights:
            return -settings.highlights * 100
        case .shadows:
            return settings.shadows * 100
        case .toneCurve:
            return settings.toneCurve * 100
        case .saturation:
            return (settings.saturation - 1) * 100
        case .hsl: return settings.hsl.progress * 100
        case .temperature:
            return settings.temperature
        case .tint:
            return settings.tint
        case .noiseReduction:
            return settings.denoise.enabled ? 1 : 0
        case .sharpening:
            return settings.sharpening * 100
        case .vignette:
            return settings.photoEffects.vignetteAmount
        case .grain:
            return settings.photoEffects.grainAmount
        }
    }

    func setValue(_ value: Double, in settings: inout RawSettings) {
        switch self {
        case .strength:
            settings.lutStrength = value
        case .exposure:
            settings.exposure = value
        case .contrast:
            settings.contrast = 1 + value / 100
        case .highlights:
            settings.highlights = -value / 100
        case .shadows:
            settings.shadows = value / 100
        case .toneCurve:
            settings.toneCurve = value / 100
        case .saturation:
            settings.saturation = 1 + value / 100
        case .hsl:
            if value == 0 { settings.hsl.reset() }
        case .temperature:
            settings.temperature = value
        case .tint:
            settings.tint = value
        case .noiseReduction:
            settings.noiseReduction = 0
            settings.denoise = RawDenoiseSettings(enabled: value > 0)
        case .sharpening:
            settings.sharpening = value / 100
        case .vignette:
            settings.photoEffects.vignetteAmount = value
        case .grain:
            settings.photoEffects.grainAmount = value
        }
    }

    // ------------------------------------------------------------------------
    //  看得见的数值：参数行、工具徽标与批量摘要共用一份格式，小数点随界面语言；
    //  零不带正负号。读屏数值仍由下面的 valueLabel 提供
    // ------------------------------------------------------------------------
    var unit: String {
        switch self {
        case .strength, .contrast, .highlights, .shadows, .toneCurve, .saturation, .sharpening: return "%"
        case .exposure: return "EV"
        case .temperature: return "K"
        default: return ""
        }
    }

    func formatted(_ value: Double) -> String {
        let scaled = self == .strength ? value * 100 : value
        let number = scaled == 0 ? 0 : scaled   // -0.0（如高光默认值）按 0 显示
        let signed = number != 0 && self != .strength && self != .temperature
        let format = (signed ? "%+" : "%") + (self == .exposure ? ".2f" : ".0f")
        return String(format: format, locale: L10n.locale, number)
    }

    func displayValue(_ value: Double) -> String {
        "\(formatted(value)) \(unit)".trimmingCharacters(in: .whitespaces)
    }

    // 选中工具圆圈里的数值徽标：只给单一数值的工具
    static let badgeKinds: Set<AdjustmentKind> = [.strength, .exposure, .highlights, .shadows,
                                                  .contrast, .toneCurve, .saturation, .sharpening]

    func badge(for value: Double) -> String? {
        Self.badgeKinds.contains(self) ? formatted(value) : nil
    }

    func valueLabel(for value: Double) -> String {
        switch self {
        case .strength:
            return String(format: "%.0f%%", value * 100)
        case .exposure:
            return String(format: "%+.2f EV", value)
        case .contrast, .saturation, .sharpening:
            return String(format: "%+.0f%%", value)
        case .noiseReduction:
            return String(format: "%.2f", value)
        case .highlights, .shadows, .toneCurve:
            return String(format: "%+.0f%%", value)
        case .temperature:
            return String(format: "%.0fK", value)
        case .tint:
            return String(format: "%.0f", value)
        case .vignette, .grain:
            return String(format: "%+.0f", value)
        case .hsl: return "HSL"
        }
    }

    func progress(in settings: RawSettings) -> Double {
        if self == .temperature {
            let temperatureProgress = scalarProgress(value: settings.temperature,
                                                     baseline: RawSettings.default.temperature,
                                                     range: RawSettings.temperatureRange)
            let tintProgress = scalarProgress(value: settings.tint,
                                              baseline: RawSettings.default.tint,
                                              range: RawSettings.tintRange)
            return abs(temperatureProgress) >= abs(tintProgress) ? temperatureProgress : tintProgress
        }
        if self == .vignette || self == .grain {
            let deltas = PhotoEffectParameter.allCases
                .filter { $0.isVignette == (self == .vignette) }
                .map { parameter -> Double in
                    let value = settings.photoEffects[keyPath: parameter.keyPath]
                    let baseline = parameter.defaultValue
                    let delta = value - baseline
                    let span = delta >= 0 ? parameter.range.upperBound - baseline : baseline - parameter.range.lowerBound
                    return span > 0 ? min(max(delta / span, -1), 1) : 0
                }
            return deltas.max { abs($0) < abs($1) } ?? 0
        }
        let baseline = value(from: .default)
        let delta = value(from: settings) - baseline
        let span = delta >= 0 ? range.upperBound - baseline : baseline - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max(delta / span, -1), 1)
    }

    private func scalarProgress(value: Double, baseline: Double, range: ClosedRange<Double>) -> Double {
        let delta = value - baseline
        let span = delta >= 0 ? range.upperBound - baseline : baseline - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max(delta / span, -1), 1)
    }

    // 白平衡面板底部的拍摄时说明：数字格式随界面语言，与上方色温、色调数值一致
    static func asShotCaption(temperature: Double, tint: Double) -> String {
        L10n.format("拍摄时：%.0f K · 色调 %+.0f", temperature, tint)
    }

    // 白平衡面板底部的拍摄时参照：色温、色调已经显示拍摄时数值时（拍摄时模式且无配方偏移）不再重复
    static func asShotNote(for settings: RawSettings, cameraTemperature: Double, cameraTint: Double) -> String? {
        let showsAsShot = settings.whiteBalanceMode == .camera && settings.masterRecipeID == nil
        return showsAsShot ? nil : asShotCaption(temperature: cameraTemperature, tint: cameraTint)
    }

    static func resetWhiteBalance(in settings: inout RawSettings,
                                  cameraTemperature: Double?, cameraTint: Double?) {
        settings.temperature = cameraTemperature ?? RawSettings.default.temperature
        settings.tint = settings.masterRecipeID == nil
            ? cameraTint ?? RawSettings.default.tint
            : RawSettings.default.tint
        settings.whiteBalanceMode = .camera
    }

    func reset(in settings: inout RawSettings) {
        switch self {
        case .vignette:
            settings.photoEffects.resetVignette()
            return
        case .grain:
            settings.photoEffects.resetGrain()
            return
        default:
            break
        }
        setValue(value(from: .default), in: &settings)
    }
}
