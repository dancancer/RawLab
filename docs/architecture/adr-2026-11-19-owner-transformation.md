# ADR-2026-11-19：RawLab Owner 架构与工程改造决策

- **裁定日期**：2026-11-19
- **参考基线**：`origin/development` @ `6f1cbb89d`
- **取代文档**：[整改路线图（2026-11-13）](../archive/architecture/remediation-roadmap-2026-11-13.md)

## 1. 背景与根因（R1–R6）

RawLab 已具备可复用的核心地基（C ABI 布局 fixture、跨端场景向量、依赖钉版与会话取消模型），但工程体系因缺少四层关键结构而陷入高摩擦空转：核心缺少内部渲染管线层、Swift 双端重复实现领域层、各端测试缺乏自动发现与依赖注入、单一真源依赖脆弱的源码正则扫描。以下六个根因驱动本次结构改造：

| # | 根因 | 核心事实与影响 |
|---|---|---|
| R1 | **核心缺内部渲染参数与管线层，C ABI 门面充当引擎** | `lutools/src/ffi/sony2fuji_c.cpp`（3905 行）直接承载 `processImpl` 与 57 个会话成员，9 个内部文件反引 ABI 头，26 个粘性 setter 存在 263 处调用；新增调整需横穿 ABI、FFI、3 个 GPU 后端与 5 个调用方，漏调即串参 |
| R2 | **规格单一真源靠正则对账而非代码消费** | `Shared/specs/adjustment-fields-v1.json` 在客户端运行时零消费者；`scripts/ci/test_adjustment_fields_spec.py`（4825 行、141 处正则）扫描 90 个源文件，仅能拦字面量漂移，排版微调即失效且放过语义漂移 |
| R3 | **同语言双写与上帝类并发膨胀** | iOS/Mac 存在 44 个同名领域类型重复维护；`EditorViewModel.kt`（2132 行/152 函数，JVM 单测零构造）、Windows `MainWindow`（24 个 partial/5610 行/9 个互斥 `choosingX` 布尔）、iOS `ContentView`（103 个 `@State`）导致改动双写、竞态难下沉，“顺手拆”策略已证伪 |
| R4 | **测试体系倒挂与 change-detector 泛滥** | Apple 202 个 shell 测试脚本手抄 886 处源文件路径（113 个无主）；Windows 测试约 1000 处字符串反射私有成员与 70 个手写 `--flag`；Android 474 个仪器测试承担过多逻辑；`test_workflow.py` 用 75 处 `assertIn` 锁死 `ci.yml`；`lutools/tests` 存在 11 个孤儿测试；缺路径即静默跳过形成假绿 |
| R5 | **流程记账吞吐带宽并误触 CI** | 大量 docs/kanban/changelog/ledger 直推 `development`；多份架构方案并存；`affected_platforms.py` 将未分类路径默认判为四端全跑并通过 `cancel-in-progress` 取消代码 CI；约 1789 行自托管 runner 遗留脚本仍随 contracts 执行 |
| R6 | **仓库体积膨胀** | 改造前 HEAD 跟踪 66 个 `.cube`（233MB）与 18MB DJI DNG，pack 达 2.46GiB。平台根目录留存 13 份单次过程文档及大量历史分支/worktree。LUT 授权与外置方式分别见 D1、D2 |

## 2. 推翻或修正的既有决策

| 既有结论 | 修正后裁定 | 依据 |
|---|---|---|
| `f-overall-plan` / `WR-03`：“不做代码生成” | **仅在 protocol 层推翻**：范围、默认值、步长、量化、wire 精度由 `Shared/specs` 生成 Swift / Kotlin / C# 常量并带 `--check` 新鲜度门禁；UI 层仍手写 | 已有 `localization/generate.py --check` 与 ABI layout 生成样板；正则对账维护成本已高于生成器 |
| `AR-5`：“共享规格、不共享代码” | **对 Swift 双端不成立**：iOS 与 Mac 共用 `RawLabKit`（SwiftPM）；四端之间仍保持共享规格边界 | 同语言双写是 R3 的最大来源 |
| `AR-1`：四端各自独立实现 conformance | **参数映射下沉核心**：新增原子编辑态 C ABI（`sony2fuji_apply_params`，载体按 D3），旧 setter 冻结为兼容包装 | 根除粘性 setter 串参整类缺陷，并复用 CLI 既有 recipe 校验 |
| `P3-34` 等“触达时顺手拆” | **改为显式工作包**：设定明确行数与职责退出标准 | FFI 与 `EditorViewModel` 持续膨胀已证伪顺手策略 |
| `AR-7` Windows“纯移动目录分组” | **按 `RawLab.Windows.Core` / App / 单一 xUnit Tests 拆工程**，目录分组随之完成 | 单纯搬移文件无法解除 WPF 耦合与建立发现机制 |
| `AR-2③` 扩展 `jni_session_lock_test.cpp` | **先瘦身 JNI**：将 47 个位置参数收敛为结构化传参，产品语义下沉核心 | 应拆解过厚门面而非加固第二层门面 |
| `WR-05`“TIFF 解析器已收口” | **撤回**：`sony2fuji_c.cpp:620-940` 与 `display_image_windows.cpp:204-600` 两套解析器须迁至 `tiff_ifd.h` | 二者均处理不可信输入 |
| `WR-06` C++ 测试“闭环” | **重做**：改用 `ctest --show-only=json-v1` 加 CMake `LABELS` 与 `test_harness.h`，删掉 194 行 CMake 正则解析器 | 测试清单应由构建系统直接导出 |
| 仓内活台账 + kanban + changelog 流水 | **状态迁至 GitHub Issues / Projects**；验证锚点进 PR 模板；撤修复变红由 CI mutation 校验；carbon 评审仅对 `CODEOWNERS` 高风险目录强制 | 落实“仓库文档只保留长期有效内容”原则 |

## 3. 改造波次（W0–W3）与退出标准

```text
W0（止血与治理） ──▶ W1（构建与测试地基） ──▶ W2（结构重建） ──▶ W3（收敛与删减）
                             └──────────────────────────────▶ W3
```

- **容量规则（D6）**：W1–W3 期间按 **改造 60% / 功能 40%** 分配；触达 R1/R3 热点文件的新功能须等待对应拆分落地，或在同 PR 内先完成拆分。

### W0：止血与治理

| ID | 范围 | 退出标准 |
|---|---|---|
| W0-1 | `.dsh-kanban.json` 移出跟踪并加入 `.gitignore`（保留本地文件）；`affected_platforms.py` 补全 `experiments/`、`tools/`、`docs/` 与根杂物映射，取消未知路径四端全跑默认 | 纯文档/记账变更仅触发 `contracts` |
| W0-2 | 一次性归档平台根目录 13 份过程文档、`reviews/`、`release-artifacts/`、`codebase-review-2026-11-12.md`；移除 `raw_decode_check.swift`、`lutools/build.sh` android 入口与过时 `platform/android/README.md`；`stb_image_write.h` 迁入测试目录 | 仓库根目录与平台根目录仅保留 `README` / `AGENTS` / 长期有效文档 |
| W0-3 | 归档打 tag 后删除自托管 runner 遗留脚本与测试，删去 `docs/process/ci.md` 中 Inactive / Not Enabled 段落 | `docs/process/ci.md` 仅描述现行托管 CI 流程 |
| W0-4 | `test_workflow.py` 仅保留语义不变量（不发布、fork 隔离密钥、SKIP 失败），删除逐字 `assertIn` 锁 | 修改无关 step 名称不再破坏工作流测试 |
| W0-5 | 记录 Fujifilm LUT 与摄影师命名配方的随包分发许可 | 项目负责人已确认现有授权（见 D1） |
| W0-6 | 新增含验证锚点栏的 PR 模板与 `CODEOWNERS`；更新 `AGENTS.md` 与 `integration-workflow.md`（D5）；台账未修/部分修复项迁入 GitHub Issues；按 D7 清理已合并远端分支并开启 auto-delete | 仓内不再维护任务台账流水文件 |

### W1：构建与测试地基

| ID | 端 | 范围 | 退出标准 |
|---|---|---|---|
| W1-1 | Apple | 建立 `Package.swift`（`RawLabKit` 收纳纯 Swift `Shared` 代码及 Swift Testing / XCTest）；iOS 接入本地包；Mac `build.sh` 改用 `swift build`；逐个迁移或归因删除 202 个 shell 测试脚本 | `swift test` 自动发现全部测试；手抄源文件路径 = 0；无主脚本 = 0 |
| W1-2 | Windows | 引入可注入 `AppPaths` 替换 19 处硬编码 `%LOCALAPPDATA%`；切至 internal 构造注入；反射断言改为 internal 访问器 | 测试不触碰真实用户目录；私有成员字符串反射 = 0 |
| W1-3 | Windows | 拆分为 `RawLab.Windows.Core`（`net8.0`，无 WPF 依赖）、App 与单一 xUnit 测试工程（WPF 用例标 `[StaFact]`）；补齐 `Directory.Build.props` / `global.json` / `.sln` / `.editorconfig`；删 `test_windows_inventory.py` | `dotnet test --list-tests` 取代手写 `--flag` 与 Python 对账 |
| W1-4 | Core | Core 改为 OBJECT library 单次编译；新增 `rawlab_add_test()` 与 `LABELS`；`ci.yml` 改用 `ctest -L`；对账改用 `ctest --show-only=json-v1`；37 份自写 `check()` 收敛至 `test_harness.h` | 194 行 CMake 正则解析器删除 |
| W1-5 | Core | 统一 LibRaw 版本锁定与构建目标至 `lutools/cmake/libraw` 及单一 manifest，四端共用 | LibRaw 升级仅修改 1 处 |
| W1-6 | 全仓 | `pyproject.toml` `testpaths` 统一 Python 测试发现；11 个孤儿 `test_*.py` 与 `test_release.py` 纳入 CI 或删除 | Python 孤儿测试 = 0 |
| W1-7 | 全仓 | 建立单一来源版本号，其余位置由生成或校验保证一致 | 发版版本号仅修改 1 处 |
| W1-8 | Core | CPU / Metal edit-JSON 像素 golden 测试接入 Mac `ctest` | 可稳定复现，撤掉任一渲染公式即变红 |

### W2：结构重建

| ID | 端 | 范围 | 退出标准 |
|---|---|---|---|
| W2-1 | Core | 引入 `RenderParams` + `Pipeline`；FFI 仅保留转换与异常边界；`processImpl` 与像素算法按 lens / ai / x3f / geometry 迁入 core；GPU 后端改接 `RenderParams` | `sony2fuji_c.cpp` < 1000 行；core/gpu 零 include ABI 头；W1-8 金标全绿 |
| W2-2 | Core + 四端 | 依 D3 先行基准测试，落地原子编辑态 ABI（`sony2fuji_apply_params`）；冻结旧 setter；四端切换并合并 CLI `EditRecipe::toRequest`；更新 ABI fixture | 生产代码调用旧 setter = 0；ABI fixture 已同步 |
| W2-3 | Core + 四端 | 配方白平衡解析、X3F 中性 `6500/0` 等共享规则下沉至 C ABI；Android JNI 移除 `core/jpeg_mpf.h` 引用并删四端副本 | 四端重复规则副本删除 |
| W2-4 | Android | `nativeProcess` 47 个位置参数与 HDR 68 位 float 数组改为结构化传参（数据类 + 缓存 `fieldID`），JNI 仅负责编组 | JNI 层不再承载产品语义 |
| W2-5 | Android | `EditorViewModel` 按职责拆分为可注入状态持有者；竞态测试迁入 JVM；一并消化 `P3-27..33` | 单文件 < 600 行；JVM 可直接构造并测试竞态 |
| W2-6 | Apple | 领域模型、规则、传输、持久化编解码（配 golden fixture）及批量日志迁入 `RawLabKit`；删除 iOS/Mac 重复实现 | 44 个同名类型中的领域类型仅存一份 |
| W2-7 | iOS | `ContentView` 导航/草稿/弹窗状态抽离至 `@MainActor` coordinator；以测试 seam 替代 4 个改写生产源码的 Python 脚本 | 生产源码不再被测试脚本修改；`@State` 数量显著下降 |
| W2-8 | Windows | 9 个互斥 `choosingX` 收敛为单一工具模式枚举；`Native.Check` 强制会话约束并删源码正则断言；88 个 `DllImport` 归并至单一绑定类并与 `abi-layout-v1.json` 对账 | 源码字面量断言 = 0 |

### W3：收敛与删减

| ID | 范围 | 退出标准 |
|---|---|---|
| W3-1 | `Shared/specs` 生成 Swift（进 `RawLabKit`）/ Kotlin / C# protocol 层常量并带 `--check`；三端补齐运行时 JSON 加载与对象断言；删除 `test_adjustment_fields_spec.py` 正则层 | spec JSON 在三种客户端语言均有生产消费者；`divergent_fields` 单调下降并设到期轮次 |
| W3-2 | 推广 `photo_tone_shader.h` 模板模式，消除 F-Log2 常量与高光/阴影公式多份副本 | 每个渲染公式仅存一份源定义 |
| W3-3 | 剩余两套 TIFF 解析器迁入 `tiff_ifd.h` | 畸形输入回归用例全部保留并通过 |
| W3-4 | UI 测试收缩为每端约 10–20 条 robot 层冒烟用例，几何断言下沉单测；Android 字面量测试改为行为断言 | UI 改版不再触发批量测试追尾提交 |
| W3-5 | DJI DNG 迁至 `.cache/shared`；压缩 11MB 文档图片；`.cube`（233MB）迁至 Git LFS 或 Release 资产 + SHA-256 校验（历史重写按 D2 延后评估） | HEAD 检出体积 < 150MB |

## 4. 明确不做（Non-Goals）

- **不更换 UI 框架**、不做 WPF 全量 MVVM 重写、不自建通用 GPU HAL：保持四端原生体验，GPU 后端仅共享 `RenderParams`。
- **不重命名 `sony2fuji_*` ABI 与命名空间**：645 个文件存在 8768 处引用，零用户收益；改为补充命名对照说明（仓库 `rawtools` / 产品 `RawLab` / 核心目录 `lutools` / 库 `sony2fuji`）。
- **不拆 Android Gradle 多模块**：当前瓶颈在依赖注入而非模块边界。
- **不触碰既有稳定基座**：`x3f-sys` vendoring、LibRaw 锚点补丁、ABI layout fixture、传输/重置场景向量、本地化生成、Velopack / Sparkle / ExifTool 进程隔离、`WR-07` 冻结、GPL + RUM 例外结构。
- **不在仓内新建大台账**：本 ADR 为唯一入库架构决策记录，执行期进度与任务跟踪统一留驻 GitHub Issues。

## 5. 关键裁定登记（D1–D7，2026-11-19）

| # | 议题 | 最终裁定 | 落地约束 |
|---|---|---|---|
| D1 | Fujifilm LUT、摄影师命名配方与第三方改编 LUT 的分发许可 | **已获授权随 RawLab 分发** | 随包保留来源与署名，见 [LUT 说明](../luts/README.md) |
| D2 | 仓库体积治理范围 | **仅治理 HEAD**，LUT 与测试 DNG 存在 `assets-v1`，由清单校验 SHA-256 | 历史重写留待 W3 之后协调所有协作者另行评估 |
| D3 | 原子编辑态 ABI 载体 | **规范 recipe JSON** | 复用核心既有 recipe 校验；**性能门禁**：W2-2 实施前实测每帧解析与转换开销，若交互预览路径不可接受则退回版本化 C 结构体，JSON 保留给持久化与批量 |
| D4 | 代码生成边界 | **仅限 protocol 层** | 范围、默认值、步长、量化、wire 精度自动生成并带 `--check` 门禁；UI 层坚持手写（W3-1） |
| D5 | 台账与评审制度 | **状态迁至 GitHub Issues/Projects；carbon 仅对 `CODEOWNERS` 高风险目录强制** | 同步修订 `AGENTS.md` 与 `docs/process/integration-workflow.md`（W0-6） |
| D6 | 改造与功能容量配比 | **改造 60% / 功能 40%** | 触达 R1/R3 热点文件的新功能须先完成或同 PR 完成对应拆分 |
| D7 | 远端分支清理 | **清理已合并远端分支并开启 auto-delete head branch** | 保留 `codex/*`、`main`、`development`、`release/*` 及全部未合并分支；执行前核对待删清单 |
