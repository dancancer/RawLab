import Foundation

/// HDR 缺失资源提示只在资源状态变化时写入通用状态消息，避免每帧预览覆盖用户刚看到的其他提示。
struct HDRResourceNotice {
    enum Change: Equatable {
        case keep
        case show(String)
        case clear
    }

    var message: String?

    mutating func change(to message: String?, status: String?) -> Change {
        guard message != self.message else { return .keep }
        let previous = self.message
        self.message = message
        if let message { return .show(message) }
        // 资源恢复后只撤回仍在显示的旧警告，不清掉其他提示。
        return status == previous ? .clear : .keep
    }
}
