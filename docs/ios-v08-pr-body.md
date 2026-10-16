参数调整使用单列原生滚轮和固定中心刻度，iPhone/iPad按窗口与动态字体布局。几何/镜头先预览草稿，明确应用或取消；导入、草稿和未完成预览期间保护编辑与导出。

## 改动

- 原生UIPickerView数值编辑、固定游标/移动刻线、精调、默认/边界反馈与Reduce Motion路径；补齐大师配方图标和iPad布局。
- 依据请求/来源身份拒绝迟到图像、错误、直方图和回调；取消后同图可重选，几何来源切换显式恢复未裁切编辑预览。
- 正常merge目标development `7da15e57b1f2178d12cabc823c249dc589578547`（含#53）；首次两处冲突同时保留#55固定标题保存反馈和#57 RUM成功回调/批量终态/隐私入口。第二次merge无新增冲突，iOS相关core兼容性独立复核无可行动缺陷。

## 本轮验证

当前framework/app/XCTest构建源 `106a958d161b2f21f27e8da54f6eea446c1a1a1d`，core tree `dcf78dcf15b0860383eb9d7e678c4b84631b52d0`。arm64 simulator库SHA256 `42ae4bc99ed03f9484b03a8039df12d401416e9f917c2a026062862a5be9fc7e`，与全新app内嵌库相同；当前公共头文件SHA256 `9331d38f6ae8c4227b29d8a8cf9a78a431293a54f747b269a679b8016e4b8dff`。

第一阶段8项UI/401断言与视口三组仍归属f2857bef app、f454核心/67bd库。#53前后RawLab/Shared diff为空，产品、工程、UITest源码不变；复用第一阶段UI证据，以新库定向检查补齐兼容性，不改称全部在DCF上重跑。

| 检查 | 最终结果 |
|---|---|
| 当前DCF framework与app+XCTest | 构建通过；30个API、实际当前头文件链接、资源/许可证/运行时依赖通过 |
| 当前DCF增量运行 | 56/56处理器断言、0失败/跳过，126.920s；loader探针确认新库路径、UNSUPPORTED/INVALID_ARGUMENT及空输出，0.572s |
| 第一阶段f454模型/处理器 | 导入167、真实RAW历史15、几何60、处理器导出56、批量89、发布14，共401断言；视口另三组；无skip/运行超时 |
| iPad几何来源切换 | 35/35，XCTest1/1 |
| 保存反馈 | iPhone竖/横屏、AX M、XS及iPad竖屏，共5/5；提示前/中/后完整frame最大delta0pt，重置≥44pt |
| 隐私 | 恢复后1/1，默认关闭/不可开启、旋转及返回通过 |
| 系统RAW流程 | 1/1；PhotosPicker→原生曝光/透视wheel→保存重启恢复→批量保留原DNG名并就绪 |
| RUM纯逻辑 | 配置、transport、线程及Shared两套，共五脚本通过 |

第一阶段定向UI合计8/8、零失败/跳过。首次沙箱/链接失败和隐私中断分别保留；CoreSimulator仅恢复本任务三个设备，旧设备与共享服务未动。import-state原wrapper在执行连接恢复时丢失，使用原已链接binary首次续跑返回0，没有重复编译或把旧日志当本轮结果。测试源码收集已排除Shared/tests两个独立main；缓存与host profile隔离只改测试。

## 范围与边界

相对7da15e57净diff为iOS产品、六语资源、测试及设计/证据文档；本任务未手改Shared、lutools或其他平台，macOS设计原文保留。#50/#51/#53/#55/#57已在目标。增量framework无下载/全套依赖重建，实际编译5个core和6个自动生成OpenCV kernel单元；严格mtime断言退出保留原记录，直接接续成功编译结果打包。Lensfun 14个成员payload一致，仅archive日期变化。

本轮为Xcode27/iOS27 arm64 Simulator。RAW系统用例停在批量就绪；实际文件输出由处理器/模型检查覆盖，完整应用导出历史保留原源码归属。真实设备、触觉、帧率/延迟、硬件辅助功能、iCloud/provider内部等待、fallback、多窗口/系统终止及真实RUM SDK/网络仍待验。e63单次SwiftUI发布警告未定位。本地通过不等于CI；当前Actions工作流为0。merge由协调任务核对exact head后执行。

历史e63 RAW/UI、139获取取消、6c249几何及原生UI分次验证保留准确来源，未冒充本轮重复运行。arm64 simulator framework不等同通用签名发布包。

## 证据

- [本轮来源、冲突、UI、命令与清理](https://github.com/dancancer/RawLab/blob/codex/ios-editor-v4/docs/ios-v08-development-integration-2026-10-16.md)
- [模型矩阵、输入及实际输出](https://github.com/dancancer/RawLab/blob/codex/ios-editor-v4/docs/ios-v08-model-integration-2026-10-16.md)
- [当前readiness与历史归属](https://github.com/dancancer/RawLab/blob/codex/ios-editor-v4/docs/ios-v08-pr-readiness-2026-10-15.md)
- [UI历史](https://github.com/dancancer/RawLab/blob/codex/ios-editor-v4/.impeccable/review/ios-editor-v4/README.md) · [获取取消](https://github.com/dancancer/RawLab/blob/codex/ios-editor-v4/docs/ios-v08-picker-acquisition-cancel-2026-10-15.md) · [几何修复](https://github.com/dancancer/RawLab/blob/6c249b483acb4987df95b1c25ee8a5e9e27a4cda/docs/ios-pr52-review-fixes-2026-10-15.md)

必要本地日志/xcresult/输出保留在 `/tmp/rawlab-ios-v08-integration-20261016`；源码未加入RAW、截图或构建包。本地PNG链接不代表远端附件。
