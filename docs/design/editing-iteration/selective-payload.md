# 选择性调整 payload v1

本文件记录 ITER-03 的逻辑交换格式与 Mac、iOS、Android、Windows adapter 的边界。共享 Swift 实现为
`Shared/AdjustmentTransfer.swift`；跨端解码与有效值向量位于
`Shared/fixtures/adjustment-transfer-v1.json`。其他端接入时消费同一向量，不能直接复制
Mac 的 UI 百分比、native snapshot 或 Agent render recipe。

四端已实现 adapter、真实本机存储事务、编辑入口和普通手势历史。
接入边界见 [iOS 接入计划](../../integration/editing-iteration/ios-selective-transactions-plan.md)与
[Android 接入计划](../../integration/editing-iteration/android-selective-transactions-plan.md)及
[Windows 接入计划](../../integration/editing-iteration/windows-selective-transactions-plan.md)。具体原生验收范围与设备边界留在 PR #134。

## 编码与范围

根对象只有 `payload_version`、`scope_version`、`source`、`values`，两个版本均为 `1`。
未知根字段、来源字段、所选字段、对象成员及未来版本均拒绝，不能忽略后保存一个残缺版本。
`values` 的键就是实际选中集合，空集合不可复制；不包含的键不表示重置。

```json
{
  "payload_version": 1,
  "scope_version": 1,
  "source": {
    "identifier": "source-display-identity",
    "is_raw": true,
    "processing_version": 2,
    "recipe": {
      "id": "hamada_daylight_v2",
      "strength": 0.5,
      "settings_version": 3
    }
  },
  "values": {
    "light.exposure": 1.4,
    "light.contrast": 1.4,
    "color.hsl.hue.red": 12.375
  }
}
```

`source.identifier` 仅用于来源摘要，应用不读取源照片。来源 processing version 为当前
照片的 provenance，不作为可粘贴字段，也不升级目标 processing identity。recipe 上下文
是解释逻辑值所需的 ID、强度和旧缩放版本，不包含源 as-shot、EXIF 或相机校准。

默认和 modified 范围排除 `geometry`；all 明确包含几何与镜头。modified 比较来源逻辑值
和该照片有效默认，包含强度为零时仍保留的逻辑修改；不从撤销历史推断修改状态。

桌面实验性的 AI 降噪尚无 v1 交换字段。AI 依赖目标照片的全尺寸计算与缓存，不能作为
普通降噪值复制。来源启用 AI 时，all/modified 明确阻挡；用户可选择自定义范围复制已有
普通字段。目标启用 AI 时，选择普通降噪字段会报告不兼容，要求先关闭 AI 或取消选择
这些字段；其他选中字段保留目标 AI 状态。历史仍保存完整本端快照，包括 AI 开关，
不保存或复制网络输出。后续支持 AI 请求转移需单独定义目标准备与成功提交合同。

## 字段单位与对象

稳定 ID 沿用[字段目录](field-catalog.md)。v1 的具体编码如下：

| 字段 | 编码 |
| --- | --- |
| `looks.reference` | `{kind,id}`；kind 为 `neutral/builtin/managed/recipe/recipe_lut`。neutral 的 ID 为 null，其他为非空稳定 ID，禁止路径分隔符。 |
| `looks.strength` | `[0,2]` factor。 |
| `light.exposure` | `[-20,20]` EV；目标 native 范围更窄时明确 blocked，不裁切。 |
| `light.contrast`、`color.saturation` | `[0,2]` multiplier，默认 1；Mac 的百分比偏移只在 adapter 中换算。 |
| `light.highlights/shadows/s_curve` | `[-1,1]`；highlights 使用 core 方向，Mac UI 正号在 adapter 中翻转。 |
| `tone.black_point`、`tone.white_point`、`color.vibrance` | `[-100,100]`，默认 0，独立于旧 recipe strength。前两项归 light，鲜艳度归 color；common 默认包含，缺字段保留目标。仅在 native/Agent 边界除以 100。 |
| `light.exposure_mode` | `scene/preview/sensor`；raster 来源只允许 sensor。 |
| `detail.sharpening` | `[0,2]`。 |
| `color.hsl.<axis>.<channel>` | 24 个独立数值，`[-100,100]`，保留小数。 |
| `effects.vignette.*`、`effects.grain.*` | 各辅助值独立；范围沿原字段目录。 |
| `color.white_balance.mode` | `camera/temperature/none`；RAW 不能声明 none，raster 只能声明 none。 |
| `color.white_balance.temperature_kelvin` | 固定 Kelvin `[2000,50000]`，或 null 表示 camera 请求；null 不是来源推算温度。 |
| `color.white_balance.tint` | 固定/相对 tint `[-150,150]`，或 null 表示 camera 请求；存在 recipe 上下文时数值是相对目标 as-shot 的逻辑偏移。 |
| `detail.denoise.raw_level` | `0/1/2`；raster 必须为 0。 |
| `detail.denoise.post_rgb` | `[0,1]`；iOS 旧 `noiseReduction` 请求，与 FBDD 独立。raster 必须为 0；Mac、Android、Windows 只支持 0，非零 blocked。旧 payload 缺字段表示未选。 |
| `detail.denoise.chroma_mode` | null 或 `0/1/2`；null 保留旧算法的缺字段语义。 |
| `detail.denoise.wavelet` | null 或完整 `{enabled,luma,chroma,coarse,preset}` 对象；三个量为 `[0,100]`，preset 为 `detail/clean/custom`。启用状态和辅助值按原生 wavelet 对象一起选择；null 表示旧算法路径。 |
| `geometry.crop.x/y/width/height` | 四个独立归一化数值；正宽高，合并后再次校验矩形在画布内，不能静默移动未选坐标。 |
| `geometry.quarter_turns`、`geometry.flip_horizontal/vertical` | 整数 `0...3`、布尔值。 |
| `geometry.straighten_degrees`、`geometry.perspective.horizontal/vertical` | `[-45,45]` 度、`[-1,1]`。 |
| `geometry.lens.distortion/tca/auto_crop` | 各自独立布尔值。 |
| `geometry.lens.profile_id` | null 为自动匹配；非空 ID 为显式请求，不包含源匹配结果。手动模式未选择 profile 时使用保留字符串 `__rawlab_manual_selection_required__`。 |

保留字符串必须解码回手动模式和空 profile，不能作为实际镜头 ID。该状态可传输关闭的校正请求；若同时启用 distortion 或 TCA，prepare 必须在目标镜头校验器前拒绝。

表中的斜线是多个独立字段的缩写，不是实际 JSON 键。wavelet 明确是完整算法请求对象；
raw 与 chroma 不因选择 wavelet 而被偷偷改写，其有效路径仍由本端既有算法选择规则决定。
普通图片目标只接受默认的 lens 请求：distortion/tca 为 false、auto_crop 为 true、profile_id
为 null。即使畸变/TCA 未启用，显式 profile 或非默认 auto_crop 也必须报告不兼容，不能
通过 raster 的有效值投影把选中请求丢弃后报告未变化。

WB 的模式、Kelvin 和 tint 可独立选择。只选固定 Kelvin/tint 时，目标必须具有可表达
该值的模式；不能为了成功而重置未选的 WB 值。比如固定 Kelvin 粘到 camera 模式而未选
模式时返回不兼容，用户可改选完整 WB 请求。recipe tint 在目标校准上解析；缺少必要
校准或新偏移超出目标范围时 blocked。已存在的 renderer clipping 是旧渲染语义，相同
请求仍为 unchanged；adapter 不给新的不可表达值增加 clamp。

## Capture 与 prepare

capture 冻结独立值；后续来源编辑、切图或源文件删除不影响 payload。草稿先处理，失败
时保留旧剪贴内容。prepare 返回完整 native candidate，不调用多个 UI setter。

recipe 固定贡献按来源强度物化一次；旧 HSL settings version 2 不随强度缩放，version 3
沿现有 HSL renderer 的缩放及边界语义。目标仍有 recipe 时，adapter 反算被选值并校验
实际 request。外观或强度改变解释上下文时，保护未选字段的原有效值；不可表示则 blocked。
不保存旧 HSL 版本的目标端可将完整 legacy 配方反算为当前 renderer 的等效参数；保证的是
本次转移的有效贡献。`source.settings_version` 用于解释来源，不强制改变目标原生持久化格式；
再次复制时必须报告目标实际使用的版本，后续强度编辑遵循目标 renderer。

只有 look、strength、所有耦合 scalar、WB 三项和 HSL 24 项都包含时保留完整 recipe
身份。部分 recipe look 使用独立 `recipe_lut` 引用；Mac native ID 为 `recipe-lut:<id>`，
原生消费者必须将其解析为该配方 LUT，不能重新执行 `applyMasterRecipe()`。

调用方提供目标真实校准/能力、可用外观和 `validateLensRequest`。启用镜头校正时，该
validator 必须确认目标的匹配/标定状态；缺少 validator 直接 blocked。不把相机自动匹配
结果写进 payload，也不在纯模型 adapter 里假装完成原生标定。

Mac 原生预检按需要通过当前 core 解析目标 RAW 的 WB/降噪能力，并验证镜头实际应用结果。
解析只补充候选所需的目标 metadata；条件保存仍比较原 registry 的完整记录与 revision。
检查目标本身不保存，关闭预检也不延续异步提交。

Android adapter 按 JNI 的实际 Float request 校验等价性：contrast/saturation 的偏移转为
逻辑 multiplier，highlights 翻转方向；反算配方参数时保护未选字段，不能用容差或新的
clamp 掩盖不可表示的请求。Android 不支持非零 RAW FBDD 或 post-RGB 降噪；缺省 chroma
和 wavelet 只在其实际 native 请求等价时转换。本端白平衡沿用 native 舍入及目标校准。

Windows 同样比较实际 Float request，保留可准确表达的原始逻辑小数，不将 Float 尾差
写回用户输入。曝光受本端 `[-4,4]` EV 限制；非零 RAW FBDD/post-RGB 请求明确 blocked。
完整 legacy HSL 配方按本端当前 renderer 反算，再次复制报告当前版本。原生预检为每个
RAW 读取目标校准，镜头请求检查实际畸变/TCA 应用结果；任一目标失败仍保留为独立结果。

## 保存、重试和历史

每次操作有独立 ID、冻结 payload/目标/候选。全部目标先 prepare，存在阻挡时默认不写；
只有明确跳过的目标才可排除。单照片使用原子条件保存，比较 identity、原 state 和 revision；
不同目标的保存结果独立，成功项不因另一张失败回滚。

同一操作重试跳过已经成功、unchanged 或明确 skipped 的分量。成功且实际改变才进入
history；保存失败没有成功历史。undo/redo 同时检查存储 revision 和该照片的历史顺序，
不能因后续编辑恰好回到相同数值就越过后续历史。冲突默认取消；明确跳过后只处理其余
分量。逆向保存失败保留可重试状态；单张新编辑只使该照片的 redo 失效。

Mac registry 仍为 version 1，只增加 optional `revisions` 映射；读取旧记录不迁移。
删除一张记录也保留其 revision tombstone，避免删除后重建绕过条件保存。会话结束只释放
clipboard/history，已保存的 native records 继续供重启恢复。

单张键盘 undo/redo 的失败恢复冻结原 transaction、照片和方向；不能在重试时选择新产生的
历史，也不能扩展成整批撤销。批量冲突只标记实际被拒绝的目标，其他等待项不进入 skip
集合。界面显示历史操作错误，不把它写成当前照片未保存；同一操作的缓存成功回执也不能
覆盖随后发生的未保存编辑或几何草稿。

Android 的 Properties registry 增加可选格式标记与逐照片 revision，旧记录读取不重写。
事务读取始终读取磁盘，写入在目录锁和文件锁内比较完整回执；删除也保留 tombstone。
原始 URI 与私有预览副本均纳入来源校验，不能用未变化的副本掩盖原始文件替换。
可用时使用文件描述符的 inode、大小和纳秒修改时间；缺少稳定文件元数据时校验内容摘要。
关闭或过期的预检释放未提交目标副本，成功历史所需资源保留到会话结束或来源重绑定。
新成功回执若在界面接收前已被外部写入替换，当前照片进入明确的重新载入流程；之前
成功项的缓存回执只保留结果，不接管随后撤销或编辑过的界面。

Windows registry 保持 version 1，增加可选 revisions/tombstone；排他文件锁内重新读取、
比较身份/完整记录/revision 后原子写入。文件身份包含同一 Windows handle 返回的卷与
文件索引，旧记录缺少索引时仍兼容读取，新操作的条件回执使用当前物理身份。普通离散
动作和几何 Apply 保存一次；拖动结束才保存，取消恢复原态，文本自身 undo 优先。
成功写入后若当前界面接收回执时发现外部更改，结果仍标记磁盘已保存，并保留错误与
显式重新载入入口；重复重试不能再次接管界面或清除该错误。
