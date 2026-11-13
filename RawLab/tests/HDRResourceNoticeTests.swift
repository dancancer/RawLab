import Foundation

/// 按 `RawEditorViewModel.updateHDRResourceNotice` 的方式逐帧交付 HDR 预览，并统计状态消息写入次数。
final class StatusProbe {
    var notice = HDRResourceNotice()
    var writes = 0
    var status: String? { didSet { writes += 1 } }

    func deliverFrame(missingResource message: String?) {
        switch notice.change(to: message, status: status) {
        case .show(let message): status = message
        case .clear: status = nil
        case .keep: break
        }
    }
}

@main enum HDRResourceNoticeTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
        print("PASS: \(message)")
    }

    static func main() throws {
        let saved = "已保存到照片。"
        let look = "上次使用的外观不可用，请重新选择或导入外观。"
        let profile = "找不到 HDR 相机配置，请重新导入。"

        let complete = StatusProbe()
        complete.status = saved
        let writesBeforeFrames = complete.writes
        for _ in 0..<3 { complete.deliverFrame(missingResource: nil) }
        check(complete.status == saved && complete.writes == writesBeforeFrames,
              "A complete HDR preview frame keeps the user's status message")

        let missing = StatusProbe()
        missing.status = saved
        missing.writes = 0
        missing.deliverFrame(missingResource: look)
        check(missing.status == look && missing.writes == 1, "A newly missing HDR resource is shown once")
        for _ in 0..<3 { missing.deliverFrame(missingResource: look) }
        check(missing.writes == 1, "Repeated HDR frames do not rewrite an unchanged missing-resource warning")
        missing.status = saved
        missing.deliverFrame(missingResource: look)
        check(missing.status == saved, "Repeated HDR frames do not replace a newer user message")
        missing.deliverFrame(missingResource: profile)
        check(missing.status == profile, "A different missing HDR resource is shown")
        missing.status = saved
        missing.deliverFrame(missingResource: nil)
        check(missing.status == saved, "Recovered HDR resources do not clear a newer user message")

        let recovered = StatusProbe()
        recovered.deliverFrame(missingResource: look)
        recovered.deliverFrame(missingResource: nil)
        check(recovered.status == nil, "Recovered HDR resources withdraw the still-visible warning")

        // 交付时状态转换收口在生产 HDRResourceNotice.delivered（导入三个交付站点共用）。
        let deliveredHDR = HDRResourceNotice.delivered(isHDREditing: true, missingMessage: look)
        check(deliveredHDR.message == look, "HDR import delivery records the warning it already showed")
        check(HDRResourceNotice.delivered(isHDREditing: true, missingMessage: nil).message == nil,
              "A complete HDR delivery records no warning")
        check(HDRResourceNotice.delivered(isHDREditing: false, missingMessage: look).message == nil,
              "SDR import delivery resets the notice cache even when the photo still misses HDR resources")

        let reEnabled = StatusProbe()
        reEnabled.notice = deliveredHDR
        reEnabled.status = look
        reEnabled.writes = 0
        reEnabled.deliverFrame(missingResource: look)
        check(reEnabled.status == look && reEnabled.writes == 0,
              "The first preview after an HDR import does not repeat the import warning")
        reEnabled.notice = .delivered(isHDREditing: false, missingMessage: look)
        reEnabled.deliverFrame(missingResource: look)
        check(reEnabled.status == look && reEnabled.writes == 1,
              "Switching the same photo back to HDR editing after an SDR delivery shows the missing-resource warning again")
    }
}
