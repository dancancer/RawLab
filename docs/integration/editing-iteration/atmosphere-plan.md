# ITER-10 清晰度与去朦胧接入计划

承接[总需求 §12](../../design/editing-iteration/requirements.md#12-清晰度与去朦胧iter-10)
和[技术方案 §8](../../design/editing-iteration/technical-design.md#85-清晰度与去朦胧)。
本地分支 `feature/editing-atmosphere` 延续 ITER-04～09 的依赖链及四端两位小数显示
检查点 `dce6893e`。当前为本地开发与验证，没有 push、PR、合并或发行授权。

## 数值与接口

- UI/保存/选择性 payload 使用 `[-100,100]`，native 与 Agent 边界除以 100；
  稳定 ID 为 `effects.clarity`、`effects.dehaze`，通用范围默认包含。
- 两个参数独立于旧配方强度。旧记录缺失为 identity；request v2 与旧
  photo-effects config v1 不扩字段，新增独立 16-byte atmosphere config v1。
- Dehaze 在 Look 后、black/white 前；Clarity 在降噪后、锐化前。两个零值保持旧
  像素和预览路径。非零首版完整源图 CPU 处理，最后缩放；Auto 整条回 CPU，Force
  明确 unsupported。CPU 数值与边界定义见[合同](../../../lutools/docs/atmosphere-v1.md)。
- 分析网格固定长边 1024，按完整源图面积平均；缓存的是分析输入内容对应的空气光、
  guided 系数与方差。每帧仍需源图扫描，不宣称已缓存完整开发结果或免除 RAW 解码。
- 真实固定集含天空、暗部高 ISO、夜景、两张人像、雾景及逆光花卉；最大正向会更显
  原有颗粒/JPEG 纹理，不能声称恢复不存在的细节或保持所有肤色不变。

## 接入顺序与状态

- [x] T1：CPU 数值合同、45 个独立 binary64 边界向量、空间性质和固定七图质量准入。
  包含零值字节一致、灰阶、正负方向、极值、强边缘、暗噪声、平滑天空噪声、
  有色高光、灰阶渐变、色域边界连续性、双倍源尺寸及缓存/全新分析一致性。
- [x] T2 实现：additive C ABI、session 配置、CPU 链、GPU Auto/Force、Agent v5
  parser/serializer/schema/capability 与 CLI/MCP。原生回归覆盖 raster/RAW、
  小→大→小预览、阶段顺序和复用清零；全量核心回归结果另行记录。
- [x] T3：四端模型、保存/恢复、native setter 与预览/导出缓存身份。
- [x] T4：四端效果工具、精确/精细输入、重置/modified、六语与无障碍语义。
  Android/iOS 在工具名称与操作区无法并排显示时分行；iOS 无障碍大字号的长名称换行。
- [x] T5：选择性复制、预设、撤销/重做、批量冻结/摘要及桌面 Agent 全链。
- [x] T6 本地实现门槛：四端构建、原生/实际 UI、80 个固定 payload 向量。
  完整 IT-15/16 联合验收与设备覆盖仍单列，不由本项代替。

先完成 T1 数值准入，再开放 T3～T5；不得把数值测试代替客户端和实际界面验证。
Windows 保留固定旧 Values 数组，Apple 使用 optional 扩展，Android 旧 CSV/JSON
读取保持兼容；`effects` 分组不能再隐含“所有字段都是旧 vignette/grain 参数”。
IT-12/15 与六语/大字号/读屏及物理设备边界在最终联合验收中单列。

## 当前核心验证边界

本地执行 `bash lutools/test.sh <task-build>`，启用 Metal、DNG SDK、chroma/wavelet，
关闭 OpenMP、Lensfun 和 AI。共 103 项：100 项通过，3 项失败；没有把全量写成通过。
失败为 `geometry_api`、`geometry_raw` 的 RAW native canvas 尺寸断言，以及
`wavelet_exposure_cache` 的完整源缓存命中次数断言。使用上一 ITER-09 构建和同一
RAW/环境重新运行，三项均复现同一错误。该命令导出的 `RAWLAB_TEST_RAW` 使通常
走合成输入的 `geometry_api` 也运行同一个真实 RAW 分支，因此它与 `geometry_raw`
同样失败。上述既有问题不在本项中扩大修复。

新增 atmosphere 数值、45 个独立向量、C ABI 和真实 RAW 用例均通过；v5 schema、
CLI 能力/参数及 43 项 MCP 检查通过。七图质量来源、原图哈希、42 个全尺寸变体和
21 处 100% 对照已绑定实际测试程序，原始照片复核未改动。以上均为本地核心证据，
不代表 Hosted CI 或整项 IT-12/15 已通过。

## 客户端验证边界

四端已执行模型、持久化/传输、native 渲染与真实界面检查。桌面 Agent 与 native
16-bit FINAL 像素一致；iOS/Android 覆盖正负强度、预览/导出和复用 session 清零。
Windows 实际 WPF 58 项检查通过；Android 328 项 JVM 及新增工具/数值输入/六语
大字号 20 项 instrumentation 通过，native atmosphere 检查另行执行通过。
iOS 完整应用的输入、撤销/重做、重新打开和六语最大无障碍字号检查通过。
Mac 完整应用英文输入/历史操作通过，并用真实 EditorView 的原生视图测试补齐
六语、两种字号、两种窗口尺寸共 48 张布局检查。

Android 两项既有 EditorTools 测试仍依赖已变更的标记位置/旧工具入口，在上一
ITER-09 APK 与测试 APK 上复现；不把这次完整旧套件写成全通过。iOS native
本轮执行 buffer 路径，真实 RAW 分支未提供输入而跳过；核心真实 RAW 检查另有结果。
大字号截图、可访问名称和触点可达性不等同于实际 VoiceOver/TalkBack/Narrator
走查。物理设备、Mac Intel 本项原生运行及四端全部功能组合仍需联合门槛确认。
