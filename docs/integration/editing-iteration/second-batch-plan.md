# 第二批：提交事务与三端重置模型

执行基线：`development@361c9949bac16c3883f9f6968f1c95b9937af0d1`。#107、#108、#109 已通过各自最新源提交的独立评审及 CI，并按顺序合入；本批从该合入结果创建独立功能分支。

Spec：`docs/design/editor-workspace/requirements.md`、`technical-design.md` 第 3、4、9 节；迭代及字段来源见 `docs/integration/editing-iteration/README.md`、`docs/design/editing-iteration/field-catalog.md`。

## 共同约束

- 六组 ID 固定 `looks/light/color/effects/detail/geometry`；scope 为组、当前 HSL 色域、全部 HSL、全部。本批不改界面，不把导航 ID 写进存储。
- 各端保持原快照、默认解析、配方缩放和历史 decoder 语义。Mac 的 v2/v3 HSL 版本分支只属于 Mac；其他端没有此字段，不据此新增存储版本或迁移。
- 重置先校验完整输入，再准备候选；无变化、取消、无效、不可表示均不改变原快照。完整对象包含关闭时仍保存的辅助字段。
- 外观独立化清全部外观身份；使用现有本端转换器先捕获有效值，物化后非外观 core Float 与最终 HSL Float 必须相等。无法表示返回 blocked，不以 clamp 修补；HSL 保留原转换已经产生的缩放与 clamp。
- RAW 配方独立化涉及自定义 WB 或非零缩放后相对 tint 时，必须有真实 as-shot 校准（无配方或无关 scope 不因此额外阻挡）；普通图片按已有有效转换处理。不能猜测 6500/0 是真实相机校准。
- 不改 Shared、C ABI、像素算法、现有 codec、批量格式或新 UI；原有配方选择/取消保持行为。只有明确指出的本端文件和测试由各执行者写入，CI 由协调者单一写入。
- 每条线使用独立 worktree。临时报告/日志在主工作区 `.cache/tmp/editing-native-models/`；依赖缓存复用 `.cache/shared/`，源版本/架构/配置绑定的构建产物不能混用。
- 先写能证明行为的失败回归，再实现；执行者报告不代替协调者核验和默认代理独立评审。真实平台未测必须保留缺口。

## Task 0：协调与公共验证入口

Owner：协调者。更新总账、批次计划、明确首批已合入基线与第二批 owner；把字段目录的历史源码行引用固定到其声明的来源提交，避免后续修改使来源锚点漂移。

公共 CI 只由协调者在 iOS 分支接入既有 `presentation.sh` 和 `edit-memory.sh`（后者承载本批 iOS 模型回归）；本批开始时 iOS CI 编译 app/tests，但尚未执行这两组模型测试。Android JVM、Windows editing 和 Mac edit-model 继续利用已有 CI 入口，不降低门槛。

## Task 1：Mac 重置提交事务

Owner：Mac transaction worker。独占 `RawLabMac/Sources/Editor/Model/EditorModel.swift`、`EditorModel+Workflow.swift`、`EditorModel+Geometry.swift`、`RawLabMac/tests/EditModelTests.swift`；必要时同目录增加本端类型，但不得擅自让现有手写 test source list 漏掉依赖。

消费 #109 的 `EditorAdjustmentRules.prepareReset`，增加 model prepare/commit 入口及准备结果。准备固定源 URL、`OriginalFileIdentity`、`editRevision`、完整原始 `PhotoEditState` 与 candidate。提交时逐项核对：源或 revision 变化、同 revision 下 WB 元数据变化都拒绝并要求重新准备。完整原快照比较不能只依靠 revision。

普通组/HSL/全部的提交沿现有普通编辑路径：在 `updatingMetadata` 中一次设置 settings/外观选择，最后一次 `edited()`；无变化不保存不渲染。持久化仍沿现有自动保存，失败保留 dirty 和可见 save error，不引入一套新的存储。`editState()` 可能将 selection ID 转成 `builtin:<filename>`；未改外观时保留原 `selectedFilmID`，不能把存储 ID 直接赋给 UI selection。looks/all 清内部 recipe、外部选择和存储身份。

有几何草稿时，普通 committed 重置被阻挡；geometry 组候选只能同时修改草稿 geometry+lens，不写 committed。全量重置需等草稿应用/放弃后再准备，本批只提供该模型边界，不新增确认弹窗。无变化草稿不产生保存请求。已有草稿 apply 保持先同步保存候选成功、再更新 committed/清草稿/一次精确预览的顺序；失败保留 committed 与草稿。

回归：候选准备纯；无变化零请求；正常提交 scheduler request ID 只增加一次；旧 revision/换源/同 revision 元数据变化拒绝；film/recipe 同步；geometry+lens 组只改草稿；保存失败可重试且旧保存不覆盖候选；原配方和编辑恢复回归。运行受影响 edit-model/geometry draft 模型检查，所链接 native core 必须来自当前 source/configuration；不能把类型检查称为运行通过。

## Task 2：iOS S1 规则与候选

Owner：iOS worker。独占新增 `RawLab/RawLab/Core/Models/EditorAdjustmentRules.swift`、必要的 `RawSettings.swift` 内部纯 helper、`RawLab/RawLab.xcodeproj/project.pbxproj`、`RawLab/tests/EditMemoryTests.swift` 和 `edit-memory.sh`。测试复用已存在 runner，协调者负责接 CI。UI/ViewModel/保存类实现不改；如现有 PhotoEditState initializer 的 nil fallback 会改变外部 filmID，可仅在 EditPersistence.swift 的该值类型增加显式保留身份的复制入口，不改编码或保存行为。

接口使用本端 `PhotoEditState`；返回 candidate 时保留原 `updatedAt`；非外观 scope 必须精确保留 filmID（包括 nil，不能被现有 initializer 的 lutID fallback 改写）。外观 scope 同步处理 `filmID`、`settings.lutID` 与 `masterRecipeID`。context 使用 RAW/raster、有效曝光默认和显式真实相机 temperature/tint（可缺失），不引入跨端 DTO。

复用 `RawSettings.renderedRecipe(cameraTemperature:cameraTint:)` 的 Float strength/HSL 语义。RAW camera + 零相对 tint 沿已有免校准路径；RAW 配方独立化中的 custom 或有效 tint 非零缺校准 blocked，普通 HSL/无配方重置不因此被阻挡。普通图片按 processor `effectiveSettings` 最终 WB/noise/lens 约束比较。已知 recipe ID 沿现有 `MasterRecipe.recipe` 判断，未知 ID blocked；不新增不存在的 recipe version 字段。

回归：六组与完整辅助对象、HSL 色域隔离/小数、完整清身份、全量默认及旧 exposureMode、strength 0/0.5/1/2、真实/缺失 WB、未知 recipe、越界/非有限、JSON round trip、timestamp/未选字段保持。运行 `edit-memory.sh` 和 `presentation.sh`；纯 macOS Swift harness 不代表 iOS simulator/真实 RAW 像素验证。

## Task 3：Android S1 规则与候选

Owner：Android worker。独占新增 `RawLabAndroid/app/src/main/java/com/rawlab/android/editor/EditorAdjustmentRules.kt`、必要的 `settings/EditSettings.kt` 纯 helper、对应 `src/test/java/.../editor/EditorAdjustmentRulesTest.kt`。不改旧 `AdjustmentGroup`（几何/镜头）、工具 ID、UI/VM、JNI 或 codec。

快照继续是不可变 `EditSettings`。context 传目标输入种类、有效默认、真实 as-shot 校准、由现有 catalog 解析的 recipe 或已知 ID 集合；不硬编码另一份 14 配方清单。六组的工具映射保留原 ID；9 只能作为历史 tint alias，不重新出现在可见工具顺序。

物化使用现有 Float 数据和 `recipeScale/renderHsl`；对照 JNI 当前 float 计算顺序：曝光/highlights/shadows 乘 strength；contrast/saturation 的最终值为 `1 + value * strength`；tone/sharpen 不再乘。RAW WB 与 JNI `std::round` 的半数远离零、加相对 tint、原 clamp 一致，不能用 tie-to-even 代替。构造目标 EditSettings 前检查可表示范围，不能触发隐式修补。复制当前公式的测试必须有依据 JNI 的独立向量，不仅重算同一 helper。

回归：六组/旧 ID、完整对象、HSL 小数、strength 四档、WB 正负半数/缺失/custom 零 tint、raster、未选字段、旧 CSV/SettingsCodec round trip。运行 `:app:testDebugUnitTest` 的相应现有与新增类；说明 JVM 与设备/JNI/GLES 验证边界。

## Task 4：Windows S1 规则与候选

Owner：Windows worker。独占新增 `RawLabWindows/EditorAdjustmentRules.cs`、必要的 `Adjustments.cs` 内部纯 helper、`tests/editing/Program.cs` 与 `EditWorkflow.Tests.csproj`。不改 WPF/MainWindow、EditWorkflow 保存行为或 JSON schema。

使用现有完整 `SavedEdit`（Identity、AdjustmentSnapshot、Look）作为候选上下文，保留 OriginalIdentity，复制数组；looks/all 同时清 `Look` 和 `MasterRecipeID`。default 与 AsShot 使用本端事实，候选校验先于 reset。不要调用 `ClearMasterRecipe()` 来假装无损物化；可以在现有捕获/恢复结构中清身份后写已验证字段。

复用 `Adjustments.Request` 与 `RenderHsl` 比较实际 core Float，特别保留 `1 + (float)(percent * scale) / 100` 的运算顺序。raster 以 `PhotoInput.PrepareInputSettings` 加实际 display WB 固定值为准。未知 recipe blocked；不引入 Mac 特有版本或 Windows 不存在的 FBDD 字段。

回归同三端共性，并验证 SavedEdit.Look/Identity、Values 数组隔离、旧 optional 默认、JSON round trip。使用 `.cache/shared/ci-tools/dotnet/8.0.426-osx-arm64/dotnet` 构建纯托管 editing target，再执行生成的 DLL；设置独立临时 `DOTNET_CLI_HOME`、`DOTNET_GENERATE_ASPNET_CERTIFICATE=false`，NuGet 复用 `.cache/shared/dotnet-packages`。自定义输出路径时不要用 `dotnet run`（其启动路径仍指向默认 bin）；使用 build + DLL 执行（不把 Mac 结果说成 Windows/WPF/D3D11 验证）；Windows hosted CI 在后续 PR 验证原生构建与现有平台套件。

## 退出与合入顺序

本批每线独立形成可检查提交、默认代理评审和实际测试结果；公共资源/CI owner 的修改绑定所属分支。当前三个 PR 的合并授权不自动扩展到这些新 PR；完成具体分支后按已有授权边界提交下一步远端操作请求。建议第二批按协调文档、Mac 事务、iOS、Android、Windows 依次集成，源更新影响本线时复核增量。完成纯模型和提交层不等于 ITER-02 的原生 UI 已验收。
