# iOS 0.8 PR #52 整合准备

现有 [PR #52](https://github.com/dancancer/RawLab/pull/52) 使用源分支 `codex/ios-editor-v4`、目标 `development`。本轮先正常merge目标435feda（4fec911），随后接入#53后的目标 `7da15e57b1f2178d12cabc823c249dc589578547`，当前源码整合提交 `106a958d161b2f21f27e8da54f6eea446c1a1a1d`。历史准备快照保留在 [683ee98版本](https://github.com/dancancer/RawLab/blob/683ee98c92d323d6c38f0f09f402357f4649d4e6/docs/ios-v08-pr-readiness-2026-10-15.md)，不作为当前PR状态或提交数。

本轮达到转Ready的本地条件：第一阶段f454核心上的模型401条断言加视口三组、定向UI8/8、RUM五个纯逻辑脚本通过；目标移动后DCF核心的新framework、30个API/实际头文件链接、全新app/XCTest、loader运行探针和56项RAW处理器检查均通过。首次失败/中断保留原始记录，未计通过。源码、测试与文档均经独立复核；远端最终head与Ready状态由PR和任务回执确认。合入由协调任务执行，本任务不执行merge、发布、main或tag操作。

## 当前可复核来源

- 当前framework/app/XCTest构建：`106a958d161b2f21f27e8da54f6eea446c1a1a1d`；新core tree `dcf78dcf15b0860383eb9d7e678c4b84631b52d0`。
- 当前arm64 simulator库SHA256 `42ae4bc99ed03f9484b03a8039df12d401416e9f917c2a026062862a5be9fc7e`，与全新`derived-v4`的app内嵌库相同；公共头文件SHA256 `9331d38f6ae8c4227b29d8a8cf9a78a431293a54f747b269a679b8016e4b8dff`。
- iOS产品树 `6c48c015fc6d8e5f53670ed9d6e512738243e5ea`、UITest树 `af3245e0176dbe3a744dfb60f8a8ce386d834e53`、Shared树 `bc401d9573b324ce8712e07d12d8ef637c2900c8` 与第一阶段不变。6c046→106a的RawLab/Shared diff为空；仅文档收口不重复构建。
- 第一阶段app/XCTest来源f2857bef、核心f454bab6、库SHA256 `67bd918c1ebce865f1c4c1665b2bb233c86d5ccda85dc734184e90deffc6e293`。8项UI/401断言与视口三组仍归属此组合，依据源码不变与新core定向检查复用，未称在DCF库上重跑。
- [整合报告](ios-v08-development-integration-2026-10-16.md)记录精确命令、两处冲突、首次失败/恢复、UI与清理；[模型报告](ios-v08-model-integration-2026-10-16.md)记录七项矩阵、输入与输出。必要本地证据在 `/tmp/rawlab-ios-v08-integration-20261016`。

最新fetch为7da15e57，本地source包含该target。首次Helpers/Panels冲突已实际解决；第二次merge无新增冲突。#53的core/header/link变化已用新产物验证，没有用旧库遮掩。提交列表和净diff以实际ref取得：

```sh
git log --oneline origin/development..HEAD
git diff --stat origin/development...HEAD
git merge-base --is-ancestor origin/development HEAD
git diff --check origin/development...HEAD
```

## 范围、依赖与复核

相对7da15e57净diff属于iOS界面、导入/发布保护、六语资源、工程及对应测试/设计文档。目标Shared/RUM与其他平台内容由正常merge接入，本任务未手改Shared/lutools/其他平台。DESIGN.md保留macOS原文，仅有已授权iOS/iPadOS扩展。

目标包含#50 RAW缓存、#51透视、#53共享display/v4 core、#55保存提示及#57 RUM。Helpers同时保留request/source guard与RUM成功回调；Panels把保存反馈放在固定标题栏、保留原生工具布局并接入隐私入口。任务内与协调侧独立review均无可行动缺陷。新增测试/脚本及文档另经只读复核，文档修正已落实；静态review没有计作动态验证。

framework使用当前DCF核心树、Release/arm64 Simulator/最低iOS18，30个C API、当前头文件实际链接、资源/许可证和系统动态依赖通过。新增loader在iOS返回UNSUPPORTED，实际运行探针通过；原RAW/BUFFER输入及iOS调用路径兼容，未引入ImageIO/CoreGraphics链接。独立只读复核未发现Must-fix/Should-fix。增量构建实际编译5个core及6个自动生成OpenCV kernel单元，无下载/全套依赖重建；Lensfun 14个成员payload一致，仅archive日期变化。只覆盖arm64 simulator；通用包仍按 `bash lutools/build.sh ios` 和 `lutools/platform/ios/verify-framework.sh` 验收，本轮没有签名device或x86_64结论。

## 本轮与历史结果归属

| 第一阶段f454核心 | 结果 |
|---|---|
| 模型/处理器 | 导入状态167、真实RAW历史15、几何60、处理器导出56、批量状态89、批量发布14，共401断言；视口另三组；零跳过、零运行超时。import-state为既有binary首次续跑返回0，原wrapper无完整退出记录 |
| 几何来源UI | 35/35断言，XCTest1/1 |
| 保存反馈UI | iPhone竖/横屏、AX M、XS四项与iPad竖屏一项，5/5；完整frame最大delta0pt，重置目标≥44pt |
| 隐私UI | 恢复后r2为1/1、13.225s；原run中断-15另存 |
| 系统RAW UI | 1/1、91.531s；真实PhotosPicker、原生wheel、保存/重启/透视恢复及批量RAW就绪；未将就绪算作实际批量文件发布 |
| RUM逻辑 | 五脚本通过，默认关闭及fake opt-in/transport/lifecycle；无真实SDK/网络发送 |

上述第一阶段UI共8/8、零失败/跳过，原始xcresult汇总见ui-final-summary.json。iPad保存仅竖屏底部参数区，不声称本轮重跑iPad横屏/大字号/滚轮保存。

DCF增量结果单列：106a来源的新app/42ae库，56/56处理器断言、0失败/跳过、exit0，126.920s含编译；loader探针exit0、0.572s，确认实际加载新库及UNSUPPORTED/INVALID_ARGUMENT/空输出。证据分别为`models-v4/processor-export-result.json`、`models-v4/display-loader-runtime.json`，构建来源在`target-v4/app-provenance.json`和`framework-v4/framework-provenance.json`；相对路径均属上述证据根目录。

历史结果不改写为本轮重跑：146fabf原生UI分次验证；精确e63a30f的167状态、13迟到RAW、三组尺寸、UI9/9和JPEG/DNG比对；3fa6ed5空态两端4/4及28次打开取消；1393423获取取消两端各3/3及54刻度数学；6c249b4几何35/35与禁用刻度输入。详情：

- [UI历史记录](../.impeccable/review/ios-editor-v4/README.md)
- [导入锁与RAW](ios-v4-import-lock-verification-2026-10-14.md)
- [获取取消](ios-v08-picker-acquisition-cancel-2026-10-15.md)
- [几何修复](ios-pr52-review-fixes-2026-10-15.md)
- [禁用刻度](ios-pr52-ruler-disabled-2026-10-15.md)

## 后续边界

CoreSimulator阻塞经核对UUID后仅终止三个任务launchd而恢复，旧设备/共享服务未动；恢复后单设备顺序验证。已清理不再需要的缓存/helper/输入副本并正常shutdown任务设备，保留匹配产品与必要证据供复核。

真实provider内部等待/iCloud/fallback/迟到失败、多窗口/系统终止、签名真机、物理触觉、帧率/延迟及硬件辅助功能待验；RUM逻辑与默认隐私UI不代表真实SDK验收。e63一次SwiftUI发布警告仍未定位，不能因本轮结果无该记录而关闭。当前GitHub Actions工作流查询为0，未把本地验证写成CI通过；最终PR检查与合入由协调核对exact head。
