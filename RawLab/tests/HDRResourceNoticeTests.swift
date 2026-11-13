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

        let imported = StatusProbe()
        imported.status = look
        imported.notice = HDRResourceNotice(message: look)
        imported.status = saved
        imported.writes = 0
        imported.deliverFrame(missingResource: look)
        check(imported.status == saved && imported.writes == 0,
              "The first preview after an HDR import does not repeat the import warning")

        let rendering = try String(contentsOfFile: "RawLab/RawLab/Core/ViewModel/RawEditorViewModel+Rendering.swift", encoding: .utf8)
        check(rendering.contains("self.updateHDRResourceNotice(hdr.missingResourceMessage)") &&
              !rendering.contains("self.statusMessage = hdr.missingResourceMessage"),
              "HDR preview delivery routes missing-resource warnings through the change-only notice")
        let io = try String(contentsOfFile: "RawLab/RawLab/Core/ViewModel/IO/RawEditorViewModel+IO.swift", encoding: .utf8)
        check(io.contains("self.hdrResourceNotice = HDRResourceNotice(message: hdr.missingResourceMessage)"),
              "HDR import records the warning it already showed")
        let sdrClearsNotice = io.contains("self.hdrResourceNotice = HDRResourceNotice()")
        check(sdrClearsNotice, "Switching to an SDR photo resets the HDR resource notice cache")

        let sdrTransition = StatusProbe()
        sdrTransition.status = look
        sdrTransition.notice = HDRResourceNotice(message: look)
        check(sdrTransition.status == look, "HDR photo with missing resource shows warning")

        sdrTransition.status = nil
        if sdrClearsNotice {
            sdrTransition.notice = HDRResourceNotice()
        }
        check(sdrTransition.status == nil, "Switching to an SDR photo clears statusMessage")

        sdrTransition.deliverFrame(missingResource: look)
        check(sdrTransition.status == look,
              "Opening an HDR photo with the same missing resource after SDR photo shows warning again")
    }
}
