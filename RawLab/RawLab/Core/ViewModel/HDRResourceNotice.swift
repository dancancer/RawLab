import Foundation

/// HDR 缺失资源提示只在资源状态变化时写入通用状态消息，避免每帧预览覆盖用户刚看到的其他提示。
struct HDRResourceNotice {
    enum Change: Equatable {
        case keep
        case show(String)
        case clear
    }

    var message: String?

    /// 交付时状态转换（导入三个交付站点共用）：HDR 帧记录本帧缺失资源消息，SDR 交付复位通知缓存。
    /// 收口成单一判定，防止逐站点手写赋值漂移；预览撤回路径继续走 `change(to:status:)` 去重。
    static func delivered(isHDREditing: Bool, missingMessage: String?) -> HDRResourceNotice {
        isHDREditing ? HDRResourceNotice(message: missingMessage) : HDRResourceNotice()
    }

    /// 帧未交付边界的统一入口（V-UIIOS P1-05）：导入开始、SDR 预览出帧前缺外观早退与
    /// 解码/渲染报错均须经此处置——上一帧的缺资源警告退役，下一帧的相同警告不再被
    /// `.keep` 压制；同图成功出帧的逐帧去重（`change(to:status:)`）不受影响。
    var afterUndeliveredFrame: HDRResourceNotice { HDRResourceNotice() }

    mutating func change(to message: String?, status: String?) -> Change {
        guard message != self.message else { return .keep }
        let previous = self.message
        self.message = message
        if let message { return .show(message) }
        // 资源恢复后只撤回仍在显示的旧警告，不清掉其他提示。
        return status == previous ? .clear : .keep
    }
}
