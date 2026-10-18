# PR #74 文案判定实施台账

## 范围

本台账保留原判定表的 164 个稳定 ID：iOS 50、Windows 86、Android 28。
JSON 来源和原生资源的生成规则见 [README](README.md)。本次不发版。

| 平台 | 对齐 | 拆分复用 | 保留 | 清理候选 | 先修 Mac | 合计 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| iOS | 8 | 8 | 18 | 15 | 1 | 50 |
| Windows | 15 | 16 | 40 | 13 | 2 | 86 |
| Android | 0 | 8 | 20 | 0 | 0 | 28 |
| 合计 | 23 | 32 | 78 | 28 | 3 | 164 |

实施结果：23 条对齐、32 条拆分复用、3 个 Mac 基准修复；原判定为保留的
78 条，其 native key、中文来源及六语有效译文不变。28 个清理候选实际删除
27 个，I04 因真实测试消费者保留。因此实际保留共 79 条，不把 I04 算作已删除。

## Mac 基准

- I16：普通图片解码按 unsupported、I/O、内存不足和通用失败分别提示。
- W05：unsupported 不再限定 RAW，使用“不支持此照片、外观或处理方式。
  请检查文件兼容性和处理设置。”。
- W06：普通 invalid argument 使用“参数或输出路径无效。”；只有输出确实
  指向输入或外观的同路径、符号链接或硬链接时，使用“不能覆盖原始文件。”。

实现位于 `RawLabMac/Sources/Rendering/RenderError.swift`。原生拒绝覆盖的
行为不变；managed 层只准确区分拒绝原因。Mac About 将隐私说明拆成两个完整
句群，与 iOS 共用；中文和日文无额外空格，其他语言用空格拼接，保持原段落内容。

## iOS

| 处理 | 数量 | ID |
| --- | ---: | --- |
| 对齐 | 8 | I06, I07, I10, I11, I12, I15, I32, I38 |
| 拆分复用 | 8 | I09, I18, I21, I27, I23, I44, I35, I50 |
| 保留 | 18 | I02, I03, I05, I08, I13, I14, I17, I19, I22, I29, I25, I39, I40, I31, I34, I49, I46, I48 |
| 清理后删除 | 14 | I01, I20, I24, I26, I28, I30, I33, I36, I37, I41, I42, I43, I45, I47 |
| 清理后保留 | 1 | I04 |
| 先修 Mac | 1 | I16 |

- I09：曝光基准与 HSL 校验失败分开，分别使用对应错误。
- I18：native status 分为输出 I/O、通用 I/O、unsupported、invalid argument、
  原始文件保护和通用处理失败；原生 detail 只加一次“处理失败”前缀。
- I21/I27：复用两个完整隐私句群，不拆译文中的半句。
- I23/I44：导出与继续操作的数量分别来自 selected/pending count，含零张状态。
- I35：根据调整栏当前状态显示展开或收起动作。
- I50：输入框占位文字“长边”、无障碍名称“导出长边像素”、范围说明
  “请输入 1–65535 之间的像素数”分开，保留既有数值校验。
- I04：`RawLab/tests/GeometrySourceHarness.swift` 仍构造
  `EditorError.renderFailed`，因此保留 `Image render failed.` 及其译文。
  `tests/test_localization.py` 明确保护此例外。

主要调用位于 `Core/RawProcessing/Errors/ProcessorError.swift`、
`UI/Export/BatchExportView.swift` 和 `UI/Export/ExportSizePicker.swift`。

## Windows

| 处理 | 数量 | ID |
| --- | ---: | --- |
| 对齐 | 15 | W34, W35, W10, W22, W30, W12, W26, W28, W59, W72, W68, W76, W82, W83, W58 |
| 拆分复用 | 16 | W01, W02, W11, W16, W17, W18, W19, W23, W24, W25, W27, W29, W44, W47, W64, W75 |
| 保留 | 40 | W07, W20, W21, W38, W39, W03, W14, W32, W33, W61, W67, W77, W04, W48, W49, W50, W51, W52, W53, W54, W55, W56, W57, W84, W85, W86, W08, W60, W63, W31, W66, W69, W70, W71, W78, W15, W40, W62, W43, W45 |
| 清理后删除 | 13 | W09, W13, W36, W37, W41, W42, W46, W65, W73, W74, W79, W80, W81 |
| 先修 Mac | 2 | W05, W06 |

- W01：文件名分隔符留在代码中，不作为独立译文。
- W02/W11/W44：完整参数化标题或错误句保留数量、文件名和底层 detail。
- W16–W19：左右方向与完整本地化分组名组合，tooltip 与无障碍名称一致。
- W23：初始化和后续刷新都使用参数化导出数量，disabled 条件不变。
- W24/W25：菜单动作 `JPEG…`、`PNG · 16-bit…` 与保存过滤器的格式名分开。
- W27：目标数进入确认标题，正文说明替换本机调整记录且不改写原始文件；
  文件夹目标包含直接 RAW 与普通图片，不恢复旧 RAW-only 范围。
- W29/W47：直方图和调整栏提示跟随可见状态；直方图外层因无结果或失败隐藏时，
  清除动作提示，避免沿用旧“收起”状态。
- W64：About 版本继续使用 OneWay 绑定，格式串和语言变更一同刷新。
- W75：可见草稿状态和阻止导出的说明分别复用对应共享句。

内部 Group/Tag 的 `输入` 标识不变，界面显示改用 `输入调整`，不改变分组匹配。
主要调用位于 `MainWindow/InteractionExport.cs`、`MainWindow/Tools.cs`、
`MainWindow/Library.cs` 和 `AboutWindow.xaml.cs`。

## Android

| 处理 | 数量 | ID |
| --- | ---: | --- |
| 拆分复用 | 8 | A03, A18, A05, A09, A10, A12, A25, A27 |
| 保留 | 20 | A01, A02, A13, A16, A20, A22, A04, A11, A21, A08, A15, A06, A14, A07, A17, A23, A24, A26, A19, A28 |

- A03：冻结源文件缺失与外观缺失分开，均保持既有全局失败语义。
- A18：未完成数量参数化，不改重试回调和目标范围。
- A05：菜单“移除外观…”与带名称的确认标题分开，删除回调仍使用稳定 ID，
  原始文件不会被删除。
- A09/A10：保留逐文件名、错误 detail 和整数参数；只有 typed invalid-look
  失败追加格式兼容说明，不把 I/O、重命名或删除失败说成文件损坏。
- A12：初始化读取失败和后续保存失败分别携带真实 detail；保存失败后的预览
  不清除详情，失败按钮保持可重试，无照片时也能显示初始化错误。
- A25/A27：参数化“重置{0}”，参数为完整分组译文，不改高级选项和启用条件。

主要调用位于 `editor/storage/EditorEditStore.kt`、`editor/EditorViewModel.kt`、
`editor/render/EditorWork.kt` 和 `editor/ui/EditorPanels.kt`。

## 验证边界

生成器和测试同时检查来源归属、中文查找键、参数类型及六语覆盖；界面截图只复核
中文和英文，其他语言核对文本。所有新增状态消息均有六语译文，不依赖中文回退。

本次不更改 `lutools` native core。native JPEG/PNG 编码器的部分写入失败仍返回
generic processing status，managed 层会显示通用“处理失败”，不宣称已将所有
编码器失败细分成输出存储错误。不能为了给出更具体的提示，把普通输入 I/O 误判为
输出 I/O。

本台账记录实施范围，不代替设备测试和当前提交的托管检查证据；实际验证结果随 PR
记录。设计文档及 `.impeccable` sidecar 只刷新已实现的原生行为和源码路径，未改版式。
