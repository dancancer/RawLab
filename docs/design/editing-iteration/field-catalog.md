# I0 字段目录与兼容边界

状态：现有字段来源与版本边界已复核；selective payload 编码及逐端 adapter 尚待冻结。基线为
`development@12cda1c67ddd1c58095831ff12a112fc1356da78`。

本文只登记稳定字段语义、现有来源和格式边界，不新增通用 native DTO，不修改现有
snapshot/Agent/C ABI，也不把尚未接通或尚未完成数值合同的新算法写成已支持。I0 目录完成
不等于四端 adapter、UI、保存、历史或导出已经实现。批次状态和 owner 以
[首批计划](../../integration/editing-iteration/first-batch-plan.md) 与
[迭代总账](../../integration/editing-iteration/README.md) 为准。

## 1. 数据类型和版本先分开

现有设计把数据分成三类。它们可以共享字段语义，不能互换：

| 数据 | 用途 | 当前来源与 I0 边界 |
| --- | --- | --- |
| 本端照片记录（native record） | 恢复一张照片的完整编辑、自动模式、配方上下文和照片身份 | iOS `PhotoEditState`、macOS `PhotoEditState`、Android `EditSettings`、Windows `AdjustmentSnapshot`；缺失新 optional 应按本端兼容规则解析为 identity，不在读取时批量改写旧记录。 |
| 选择性调整 payload | 剪贴板、用户预设、批量同步 | I0 只定义稳定字段 ID、选中集合、逻辑值/模式、外观引用和来源上下文；`payload_version=1` 与 `scope_version=1` 是独立版本，当前代码尚无该 payload 实现。 |
| Agent render recipe | CLI/MCP/处理验收 | 当前 Edit JSON v1～v4 保存解析到目标后的最终 core 值；不能直接作为跨照片 selective payload。 |

版本彼此独立：`payload_version/scope_version` 不等于 Agent `schema_version`、native
record version 或 batch journal version。该分层和版本规则来自
[总技术方案第 2 节](technical-design.md#2-字段与格式兼容先区分三类数据)。

当前 Agent 事实如下：`EditRecipe` 的 JSON schema 独立于 binary request v2，结构包含输入、
曝光/WB/look、tone/detail/HSL/effects/denoise/lens、geometry/perspective 和输出：
[edit_recipe.h](../../../lutools/include/sony2fuji/edit_recipe.h#L8)。解析器只接受
`schema_version` 1～4，旧版本拒绝 v4 组和未知字段：
[edit_recipe.cpp](../../../lutools/src/cli/edit_recipe.cpp#L158)。v4 的 recipe 是最终 core
值，未保存 UI 百分比、master recipe ID 或另一次 look strength 乘法：
[edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L241)。

## 2. 六组 ID 和 reset 所有权

六组 ID 是工作区契约，不是四端内部 enum，也不写入照片参数记录：

| 稳定组 ID | 组内字段/对象 | 组 reset 的范围 | 现有依据 |
| --- | --- | --- | --- |
| `looks` | 外观引用、master recipe、外观强度 | 只重置外观引用/配方选择/强度；其他组的有效调整保留。配方耦合按来源上下文处理。 | [workspace requirements](../editor-workspace/requirements.md?plain=1#L27)；iOS `RawSettings.applyMasterRecipe` [RawSettings.swift](../../../RawLab/RawLab/Core/Models/RawSettings.swift#L243)；macOS [Adjustments.swift](../../../RawLabMac/Sources/Adjustments/Adjustments.swift#L168)。 |
| `light` | 曝光、适用的曝光基准模式、高光、阴影、对比度、legacy S 曲线 | 重置用户曝光、适用模式、明暗、对比度和现有 S 曲线。RAW 自动基准仍按目标解析。 | [workspace requirements](../editor-workspace/requirements.md?plain=1#L31)；Edit JSON tone/exposure [edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L290)。 |
| `color` | 白平衡模式/固定值、饱和度、HSL 24 值 | 重置白平衡模式及自定义值、饱和度和全部 HSL 值。 | [workspace requirements](../editor-workspace/requirements.md?plain=1#L31)；C ABI HSL [sony2fuji_c.h](../../../lutools/include/sony2fuji/ffi/sony2fuji_c.h#L219)。 |
| `effects` | 暗角完整对象、颗粒完整对象 | 重置两个完整对象及辅助参数，不能只把主强度归零。 | [workspace requirements](../editor-workspace/requirements.md?plain=1#L31)；[photo effects config](../../../lutools/include/sony2fuji/ffi/sony2fuji_c.h#L205)。 |
| `detail` | 锐化、legacy/raw/chroma/wavelet 降噪对象 | 重置锐化和完整降噪对象，保留旧记录仍携带的合法降噪语义。 | [workspace requirements](../editor-workspace/requirements.md?plain=1#L31)；macOS legacy 分支 [Adjustments.swift](../../../RawLabMac/Sources/Adjustments/Adjustments.swift#L18)。 |
| `geometry` | crop/rotate/flip/straighten/perspective，以及镜头校正对象 | 几何和镜头均属于此组的 reset 范围；草稿态只改草稿，应用成功后才写 native record。默认 scope 仍排除整个组。 | [workspace requirements](../editor-workspace/requirements.md?plain=1#L31)；Android draft 明确只投影 geometry/lens [AdjustmentDraft.kt](../../../RawLabAndroid/app/src/main/java/com/rawlab/android/editor/AdjustmentDraft.kt#L12)。 |

导航 ID、当前工具、HSL 当前色域、zoom/pan、比较方式和临时草稿不是字段，也不能进入
payload 或 native record 的编辑参数部分。六组是 UI/reset 归属；不要求四端共享内部模型。

## 3. 稳定字段目录

下面的 `field_id` 是 I0 语义 ID。`group` 使用上一节六组；平台字段只作为 adapter
来源，不能把平台字段名、旧数组索引或本地化字符串当作跨端身份。单位和范围同时列出
当前 core/recipe 事实与需要继续核对的 UI 差异。

本表的 core 范围只说明现有 Agent 的最终值边界，并未冻结 selective payload 的 canonical 编码。对比度、饱和度、明暗、S 曲线和锐化必须以 recipe-active/未选字段 sentinel 向量验证逻辑值、物化值与配方上下文的唯一转换；通过前不得把 Agent 字段直接当作可消费的 payload。

表中 `a/b/c` 只为压缩展示多个独立字段 ID；实现和 payload 选择时必须分别登记、分别
校验、分别记录是否包含。只有写成“对象”时才表示一个需要整体 reset/兼容判断的对象。

### 3.1 已有字段：语义可登记，adapter 仍需逐端接线

| `field_id` | group | 当前语义参考、单位和默认 | RAW/配方/复制语义 | 当前来源与待核对项 |
| --- | --- | --- | --- | --- |
| `looks.reference` | `looks` | 稳定外观引用；identity 为无外观/neutral。引用可以是内置外观、用户外观或 master recipe，但引用类型和缺失状态必须保留。 | 复制引用本身及来源上下文；外观缺失必须 blocked/跳过，不能静默替换 neutral。未选外观时不自动选中源 recipe。 | Agent `edits.look.path` 是路径，iOS/Mac/Android/Windows 使用各自 ID/路径字段；跨端稳定引用格式待 I2 adapter 核对。[EditRecipe](../../../lutools/include/sony2fuji/edit_recipe.h#L15)、[RawSettings](../../../RawLab/RawLab/Core/Models/RawSettings.swift#L236)、[Adjustments](../../../RawLabMac/Sources/Adjustments/Adjustments.swift#L27)、[EditSettings](../../../RawLabAndroid/app/src/main/java/com/rawlab/android/settings/EditSettings.kt#L8)、[AdjustmentSnapshot](../../../RawLabWindows/EditPersistence.cs#L6)。 |
| `looks.strength` | `looks` | look factor；Agent v4 `[0,2]`，默认 `1`。各端 UI strength/recipe scale 的具体持久化单位不同。 | 只按目录声明的强度语义应用一次；不能把最终 recipe core 值再乘一次。部分复制不能调用完整 `applyMasterRecipe()`。 | Agent 范围/默认：[edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L290)；iOS recipe scale [RawSettings.swift](../../../RawLab/RawLab/Core/Models/RawSettings.swift#L242)；Mac/Android/Windows 的 UI scale 需要 adapter 逐项确认。 |
| `light.exposure` | `light` | EV。Agent parser 当前接受 `[-20,20]`，各端 UI/模型普遍使用 `[-4,4]` 或同语义窄范围；I0 不把两者静默当成同一合法范围，目标 UI 范围需冻结。默认 `0`。 | 固定用户 EV 可复制；自动曝光基准/测光结果不物化复制，按目标 RAW 重新解析。recipe strength 只按来源上下文规则解释一次。 | Agent parser：[edit_recipe.cpp](../../../lutools/src/cli/edit_recipe.cpp#L194)；iOS：[Sony2FujiProcessor+Helpers.swift](../../../RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor+Helpers.swift#L177)；Android strength 处理：[rawlab_jni.cpp](../../../RawLabAndroid/app/src/main/cpp/rawlab_jni.cpp#L417)；Windows：[Adjustments.cs](../../../RawLabWindows/Adjustments.cs#L195)。 |
| `light.exposure_mode` | `light` | `scene`/`preview`/`sensor`；Agent v4 必须显式输出。native 默认和旧记录缺失默认按端兼容，不由 payload 推测。 | 这是模式字段，不是测光结果；复制模式时保留语义，普通图片按 raster 约束使用 `sensor`。 | C ABI enum：[sony2fuji_c.h](../../../lutools/include/sony2fuji/ffi/sony2fuji_c.h#L124)；Agent 约束：[edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L274)；四端旧缺失默认见 [四端记录演进](technical-design.md?plain=1#L73)。 |
| `light.contrast` | `light` | core multiplier `[0,2]`，identity/default `1`。macOS/Windows UI 是 `[-100,100]` 百分比偏移，Android 是 `[-1,1]` 归一化输入；这些是 adapter 表示，不是 payload 单位。 | 此处是 Agent/core 参考；payload 的逻辑表示与配方上下文待 adapter 冻结，不能直接复制最终 core 值再乘强度；未选字段保留。 | Agent：[edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L293)；iOS 直接写 multiplier：[Sony2FujiProcessor+Helpers.swift](../../../RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor+Helpers.swift#L189)；Mac 转换：[Adjustments.swift](../../../RawLabMac/Sources/Adjustments/Adjustments.swift#L195)；Windows 范围：[Adjustments.cs](../../../RawLabWindows/Adjustments.cs#L49)。 |
| `color.saturation` | `color` | core multiplier `[0,2]`，identity/default `1`。平台 UI 表示有百分比/归一化差异，需 adapter 映射。 | 与 HSL 各色域 saturation 分开；同属颜色组，未选 HSL 时保留其原值。 | Agent：[edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L293)；Mac/Windows 转换同上一行来源。 |
| `light.highlights` | `light` | signed core `[-1,1]`，默认 `0`。Windows/Mac UI 正负方向与 core 符号有转换；不能按 UI 文案直接复制。 | 固定逻辑值可复制；recipe 强度上下文需附带，不能再次缩放。 | Agent：[edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L294)；Mac 符号转换：[Adjustments.swift](../../../RawLabMac/Sources/Adjustments/Adjustments.swift#L209)；Windows：[Adjustments.cs](../../../RawLabWindows/Adjustments.cs#L199)。 |
| `light.shadows` | `light` | signed core `[-1,1]`，默认 `0`；平台 UI 可能是百分比。 | 同 `light.highlights`。 | Agent：[edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L294)；Mac：[Adjustments.swift](../../../RawLabMac/Sources/Adjustments/Adjustments.swift#L211)。 |
| `light.s_curve` | `light` | legacy scalar `[-1,1]`，默认 `0`；仍是旧 S 曲线，不是未来 custom curve。 | 旧 recipe/旧 snapshot 保留原公式；不能把新曲线或近似点列替换旧值。 | Agent：[edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L294)；旧版本拒绝 v4 tone：[edit_recipe_tests.cpp](../../../lutools/tests/edit_recipe_tests.cpp#L220)。 |
| `color.white_balance.mode` | `color` | RAW 模式为 `camera`/`auto`/`temperature`；raster 为 `none`。固定 Kelvin/tint 仅在 `temperature` 模式有效。 | 复制模式和固定值；camera/auto 的目标派生结果不复制。普通图片不可用时返回兼容信息，不伪造 RAW WB。 | Agent/raster 约束：[edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L266)；iOS native 只有 camera/custom 表示：[RawSettings.swift](../../../RawLab/RawLab/Core/Models/RawSettings.swift#L178)；四端 auto 支持待核对。 |
| `color.white_balance.temperature_kelvin` | `color` | Kelvin `[2000,50000]`，Agent temperature 模式必须显式提供 Kelvin；`6500` 仅是 EditRecipe 默认成员/序列化值，不是可省略的 temperature 输入。native RAW 有效默认由目标 as-shot 解析。 | 固定值可复制；as-shot/camera 派生温度不能物化成来源数值。 | Agent parser：[edit_recipe.cpp](../../../lutools/src/cli/edit_recipe.cpp#L205)；字段范围：[edit_recipe_tests.cpp](../../../lutools/tests/edit_recipe_tests.cpp#L267)。 |
| `color.white_balance.tint` | `color` | tint `[-150,150]`，默认 `0`；仅 temperature 模式。 | 同 Kelvin；recipe tint offset 必须保留来源解释，不能与目标 as-shot 结果混成固定值。 | Agent parser：[edit_recipe.cpp](../../../lutools/src/cli/edit_recipe.cpp#L205)；iOS recipe 处理：[RawSettings.swift](../../../RawLab/RawLab/Core/Models/RawSettings.swift#L256)。 |
| `color.hsl.hue.<channel>` | `color` | 8 色域、每项 `[-100,100]`，默认 `0`；索引红、橙、黄、绿、青、蓝、紫、品红。 | 24 个 HSL 值按轴/色域选择；HSL 小数和未选轴/色域必须保持。 | C ABI 数组：[sony2fuji_c.h](../../../lutools/include/sony2fuji/ffi/sony2fuji_c.h#L219)；通道顺序：[requirements.md](../editor-workspace/requirements.md?plain=1#L40)。 |
| `color.hsl.saturation.<channel>` | `color` | 同上，`[-100,100]`，默认 `0`。 | 同上。 | 同上。 |
| `color.hsl.lightness.<channel>` | `color` | 同上，`[-100,100]`，默认 `0`；中文统一为“明度”。 | 同上。 | 同上。 |
| `effects.vignette.amount` | `effects` | `[-100,100]`，默认 `0`。 | 组 reset 必须同时处理暗角辅助参数；关闭主强度不代表辅助值未保存。 | Agent：[edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L298)；iOS object：[RawSettings.swift](../../../RawLab/RawLab/Core/Models/RawSettings.swift#L9)。 |
| `effects.vignette.midpoint` | `effects` | `[0,100]`，默认 `50`。 | 同暗角完整对象语义。 | [edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L298)。 |
| `effects.vignette.roundness` | `effects` | `[-100,100]`，默认 `0`。 | 同暗角完整对象语义。 | [edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L298)。 |
| `effects.vignette.feather` | `effects` | `[0,100]`，默认 `50`。 | 同暗角完整对象语义。 | [edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L299)。 |
| `effects.vignette.highlights` | `effects` | `[0,100]`，默认 `0`。 | 同暗角完整对象语义。 | [edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L299)。 |
| `effects.grain.amount` | `effects` | `[0,100]`，默认 `0`。 | 组 reset 必须同时处理 size/roughness。 | [edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L300)。 |
| `effects.grain.size` | `effects` | `[0,100]`，默认 `25`。 | 同颗粒完整对象语义。 | [edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L300)。 |
| `effects.grain.roughness` | `effects` | `[0,100]`，默认 `50`。 | 同颗粒完整对象语义。 | [edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L300)。 |
| `detail.sharpening` | `detail` | core `[0,2]`，默认 `0`。 | 与降噪独立；不因降噪切换而重置锐化。 | Agent：[edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L295)。 |
| `detail.denoise.raw_level` | `detail` | integer `0..2`，默认 `0`；RAW-only。 | 普通图片必须 blocked/不可用，不把源 RAW 的 FBDD 结果复制到 raster。 | [edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L301)；raster 约束：[edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L274)。 |
| `detail.denoise.chroma_mode` | `detail` | integer `0..2`，默认 `0`；显示色度降噪。 | 旧记录缺失时保持旧端默认；不能把 legacy FBDD 自动改成 wavelet。 | [edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L301)；macOS legacy 注释：[Adjustments.swift](../../../RawLabMac/Sources/Adjustments/Adjustments.swift#L18)。 |
| `detail.denoise.wavelet.enabled` | `detail` | Boolean，默认 `false`。 | 启用状态和 luma/chroma/coarse 是一个完整对象；关闭时辅助值仍可合法保存，但 modified/reset 需按对象语义判断。 | [edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L302)。 |
| `detail.denoise.wavelet.luma` | `detail` | `[0,100]`，默认 `0`。 | 同 wavelet 对象语义。 | [edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L303)。 |
| `detail.denoise.wavelet.chroma` | `detail` | `[0,100]`，默认 `46`。 | 同 wavelet 对象语义。 | [edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L303)。 |
| `detail.denoise.wavelet.coarse` | `detail` | `[0,100]`，默认 `50`。 | 同 wavelet 对象语义。 | [edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L303)。 |
| `geometry.crop.x/y/width/height` | `geometry` | normalized；identity `(0,0,1,1)`。具体端点约束沿现有 geometry validator，不由 payload 自行 clamp。 | 默认 scope 排除；显式选择后按 transformed canvas 语义复制。草稿未应用不可 capture。 | C ABI：[sony2fuji_c.h](../../../lutools/include/sony2fuji/ffi/sony2fuji_c.h#L230)；Android validator：[GeometrySettings.kt](../../../RawLabAndroid/app/src/main/java/com/rawlab/android/geometry/GeometrySettings.kt#L3)。 |
| `geometry.quarter_turns` | `geometry` | integer `0..3`，默认 `0`，顺时针。 | 显式选择才复制；与 crop/flip 的 transformed canvas 顺序一起解释。 | [sony2fuji_c.h](../../../lutools/include/sony2fuji/ffi/sony2fuji_c.h#L238)。 |
| `geometry.flip_horizontal/vertical` | `geometry` | Boolean，默认 `false`，作用于旋转后画布。 | 同 geometry scope。 | [sony2fuji_c.h](../../../lutools/include/sony2fuji/ffi/sony2fuji_c.h#L239)。 |
| `geometry.straighten_degrees` | `geometry` | `[-45,45]` degrees，默认 `0`。 | 同 geometry scope；不能把 preview viewport 坐标当持久化值。 | [sony2fuji_c.h](../../../lutools/include/sony2fuji/ffi/sony2fuji_c.h#L241)。 |
| `geometry.perspective.horizontal/vertical` | `geometry` | `[-1,1]`，默认 `0`。 | 与 geometry 同一 transformed canvas；显式选择才复制。 | [sony2fuji_c.h](../../../lutools/include/sony2fuji/ffi/sony2fuji_c.h#L244)。 |
| `geometry.lens.distortion/tca` | `geometry` | Boolean，默认 `false`；RAW-only。 | `profile_id` 和 auto matching 是请求配置/目标上下文，不复制来源匹配结果；默认 scope 排除。 | Agent：[edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L304)；C ABI profile：[sony2fuji_c.h](../../../lutools/include/sony2fuji/ffi/sony2fuji_c.h#L252)。 |
| `geometry.lens.auto_crop` | `geometry` | Boolean，默认 `true`。 | 仅随明确 lens scope 复制；不能因未选择 lens 把目标 lens 清空。 | [edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L305)。 |
| `geometry.lens.profile_id` | `geometry` | nullable stable catalog ID；`null` 为自动匹配。 | 只保存请求 ID；目标是否匹配、无数据库、无标定等是 prepare 结果，不是 payload 值。 | [edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L306)；C ABI setter：[sony2fuji_c.cpp](../../../lutools/src/ffi/sony2fuji_c.cpp#L1083)。 |

### 3.2 尚未支持的候选新字段

以下名称只登记未来接线位置，不表示当前 core、Agent、四端或 GPU 已支持：

| 候选字段/配置 | 设计状态 | 当前边界 |
| --- | --- | --- |
| `light.black_point` / `light.white_point` | proposed | 方案候选 core `[-1,1]`，不改 LibRaw sensor black/white；当前 request v2/C ABI 没有该配置。 |
| `color.vibrance` | proposed | 方案候选 core `[-1,1]`；当前 photo effects/HSL v1 不包含该字段。 |
| `color.grading.shadows/midtones/highlights` | proposed | 方案候选 hue/saturation；当前无 `color_grading_config`。 |
| `light.curve` | proposed | custom curve 与 legacy `s_curve` 互斥；当前 EditRecipe v4 只有 scalar `s_curve`。 |
| `effects.clarity` / `effects.dehaze` | proposed | 方案候选 core `[-1,1]`；当前无 atmosphere config，算法数值合同和质量集未冻结。 |

来源：[总技术方案 2.1](technical-design.md#21-agent-v5-与-additive-c-abi)。在真实核心、parser/serializer、能力查询、native adapter、保存、Agent 和回归全部接通前，能力响应不得宣告这些字段；旧 schema 和旧像素行为必须保持。

## 4. scope、modified、自动值和配方规则

### 4.1 scope 和未选字段

- 默认 scope 包含通用调整；`geometry` 和 `lens` 默认排除。只有“全部”或显式勾选才进入 payload。未进入 payload 的目标字段原值保留，不能被解释为 identity/reset。
- `capture` 必须深拷贝选中字段、模式、固定值、外观引用和来源上下文；不能引用正在变化的源 snapshot。
- `prepare` 在目标上解析自动项，再合并选中字段，并比较未选组的有效参数；无法无损表示时 `blocked`，不静默 clamp。
- 一个目标的选中字段应作为一个原子 candidate 保存；失败不清理目标旧记录，也不能静默半组提交。

这些规则对应总技术方案的 `capture → prepare → commit`：
[technical-design.md](technical-design.md?plain=1#L110-L120)。I0 只冻结契约，I2 才实现本端事务。

### 4.2 自动值和 RAW/raster

- 相机 WB、自动曝光基准、镜头自动匹配保存模式/请求配置，不保存来源照片的自动派生结果。
- RAW-only 字段在 raster 目标上必须显示不兼容原因；raster recipe 使用 `sensor` exposure、`none` WB，并禁用 raw denoise/lens correction：
  [edit-json.md](../../../lutools/docs/edit-json.md?plain=1#L266-L281)。
- 不同平台当前默认并不完全相同。iOS 缺失 `exposureMode` 解码为 `.scene`：
  [RawSettings.swift](../../../RawLab/RawLab/Core/Models/RawSettings.swift#L333)；Android 缺失旧 CSV mode 为 `0`：
  [EditPersistence.kt](../../../RawLabAndroid/app/src/main/java/com/rawlab/android/settings/EditPersistence.kt#L93)；Windows 新对象默认 exposure mode 为 `1`：
  [Adjustments.cs](../../../RawLabWindows/Adjustments.cs#L57)。I0 不把这些 legacy decode 默认重写成一个跨端 native 默认；payload 模式必须显式定义，兼容 adapter 另行处理。

### 4.3 配方和外观

- 部分复制不能调用完整 `applyMasterRecipe()`，否则会覆盖未选字段。
- 不复制外观时不自动选源配方；需要物化 recipe 固定贡献时，摘要要说明“按实际生效值应用，已包含配方强度”。
- 只有复制完整 recipe 上下文及所有依赖时才保留 recipe identity；否则目标保存独立调整，不声称仍完整选用了源 recipe。
- recipe strength 不能被 Agent 或目标 adapter 二次缩放；旧 recipe 的旧缩放语义必须按各端 `masterRecipeSettingsVersion`/legacy 规则保留。

依据：[technical-design.md](technical-design.md?plain=1#L116-L118)；macOS 旧 recipe 版本迁移在
[Adjustments.swift](../../../RawLabMac/Sources/Adjustments/Adjustments.swift#L320)，iOS recipe
渲染展开在 [RawSettings.swift](../../../RawLab/RawLab/Core/Models/RawSettings.swift#L256)。

## 5. 四端 snapshot、映射和持久化入口

这张表记录现有来源，不代表四端已经实现 I0 payload adapter。

| 端 | native snapshot / 当前字段 | 持久化入口与版本事实 | I0 映射边界 |
| --- | --- | --- | --- |
| iOS | `PhotoEditState(settings: RawSettings, filmID, updatedAt)`；`RawSettings` 有 geometry、denoise、lens、photoEffects、HSL、exposureMode、曝光/contrast/saturation/WB/tone/noise/sharpening/look： [RawSettings.swift](../../../RawLab/RawLab/Core/Models/RawSettings.swift#L211) | `StoreFile` 只有 `records`，没有顶层版本；JSON 读失败报 corrupt，写入原子替换：[EditPersistence.swift](../../../RawLab/RawLab/Core/Persistence/EditPersistence.swift#L46)、[EditPersistence.swift](../../../RawLab/RawLab/Core/Persistence/EditPersistence.swift#L72) | iOS `contrast/saturation` 已接 core multiplier；白平衡 native 表示为 camera/custom，不等于 Agent 的 camera/auto/temperature 三模式，auto 映射待核对。 |
| macOS | `PhotoEditState(settings: Adjustments, filmID, masterRecipeID)`；optional `chromaNoiseReduction/wavelet/photoEffects/hsl/lens/geometry`，并有 `masterRecipeSettingsVersion`：[Adjustments.swift](../../../RawLabMac/Sources/Adjustments/Adjustments.swift#L3) | `Registry.version=1`，只接受 v1：[EditPersistence.swift](../../../RawLabMac/Sources/Editor/Storage/EditPersistence.swift#L23)；旧 recipe 缺版本时在 decode 做兼容迁移：[Adjustments.swift](../../../RawLabMac/Sources/Adjustments/Adjustments.swift#L320) | UI `contrast/saturation/highlights/shadows` 是百分比/偏移，最终 request 才转 core：[Adjustments.swift](../../../RawLabMac/Sources/Adjustments/Adjustments.swift#L195)；payload 不应直接采用 UI 数值。 |
| Android | `EditSettings` 包含 film/strength/曝光/WB/tone/detail/denoise/effects/HSL/recipe/lens/geometry：[EditSettings.kt](../../../RawLabAndroid/app/src/main/java/com/rawlab/android/settings/EditSettings.kt#L8) | 每照片 `EditStore` 读写 `edits.properties`；旧 CSV 接受 `11/15/24/49` 长度：[EditPersistence.kt](../../../RawLabAndroid/app/src/main/java/com/rawlab/android/settings/EditPersistence.kt#L82)。批量 `SettingsCodec` 当前没有版本字段，按 `12/16/25/50/51/52/53` 字段数解码：[SettingsCodec.kt](../../../RawLabAndroid/app/src/main/java/com/rawlab/android/settings/SettingsCodec.kt#L24)；仅外层 `JournalCodec.VERSION=3` 明确版本：[JournalCodec.kt](../../../RawLabAndroid/app/src/main/java/com/rawlab/android/batch/journal/JournalCodec.kt#L21)。每照片记录的 `v2:` 和 SettingsCodec 显式版本仍是待实现方案。 | `contrast/saturation` 是归一化输入，JNI 按 recipe strength 转 request：[rawlab_jni.cpp](../../../RawLabAndroid/app/src/main/cpp/rawlab_jni.cpp#L417)；新曲线/色轮不能插入旧 CSV 中间。 |
| Windows | `AdjustmentSnapshot.Values` 固定数组，附 ExposureMode、CameraWhiteBalance/as-shot、nullable Denoise/Effects/HSL/recipe/Lens/Geometry：[EditPersistence.cs](../../../RawLabWindows/EditPersistence.cs#L6) | `Registry.Version=1` 且只接受 v1：[EditPersistence.cs](../../../RawLabWindows/EditPersistence.cs#L65)；`FromSnapshot` 要求 Values 长度等于旧 `ParameterSpec.All`：[Adjustments.cs](../../../RawLabWindows/Adjustments.cs#L103) | 新字段只能走 nullable extension；不能新增 enum/index 后让旧 Values 全部因长度不符失效。UI 百分比在 request 时转换：[Adjustments.cs](../../../RawLabWindows/Adjustments.cs#L49)。 |

批量任务版本另行维护，不能拿来替代 native/payload version：Android `JournalCodec.VERSION=3`
并拒绝更高版本：[JournalCodec.kt](../../../RawLabAndroid/app/src/main/java/com/rawlab/android/batch/journal/JournalCodec.kt#L21)；macOS/Windows batch job 各有自己的 v1/v2 兼容入口：[BatchExport.swift](../../../RawLabMac/Sources/Export/BatchExport.swift#L33)、[BatchExport.cs](../../../RawLabWindows/BatchExport.cs#L23)。

## 6. C ABI 和 Agent 兼容边界

- request v2 的字段顺序、大小和数值意义保持不变；已有 HSL/photo-effects/wavelet/geometry/lens
  配置是独立 v1 additive ABI：[sony2fuji_c.h](../../../lutools/include/sony2fuji/ffi/sony2fuji_c.h#L134)。
- 新配置必须有独立 `version/struct_size` 和 setter；setter 先校验全部值，错误版本、size、非有限、越界、非法曲线或不支持能力时保留旧 session 状态。新 session 从 identity 开始，复用 session 时请求必须显式设置或清零，不能泄漏上一张照片参数。
- 当前 setter 的 `struct_size` 兼容规则存在 exact/min 差异，新增 ABI 不得自行假定旧规则：wavelet 实现接受 `>= sizeof`，effects/HSL/geometry/perspective/lens 实现要求 exact size，详见 [sony2fuji_c.cpp](../../../lutools/src/ffi/sony2fuji_c.cpp#L1083)。
- Agent v1～v4 的未知字段/旧版本拒绝行为保持；只有 v5 parser、serializer、CLI capability、native preview/export、Mac/Windows AgentRecipe 和实际核心全部接通，才能宣告 v5。当前能力查询仍报告 recipe versions `[1,2,3,4]`：[agent_commands.cpp](../../../lutools/src/cli/agent_commands.cpp#L133)。
- 新算法候选 `black_point/white_point/vibrance/color_grading/custom curve/clarity/dehaze` 目前只是技术方案候选，未写入本目录的“已支持”表；数值合同和固定质量集未冻结前，保持 `proposed/unimplemented`：[technical-design.md](technical-design.md?plain=1#L56-L69)、[technical-design.md](technical-design.md?plain=1#L228)。

## 7. 未来版本、缺字段和失败处理

1. native record 缺失新 optional：解析为本端 identity/default，读取不全量迁移；明确编辑并成功保存时才允许写新字段。
2. selective payload 缺字段：表示“未包含”，目标对应字段保持原值，不解释为 reset。
3. payload/scope/record 未来版本：无法无损解析时 `blocked`/拒绝并保留原记录；不按字段数量猜测新格式，不静默丢弃未知字段。
4. 当前端不支持某字段：prepare 返回字段级不兼容摘要，用户可取消或明确跳过；不得把部分成功报告为全部成功。
5. 外观丢失、目标 RAW/raster 不兼容、自动值无法解析、曲线/范围非法、保存失败均保持目标旧 snapshot；失败项可以单独重试。
6. active draft 未完成预检时，不能 capture、prepare 或冻结逐张导出；保存成功后的 committed snapshot/revision 才是事务输入。

依据：[technical-design.md](technical-design.md?plain=1#L73-L78)、[technical-design.md](technical-design.md?plain=1#L120)、[technical-design.md](technical-design.md?plain=1#L126-L139)。

## 8. 共享文件 owner 与 I0 缺口

当前 owner 以总账为准；本文件由协调者维护；`field_contract` 提供来源核验：

| 范围 | 当前 owner / I0 边界 | 文件 |
| --- | --- | --- |
| I0 字段目录 | 协调者；不写 runtime 或无 consumer 的 fixture | `docs/design/editing-iteration/field-catalog.md` |
| 总账、批次计划、共享语义决定 | 协调者 | `docs/integration/editing-iteration/` |
| 核心 C ABI/EditRecipe/CLI/schema | 协调者保留，后续每个算法批次另派单一 owner | `lutools/include/sony2fuji/`、`lutools/src/ffi/`、`lutools/src/cli/`、对应 schema/tests |
| iOS/Android/Windows 平台入口 | 平台 owner 尚未激活；I0 只记录来源，不改端代码 | 各端 editor、snapshot、storage、bridge、batch |
| Mac S1 | 协调者分配实施 owner；`workspace_s1` 只读核验 | `RawLabMac/Sources/Adjustments/`、对应测试 |
| 共享本地化、构建/CI/依赖 | 协调者保留 | `Shared/strings/`、根构建、`lutools/CMakeLists.txt`、`.github/` |

I0 仍需协调者复核或后续 adapter 冻结的事项：

- `light.exposure` 的 payload 合法范围是 Agent `[-20,20]` 还是 UI 当前 `[-4,4]`；本文保留两者事实，没有猜测统一范围。
- `looks.reference` 的跨端稳定引用格式；当前 Agent 用 path，四端保存 ID/film/LUT/recipe 的形态不同。
- Agent `auto` WB 与四端 native camera/custom/as-shot 表示的精确转换。
- `light` canonical 值与 Mac/Windows 百分比、Android normalized 值的唯一转换方向及舍入误差合同。
- native record 顶层版本：iOS `StoreFile` 当前无版本字段，macOS/Windows 当前 registry v1，Android 依赖旧长度；I0 不擅自改写这些格式。
- 新 payload 的机器可读编码和真正 consumer。I0 不新增 JSON fixture 或无 consumer 的生成代码；各端契约测试在 I0 复核后由协调者按平台派发。
