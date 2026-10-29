# Android / Windows HDR 对齐

本设计延续 [HDR 技术设计](technical-design.md) 和
[颜色契约](../../../lutools/docs/hdr-color-contract.md)，将已交付的 Mac / iOS
编辑流程接入 Android 和 Windows，不改变现有 C ABI 的版本和像素语义。

## 共同边界

- 导入手机 gain-map HDR JPEG / HEIF；普通栅格输入继续使用已有解码路径。
  必须先严格探测，只有 `NOT_HDR` 可回退普通 SDR 解码；损坏或不支持的 HDR
  不得静默丢弃 gain map。Apple gain map 与 ISO / XMP 元数据按各自协议解析。
- 共享核心输出方向已应用的扩展线性 sRGB RGB32F HDR / SDR 双图。预览、自动曝光、
  LUT 兼容向导使用有界 PREVIEW；导出重新获取 FINAL。不得用代理图导出。
- 新 HDR 原片默认 HDR 编辑；旧的无 HDR 字段记录仍为 SDR。独立保存 HDR 参数与
  SDR 参数；模式切换、重置、撤销重做遵守现有 Apple 客户端的规则。
- HDR 仅开放曝光、相对色温、相对色偏、对比度、高光、阴影、饱和度及几何。
  不支持的外观、配方和高级算子必须明确禁用或由预检整体拒绝。
- HDR 调整传递使用 v2 和 `hdr_processing_version = 1`，不自动改变目标模式。
  公共逻辑字段可在 SDR / HDR 处理家族间应用；相对 WB 不跨家族转换，含不支持字段
  的请求整体拒绝。默认和“仅已修改”范围排除几何。预设、集合同步和冻结批量包含 HDR 状态。
- HDR JPEG 使用新生成的 ISO / XMP gain map；显式 SDR JPEG、PNG16、rendered DNG
  使用 SDR rendition。保留输入原文件、来源指纹和现有原子发布机制。
- HDR 显示能力与 HDR 编辑能力分离。显示不可用时使用双图中的 SDR rendition；
  不把裁切后的 HDR 八位像素称作 HDR。不把显示器容量写入配方或导出。
- 两端各自使用进程级 128 MiB source-only LRU，以路径和 SHA-256 区分源；lease 保活
  正在使用的不可变双图，淘汰只释放可选缓存，FINAL 前清除可选源缓存。
- HDR 浮点处理复用共享核心 CPU 多核实现，GPU Force 的不支持错误保持真实。
  独立的 GPU 显示路径不代表 HDR 编辑算子已在 GPU 上运行。

## 平台适配

共享文件层引入校验并锁定版本的 libultrahdr、libheif / HEVC 解码器与 ICC 转换依赖；
下载使用主工作区共享缓存，构建结果按平台隔离。Apple 默认文件适配器保持原样，
另设可在 Mac 上运行的便携解码回归，以同一素材核对来源、方向、双图和导出。

Android 在现有 JNI session、取消、预览队列和存储授权模型上增加 HDR pair 封装。
HDR 预览使用 FP16 扩展线性 sRGB 位图，经 Android 硬件加速 Canvas / Window 呈现，
运行时核对 API、显示器 HDR / SDR 比率和 View 的硬件加速状态；不可用时保留
Compose 的 SDR、缩放、前后对比和几何交互。Java 堆中的浮点前后对比图按堆预算
限制尺寸，为新旧发布帧、假色转换和 SDR 模式切换保留空间；原片导出不使用此代理。
MediaStore / SAF 沿用既有发布事务。

Windows 在现有 P/Invoke、冻结快照和 WPF 预览调度上增加 HDR pair 封装。
真实 HDR 呈现需要 FP16 scRGB flip-model swap chain，核对硬件、当前显示器和
颜色空间，并处理跨屏、尺寸变化和设备丢失。WPF 的原生窗口 airspace 不能遮挡
现有交互或辅助信息；未满足条件时明确使用现有 SDR canvas。
裁切交互与八位裁切警告叠层期间也使用 SDR canvas，避免原生窗口遮挡编辑辅助线。
两平台假色和 SDR 兼容预览只改变监看，不更改持久化参数。

## 验收

1. 同一公开 Ultra HDR JPEG 和本地 iPhone HEIC 在共享层及两客户端探测一致；
   预览有界、方向正确、双图存在，损坏元数据不会降级为普通 SDR。
2. 默认状态、旧记录、模式切换、七项参数、几何、重开、撤销重做、重置均有回归。
3. 未编辑 HDR 可直接保存预设；复制、预设、同步默认字段为 HDR 集合；不支持字段
   与相对 WB 跨家族请求在预检中整体拒绝，目标无部分写入。
4. HDR 来源切到 SDR 后，预览、自动曝光与 LUT 向导均使用有界 SDR rendition。
5. 单张与批量导出核对格式、位深、尺寸、方向、可重读的 gain map；代理图不可导出。
6. Android 模拟器和 Windows 可用桌面实际操作受影响界面；记录构建与模型测试结果。
   模拟器、虚拟显示器和 RDP 不作为物理 HDR 显示验收。
7. 原生 pair 的取消、陈旧结果、缓存淘汰和销毁释放有回归；内存准入、线程数、
   CPU 回退与 GPU 强制错误保持明确。真实 HDR 屏幕与 HEVC 硬件性能单独验收。
