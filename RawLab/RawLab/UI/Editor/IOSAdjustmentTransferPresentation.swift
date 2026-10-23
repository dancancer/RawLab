import Foundation

extension AdjustmentTransferField {
    static func groupTitle(_ group: String) -> String {
        L10n.text(["looks": "外观", "light": "光线", "color": "颜色", "effects": "效果", "detail": "细节", "geometry": "几何与镜头"][group] ?? group)
    }
    var displayTitle: String {
        if let location = hslLocation {
            return L10n.text(HSLSettings.channelNames[location.channel]) + " · " + HSLAxis(rawValue: location.axis)!.title
        }
        let labels: [Self: String] = [
            .look: "外观", .strength: "强度", .exposure: "曝光", .exposureMode: "曝光模式",
            .contrast: "对比度", .highlights: "高光", .shadows: "阴影", .sCurve: "S 曲线",
            .whiteBalanceMode: "白平衡模式", .temperature: "色温", .tint: "色调", .saturation: "饱和度",
            .vignetteAmount: "暗角", .vignetteMidpoint: "中点", .vignetteRoundness: "圆度",
            .vignetteFeather: "羽化", .vignetteHighlights: "高光保护", .grainAmount: "颗粒",
            .grainSize: "大小", .grainRoughness: "粗糙度", .sharpening: "锐化",
            .rawDenoise: "RAW 降噪", .postRGBDenoise: "旧版降噪", .chromaDenoise: "色度降噪", .waveletDenoise: "降噪参数",
            .cropX: "水平位置", .cropY: "垂直位置", .cropWidth: "宽度", .cropHeight: "高度",
            .quarterTurns: "旋转", .flipHorizontal: "水平翻转", .flipVertical: "垂直翻转",
            .straighten: "拉直", .perspectiveHorizontal: "水平透视", .perspectiveVertical: "垂直透视",
            .lensDistortion: "畸变校正", .lensTCA: "横向色差", .lensAutoCrop: "自动裁切", .lensProfile: "镜头配置"
        ]
        return L10n.text(labels[self] ?? rawValue)
    }
}

extension IOSAdjustmentTransferStatus {
    var title: String {
        switch self {
        case .applied: return L10n.text("已保存")
        case .unchanged: return L10n.text("未变化")
        case .skipped: return L10n.text("已跳过")
        case .blocked: return L10n.text("待处理")
        case .conflict: return L10n.text("调整已变化")
        case .failed: return L10n.text("保存失败")
        }
    }
}
