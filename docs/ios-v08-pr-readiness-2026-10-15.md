# iOS 0.8 PR #52 整合准备

现有 [PR #52](https://github.com/dancancer/RawLab/pull/52) 使用源分支 `codex/ios-editor-v4`、目标 `development`。本轮以正常merge接入目标 `435feda1d6e44cc5a53a4a0c73208ce96fc6ee0b`，整合提交 `4fec9111869e65f5927757390feed3bdcc038828`。历史准备快照保留在 [683ee98版本](https://github.com/dancancer/RawLab/blob/683ee98c92d323d6c38f0f09f402357f4649d4e6/docs/ios-v08-pr-readiness-2026-10-15.md)，不作为当前PR状态或提交数。

本轮达到转Ready的本地条件：新framework与app/XCTest构建通过；模型401条断言加视口三组、恢复后的定向UI8/8、RUM五个纯逻辑脚本通过。首次失败/中断保留原始记录，未计通过。源码、测试与文档均经独立复核；远端最终head与Ready状态由PR和任务回执确认。合入由协调任务执行，本任务不执行merge、发布、main或tag操作。

## 当前可复核来源

- 产品/app/XCTest构建：`f2857bef02ff49ffaacfdd8b7fe41cae235e9e29`；产品树 `6c48c015fc6d8e5f53670ed9d6e512738243e5ea` 自4fec911未变。
- 已复核测试脚本：`9ec42c6649a5797efeefcf74ea2e3b3ba1a4c284`。之后仅文档收口，产品、工程、UITest、Shared及native构建输入与f285一致；不为同内容文档提交重复构建。
- 新framework核心树：`f454bab64993119d45795d5996702a824daadea5`；arm64 simulator SHA256 `67bd918c1ebce865f1c4c1665b2bb233c86d5ccda85dc734184e90deffc6e293`，与app内嵌库相同。
- [整合报告](ios-v08-development-integration-2026-10-16.md)记录精确命令、两处冲突、首次失败/恢复、UI与清理；[模型报告](ios-v08-model-integration-2026-10-16.md)记录七项矩阵、输入与输出。必要本地证据在 `/tmp/rawlab-ios-v08-integration-20261016`。

最终fetch仍为435feda，本地source包含该target，已实际解决两处文本冲突；不沿用旧440b978的无冲突结论。#53新core尚未合入，协调给出准确target后按实际core/header/link差异补增量构建与验证，不用旧预构建库遮掩变化。提交列表和净diff以实际ref取得，避免固定计数过期：

```sh
git log --oneline origin/development..HEAD
git diff --stat origin/development...HEAD
git merge-base --is-ancestor origin/development HEAD
git diff --check origin/development...HEAD
```

## 范围、依赖与复核

相对435feda净diff属于iOS界面、导入/发布保护、六语资源、工程及对应测试/设计文档。目标Shared/RUM与其他平台内容由正常merge接入，本任务未手改Shared/lutools/其他平台。DESIGN.md保留macOS原文，仅有已授权iOS/iPadOS扩展。

目标包含#50 RAW缓存、#51透视、#55保存提示及#57 RUM。Helpers同时保留request/source guard与RUM成功回调；Panels把保存反馈放在固定标题栏、保留原生工具布局并接入隐私入口。任务内与协调侧独立review均无可行动缺陷。新增测试/脚本及文档另经只读复核，文档修正已落实；静态review没有计作动态验证。

framework使用当前核心树、Release/arm64 Simulator/最低iOS18，29个C API、当前头文件实际链接、资源/许可证和系统动态依赖通过。只覆盖arm64 simulator；通用包仍按 `bash lutools/build.sh ios` 和 `lutools/platform/ios/verify-framework.sh` 验收，本轮没有签名device或x86_64结论。

## 本轮与历史结果归属

| 本轮 | 结果 |
|---|---|
| 模型/处理器 | 导入状态167、真实RAW历史15、几何60、处理器导出56、批量状态89、批量发布14，共401断言；视口另三组；零跳过、零运行超时。import-state为既有binary首次续跑返回0，原wrapper无完整退出记录 |
| 几何来源UI | 35/35断言，XCTest1/1 |
| 保存反馈UI | iPhone竖/横屏、AX M、XS四项与iPad竖屏一项，5/5；完整frame最大delta0pt，重置目标≥44pt |
| 隐私UI | 恢复后r2为1/1、13.225s；原run中断-15另存 |
| 系统RAW UI | 1/1、91.531s；真实PhotosPicker、原生wheel、保存/重启/透视恢复及批量RAW就绪；未将就绪算作实际批量文件发布 |
| RUM逻辑 | 五脚本通过，默认关闭及fake opt-in/transport/lifecycle；无真实SDK/网络发送 |

上述UI共8/8、零失败/跳过，原始xcresult汇总见ui-final-summary.json。iPad保存仅竖屏底部参数区，不声称本轮重跑iPad横屏/大字号/滚轮保存。

历史结果不改写为本轮重跑：146fabf原生UI分次验证；精确e63a30f的167状态、13迟到RAW、三组尺寸、UI9/9和JPEG/DNG比对；3fa6ed5空态两端4/4及28次打开取消；1393423获取取消两端各3/3及54刻度数学；6c249b4几何35/35与禁用刻度输入。详情：

- [UI历史记录](../.impeccable/review/ios-editor-v4/README.md)
- [导入锁与RAW](ios-v4-import-lock-verification-2026-10-14.md)
- [获取取消](ios-v08-picker-acquisition-cancel-2026-10-15.md)
- [几何修复](ios-pr52-review-fixes-2026-10-15.md)
- [禁用刻度](ios-pr52-ruler-disabled-2026-10-15.md)

## 后续边界

CoreSimulator阻塞经核对UUID后仅终止三个任务launchd而恢复，旧设备/共享服务未动；恢复后单设备顺序验证。已清理不再需要的缓存/helper/输入副本并正常shutdown任务设备，保留匹配产品与必要证据供复核。

真实provider内部等待/iCloud/fallback/迟到失败、多窗口/系统终止、签名真机、物理触觉、帧率/延迟及硬件辅助功能待验；RUM逻辑与默认隐私UI不代表真实SDK验收。e63一次SwiftUI发布警告仍未定位，不能因本轮结果无该记录而关闭。当前GitHub Actions工作流查询为0，未把本地验证写成CI通过；最终PR检查与合入由协调核对exact head。
