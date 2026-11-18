# RawLab 分层复用与“去重复造轮子”专项整改方案（2026-11-16）

本文基于根 [AGENTS.md](../../../AGENTS.md) 新增的**“分层复用（避免重复造轮子）”**全局原则，对全仓现存的重复实现与手搓通用轮子现象做系统盘点，并给出按投入产出比（ROI）分级的整改路线、许可证约束与验收锚点。整改全部收官后按文档规范移入 `docs/archive/`。

- **状态快照**：2026-11-16 晚，详见各 PR
- **代码基线**：`origin/development` @ `1e10a0152`（2026-11-16；本地工作区对照核实，近百余提交新增的 `ExifToolSession.cs`、`Shared/ExportMetadata.swift` PNG `eXIf` 注入及 `sha256.h` 平台硬件加速均已按最新远端基线纳入）。
- **与既有台账的关系**：
  - [架构评审（2026-11-13）](architecture-review-2026-11-13.md)（`AR-1`～`AR-7`）与 [综合整改任务清单](remediation-plan-2026-11-13.md) 主管跨端缺陷与一致性架构债；
  - 本文聚焦**“仓内已有基础设施未复用”**与**“放着成熟标准库/SDK 不用而手搓底层轮子”**两类工程债。凡与 `AR-*` 交汇的条目（如编辑规格层 `AR-1`、ABI 绑定 `AR-2`、测试拓扑 `AR-6`）均直接复用既有裁定口径，不另立冲突方案。

---

## 1. 选型准则与整改红线

### 1.1 三级复用选型优先级

1. **优先复用项目内已有基础设施与组件**：先检索 `lutools` 核心及已链接三方库（`libjpeg-turbo`、`libtiff`、`lcms2`、`libheif`、`Adobe DNG SDK`、`Lensfun`、`OpenCV`、`wavelib`、`nlohmann/json`）、`Shared/` 规格与公共模块、现有缓存与原子写原语。
2. **次选业界通用、成熟的解决方案**：项目内无合适实现时，优先采用操作系统原生 SDK（ImageIO / CommonCrypto / WIC / BCrypt / Android NDK & Jetpack）、语言标准库，或许可证兼容的主流成熟开源库与标准工具。
3. **最后才考虑最小必要自研**：仅当上述两者在跨端色彩/持久化契约、许可证合规、包体积或热路径性能上确实无法满足时，才做最小必要自研，且必须收敛在单一模块供多端调用。

### 1.2 许可证合规硬约束（选型必查）

项目原创代码采用 `GPL-3.0-only`，并附带针对专有统计组件的 [阿里云 RUM SDK 链接例外](../../../LICENSE-ALIYUN-RUM-EXCEPTION)（详见 [许可与归属说明](../../reference/licensing.md)）。引入外部开源库替换自研轮子时必须遵守：

- **允许直接链接进客户端二进制**：MIT、BSD（2/3-Clause）、Apache-2.0（与 GPLv3 兼容）、ISC、Zlib、MPL-2.0、Public Domain，以及满足源码随附与动态/重链接条款的 LGPL-2.1 / LGPL-3.0。
- **严禁直接静态/动态链接进携带 RUM SDK 的客户端进程**：第三方强传染 **GPLv2-only / GPLv2+ / 无匹配例外的第三方 GPLv3** 库（例如 `Exiv2` 为 GPLv2+，其版权人不提供本项目的 RUM 链接例外，不可直接链入正式客户端进程）。若确需使用此类工具，必须保持独立外部进程隔离并核实分发条款（如当前 Windows 对 `ExifTool` 的进程级调用）。

### 1.3 存量处置三原则（防止“把减法票做成加法票”）

- **P1 主动收敛（真实痛点驱动）**：同时存在性能劣化、跨端功能残缺（如合法输入被手搓解析器误拒）或高频维护同步税的重复轮子，立项替换并删减旧代码。
- **P2 冻结扩张 + 演进触发迁移**：存量代码体积小、已有严密回归测试且线上稳定的自研组件，**禁止复制扩散或继续往上叠特性**；待下次业务需求触达该模块时一并迁移至标准方案，不为纯粹“换库”空转重构。
- **豁免保留（领域核心壁垒）**：属于 RawLab 跨端像素级一致渲染契约或原生交互定位的自研实现，列入 §5 白名单，不作误伤清理。

---

## 2. 整改任务总览（`WR-01` ～ `WR-09`）

| 编号 | 优先级 | 违背层级 | 模块 / 端 | 造轮子现象简述 | 目标收敛方案 | 量级 | 状态 |
|---|---|---|---|---|---|---|---|
| **WR-01** | **P1** | 一级（对内未复用）+ 二级 | Core (`lutools`) | 核心已链 `libjpeg-turbo`，普通 JPEG 导出仍用 `stb_image_write` + `longjmp`；16-bit PNG 导出手写 chunk/CRC/zlib 且固定滤波 `0` | JPEG 统一复用 `libjpeg-turbo` 并从核心生产路径移除 `stb_image_write.h`；PNG 编码改用 `libpng` / `libspng`（支持行滤波与编码期直写 `eXIf`/`iCCP`） | 2～3 天 | ✅ 已修（#426/#431） |
| **WR-02** | **P1** | 一级（对内未复用） | Android + Core | 核心非 Apple 端已链 `lcms2` 且有 `display_image`，Android 却在 Kotlin/JNI 手写 289 行 ICC 解析器（拒收 `A2B0`/`B2A0`）、手写矩阵色彩转换并单独编一份 `stb_image.h` | Android PNG16 解码与 ICC→sRGB 转换下沉至原生层复用 `lcms2`（恢复 LUT 型 ICC 支持），逐步并入 `lutools` 栅格输入层 | 3～4 天 | ✅ 已修（#433） |
| **WR-03** | **P1** | 一级（跨端重复） | Shared + 四端 + CLI | 参数范围/步长/默认值写 5 份（65/83 字段分叉）；传输/重置/持久化四端各一套；Win 手抄 114+ 处 `DllImport`，Android `rawlab_jni.cpp` 自建第二套会话语义 | 衔接 `AR-1`/`AR-2`：以 `Shared/specs/` 单一真源 + 四端/CLI parity 测试收口语义分叉；扩 ABI fixture 覆盖函数签名与枚举，对账 P/Invoke 与 JNI | 持续（并入 AR-1/2） | 🔄 持续（随 AR 触达） |
| **WR-04** | **P2** | 二级（对外未用标准库） | Android + Shared | Android 手写 `StrictJSON.kt` 状态机及数百行 `JSONObject` 手工映射；Swift 手写 `PresetJSONScanner.swift` 递归下降扫描器 | Android 引入 Apache-2.0 许可的严格 JSON 库（如 `Jackson` `STRICT_DUPLICATE_DETECTION`）或经 JNI 复用核心 `nlohmann::json`；Swift 存量扫描器冻结扩张 | 2～3 天 | ✅ 已修（#439：jackson-core 2.18.3 STRICT+嵌套64，−83 行） |
| **WR-05** | **P2** | 一级 + 二级 | Core + Apple + Android | 仓内散落 **4 套**手搓 TIFF IFD / 容器段字节解析器（`dcp_compiler.cpp`、`hdr_metadata.cpp`、`Shared/ExportMetadata.swift`、Android `MpfThumbnails.kt` 等） | 在 `lutools` 收敛单一受界 TIFF/JPEG/PNG 容器读写原语（优先复用已链 `libtiff` / `DNG SDK`），客户端不再新增字节级容器解析；保留 Win `ExifTool` 外部进程隔离 | 3～5 天（按触达推进） | ✅ 本波收口（#440 Core 两处收敛 tiff_ifd；#442 Shared/ExportMetadata 判定"活且必要→冻结"，重复写定案不存在；Android Kotlin 按方案冻结禁新增） |
| **WR-06** | **P2** | 二级（工程基建自造） | Win + Mac/Shared + Core | Win 拆 12 个手写 `Main` 测试 `Exe`；Mac/Shared 数十个 `.sh` 手抄 `swiftc` 源文件数组；`lutools/tests` 复制粘贴 `check()` | 衔接 `AR-6`：Win 纯模型测试迁入 `dotnet test` (`xUnit`)；`Shared`/Mac 模型层建 `Package.swift` 或自动源码清单；C++ 统一轻量测试断言头（如 `doctest`） | 分批（3～5 天） | ✅ C++ 部分闭环（#437 harness+清单对账、#438 *.mm+add_test 绑定；Windows 纯模型测试迁 `dotnet test`（xUnit）与 Mac/Shared SwiftPM 源码清单为后续顺路项） |
| **WR-07** | **P2** | 一级（双端重复） | iOS + Android + Core | iOS (`CameraPTPClient.swift`) 与 Android (`SonyMobileSession.java`) 基于裸 TCP Socket 把 PTP/IP 协议栈与卡上分页核对各写了一遍 | 演进触发：冻结 Swift/Java 双写扩张；下次新增相机协议/机型时将 PTP/IP 报文与状态机下沉至 `lutools`（C++/Rust），移动端仅提供系统 Socket 字节通道 | 演进触发 | ❄️ 冻结（触发条件未到） |
| **WR-08** | **P3** | 二级（框架外叠屋架床） | Mac + Win + Android | 桌面端已接 `Sparkle` / `Velopack`，仍保留拉 GitHub Releases 手拆版本号的 `UpdateChecker` 及厚重外围状态机（状态损坏甚至阻塞修图 `BlocksEditing`） | 桌面端收敛至 `Sparkle` / `Velopack` 单一更新发现源，退役桌面端重复 GitHub API 检查器；解耦更新状态文件故障对修图主流程的阻塞 | 2 天 | ✅（#429 门禁解耦、#435 Mac 退役净−244、#436 Win 退役净−459，WPF 门禁 checks=build hosted 实证+125 套件基线对照：5 红全预存在） |
| **WR-09** | **P3** | 一级 + 二级（局部算子） | Core (`lutools`) | `hdr_resample.h` 手写标量双线性缩放、`hdr_half.h` 手写软 FP16、`sha256.h` 非 Apple/Win 手写压缩轮函数、CLI 手写 `argv` 循环 | 开启 OpenCV/硬件指令集时复用 `cv::resize` 与 NEON/F16C 半精度转换（标量仅作兜底）；冻结 `sha256.h` 标量兜底扩散；CLI 扩复杂子命令时引入 `CLI11`/`argparse` | 1～2 天 | ❄️ 冻结 |

---

## 3. 逐项问题证据、整改设计与验收锚点

### WR-01（P1）核心 JPEG / 16-bit PNG 编码器统一收敛

- **现状与代码位置**：
  1. `lutools/CMakeLists.txt:239` 已无条件为 `sony2fuji_core` 链接 `rawlab_jpeg`（`libjpeg-turbo 3.1.3`），并在 `lutools/src/core/hdr_jpeg.cpp:405` 与 `lutools/src/core/rendered_dng.cpp:447` 成熟使用。
  2. 但普通照片导出 `lutools/src/core/raw_processor.cpp:58,1136-1190` 仍使用单头文件 `lutools/src/core/stb_image_write.h`（71 KB），无 SIMD 加速，且为了支持中途取消与 >2GB 缓冲专门维护了 `JpegWriteContext` + `setjmp`/`std::longjmp` 跳转及 `stb` 偏移补丁。
  3. 同文件的 `ImageEncoder::savePNG`（`lutools/src/core/raw_processor.cpp:1296-1395`）从零手写了 PNG 签名、`IHDR`、`sRGB`、`crc32` 与 `deflate` 循环，每行硬编码滤波器字节 `row[0] = 0`（无 Sub/Paeth 自适应预测，16-bit 渐变图体积显著膨胀），且不支持编码时直接写入 `eXIf` / `iCCP` 块，迫使 Apple 侧在导出后二次流式扫描重写 PNG（`Shared/ExportMetadata.swift`）。
- **整改动作**：
  1. 抽离 `libjpeg-turbo` 扫描线编码公共内部模块，`ImageEncoder::saveJPEG` 改调 `jpeg_write_scanlines` 逐行写入并自然响应 `checkProcessingCancellation()`，保留 `EncodedStagingFile` 原子暂存替换；清理核心生产构建对 `stb_image_write.h` 的依赖。
  2. 引入许可证兼容的 `libspng`（BSD-2-Clause，单源轻量）或系统/静态 `libpng`（libpng license，OpenCV 构建链亦已含）替换 `savePNG` 手写块拼装，开启标准行滤波并支持可选传入 `eXIf` / ICC 块。
- **验收锚点**：
  - `ctest --test-dir lutools/build-macos --output-on-failure` 全绿；
  - 新增/更新导出测试：同源图像 JPEG 导出像素 PSNR 对齐、取消信号在扫描线边界干净中止且不留 `.tmp`、只读/写失败不破坏已有目标文件；16-bit PNG 解码像素逐位无损一致且体积不劣于旧实现。
- **落地 PR**：#426 + #431

---

### WR-02（P1）Android 栅格输入与 16-bit PNG 色彩管理下沉复用 `lcms2`

- **现状与代码位置**：
  - `lutools/CMakeLists.txt:240-242` 在 `if(NOT APPLE)` 分支已直接链接 `rawlab_lcms`（LittleCMS2，MIT），但 Android 在 JVM/JNI 层另建了一整套栅格预检与 PNG16 管线：
    - `RawLabAndroid/app/src/main/java/com/rawlab/android/raster/IccProfiles.kt:12-289`：手写 289 行 ICC 二进制解析器，在 `:131-134` 硬编码拒绝所有含 `A2B0`～`B2D3` 标签的 LUT 型 ICC 配置文件；
    - `RawLabAndroid/app/src/main/cpp/png16_color.h:8-23`：手写 3×3 线性矩阵 + 65536 点一维查找表插值；
    - `RawLabAndroid/app/src/main/cpp/png16_decoder.h:9-14`：单独 `#define STB_IMAGE_IMPLEMENTATION` 编译 `stb_image.h` 解码 PNG16。
- **整改动作**：
  1. 在原生层（`lutools` 栅格输入模块或 JNI 桥接层）直接复用已链接的 `rawlab_lcms`（`cmsOpenProfileFromMem` + `cmsCreateTransform` 转线性/sRGB 16-bit）与标准 PNG 解码（与 WR-01 共用 `libspng`/`libpng`），删除 `png16_color.h`、`png16_decoder.h` 对 `stb_image.h` 的生产依赖及 `IccProfiles.kt` 中的手搓矩阵/TRC 解析限制。
  2. 保持既有产品安全契约不变：128MP 普通栅格上限、32MP PNG16 上限、拒绝透明通道、拒绝把含未知增益图/多视角副图的容器静默降级为普通 SDR。
- **验收锚点**：
  - `RawLabAndroid/tests/png16_test.cpp` 与 `png16_color_test.cpp` 全绿；
  - 新增包含合法 `A2B0` LUT 型 RGB ICC Profile 的 16-bit PNG 用例：整改前被拒收，整改后正确转换至 sRGB 且像素与桌面端 `display_image` 一致；撤掉透明 PNG 或超限尺寸门禁能稳定变红。
- **落地 PR**：#433

---

### WR-03（P1）编辑语义规格单一真源与 C ABI 绑定防漂移（衔接 `AR-1` / `AR-2`）

- **现状与代码位置**：
  - 调整字段定义分散在 `RawLabMac/Sources/Adjustments/Adjustments.swift`、`RawLab/RawLab/Core/Models/EditorAdjustmentRules.swift`、`RawLabAndroid/.../editor/EditorAdjustmentRules.kt`、`RawLabWindows/EditorAdjustmentRules.cs` 与 `lutools/src/cli/edit_recipe.cpp` 共 5 处；`Shared/specs/adjustment-fields-v1.json:12-21` 登记的 83 个字段中有 65 个存在跨端分歧。
  - Windows 在 `RawLabWindows/Native.cs` 等文件中手写 114+ 处 `DllImport`；Android `RawLabAndroid/app/src/main/cpp/rawlab_jni.cpp`（95 KB）在 C ABI 外又包了一层自定义会话与错误语义。
- **整改动作**（严格沿用既有路线图，不另搞跨四端业务代码生成器）：
  1. 按 `remediation-plan-2026-11-13` 既定节奏推进 `Shared/specs/`（字段表 + 传输/重置场景向量 + `versions-v1.json` + `divergences` 棘轮），所有跨端编辑规则变更先改规格与向量再落四端 parity 测试。
  2. 扩展 `Shared/fixtures/generate-abi-layout.sh` 输出导出函数签名摘要与枚举常量表；Windows 镜像测试对 `DllImport` 符号与参数大小做自动对账（新增绑定可评估 `.NET LibraryImport` / `ClangSharp` 生成）；为 `rawlab_jni.cpp` 补齐取消、会话复用与错误码映射契约测试。
- **验收锚点**：`scripts/ci/test_abi_layout.py`、`test_adjustment_fields_spec.py` 及四端 conformance 向量全绿，且 `divergences` 计数单调递减。

---

### WR-04（P2）严格 JSON 校验与持久化编解码去手搓化

- **现状与代码位置**：
  - Android：`RawLabAndroid/app/src/main/java/com/rawlab/android/json/StrictJSON.kt:6-89` 手写词法校验器弥补 `org.json` 宽松语法，并在 `StructuredSettingsCodec.kt`（295 行）、`JournalCodec.kt`、`PresetJSON.kt` 手写大量 `JSONObject` 键值拼装。
  - Swift：`Shared/PresetJSONScanner.swift:25-212` 手写字节级递归下降扫描器以识别根级语法错误与单条目 `hasDuplicateKey`。
  - C++ 核心：`lutools/src/core/lut_contract_json.h` 已展示正确范式——仅用 15 行 `nlohmann::json::parse_event_t` 回调即实现标准语法 + 严格重复键拦截。
- **整改动作**：
  1. **Android**：引入 Apache-2.0 许可的轻量成熟库（如 `com.fasterxml.jackson.core:jackson-core` 开启 `StreamReadFeature.STRICT_DUPLICATE_DETECTION`，或 `jackson-databind` / `kotlinx.serialization` 配合流式判重），或通过 JNI 复用核心 `nlohmann::json` 严格校验入口，替换 `StrictJSON.kt` 并在演进时逐步淘汰手工 `JSONObject` 样板。
  2. **Swift**：存量 `PresetJSONScanner.swift`（212 行，已通过跨端预设 fixture 验证）列入**冻结名单**——无线上缺陷不专门重写，但严禁为其他 JSON 文件再复制或新建手写扫描器；后续若有新严格 JSON 需求，统一走 C ABI 复用核心 `nlohmann::json`。
- **验收锚点**：`Shared/fixtures/adjustment-presets-v1.json` 与 `edit-records-v1.json` 全部正反例（尾逗号、注释、重复键、浮点冒充整数、单坏条目隔离）在 Android 与 Apple 端保持全绿。

---

### WR-05（P2）TIFF / IFD / 容器段二进制解析收敛

- **现状与代码位置**：
  - 仓内目前存在 **4 套独立手写的 TIFF IFD（`II`/`MM` + `42` + 12 字节目录项）及 JPEG/PNG 容器段解析代码**：
    1. `lutools/src/core/dcp_compiler.cpp:66-160`（`struct Reader`）；
    2. `lutools/src/platform/hdr_metadata.cpp:25-125`（`segments()` 与 `struct TIFF`）；
    3. `Shared/ExportMetadata.swift`（PNG `eXIf` 块注入与内嵌 TIFF 尺寸字段原位修补）；
    4. Android `RawLabAndroid/.../raster/MpfThumbnails.kt:21-90`、`RasterContainerValidator.kt`、`C2paJpegMetadata.kt`。
- **整改动作**：
  1. WR-01 落地编码期直写 `eXIf` 后，评估简化或退役 `Shared/ExportMetadata.swift` 的 PNG 事后字节修补路径。
  2. 在 `lutools` 内部提取单一、带严格字节预算与循环目录防护的容器元数据/IFD 辅助模块（或优先调用已链接的 `libtiff` / `Adobe DNG SDK` 接口），供 HDR 元数据、DCP 编译与跨端栅格预检共用；**禁止在 Swift / Kotlin / C# 客户端层新增任何字节级 TIFF/JPEG/PNG 容器解析器**。
  3. Windows `RawLabWindows/ExportMetadata.cs` / `ExifToolSession.cs` 的外部进程 `ExifTool` 路线因满足 GPLv3+RUM 进程隔离且覆盖全品牌 RAW 元数据，予以保留，不改写为手搓二进制写库。
- **验收锚点**：现有畸形 TIFF/EXIF 炸弹回归（循环 IFD、越界偏移、放大预算上限）在统一模块上 100% 保留并通过 `ctest`。

---

### WR-06（P2）测试运行器与构建清单机制标准化（衔接 `AR-6`）

- **现状与代码位置**：
  - Windows：`RawLabWindows/tests/` 下维护了 12 个 `<OutputType>Exe</OutputType>` 工程与 327 行的 `RawLabWindows/tests/Program.cs` 手写 `--flag` 路由及 `Check()` 断言。
  - Mac / Shared：`RawLabMac/build.sh` 与 `RawLabMac/tests/*.sh`（如 `edit-memory.sh:9-17`）手工拼接数十个 `.swift` 路径调 `swiftc`，增删一个源文件需同步修补多份脚本。
  - C++ 核心：`lutools/tests/*.cpp` 各自手写 `int failures = 0; void check(...)`。
- **整改动作**：
  1. **止血规则（立即生效）**：禁止再新建手写 `Main(string[] args)` 的 Windows 测试 `Exe` 工程，禁止再新建手抄源文件长列表的 `.sh` 编译脚本。
  2. **Windows**：纯模型与非 UI 自动化测试分批迁入标准 `Microsoft.NET.Test.Sdk` + `xUnit`（Apache-2.0），使用 `dotnet test` 自动发现与过滤（需要 STA 线程的 WPF 用例使用成熟 `[StaFact]` 扩展）。
  3. **Mac / Shared**：为 `Shared` 及可独立编译的模型层建立 `Package.swift`（SwiftPM）或单一源码清单生成脚本，消除多处手抄 `SOURCES=(...)`。
  4. **C++ 核心**：引入单头文件 `doctest`（MIT）或提取统一的 `lutools/tests/test_harness.h`，新测试统一接入 `CTest` 自动注册。
- **验收锚点**：CI 测试发现对账脚本确认零孤儿测试文件，删除任意一条生产逻辑修复能被 `dotnet test` / `swift test` / `ctest` 直接标红。

---

### WR-07（P2 · 演进触发）相机无线连接协议（PTP/IP）双端实现收敛

- **背景核实**：据 [相机厂商 SDK 调研](../../design/camera-transfer/vendor-sdk-survey.md)，行业内不存在可自由分发且同时覆盖 iOS/Android 无线读取卡内原图的统一官方开源 SDK；`libgphoto2`（LGPL-2.1）在移动端多网卡绑定（Wi-Fi 相机无外网路由时的 `NWConnection` / Android `SocketFactory` 绑定）与体积上适配成本较高，因此采用轻量 PTP/IP 子集本身合理。
- **真正的重复问题**：iOS `RawLab/RawLab/Core/Camera/CameraPTPClient.swift:13-164` 与 Android `RawLabAndroid/.../camera/protocol/SonyMobileSession.java:12-367` 把完全同构的 PTP/IP 报文分帧、握手、事务序号、事件心跳与卡内分页校验逻辑用 Swift 和 Java 各写了一遍。
- **整改动作（演进触发）**：
  - 当前 Sony 实验性连接逻辑若仅做小修则维持现状；
  - **一旦启动新品牌接入（如调研列出的 Canon CCAPI）或重构 Sony PC Remote / 手机模式协议**，必须先在 `lutools`（C++ 或参考 `x3f-bridge` 的 Rust 模块）定义平台无关的协议状态机与报文编解码器，iOS 与 Android 仅实现几行 `ByteChannel` 系统 Socket 适配。

---

### WR-08（P3）桌面自动更新外围自研层瘦身

- **现状与代码位置**：
  - Mac 已集成 `Sparkle`、Windows 已集成 `Velopack`，但两端仍同时保留直接拉取 GitHub Releases API 并手写版本号拆分比对的 `UpdateChecker.swift`、`UpdateChecker.cs`（Android 为 `UpdateRelease.kt`），且外围各自维护了 400+ 行的 `DesktopUpdateController.{swift,cs}` + `UpdateStore` + 备份恢复状态机，甚至在状态存储异常时置位 `BlocksEditing` 锁死照片编辑区。
- **整改动作**：
  1. 保留真正承载业务安全边界的薄层：**自定义签名/包哈希信任校验**（零预算签名方案所需）与 **导出/编辑进行中推迟重启门禁（`UpdateInstallGate`）**。
  2. 桌面端统一以 `Sparkle` Appcast / `Velopack` Feed 作为唯一版本发现源，下线桌面端重复的 GitHub Releases JSON `UpdateChecker`；解耦更新组件状态异常对修图主界面的阻塞（更新坏了只降级为“自动更新不可用，提示手动下载”，绝不锁死用户修图）。
- **验收锚点**：损坏 `UpdateStore` 状态文件后启动应用，编辑器仍可正常打开、调整和导出照片，仅更新入口展示明确降级提示。
- **落地 PR**：WR-08a=#429、WR-08b Mac=#435（净−244）、Win=#436（净−459），双端收官

---

### WR-09（P3 · 按需顺手）核心局部算子与工具链清理

- **`hdr_resample.h` 与 `hdr_half.h`**：在已启用 OpenCV 的客户端构建中优先复用 `cv::resize` 与硬件半精度转换（ARM NEON / x86 F16C 或 OpenCV SIMD），手写标量循环仅作无加速环境兜底。
- **`lutools/src/core/sha256.h`**：Apple（`CommonCrypto`）与 Windows（`BCrypt`）已完成系统硬件 API 切换；保留的非 Apple/Win 标量实现作为无系统加密库环境的唯一兜底，**严禁在仓内任何其他文件再新增手写哈希实现**。
- **CLI 参数解析（`lutools/src/cli/main.cpp`、`agent_commands.cpp`）**：现存参数保持兼容不动；下次新增复杂子命令或选项组合时引入单头文件 `CLI11`（BSD-3-Clause）或 `argparse`（MIT），不再扩写手搓 `argv` 状态布尔量。

---

## 4. 分阶段推进路线

| 阶段 | 包含条目 | 推进策略 | 核心产出与收益 |
|---|---|---|---|
| **Phase 1：高收益减法与能力补齐** | `WR-01`、`WR-02`、`WR-03`（随 AR-1/2） | 独立立项 PR，优先执行 | 核心砍掉生产 `stb_image_write.h` 与手搓低效 PNG 编码；Android PNG16 打通 `lcms2` 补齐 LUT 型 ICC 支持；四端参数规格与 ABI 绑定消除手抄漂移 |
| **Phase 2：解析器与工程基建止血** | `WR-04`、`WR-05`、`WR-06` | 新功能严禁扩写旧轮子 + 按模块分批替换 | Android 淘汰手写 `StrictJSON` 与手工 `JSONObject` 大泥球；TIFF/容器解析收敛至核心单点；Win/Mac 单测告别手抄文件清单与手写 `Main` |
| **Phase 3：演进触发与外围瘦身** | `WR-07`、`WR-08`、`WR-09` | 触达该子系统时顺手收口，不空转大改 | 桌面更新解耦 `BlocksEditing` 并去掉双轨检查；新相机协议下沉核心单份实现；局部算子走硬件/OpenCV 快路径 |

---

## 5. 豁免白名单（合理且必要的自研边界）

以下模块虽为项目自研或按端分别实现，但经第一性原理审视属于产品核心竞争力或合理的平台原生边界，**不列为“重复造轮子”整改对象**：

1. **核心色彩科学与渲染管线**（`lutools/src/core/color_converter.cpp`、`photo_*.cpp`、`dcp_look.cpp`、`lut_applicator.cpp` 及跨语言共享公式头 `lutools/src/gpu/photo_tone_shader.h` 等）：承载 `线性 RAW -> F-Gamut/F-Log2 -> 兼容 LUT` 及 CPU / Metal / GLES 3.1 / D3D11 四路像素级一致契约，通用图像处理库无法替代。
2. **四端原生 UI 视图与平台交互壳**（SwiftUI×2 / Jetpack Compose / WPF）：原生交互体验是产品明确定位，不应引入跨端 UI 框架强行统一；应收敛的是 UI 下方的规格（`Shared/specs/`）与核心 C ABI。
3. **Sigma X3F 独立 Rust 桥（`x3f-bridge`）与 DualDn 硬件推理运行时封装（Core ML / DirectML）**：针对 Foveon/Quattro 特殊传感器数据流与硬件 GPU-only AI 降噪契约的领域专用层，无现成通用替代品。
