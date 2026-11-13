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

    static func occurrences(_ haystack: String, _ needle: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
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

        let failedImport = StatusProbe()
        failedImport.status = look
        failedImport.notice = HDRResourceNotice(message: look)
        failedImport.status = saved
        failedImport.writes = 0
        failedImport.deliverFrame(missingResource: look)
        check(failedImport.status == saved && failedImport.writes == 0,
              "A failed or cancelled import stays on the old photo and its HDR frames keep deduplicating")

        let rendering = try String(contentsOfFile: "RawLab/RawLab/Core/ViewModel/RawEditorViewModel+Rendering.swift", encoding: .utf8)
        check(rendering.contains("self.updateHDRResourceNotice(hdr.missingResourceMessage)") &&
              !rendering.contains("self.statusMessage = hdr.missingResourceMessage"),
              "HDR preview delivery routes missing-resource warnings through the change-only notice")
        let io = try String(contentsOfFile: "RawLab/RawLab/Core/ViewModel/IO/RawEditorViewModel+IO.swift", encoding: .utf8)
        check(io.contains("self.hdrResourceNotice = HDRResourceNotice(message: hdr.missingResourceMessage)"),
              "HDR import records the warning it already showed")

        // 防伪造接线锚点：行为断言由 StatusProbe 驱动生产 HDRResourceNotice 完成，
        // 下面逐处钉死生产代码里每一个缓存重置/撤回站点，删除任何一处本套件必红。
        let sdrReset = "self.hdrResourceNotice = HDRResourceNotice()"
        guard let hdrStart = io.range(of: "if let hdr=restoredSettings.hdr,restoredSettings.isHDREditing {"),
              let rawStart = io.range(of: "} else if sourceKind == .raw {"),
              let rasterStart = io.range(of: "                        } else {", range: rawStart.upperBound..<io.endIndex)
        else { fatalError("importImage lost a delivery branch anchor") }
        check(!io[io.startIndex..<hdrStart.lowerBound].contains("hdrResourceNotice = HDRResourceNotice()"),
              "The import entry keeps the notice cache so a failed or cancelled import can fall back to the old photo")
        check(occurrences(String(io[rawStart.lowerBound..<rasterStart.lowerBound]), sdrReset) == 1,
              "The RAW SDR delivery resets the HDR resource notice cache")
        check(occurrences(String(io[rasterStart.lowerBound...]), sdrReset) == 1,
              "The raster SDR delivery resets the HDR resource notice cache")
        check(occurrences(rendering, "updateHDRResourceNotice(nil)") == 3,
              "Every SDR preview delivery path (RAW render, raster render, cached preview) withdraws the stale HDR notice")

        let sdrTransition = StatusProbe()
        sdrTransition.status = look
        sdrTransition.notice = HDRResourceNotice(message: look)
        check(sdrTransition.status == look, "HDR photo with missing resource shows warning")
        sdrTransition.deliverFrame(missingResource: nil)
        check(sdrTransition.status == nil, "Switching the same photo to the SDR preview withdraws the still-visible HDR warning")
        sdrTransition.deliverFrame(missingResource: look)
        check(sdrTransition.status == look,
              "Re-enabling HDR editing on the same photo shows the missing-resource warning again")
    }
}
