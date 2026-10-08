# 跨相机预设首批工程验证

日期：2026-10-07。基线：`81f98c350b8f76434dcdbaa21331485a1f382651`，在当前分支的未提交工作区验证。

本轮落实 [整体规划](superpowers/specs/2026-10-07-cross-camera-presets-roadmap.md) 的 P0/P1/P2 工程部分：批量诊断、共享成品校验、Mac/Android 持久化外观库和固定样本工具。未提交、推送、修改版本或发布；P3/P4 未实现。没有修改 RAW 显影数学、DCP 阶段算法、shader 或 PHOTO v2 请求布局。

## 结果摘要

| 检查 | 本轮结果 | 证明范围 |
| --- | --- | --- |
| Python | 94/94 通过，0 skipped | 含实际 Canon DCP、native probe、audit 和 reference 工具 |
| macOS arm64 CTest | 10/10 通过 | 成品校验、实际 Metal、Sony/DJI RAW/WB/高光/加速回归 |
| Mac 外观库存储 | 25 项断言通过 | 托管副本、源失效、重启、同名、损坏索引、回滚及中断删除恢复 |
| Mac EditorModel | 12 项断言通过 | 异步导入、失败保持选择、重命名、删除当前外观及恢复 |
| Mac 真实 RAW progressive | 6 项断言通过 | 交互/精确预览、最新参数、直接渲染一致 |
| Mac 既有 UI 模型 | presentation 和 render-scheduling 全部通过 | 内置外观、参数、布局模型、预览调度及导出门禁 |
| Mac 当前 app 构建/导出 | 通过 | macOS 15 arm64 目标，依赖签名；Sony/DJI JPEG smoke 和缺失输入拒绝 |
| Android JVM | 33/33 通过，0 skipped | 库存储、工作副本、状态合并、预览完成与外观操作并发 |
| Android lint/构建 | 通过 | debug APK、测试 APK；保留 12 条既有 lint warning |
| Android API 35 arm64 instrumentation | 36/36 通过 | 实际 JNI、RAW/CUBE/RLOOK、导出/EXIF、相册/缩放、库及 ViewModel 并发 |
| Android 手机界面 | 通过 | 导入后预览，删除源文件，重命名，实际导出，Activity 重建和删除 |
| Android 大屏/深色/大字体 | 通过，1/1 UI 流程 | 2560x1600、240 dpi、font_scale=1.3、深色；不代表平板真机性能 |
| Mac 图形界面完整流程 | NOT REACHED | 能打开 Sony RAW；随后 Mac 锁定，未完成 GUI 导入/重启验收 |
| 独立来源外观参考 | NOT SUPPLIED | Lightroom 启动失败；本地 DNG SDK 只有源码，无现成 reference renderer |
| 受控同场景跨相机质量 | NOT SUPPLIED | 现有 Sony/DJI 来自不同场景，不能证明同场景颜色一致 |

## 来源诊断

`audit` 只读扫描本地 Panasonic/Ricoh 资源，`--verify-compile` 实际临时编译并读取回成品，不以 parser 成功冒充编译成功。

| 项目 | 数量 |
| --- | ---: |
| 文件 | 562 |
| DCP | 484 |
| DCP 实际编译通过 | 388 |
| DCP 缺少 ToneCurve，阻挡 | 96 |
| XMP 结构可读取，但无执行链 | 78 |
| 编译执行失败 | 0 |
| 外观效果未验证 | 562 |

`summary.status=completed` 仅表示扫描完成，read/compile/appearance 独立计数。损坏文件不会中断其他条目，目录扫描失败显式报告且退出 2。XMP 只识别 CRS 语义，foreign namespace 保留 unknown；嵌入表正文和嵌套 payload 不写入报告。

本地报告：`output/cross-camera-p0/panasonic-ricoh-audit.json`、`donor-audit.json`。源文件身份记录于 `source-identities.sha256`。这些本地资源和报告不进入仓库或安装包。

## 首批运行样本

| 来源 | 成品/策略 | 状态 |
| --- | --- | --- |
| Sony ILCE-7CM2 Camera FL | `.rlook` v1，显式 profile tone、black=None、D65，profile EV -0.35 | 实际运行通过，来源外观未验证 |
| RICOH GR III Camera Positive Film | `.rlook` v1，同上，profile EV +0.55 | 实际运行通过，来源外观未验证 |
| Panasonic DC-S5 Camera Vivid | `.rlook` v1，同上，profile EV -0.15 | 实际运行通过，来源外观未验证 |
| 兼容 F-Gamut/F-Log2 PROVIA CUBE | 按已声明合同逐字节保留 | 实际运行通过，不代表原厂 JPEG 等价 |
| display-sRGB identity + `srgb-creative.json` | 尝试 size 129，保留默认 `max_error=0.02` | 烘焙失败，未安装近似成品 |

显示域失败的实测最大通道误差为 `0.4339378178`，mean `0.0003260082`、p99 `0.0030857700`；scene 样本最大 `0.2729358673`，gray 最大 `0.0006203651`。这些是确定性采样的绝对 display-sRGB 通道误差，不是 Delta E 或全局数学界。没有放宽门槛或启用 `allow_approximation`。详见 `output/cross-camera-p0/srgb-preparation.json`。

Sony `DSC06251.ARW` 和 DJI `DJI_20250602164503_0444_D.DNG` 各测试上述 3 个 RLOOK 加 1 个 CUBE，共 8 组。均确认实际 Metal backend；CPU/Metal 在拍摄 WB、4000K、8500K、全部调整与精确渲染下最大差异 1 DN，低于原 2 DN 门槛。FINAL/文件导出忽略 interactive proxy 标记，差异 0 DN。日志为 `output/cross-camera-p0/{sony,dji}-*-native.log`。

新固定样本包括 20 个命名 RGB，覆盖灰阶、skin-like、天空、植被、饱和色、负值与超白；它们不是实测色卡。三份真实 RLOOK 已通过实际 native CPU probe 输出报告，均保留 `reference_status=not_supplied` 和 `appearance.status=unverified`。比较工具拒绝内部伪参考、缺失 renderer 信息、条件/样本不匹配及非法输出；只报告具名样本一致性，不签发相机准确性结论。协议见 [Look Reference Protocol](../lutools/docs/look-reference.md)。

## 客户端行为与回归

- 统一 `sony2fuji_validate_look` 在无 RAW/session/GPU 的情况下使用既有 parser/PHOTO 合同，返回格式和版本；缺失文件、不可兼容文件、坏 payload 明确失败，输出参数失败时清零。
- Mac 使用 Application Support 托管副本及原子 JSON registry；Android 使用 `filesDir/looks`，不依赖会被清理的 RAW cache 或外部 URI。源删除和同名文件不会破坏已导入记录。
- 损坏索引不会按空库覆盖，重复 UUID 被拒绝；不可用外观保留可删除记录。内置 ID、既有相册及编辑参数行为不变。
- Android 单独安排库 I/O，避免 latest-only 预览队列丢弃 startup load；原生读取与库删除共享临界区。旧 render 完成不提前解除正在执行的外观操作。失败导入保留精确预览及导出能力。
- 回归先观测到失败再修复：Mac 中断删除恢复、Android 损坏 registry/无名称 provider、失败导入导致 rendering 卡住、旧 render 完成覆盖操作状态、XMP namespace/payload，以及 reference 报告非法结构。
- Android 新测试最初错从正式 APK 读取测试 RAW，另一个 UI 测试把胶片简称当资产文件名、按节点顺序点到全局菜单；修正测试夹具/选择器后，真实流程与最终 36 项设备测试通过。这些初始失败未算作产品运行通过。

## 复现命令

从仓库根目录执行；本机 native 构建目录为 `lutools/build-macos15-arm64`，Mac 依赖 pkg-config 目录为 `build/macos15-deps/arm64/install/lib/pkgconfig`。其他机器按各端 README 准备依赖与外部 RAW。

```bash
RAWLAB_TEST_CANON_DCP=/path/to/Canon-Standard.dcp \
RAWLAB_DCP_PROBE="$PWD/lutools/build-macos15-arm64/dcp_look_tests" \
  lutools/.venv-lutprep/bin/python -m unittest discover -s lutools/tests -p 'test_*.py' -q
ctest --test-dir lutools/build-macos15-arm64 --output-on-failure

RAWLAB_BUILD_DIR="$PWD/lutools/build-macos15-arm64" bash RawLabMac/tests/look-library.sh
RAWLAB_BUILD_DIR="$PWD/lutools/build-macos15-arm64" bash RawLabMac/tests/look-import-model.sh
RAWLAB_TEST_RAW=/path/to/Sony.ARW RUN_PROGRESSIVE_RENDER=1 \
RAWLAB_BUILD_DIR="$PWD/lutools/build-macos15-arm64" bash RawLabMac/tests/progressive-render.sh
RAWLAB_APP_PATH="$PWD/build/RawLab Cross Camera.app" \
RAWLAB_TEST_RAW=/path/to/Sony.ARW bash RawLabMac/tests/smoke.sh
```

Android 目录：JDK 21、SDK 35、NDK 27.2.12479018，设置 `RAWLAB_TEST_RAW` 后执行 `./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug :app:assembleDebugAndroidTest`。使用专用干净模拟器运行 `:app:connectedDebugAndroidTest`；外部 RAW 只放入测试 APK。最终全量也通过 `adb shell am instrument -w com.rawlab.android.test/androidx.test.runner.AndroidJUnitRunner` 验证，日志为 `output/cross-camera-p0/android-full-instrumentation.log`。手机和大屏截图为同目录 `phone-managed-look.png`、`tablet-managed-look.png`，均已人工查看，没有发现新增控件或文本重叠；大屏单独的 UI 流程日志为 `android-tablet-look-ui.log`。

## 剩余门禁

1. 取得可重现的独立 SDK/来源软件 reference，并冻结视觉验收条件。目前三份成品只能标记可运行/实验性。
2. 提供或拍摄受控同场景配对 RAW。可解码范围不等于全部机型经过色彩校准。
3. 显示域 LUT 在原误差门禁下失败，需另行分析烘焙表示或明确近似策略；不能静默改阈值。
4. Mac 解锁后补 GUI 导入、选择、导出及进程重启验收。Android 已覆盖正常库重建/Activity 重建，但 SAF 第三方 provider 手工往返、物理设备性能、低存储空间及导入中强杀未全面验证。
5. 文件安装与 registry 更新不是一个跨文件事务。导入过程中强杀可能留下未注册的托管文件；常规异常回滚已测。Android 删除中强杀同样可能遗留不可见托管文件，不影响已提交的其他记录。
6. Windows/iOS 未接入新的持久化库或重新构建。XMP 执行、更多 DCP 策略、更多机型及 GLES/D3D11 原生 DCP 加速属于 P3/P4，不能用本轮结果替代。

本地试用产物：`build/RawLab Cross Camera.app`、`RawLabAndroid/app/build/outputs/apk/debug/app-debug.apk`。Android 为 debug 签名，与正式发布签名不同，不能作为 v0.3.0 的覆盖升级包。原始 RAW 和 Adobe profiles 不纳入本次源码或安装包；报告、照片导出和测试截图留在本地忽略目录。
