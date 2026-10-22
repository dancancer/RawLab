# 第七批：S4 RGB 与工作区联合回归

状态：实施中。范围来自 [工作区需求 REQ-10/11、AC-16/17/20/21](../../design/editor-workspace/requirements.md) 和 [技术方案 8.2、10](../../design/editor-workspace/technical-design.md)。本批承接 S3，不改整体迭代的审批或验收状态。

## 基线与责任

四端复用各自干净的隔离 worktree。分支从最新 `origin/development`（启动时 `a11048ea`）创建，显式合入本地 S3 集成 `1e4d9ce1`。后者包含四端最终 S3 和当前 CI 流程；本地集成不等于远端合入。共享 C++ 核心没有变更，不因只改客户端而重复冷构建。

| 任务 | owner 与独占路径 | 消费和产出 |
| --- | --- | --- |
| T0 共享资源与总账 | 协调者：`Shared/strings/`、30 个生成输出、本文和总账 | 四端共用六语 RGB 标题、不可用状态及已有展开/收起/来源文案 |
| T1 iOS RGB | 主代理：processor、VM rendering/import、EditorComponents/ContentView、本端相关测试 | 从持有的实际显示 buffer 生成三通道计数；保留延后统计与帧身份校验 |
| T2 Android RGB | 主代理：JNI、NativeProcessor/NativeFrame、EditorRenderer/PreviewPair、照片叠层及本端测试 | native 统计拷贝为 JVM 自有数组；像素和可空统计随同一结果接受 |
| T3 桌面补齐 | 主代理：Mac Engine/直方图展示、Windows RenderEngine/Viewing、对应测试 | 统计失败保留图像；Windows neutral 真统计；四端一致的来源和不可用语义 |
| T4 独立核验与联合回归 | 默认只读代理复核；主代理执行原生验证与最终集成 | 精确计数、切图/乱序/无统计、六语与可访问性、导入/外观/导出/批量快照的实际证据 |

平台源码由主代理修改，默认代理仅承担范围明确的只读核验。共享资源只由协调者写入。每端从同一基础资源提交继续；所有平台变更进入同一本地集成源后做受影响组合验证。

## 统计接口

1. 复用 `sony2fuji_analyze_image`，不改变 C ABI 或核心算法。计数固定为 channel-major 的 768 个 UInt32；每通道总和等于该统计帧的宽×高。桥接保留无符号计数、尺寸与数组所有权，拒绝非法长度或不完整统计。
2. 只统计已生成且位于 CPU 的显示 RGB8/RGBA8 buffer，使用 CPU 路径、不请求移动端 clipping mask；不改变照片渲染的 Auto/Force，不增加 RAW 解码，不经过截图或 CGImage 读回。
3. iOS 保留交互 `includeHistogram=false`、串行 render queue 及延迟统计。接受新图时清除旧统计；延迟结果必须同时匹配 source revision、render ID 和已接受 frame ID。Android 通过现有 revision 门控接受完整 PreviewPair，neutral cache 同时缓存本帧统计。
4. 统计失败不使已经生成的照片失败；当前统计为空，绘图清空并保留叠层位置，显示本地化不可用状态。不得回退到旧帧/base bins。
5. 普通、并排和分割线显示调整后统计；hold 显示匹配 neutral 的真实统计并标识调整前。统计尺寸使用真实预览尺寸，不冒称全尺寸 RAW。查看、折叠和统计更新不保存调整。
6. 三通道共用峰值，重叠显示 RGB/CMY/灰。移动纯预览隐藏普通直方图叠层；恢复保留折叠状态。触点、字号和可访问名称沿用原生约定。

## 实施与验证

1. 先增加确定会失败的精确 RGB fixture 回归，再实现桥接：覆盖黑白、纯色、不同通道峰值、RGBA alpha、带 padding stride，以及非法 buffer/统计失败。检查全部 768 个 bin 和三个通道总和，不能只测红通道或数组长度。
2. iOS 扩展现有 processor-export、ViewingRender、ImportState/RawImportHistory 检查，验证交互新图清统计、旧延迟丢弃、neutral/after 来源与真实尺寸。Android 扩展已有 JNI/模型/Compose 检查，验证无符号拷贝、帧与缓存一致、切图和失败重试。
3. 桌面保留已有 RGB 绘制规则，补真实 neutral 和非致命统计失败回归；现有渲染/比较门控继续生效。统计和 clipping 不可用时不发布另一帧数据。
4. 四端构建并执行受影响的原生测试。基于同一集成源核验 RAW/raster 导入切换、保存重开、外观管理、单张/批量导出、取消/恢复和 snapshot 隔离；复用已有测试与只读样本。相同设置的 preview/FINAL 对照按实际运行路径登记。
5. 六语、普通/大字号、窄窗/横屏、折叠/纯预览、键盘/语义入口与 Reduce Motion 覆盖新增叠层；实际 VoiceOver/TalkBack、物理设备、硬件 GPU 和真实系统权限恢复未执行时明确记为未验证，不能以语义树或模拟失败代替。
6. 验证按 source/configuration 绑定，保留有效原生缓存，只重跑新代码及其受影响流程。最终独立复评关闭实际问题后清理本次一次性产物，保留必要证据和原始 RAW。

本批不包含 push、创建 PR、远端合并或发布授权；完成本地交付后如需这些动作，针对实际提交另行取得授权。S4 本地完成不自动关闭 I1 的 Windows MCP 实测或其他 ITER 项。
