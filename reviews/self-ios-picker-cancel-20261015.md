# iOS picker 取消独立复核

## Must-fix

（无）

## Should-fix

（无）未发现可行动缺陷。

## 范围与覆盖

Self / Solo，功能、并发取消、状态机、测试覆盖；标准：根 AGENTS.md、agent.md、RawLab/AGENTS.md。分支 `codex/ios-editor-v4`，base=HEAD=merge-base `3fa6ed5b9228cc71bf50241bcde3f441a478b3d0`，审查其冻结 WIP；committed/staged 空，2 modified + 4 untracked。终检 6/6 与 `/tmp/rawlab-ios-v08-picker-review-source/manifest.txt` 源副本逐字一致。

全读 6/6（相对 `RawLab/`）：`RawLab.xcodeproj/project.pbxproj`、`RawLab/UI/ContentView+Helpers.swift`、`RawLabUITests/PickerAcquisitionCancelUITests.swift`、`tests/PickerCancelHarness.swift`、`tests/picker-cancel-harness.sh`、`tests/picker-cancel-ui.sh`；无遗漏。生产仅 +1 行，PBX +4/-1，新增测试与脚本 656 行，影响限 iOS 导入。

## 证据

原始 `/tmp/rawlab-ios-v08-picker-baseline/picker-cancel-ui.log:295` 显示取消后 source=A、selectedPhoto=B、acquisitionCount=2，重选 B 超时。`ContentView.swift:103` 仅响应选择变化；Helpers:314 清空选择恢复重选，nil 经 guard 返回。追踪 onDisappear:191 → cancelPhotoImport:310 → loadSource:86–95：先撤销 request、取消 task、解锁，迟到成功文件由生产取消检查释放，旧 catch:299 无权更新新请求。获取期 VM 无 active import，旧图及未改几何草稿不被撤销。

测试先走系统选片/真实本地 PNG transferable，再在返回后扣门；UIKit push/pop 保留同一 hosting controller，真实 onDisappear 执行取消。成功门交回原 source；失败门由 Harness:67 自清文件后抛合成错误，不能作为生产失败清理证据。

## 验证边界

本 reviewer 未构建、运行测试或操作设备。已读 fixed-phone/ipad 的 manifest 与三处插桩 diff；截至本次取样，两端首个空编辑器用例通过，其余运行中，完整结果待 root 核实。无静态阻断，定向验证终态仍待完成。不覆盖 provider 内部在途、iCloud、RAW fallback、旧解码/Shared 算法或未改平台。Self CI N/A；无远端自动审查，未发布远端评论、review 或 approval。
